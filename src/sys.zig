//! The handful of syscalls this app makes, straight on libc. Zig 0.17 moved
//! file access behind `std.Io`; a scanner that already owns its threads and
//! deadlines only needs the calls, with errors it can act on.
const std = @import("std");
const c = std.c;

pub const fd_t = c.fd_t;
pub const pid_t = c.pid_t;

pub const Error = error{ NameTooLong, Failed };

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern "c" fn symlink(target: [*:0]const u8, link: [*:0]const u8) c_int;

pub fn z(path: []const u8) Error![std.fs.max_path_bytes - 1:0]u8 {
    return std.posix.toPosixPath(path) catch error.NameTooLong;
}

/// A directory opened for listing, without following a final symlink when
/// `nofollow` is set.
pub fn openDirAt(parent: fd_t, path: []const u8, nofollow: bool) Error!fd_t {
    return std.posix.openat(parent, path, .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .CLOEXEC = true,
        .NOFOLLOW = nofollow,
    }, 0) catch error.Failed;
}

pub fn openDir(path: []const u8) Error!fd_t {
    return openDirAt(c.AT.FDCWD, path, false);
}

pub fn close(fd: fd_t) void {
    _ = c.close(fd);
}

pub fn unlink(path: []const u8) Error!void {
    const p = try z(path);
    if (c.unlink(&p) != 0) return error.Failed;
}

pub fn rmdir(path: []const u8) Error!void {
    const p = try z(path);
    if (c.rmdir(&p) != 0) return error.Failed;
}

/// The path with every symlink resolved; it must exist.
pub fn realpath(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const p = try z(path);
    var out: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = c.realpath(&p, &out) orelse return error.Failed;
    return gpa.dupe(u8, std.mem.span(resolved));
}

/// `mkdir -p`. Existing directories are fine.
pub fn makePath(path: []const u8) Error!void {
    var p = try z(path);
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i < path.len and p[i] != '/') continue;
        const saved = p[i];
        p[i] = 0;
        const rc = c.mkdir(&p, 0o755);
        p[i] = saved;
        if (rc != 0 and c._errno().* != @intFromEnum(c.E.EXIST)) return error.Failed;
    }
}

/// The whole file, refusing anything longer than `limit`.
pub fn readFile(gpa: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    const p = try z(path);
    const fd = c.open(&p, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return error.Failed;
    defer close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        const n = c.read(fd, &chunk, chunk.len);
        if (n < 0) return error.Failed;
        if (n == 0) break;
        if (out.items.len + @as(usize, @intCast(n)) > limit) return error.Failed;
        try out.appendSlice(gpa, chunk[0..@intCast(n)]);
    }
    return out.toOwnedSlice(gpa);
}

fn writeAll(fd: fd_t, data: []const u8) Error!void {
    var at: usize = 0;
    while (at < data.len) {
        const n = c.write(fd, data[at..].ptr, data.len - at);
        if (n <= 0) return error.Failed;
        at += @intCast(n);
    }
}

/// Readers see the old file or the complete new one, never a torn write:
/// a private temp file beside the target, synced, then renamed over it.
pub fn publishFile(path: []const u8, data: []const u8) Error!void {
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.{d}.tmp", .{ path, c.getpid() }) catch return error.NameTooLong;
    const tmp_z = try z(tmp);
    const fd = c.open(&tmp_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .EXCL = true, .CLOEXEC = true }, @as(c_uint, 0o600));
    if (fd < 0) return error.Failed;
    writeAll(fd, data) catch {
        close(fd);
        _ = c.unlink(&tmp_z);
        return error.Failed;
    };
    _ = c.fsync(fd);
    close(fd);
    const dest = try z(path);
    if (c.rename(&tmp_z, &dest) != 0) {
        _ = c.unlink(&tmp_z);
        return error.Failed;
    }
}

pub const Pipe = [2]fd_t;

pub fn pipe() Error!Pipe {
    var fds: Pipe = undefined;
    if (c.pipe(&fds) != 0) return error.Failed;
    for (fds) |fd| _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
    return fds;
}

pub fn fork() Error!pid_t {
    const pid = c.fork();
    if (pid < 0) return error.Failed;
    return pid;
}

pub const Wait = struct { pid: pid_t, status: u32 };

/// `null` while the child runs (with `nohang`) or when waiting failed.
pub fn waitpid(pid: pid_t, nohang: bool) ?Wait {
    var status: c_int = 0;
    while (true) {
        const r = c.waitpid(pid, &status, if (nohang) c.W.NOHANG else 0);
        if (r < 0 and c._errno().* == @intFromEnum(c.E.INTR)) continue;
        if (r <= 0) return null;
        return .{ .pid = r, .status = @bitCast(status) };
    }
}

pub fn symlinkAt(target: []const u8, link: []const u8) Error!void {
    const t = try z(target);
    const l = try z(link);
    if (symlink(&t, &l) != 0) return error.Failed;
}

/// A fresh private directory under the temp root, for tests.
pub fn makeTempDir(gpa: std.mem.Allocator) ![]u8 {
    var template = "/tmp/sysdata-test-XXXXXX".*;
    const made = mkdtemp(&template) orelse return error.Failed;
    const real = try realpath(gpa, std.mem.span(made));
    return real;
}
