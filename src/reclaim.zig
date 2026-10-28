//! Every filesystem change the app makes goes through here.
//!
//! A path must pass the guard before anything touches it. Review items go to
//! the Trash, and if the Trash refuses them they are reported, never deleted
//! outright in its place.
const std = @import("std");
const sys = @import("sys.zig");
const nanoui = @import("nanoui");
const item_mod = @import("item.zig");
const guard = @import("guard.zig");
const mac = @import("mac.zig");
const proc = @import("proc.zig");
const walker_mod = @import("walker.zig");

const Action = item_mod.Action;
const Item = item_mod.Item;
const Safety = item_mod.Safety;

pub const Failure = union(enum) {
    /// The person dismissed the administrator prompt.
    cancelled,
    /// A run nobody is watching may not raise a password prompt.
    needs_admin,
    /// The guard refused a path.
    refused: []const u8,
    failed: []const u8,

    pub fn message(f: Failure) []const u8 {
        return switch (f) {
            .cancelled => "Cancelled at the administrator prompt.",
            .needs_admin => "It needs an administrator password, so it was left for you to delete from the list.",
            .refused => |reason| reason,
            .failed => |reason| reason,
        };
    }
};

pub const Options = struct {
    home: []const u8,
    /// Also send Safe items to the Trash, so a delete can be undone.
    safe_to_trash: bool,
    allow_admin: bool,
};

fn refusalText(refusal: guard.Refusal) []const u8 {
    return switch (refusal) {
        error.NotAbsolute => "not an absolute path",
        error.ContainsDot => "it contains . or ..",
        error.ProtectedFolder => "it is a folder macOS or you depend on",
        error.AppInside => "this app is running from inside it",
        error.SymlinkedTarget => "it resolves to a protected folder",
        error.MountedVolume => "it is a mounted volume",
    };
}

/// `Ok(trashed)` where `trashed` says whether anything went to the Trash
/// rather than being deleted, because the Trash frees nothing until it is
/// emptied.
pub const Result = union(enum) { ok: bool, fail: Failure };

/// Runs one action.
pub fn perform(
    action: Action,
    to_trash: bool,
    options: Options,
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
) Result {
    switch (action) {
        .remove_paths => |paths| return remove(paths, to_trash, options, arena, gpa),
        .empty_directories => |dirs| {
            var trashed = false;
            for (dirs) |dir| {
                if (!walker_mod.exists(dir)) continue;
                if (walker_mod.isSymlink(dir)) {
                    return .{ .fail = .{ .refused = std.fmt.allocPrint(
                        arena,
                        "Refused {s}: it is a symlink, and emptying it would reach elsewhere.",
                        .{dir},
                    ) catch "Out of memory." } };
                }
                var children: std.ArrayList(walker_mod.Child) = .empty;
                walker_mod.children(dir, arena, &children) catch return .{ .fail = .{ .failed = "Out of memory." } };
                var paths: std.ArrayList([]const u8) = .empty;
                for (children.items) |child| paths.append(arena, child.path) catch return .{ .fail = .{ .failed = "Out of memory." } };
                switch (remove(paths.items, to_trash, options, arena, gpa)) {
                    .ok => |any| trashed = trashed or any,
                    .fail => |f| return .{ .fail = f },
                }
            }
            return .{ .ok = trashed };
        },
        .prune_older_than => |p| {
            if (guard.check(p.dir, options.home, arena)) |_| {
                prune(arena, p.dir, p.days);
                return .{ .ok = false };
            } else |refusal| {
                return .{ .fail = .{ .refused = refusedMessage(arena, p.dir, refusalText(refusal)) } };
            }
        },
        .command => |c| {
            const line = item_mod.commandLine(arena, c.program, c.args) catch return .{ .fail = .{ .failed = "Out of memory." } };
            const out = proc.run(gpa, c.program, c.args, true, proc.clean_timeout_ms) catch |e| {
                return .{ .fail = .{ .failed = std.fmt.allocPrint(arena, "{s}: {s}", .{ line, @errorName(e) }) catch "Out of memory." } };
            };
            defer gpa.free(out.text);
            if (out.ok()) return .{ .ok = false };
            return .{ .fail = .{ .failed = proc.describeFailure(arena, line, &out) } };
        },
        .privileged => |script| {
            switch (privileged(script, options, arena, gpa)) {
                .ok => return .{ .ok = false },
                .fail => |f| return .{ .fail = f },
            }
        },
        .shutdown_simulators => {
            const out = proc.run(gpa, "/usr/bin/xcrun", &.{ "simctl", "shutdown", "all" }, true, proc.probe_timeout_ms) catch {
                return .{ .ok = false };
            };
            gpa.free(out.text);
            return .{ .ok = false };
        },
        .erase_simulator => |udid| {
            const eraseOnce = struct {
                fn run(g: std.mem.Allocator, id: []const u8) proc.Output {
                    const argv = [_][]const u8{ "simctl", "erase", id };
                    return proc.run(g, "/usr/bin/xcrun", &argv, true, proc.clean_timeout_ms) catch
                        proc.Output{ .status = 127, .text = @constCast(""), .timed_out = false };
                }
            }.run;
            // A booted device refuses to erase; shut it down and retry once.
            {
                const shutdown = [_][]const u8{ "simctl", "shutdown", udid };
                const out = proc.run(gpa, "/usr/bin/xcrun", &shutdown, true, proc.clean_timeout_ms) catch
                    return .{ .fail = .{ .failed = "Could not run xcrun." } };
                gpa.free(out.text);
            }
            var out = eraseOnce(gpa, udid);
            if (!out.ok()) {
                gpa.free(out.text);
                const all = [_][]const u8{ "simctl", "shutdown", "all" };
                const shut = proc.run(gpa, "/usr/bin/xcrun", &all, true, proc.clean_timeout_ms) catch
                    return .{ .fail = .{ .failed = "Could not run xcrun." } };
                gpa.free(shut.text);
                out = eraseOnce(gpa, udid);
            }
            if (out.ok()) {
                gpa.free(out.text);
                return .{ .ok = false };
            }
            defer gpa.free(out.text);
            if (std.mem.indexOf(u8, out.text, "Booted") != null) {
                return .{ .fail = .{ .failed = "The simulator is still running. Quit Simulator and Xcode, then try again." } };
            }
            const line = std.fmt.allocPrint(arena, "xcrun simctl erase {s}", .{udid}) catch "xcrun simctl erase";
            return .{ .fail = .{ .failed = proc.describeFailure(arena, line, &out) } };
        },
        .steps => |steps| {
            var trashed = false;
            for (steps) |step| {
                switch (perform(step, to_trash, options, arena, gpa)) {
                    .ok => |any| trashed = trashed or any,
                    .fail => |f| return .{ .fail = f },
                }
            }
            return .{ .ok = trashed };
        },
        .manual => return .{ .ok = false },
    }
}

fn refusedMessage(arena: std.mem.Allocator, path: []const u8, why: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "Refused {s}: {s}.", .{ path, why }) catch "Refused.";
}

fn privileged(script: []const u8, options: Options, arena: std.mem.Allocator, gpa: std.mem.Allocator) Result {
    if (!options.allow_admin) return .{ .fail = .needs_admin };
    const out = proc.runPrivileged(gpa, script) catch |e| {
        return .{ .fail = .{ .failed = std.fmt.allocPrint(arena, "{s}", .{@errorName(e)}) catch "Out of memory." } };
    };
    if (out.ok()) {
        gpa.free(out.text);
        return .{ .ok = false };
    }
    if (proc.wasCancelled(out.text)) {
        gpa.free(out.text);
        return .{ .fail = .cancelled };
    }
    defer gpa.free(out.text);
    return .{ .fail = .{ .failed = proc.describeFailure(arena, script, &out) } };
}

fn remove(
    paths: []const []const u8,
    to_trash: bool,
    options: Options,
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
) Result {
    var present: std.ArrayList([]const u8) = .empty;
    for (paths) |p| {
        if (walker_mod.lstat(p) != null) present.append(arena, p) catch return .{ .fail = .{ .failed = "Out of memory." } };
    }
    // Every path is screened before any is touched.
    for (present.items) |path| {
        guard.check(path, options.home, arena) catch |refusal| {
            return .{ .fail = .{ .refused = refusedMessage(arena, path, refusalText(refusal)) } };
        };
    }
    var as_root: std.ArrayList([]const u8) = .empty;
    var trashed = false;
    for (present.items) |path| {
        if (item_mod.needsRoot(path)) {
            as_root.append(arena, path) catch return .{ .fail = .{ .failed = "Out of memory." } };
        } else if (to_trash) {
            if (!nanoui.shell.trash(path)) {
                return .{ .fail = .{ .failed = std.fmt.allocPrint(
                    arena,
                    "{s} could not go to the Trash, so it was left in place.",
                    .{path},
                ) catch "Out of memory." } };
            }
            trashed = true;
        } else if (!removeTree(gpa, path)) {
            as_root.append(arena, path) catch return .{ .fail = .{ .failed = "Out of memory." } };
        }
    }
    if (as_root.items.len > 0) {
        if (to_trash) {
            return .{ .fail = .{ .failed = std.fmt.allocPrint(
                arena,
                "{s} belongs to another user and cannot go to your Trash, so it was left in place.",
                .{as_root.items[0]},
            ) catch "Out of memory." } };
        }
        var script: std.ArrayList(u8) = .empty;
        script.appendSlice(arena, "rm -rf") catch return .{ .fail = .{ .failed = "Out of memory." } };
        for (as_root.items) |p| {
            script.append(arena, ' ') catch return .{ .fail = .{ .failed = "Out of memory." } };
            script.appendSlice(arena, proc.quote(arena, p) catch return .{ .fail = .{ .failed = "Out of memory." } }) catch return .{ .fail = .{ .failed = "Out of memory." } };
        }
        switch (privileged(script.items, options, arena, gpa)) {
            .ok => {},
            .fail => |f| return .{ .fail = f },
        }
    }
    return .{ .ok = trashed };
}

/// Deletes a tree: directories are emptied first, so removal is a rename
/// per entry rather than a walk per entry. Symlinks are unlinked, never
/// followed.
fn removeTree(gpa: std.mem.Allocator, path: []const u8) bool {
    const info = walker_mod.lstat(path) orelse return false;
    if (!info.isDir()) {
        sys.unlink(path) catch return false;
        return true;
    }
    var level = std.heap.ArenaAllocator.init(gpa);
    defer level.deinit();
    var children: std.ArrayList(walker_mod.Child) = .empty;
    walker_mod.children(path, level.allocator(), &children) catch return false;
    for (children.items) |child| {
        if (child.kind == .dir) {
            if (!removeTree(gpa, child.path)) return false;
        } else {
            sys.unlink(child.path) catch return false;
        }
    }
    sys.rmdir(path) catch return false;
    return true;
}

/// Deletes regular files not modified for `days`, then only the folders this
/// pass emptied. Sockets, pipes and links are never touched: running apps
/// keep live ones in these folders, and they hold no data.
pub fn prune(arena: std.mem.Allocator, dir: []const u8, days: u32) void {
    const cutoff = @import("clock.zig").now() - @as(i64, days) * 86_400;
    var emptied: std.StringHashMapUnmanaged(void) = .empty;
    var queue: std.ArrayList([]const u8) = .empty;
    queue.append(arena, dir) catch return;
    while (queue.items.len > 0) {
        const current = queue.items[queue.items.len - 1];
        queue.items.len -= 1;
        var children: std.ArrayList(walker_mod.Child) = .empty;
        walker_mod.children(current, arena, &children) catch continue;
        for (children.items) |child| {
            switch (child.kind) {
                .dir => queue.append(arena, child.path) catch {},
                .file => {
                    if (child.modified >= cutoff) continue;
                    sys.unlink(child.path) catch continue;
                    const key = arena.dupe(u8, current) catch continue;
                    emptied.put(arena, key, {}) catch {};
                },
                else => {},
            }
        }
    }
    // Deepest first, so a parent holding only an emptied folder goes too.
    var candidates: std.ArrayList([]const u8) = .empty;
    var it = emptied.iterator();
    while (it.next()) |entry| candidates.append(arena, entry.key_ptr.*) catch return;
    while (candidates.items.len > 0) {
        var best: usize = 0;
        for (candidates.items, 0..) |p, i| {
            if (componentCount(p) > componentCount(candidates.items[best])) best = i;
        }
        const deepest = candidates.items[best];
        _ = candidates.orderedRemove(best);
        if (std.mem.eql(u8, deepest, dir)) continue;
        if (!(deepest.len > dir.len and std.mem.startsWith(u8, deepest, dir) and deepest[dir.len] == '/')) continue;
        // rmdir refuses a folder that still holds anything.
        sys.rmdir(deepest) catch continue;
        if (std.fs.path.dirname(deepest)) |parent| {
            candidates.append(arena, parent) catch {};
        }
    }
}

fn componentCount(path: []const u8) usize {
    var n: usize = 0;
    var it = std.fs.path.componentIterator(path);
    while (it.next()) |_| n += 1;
    return n;
}

/// What one batch reports as it goes.
pub const Event = union(enum) {
    busy: []const []const u8,
    /// Removed. `freed` is what the disk gained, or the item's size when the
    /// disk under-reports it; zero for anything moved to the Trash.
    done: struct { ids: []const []const u8, trashed: bool, freed: u64 },
    failed: struct { ids: []const []const u8, message: []const u8 },
    /// The person dismissed the password prompt; these were left alone.
    stopped: struct { deleted: usize, remaining: []const []const u8 },
};

/// Review items go to the Trash; Safe items are deleted unless the person
/// asked for the Trash for those too.
pub fn goesToTrash(item: *const Item, safe_to_trash: bool) bool {
    if (item.category == .trash) return false;
    return switch (item.safety) {
        .review => true,
        .safe => safe_to_trash,
        .manual => false,
    };
}

pub const Report = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, event: Event) void,
};

/// Runs a batch in order. Several administrator scripts share one prompt,
/// and each script's failure is reported against its own item.
pub fn runBatch(
    items: []const Item,
    options: Options,
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    report: Report,
) void {
    var scripts: std.ArrayList(*const Item) = .empty;
    var direct: std.ArrayList(*const Item) = .empty;
    for (items) |*item| {
        if (item.action.isManual()) continue;
        if (item.action == .privileged) {
            scripts.append(arena, item) catch return;
        } else {
            direct.append(arena, item) catch return;
        }
    }
    if (scripts.items.len == 1 or !options.allow_admin) {
        var at: usize = 0;
        for (scripts.items) |script| {
            direct.insert(arena, at, script) catch return;
            at += 1;
        }
    } else if (scripts.items.len > 1) {
        const ids = idsOf(arena, scripts.items) catch return;
        report.func(report.ctx, .{ .busy = ids });
        const before = mac.diskSpace().free;
        var bodies: std.ArrayList([]const u8) = .empty;
        for (scripts.items) |script| {
            switch (script.action) {
                .privileged => |text| bodies.append(arena, text) catch return,
                else => {},
            }
        }
        switch (privileged(combinedScript(arena, bodies.items) catch return, options, arena, gpa)) {
            .ok => report.func(report.ctx, doneEvent(arena, scripts.items, false, before)),
            .fail => |failure| {
                if (failure == .cancelled) {
                    const remaining = remainingAfter(arena, ids, direct.items, 0) catch return;
                    report.func(report.ctx, .{ .stopped = .{ .deleted = 0, .remaining = remaining } });
                    return;
                }
                const message = failure.message();
                const failed = failedIndices(arena, message) orelse fullSet(arena, scripts.items.len);
                const good = keepIndices(arena, scripts.items, failed) catch return;
                if (good.items.len > 0) {
                    report.func(report.ctx, doneEvent(arena, good.items, false, before));
                }
                const failed_ids = idsWhere(arena, scripts.items, failed) catch return;
                report.func(report.ctx, .{ .failed = .{
                    .ids = failed_ids,
                    .message = withoutMarker(arena, message),
                } });
            },
        }
    }
    for (direct.items, 0..) |item, index| {
        const one = arena.dupe([]const u8, &.{item.id}) catch return;
        report.func(report.ctx, .{ .busy = one });
        const before = mac.diskSpace().free;
        const result = perform(
            item.action,
            goesToTrash(item, options.safe_to_trash),
            options,
            arena,
            gpa,
        );
        switch (result) {
            .ok => |trashed| {
                const done_ids = arena.dupe([]const u8, &.{item.id}) catch return;
                const single = [_]*const Item{item};
                report.func(report.ctx, .{ .done = .{
                    .ids = done_ids,
                    .trashed = trashed,
                    .freed = freed(mac.diskSpace().free, before, trashed, single[0..1]),
                } });
            },
            .fail => |failure| {
                if (failure == .cancelled) {
                    var remaining: std.ArrayList([]const u8) = .empty;
                    for (direct.items[index..]) |left| remaining.append(arena, left.id) catch return;
                    report.func(report.ctx, .{ .stopped = .{ .deleted = index, .remaining = remaining.items } });
                    return;
                }
                const failed_ids = arena.dupe([]const u8, &.{item.id}) catch return;
                const message = std.fmt.allocPrint(arena, "{s}: {s}", .{ item.name, failure.message() }) catch return;
                report.func(report.ctx, .{ .failed = .{ .ids = failed_ids, .message = message } });
            },
        }
    }
}

fn idsOf(arena: std.mem.Allocator, items: []const *const Item) ![]const []const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    for (items) |item| try ids.append(arena, item.id);
    return ids.items;
}

fn keepIndices(arena: std.mem.Allocator, items: []const *const Item, failed: []const usize) !std.ArrayList(*const Item) {
    var good: std.ArrayList(*const Item) = .empty;
    for (items, 0..) |item, n| {
        var is_failed = false;
        for (failed) |f| {
            if (f == n) {
                is_failed = true;
                break;
            }
        }
        if (!is_failed) try good.append(arena, item);
    }
    return good;
}

fn idsWhere(arena: std.mem.Allocator, items: []const *const Item, failed: []const usize) ![]const []const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    for (items, 0..) |item, n| {
        for (failed) |f| {
            if (f == n) {
                try ids.append(arena, item.id);
                break;
            }
        }
    }
    return ids.items;
}

fn fullSet(arena: std.mem.Allocator, n: usize) []const usize {
    const all = arena.alloc(usize, n) catch return &.{};
    for (all, 0..) |*slot, i| slot.* = i;
    return all;
}

fn remainingAfter(
    arena: std.mem.Allocator,
    script_ids: []const []const u8,
    direct: []const *const Item,
    from: usize,
) ![]const []const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    for (script_ids) |id| try ids.append(arena, id);
    for (direct[from..]) |item| try ids.append(arena, item.id);
    return ids.items;
}

fn doneEvent(arena: std.mem.Allocator, items: []const *const Item, trashed: bool, before: u64) Event {
    const ids = idsOf(arena, items) catch {
        return .{ .done = .{ .ids = &.{}, .trashed = trashed, .freed = 0 } };
    };
    return .{ .done = .{
        .ids = ids,
        .trashed = trashed,
        .freed = freed(mac.diskSpace().free, before, trashed, items),
    } };
}

/// What the disk gained, or the items' total size when the disk
/// under-reports it. A trashed item is renamed on the same volume;
/// crediting its size would claim room the disk does not have.
fn freed(after: u64, before: u64, trashed: bool, items: []const *const Item) u64 {
    const gained = after -| before;
    if (trashed) return gained;
    var expected: u64 = 0;
    for (items) |item| expected += item.bytes();
    return @max(gained, expected);
}

const marker = "SYSDATA_FAILED:";

/// Each script in its own subshell, its failure noted by position.
pub fn combinedScript(arena: std.mem.Allocator, scripts: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "failed=''");
    for (scripts, 0..) |script, n| {
        try out.appendSlice(arena, " ; ( ");
        try out.appendSlice(arena, script);
        const step = try std.fmt.allocPrint(arena, " ) || failed=\"$failed {d}\"", .{n});
        try out.appendSlice(arena, step);
    }
    try out.appendSlice(arena, " ; [ -z \"$failed\" ] || { echo \"SYSDATA_FAILED:$failed\" >&2; exit 1; }");
    return out.items;
}

/// Positions the combined script reported as failed, or null when it never
/// got that far.
pub fn failedIndices(arena: std.mem.Allocator, output: []const u8) ?[]const usize {
    const at = (std.mem.indexOf(u8, output, marker) orelse return null) + marker.len;
    var rest = output[at..];
    if (std.mem.indexOfAny(u8, rest, "\n\r\"")) |cut| rest = rest[0..cut];
    var found: std.ArrayList(usize) = .empty;
    var it = std.mem.tokenizeAny(u8, rest, " \t");
    while (it.next()) |word| {
        const index = std.fmt.parseInt(usize, word, 10) catch continue;
        found.append(arena, index) catch return null;
    }
    if (found.items.len == 0) return null;
    return found.items;
}

fn withoutMarker(arena: std.mem.Allocator, text: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, marker) != null) continue;
        if (out.items.len > 0) out.append(arena, '\n') catch {};
        out.appendSlice(arena, line) catch {};
    }
    return std.mem.trim(u8, out.items, " \t\r\n");
}

test "the guard refuses what matters" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/Users/someone";
    for ([_][]const u8{
        "/",                  "/Users/someone", "/Users/someone/Library",
        "/Users/someone/Documents", "/Applications",  "/Users/someone/.ssh",
    }) |path| {
        try std.testing.expectError(error.ProtectedFolder, guard.check(path, home, arena));
    }
    try std.testing.expectError(error.NotAbsolute, guard.check("relative/path", home, arena));
    try std.testing.expectError(error.ContainsDot, guard.check("/Users/someone/Library/Caches/../Documents", home, arena));
    try guard.check("/Users/someone/Library/Caches/com.example", home, arena);
}

test "a combined script reports failures by position" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const script = try combinedScript(arena, &.{ "true", "false", "exit 3" });
    const out = try proc.run(std.testing.allocator, "/bin/sh", &.{ "-c", script }, true, 5_000);
    defer std.testing.allocator.free(out.text);
    try std.testing.expectEqual(@as(i32, 1), out.status);
    const failed = failedIndices(arena, out.text).?;
    try std.testing.expectEqual(@as(usize, 1), failed[0]);
    try std.testing.expectEqual(@as(usize, 2), failed[1]);
    try std.testing.expect(failedIndices(arena, "osascript said nothing useful") == null);
    try std.testing.expectEqualStrings("rm: x: denied", withoutMarker(arena, "rm: x: denied\nSYSDATA_FAILED: 1"));
}
