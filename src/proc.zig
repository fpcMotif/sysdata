//! Child processes with a deadline. A cleanup tool must never be hostage to
//! a child that waits on a lock or a prompt nobody will answer.
//!
//! `fork`, `exec` and a poll: nothing here allocates between the fork and
//! the exec, the child's stdin is /dev/null so a prompting tool gets EOF,
//! and past its deadline the child is killed and whatever it printed so
//! far is returned, without waiting for grandchildren holding the pipe.
const std = @import("std");
const clock = @import("clock.zig");
const walker = @import("walker.zig");
const sys = @import("sys.zig");

pub const probe_timeout_ms: u32 = 20_000;
pub const clean_timeout_ms: u32 = 600_000;

pub const Output = struct {
    /// Exit status, or the signal number negated when a signal ended it.
    status: i32,
    /// Everything the child wrote; owned by the caller.
    text: []u8,
    timed_out: bool,

    pub fn ok(out: *const Output) bool {
        return out.status == 0 and !out.timed_out;
    }
};

/// Runs `program` with stdin at `/dev/null`, collecting stdout (and stderr
/// when `merge_stderr`). Past `timeout_ms` the child is killed and the
/// output so far is returned.
pub fn run(
    gpa: std.mem.Allocator,
    program: []const u8,
    args: []const []const u8,
    merge_stderr: bool,
    timeout_ms: u32,
) !Output {
    var env_state = std.heap.ArenaAllocator.init(gpa);
    defer env_state.deinit();
    const env = try childEnv(env_state.allocator());

    var argv_state = std.heap.ArenaAllocator.init(gpa);
    defer argv_state.deinit();
    const argv = try argv_state.allocator().allocSentinel(?[*:0]const u8, args.len + 1, null);
    argv[0] = try std.fmt.allocPrintSentinel(argv_state.allocator(), "{s}", .{program}, 0);
    for (args, 0..) |a, i| {
        argv[i + 1] = try std.fmt.allocPrintSentinel(argv_state.allocator(), "{s}", .{a}, 0);
    }
    const devnull = devnull_fd();
    defer if (devnull > 2) sys.close(devnull);

    const out_pipe = sys.pipe() catch return error.CannotPipe;
    var err_pipe: sys.Pipe = .{ -1, -1 };
    if (merge_stderr) {
        err_pipe = sys.pipe() catch {
            sys.close(out_pipe[0]);
            sys.close(out_pipe[1]);
            return error.CannotPipe;
        };
    }

    const pid = sys.fork() catch {
        sys.close(out_pipe[0]);
        sys.close(out_pipe[1]);
        if (merge_stderr) {
            sys.close(err_pipe[0]);
            sys.close(err_pipe[1]);
        }
        return error.CannotFork;
    };
    if (pid == 0) {
        // The child: no allocations between here and exec.
        _ = std.c.dup2(out_pipe[1], 1);
        _ = std.c.dup2(if (merge_stderr) err_pipe[1] else devnull, 2);
        _ = std.c.dup2(devnull, 0);
        _ = std.c.execve(argv[0].?, argv.ptr, env.ptr);
        std.c._exit(127);
    }
    sys.close(out_pipe[1]);
    if (merge_stderr) sys.close(err_pipe[1]);

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    var status: u32 = 0;
    var timed_out = false;
    const deadline = clock.monotonicMs() + timeout_ms;
    while (true) {
        drain(gpa, out_pipe[0], &text);
        if (merge_stderr) drain(gpa, err_pipe[0], &text);
        if (sys.waitpid(pid, true)) |result| {
            status = result.status;
            break;
        }
        if (clock.monotonicMs() >= deadline) {
            timed_out = true;
            std.posix.kill(pid, std.posix.SIG.KILL) catch {};
            const last = sys.waitpid(pid, false) orelse break;
            status = last.status;
            break;
        }
        clock.sleepMs(15);
    }
    // Whatever the pipes still held, now that the child is gone.
    drain(gpa, out_pipe[0], &text);
    if (merge_stderr) drain(gpa, err_pipe[0], &text);
    sys.close(out_pipe[0]);
    if (merge_stderr) sys.close(err_pipe[0]);

    const W = std.c.W;
    const decoded: i32 = if (W.IFEXITED(status))
        W.EXITSTATUS(status)
    else if (W.IFSIGNALED(status))
        -@as(i32, @intCast(status & 0o177))
    else
        -1;
    return .{ .status = decoded, .text = try text.toOwnedSlice(gpa), .timed_out = timed_out };
}

/// Everything the pipe holds now. `poll` first: a plain read on a pipe the
/// child still holds would block until it writes or exits.
fn drain(gpa: std.mem.Allocator, fd: sys.fd_t, into: *std.ArrayList(u8)) void {
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        var fds = [1]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, 0) catch return;
        if (ready == 0) return;
        const n = std.posix.read(fd, &chunk) catch return;
        if (n == 0) return;
        into.appendSlice(gpa, chunk[0..n]) catch return;
    }
}

fn devnull_fd() sys.fd_t {
    const fd = std.c.open("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true });
    return if (fd < 0) 0 else fd;
}

/// The parent's environment with the login-shell PATH this app resolves
/// and Homebrew's auto-update turned off. The list is null-terminated, as
/// `execve` wants.
fn childEnv(a: std.mem.Allocator) ![:null]?[*:0]const u8 {
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    errdefer list.deinit(a);
    if (walker.env("HOME")) |home_value| {
        try list.append(a, try std.fmt.allocPrintSentinel(a, "HOME={s}", .{home_value}, 0));
    }
    var path_buf: std.ArrayList(u8) = .empty;    defer path_buf.deinit(a);
    var dirs: std.ArrayList([]const u8) = .empty;
    defer {
        for (dirs.items) |d| a.free(d);
        dirs.deinit(a);
    }
    try searchPath(a, home(), &dirs);
    for (dirs.items, 0..) |dir, i| {
        if (i > 0) try path_buf.append(a, ':');
        try path_buf.appendSlice(a, dir);
    }
    try list.append(a, try std.fmt.allocPrintSentinel(a, "PATH={s}", .{path_buf.items}, 0));
    try list.append(a, try std.fmt.allocPrintSentinel(a, "HOMEBREW_NO_AUTO_UPDATE=1", .{}, 0));
    try list.append(a, try std.fmt.allocPrintSentinel(a, "LC_CTYPE=UTF-8", .{}, 0));
    if (walker.env("TZ")) |tz| {
        try list.append(a, try std.fmt.allocPrintSentinel(a, "TZ={s}", .{tz}, 0));
    }
    if (walker.env("ANDROID_HOME")) |android| {
        try list.append(a, try std.fmt.allocPrintSentinel(a, "ANDROID_HOME={s}", .{android}, 0));
    }
    return list.toOwnedSliceSentinel(a, null);
}

/// Runs a probe command and returns its stdout only when it succeeded.
pub fn probe(gpa: std.mem.Allocator, program: []const u8, args: []const []const u8) ?[]u8 {
    var out = run(gpa, program, args, false, probe_timeout_ms) catch return null;
    defer gpa.free(out.text);
    if (!out.ok()) return null;
    return gpa.dupe(u8, out.text) catch null;
}

/// Runs `script` as root through the standard administrator prompt.
/// Dismissing the prompt makes osascript fail with `(-128)`.
pub fn runPrivileged(gpa: std.mem.Allocator, script: []const u8) !Output {
    var escaped: std.ArrayList(u8) = .empty;
    defer escaped.deinit(gpa);
    for (script) |c| {
        if (c == '\\' or c == '"') try escaped.append(gpa, '\\');
        try escaped.append(gpa, c);
    }
    const source = try std.fmt.allocPrint(
        gpa,
        "do shell script \"{s}\" with administrator privileges",
        .{escaped.items},
    );
    defer gpa.free(source);
    return run(gpa, "/usr/bin/osascript", &.{"-e", source}, true, clean_timeout_ms);
}

pub fn wasCancelled(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "(-128)") != null;
}

/// Removes osascript's "12:345: execution error: " prefix.
/// Allocation failure falls back to a static string: use an arena.
pub fn describeFailure(gpa: std.mem.Allocator, command: []const u8, out: *const Output) []const u8 {
    const trimmed = std.mem.trim(u8, out.text, " \t\r\n");
    var body = trimmed;
    if (std.mem.indexOf(u8, trimmed, ": execution error: ")) |at| {
        var digits_colons = true;
        for (trimmed[0..at]) |c| {
            if (!std.ascii.isDigit(c) and c != ':') {
                digits_colons = false;
                break;
            }
        }
        if (digits_colons) body = trimmed[at + ": execution error: ".len ..];
    }
    if (out.timed_out) {
        return std.fmt.allocPrint(
            gpa,
            "{s} was still running after {d} minutes, so it was stopped. Another program may hold its lock.",
            .{ command, clean_timeout_ms / 60_000 },
        ) catch "failed";
    }
    if (body.len == 0) {
        return std.fmt.allocPrint(gpa, "{s} failed (exit {d})", .{ command, out.status }) catch "failed";
    }
    return gpa.dupe(u8, body) catch "failed";
}

/// `'…'` quoting for a POSIX shell.
pub fn quote(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, '\'');
    for (path) |c| {
        if (c == '\'') {
            try out.appendSlice(gpa, "'\\''");
        } else {
            try out.append(gpa, c);
        }
    }
    try out.append(gpa, '\'');
    return out.toOwnedSlice(gpa);
}

pub fn home() []const u8 {
    return walker.env("HOME") orelse "/";
}

/// Finds a tool the way a login shell would. A GUI app inherits almost no
/// PATH, and "not looked for" must not read as "not installed".
pub fn which(gpa: std.mem.Allocator, name: []const u8, path: []const []const u8) ?[]u8 {
    for (path) |dir| {
        const candidate = std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name }) catch continue;
        defer gpa.free(candidate);
        const info = walker.lstat(candidate) orelse continue;
        if (!info.isRegular()) continue;
        if (info.mode & 0o111 != 0) return gpa.dupe(u8, candidate) catch null;
    }
    return null;
}

/// The directories a login shell would search, home entries first.
/// `out` is filled with slices allocated from `gpa`; the caller owns them.
pub fn searchPath(gpa: std.mem.Allocator, home_dir: []const u8, out: *std.ArrayList([]const u8)) !void {
    const fixed = [_][]const u8{
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    };
    for (fixed) |dir| try out.append(gpa, try gpa.dupe(u8, dir));
    const home_subs = [_][]const u8{
        ".cargo/bin",            ".local/bin",                      "Library/pnpm",
        ".volta/bin",             ".asdf/shims",                     ".local/share/mise/shims",
        "Library/Application Support/fnm/aliases/default/bin", ".bun/bin",
        ".deno/bin",
    };
    for (home_subs) |sub| {
        try out.append(gpa, try std.fmt.allocPrint(gpa, "{s}/{s}", .{ home_dir, sub }));
    }
    // nvm's chosen version, from the alias file itself.
    const alias_path = try std.fmt.allocPrint(gpa, "{s}/.nvm/alias/default", .{home_dir});
    defer gpa.free(alias_path);
    if (sys.readFile(gpa, alias_path, 64)) |raw| {
        defer gpa.free(raw);
        const version = std.mem.trim(u8, raw, " \t\r\n");
        if (version.len > 0) {
            const prefix: []const u8 = if (version[0] == 'v') "" else "v";
            try out.append(gpa, try std.fmt.allocPrint(gpa, "{s}/.nvm/versions/node/{s}{s}/bin", .{ home_dir, prefix, version }));
        }
    } else |_| {}
    if (walker.env("PATH")) |inherited| {
        var it = std.mem.splitScalar(u8, inherited, ':');
        while (it.next()) |dir| {
            if (dir.len > 0) try out.append(gpa, try gpa.dupe(u8, dir));
        }
    }
    // Deduplicate, keeping the first of each.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);
    var keep: usize = 0;
    for (out.items) |dir| {
        const gop = try seen.getOrPut(gpa, dir);
        if (!gop.found_existing) {
            out.items[keep] = dir;
            keep += 1;
        } else {
            gpa.free(dir);
        }
    }
    out.shrinkRetainingCapacity(keep);
}

test "a wedged child is killed at its deadline" {
    const out = try run(std.testing.allocator, "/bin/sleep", &.{"30"}, true, 200);
    defer std.testing.allocator.free(out.text);
    try std.testing.expect(out.timed_out);
    try std.testing.expect(!out.ok());
}

test "output and status are collected" {
    const gpa = std.testing.allocator;
    {
        const out = try run(gpa, "/bin/sh", &.{ "-c", "echo out; echo err >&2; exit 3" }, true, 5_000);
        defer gpa.free(out.text);
        try std.testing.expectEqual(@as(i32, 3), out.status);
        try std.testing.expect(std.mem.indexOf(u8, out.text, "out") != null);
        try std.testing.expect(std.mem.indexOf(u8, out.text, "err") != null);
    }
    {
        const out = try run(gpa, "/bin/sh", &.{ "-c", "echo err >&2" }, false, 5_000);
        defer gpa.free(out.text);
        try std.testing.expect(out.ok());
        try std.testing.expectEqual(@as(usize, 0), out.text.len);
    }
}

test "a prompting child gets EOF" {
    const out = try run(
        std.testing.allocator,
        "/bin/sh",
        &.{ "-c", "read answer; echo got:$answer" },
        true,
        5_000,
    );
    defer std.testing.allocator.free(out.text);
    try std.testing.expectEqualStrings("got:", std.mem.trim(u8, out.text, " \t\r\n"));
}

test "osascript failures are described and paths quoted" {
    const gpa = std.testing.allocator;
    var text = "12:345: execution error: rm: /x: Operation not permitted (1)\n".*;
    const out = Output{ .status = 1, .text = &text, .timed_out = false };
    const described = describeFailure(gpa, "rm", &out);
    defer gpa.free(described);
    try std.testing.expectEqualStrings("rm: /x: Operation not permitted (1)", described);
    const quoted = try quote(gpa, "/a'b");
    defer gpa.free(quoted);
    try std.testing.expectEqualStrings("'/a'\\''b'", quoted);
}
