//! What a scan finds: one row per reclaimable (or explainable) location.
//!
//! Every string is a slice into the scan's arena, so a scan's results are
//! freed whole, never item by item: no per-item refcounting, no leaks that
//! outlive the scan that made them.
const std = @import("std");
const walker = @import("walker.zig");

/// Groups in the list, in their fixed display order.
pub const Category = enum {
    snapshots,
    simulators,
    runtimes,
    xcode,
    packages,
    tools,
    logs,
    temp,
    docker,
    vms,
    trash,
    backups,
    shared,
    android,
    apps,
    projects,
    system,
    other,

    /// Stable machine name, shared with the `--json` output.
    pub fn key(c: Category) []const u8 {
        return @tagName(c);
    }

    pub fn title(c: Category) []const u8 {
        return switch (c) {
            .snapshots => "Time Machine snapshots",
            .simulators => "Simulator devices",
            .runtimes => "Simulator runtimes",
            .xcode => "Xcode",
            .packages => "Package managers",
            .tools => "Developer tool data",
            .logs => "Logs & diagnostics",
            .temp => "Temporary files",
            .docker => "Docker",
            .vms => "Virtual machines",
            .trash => "Trash",
            .backups => "iOS device backups",
            .shared => "Shared & other users",
            .android => "Android",
            .apps => "App data & caches",
            .projects => "Project build folders",
            .system => "System",
            .other => "Other large folders",
        };
    }
};

pub const every_category = [_]Category{
    .snapshots, .simulators, .runtimes,   .xcode,     .packages, .tools,
    .logs,      .temp,        .docker,    .vms,       .trash,    .backups,
    .shared,    .android,     .apps,      .projects,  .system,   .other,
};

/// How much thought a deletion needs.
pub const Safety = enum {
    /// The owning tool or macOS rebuilds it on demand.
    safe,
    /// Deletable, but something real is lost: a device, a login, a download.
    review,
    /// This app never deletes it; the row shows how instead.
    manual,

    pub fn label(s: Safety) []const u8 {
        return switch (s) {
            .safe => "Safe",
            .review => "Review",
            .manual => "Manual",
        };
    }

    pub fn key(s: Safety) []const u8 {
        return @tagName(s);
    }
};

pub const Action = union(enum) {
    remove_paths: []const []const u8,
    /// Deletes every entry inside each directory and keeps the directories.
    empty_directories: []const []const u8,
    /// Deletes regular files not modified for `days`, then folders that left empty.
    prune_older_than: Prune,
    command: Command,
    /// A shell script run as root behind the administrator prompt.
    privileged: []const u8,
    /// Files a booted simulator has mapped cannot be deleted, not even by root.
    shutdown_simulators,
    erase_simulator: []const u8,
    /// Runs in order and stops at the first failure.
    steps: []const Action,
    manual: []const u8,

    pub const Prune = struct { dir: []const u8, days: u32 };
    pub const Command = struct { program: []const u8, args: []const []const u8 };

    pub fn isManual(a: Action) bool {
        return a == .manual;
    }

    pub fn manualInstructions(a: Action) ?[]const u8 {
        return switch (a) {
            .manual => |text| text,
            else => null,
        };
    }

    /// Exactly what runs, one line per operation, shown before anything does.
    pub fn planInto(a: Action, gpa: std.mem.Allocator, out: *std.ArrayList([]const u8)) !void {
        switch (a) {
            .remove_paths => |paths| for (paths) |p| {
                try out.append(gpa, try std.fmt.allocPrint(gpa, "Delete {s}", .{p}));
            },
            .empty_directories => |dirs| for (dirs) |d| {
                try out.append(gpa, try std.fmt.allocPrint(gpa, "Delete everything inside {s}", .{d}));
            },
            .prune_older_than => |p| try out.append(gpa, try std.fmt.allocPrint(
                gpa,
                "Delete files older than {d} days in {s}",
                .{ p.days, p.dir },
            )),
            .command => |c| try out.append(gpa, try commandLine(gpa, c.program, c.args)),
            .privileged => |script| try out.append(gpa, try std.fmt.allocPrint(
                gpa,
                "As administrator: {s}",
                .{script},
            )),
            .shutdown_simulators => try out.append(gpa, "Shut every simulator down first"),
            .erase_simulator => |udid| {
                try out.append(gpa, try std.fmt.allocPrint(gpa, "/usr/bin/xcrun simctl shutdown {s}", .{udid}));
                try out.append(gpa, try std.fmt.allocPrint(gpa, "/usr/bin/xcrun simctl erase {s}", .{udid}));
            },
            .steps => |steps| for (steps) |step| try step.planInto(gpa, out),
            .manual => {},
        }
    }

    /// Filesystem locations this action deletes from, into a fixed buffer:
    /// past its capacity the rest are dropped.
    pub fn pathsInto(a: Action, out: *std.ArrayList([]const u8)) void {
        switch (a) {
            .remove_paths => |paths| out.appendSliceBounded(paths) catch {},
            .empty_directories => |dirs| out.appendSliceBounded(dirs) catch {},
            .prune_older_than => |p| out.appendBounded(p.dir) catch {},
            .steps => |steps| for (steps) |step| step.pathsInto(out),
            else => {},
        }
    }

    /// Whether running it shows the administrator prompt: a script always
    /// does, and so does deleting a path this user cannot unlink.
    pub fn needsAdmin(a: Action) bool {
        switch (a) {
            .privileged => return true,
            .steps => |steps| {
                for (steps) |step| if (step.needsAdmin()) return true;
                return false;
            },
            else => {
                var found: [64][]const u8 = undefined;
                var list = std.ArrayList([]const u8).initBuffer(&found);
                a.pathsInto(&list);
                for (list.items) |p| if (needsRoot(p)) return true;
                return false;
            },
        }
    }

    pub fn shutsDownSimulators(a: Action) bool {
        return switch (a) {
            .shutdown_simulators, .erase_simulator => true,
            .steps => |steps| blk: {
                for (steps) |step| if (step.shutsDownSimulators()) break :blk true;
                break :blk false;
            },
            else => false,
        };
    }
};

pub fn commandLine(gpa: std.mem.Allocator, program: []const u8, args: []const []const u8) ![]const u8 {
    var n: usize = program.len;
    for (args) |a| n += 1 + a.len;
    var out = std.ArrayList(u8).empty;
    try out.ensureTotalCapacity(gpa, n);
    try out.appendSlice(gpa, program);
    for (args) |a| {
        try out.append(gpa, ' ');
        try out.appendSlice(gpa, a);
    }
    return out.items;
}

/// Exists, and the current user cannot unlink it from its parent.
pub fn needsRoot(path: []const u8) bool {
    if (walker.lstat(path) == null) return false;
    const parent = std.fs.path.dirname(path) orelse return true;
    const z = @import("sys.zig").z(parent) catch return true;
    return c_access(&z, 2) != 0;
}

extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
const c_access = access;

pub const Item = struct {
    id: []const u8,
    category: Category,
    name: []const u8,
    detail: []const u8,
    /// `null` when the size cannot be measured, such as APFS snapshots.
    size: ?u64,
    safety: Safety,
    action: Action,
    /// The folder Finder opens; `null` when there is none.
    reveal: ?[]const u8 = null,
    /// Newest modification under the location, in seconds since the epoch.
    /// `null` means not measured, not "never used".
    modified: ?i64 = null,
    /// Locations counted here beyond the action and reveal paths.
    also_claims: []const []const u8 = &.{},

    pub fn bytes(i: *const Item) u64 {
        return i.size orelse 0;
    }

    pub fn idleDays(i: *const Item, now: i64) ?u64 {
        const modified = i.modified orelse return null;
        if (now <= modified) return 0;
        return @as(u64, @intCast(now - modified)) / 86_400;
    }

    /// "3 months idle", or `null` below a fortnight, where age says nothing.
    pub fn idleLabel(i: *const Item, buf: []u8, now: i64) ?[]const u8 {
        const days = i.idleDays(now) orelse return null;
        if (days < 14) return null;
        const Count = struct { n: u64, unit: []const u8 };
        const c: Count = if (days >= 365)
            .{ .n = days / 365, .unit = "year" }
        else if (days >= 30)
            .{ .n = days / 30, .unit = "month" }
        else
            .{ .n = days, .unit = "day" };
        return std.fmt.bufPrint(buf, "{d} {s}{s} idle", .{
            c.n, c.unit, if (c.n == 1) "" else "s",
        }) catch null;
    }

    /// Every location this item accounts for, so the catch-all skips it.
    /// `buf` must hold every path; a probe claims at most a few.
    pub fn claimedPaths(i: *const Item, buf: [][]const u8) [][]const u8 {
        var n: usize = 0;
        var scratch: [64][]const u8 = undefined;
        var list = std.ArrayList([]const u8).initBuffer(&scratch);
        i.action.pathsInto(&list);
        for (list.items) |p| {
            if (n >= buf.len) return buf[0..n];
            buf[n] = p;
            n += 1;
        }
        if (i.reveal) |p| {
            if (n < buf.len) {
                buf[n] = p;
                n += 1;
            }
        }
        for (i.also_claims) |p| {
            if (n >= buf.len) return buf[0..n];
            buf[n] = p;
            n += 1;
        }
        return buf[0..n];
    }

    /// Matches the name, the detail, or the category title, so "simulator"
    /// keeps a whole group rather than only rows that repeat the word.
    pub fn matches(i: *const Item, filter: []const u8) bool {
        const needle = std.mem.trim(u8, filter, " \t");
        if (needle.len == 0) return true;
        if (containsIgnoreCase(i.name, needle)) return true;
        if (containsIgnoreCase(i.detail, needle)) return true;
        return containsIgnoreCase(i.category.title(), needle);
    }
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Finder-style decimal sizes: whole KB, one decimal for MB, two for GB and
/// up, trailing zeros dropped: "598 KB", "33.6 MB", "1.6 GB", "205.94 GB".
pub fn formatBytes(buf: []u8, bytes: u64) []const u8 {
    const Unit = struct { name: []const u8, decimals: usize };
    const units = [_]Unit{
        .{ .name = "KB", .decimals = 0 },
        .{ .name = "MB", .decimals = 1 },
        .{ .name = "GB", .decimals = 2 },
        .{ .name = "TB", .decimals = 2 },
        .{ .name = "PB", .decimals = 2 },
    };
    if (bytes < 1_000) return std.fmt.bufPrint(buf, "{d} bytes", .{bytes}) catch "0 bytes";
    var value: f64 = @as(f64, @floatFromInt(bytes)) / 1_000.0;
    var unit: usize = 0;
    var number: [32]u8 = undefined;
    while (true) {
        const shown = switch (units[unit].decimals) {
            0 => std.fmt.bufPrint(&number, "{d:.0}", .{value}) catch return "0 bytes",
            1 => std.fmt.bufPrint(&number, "{d:.1}", .{value}) catch return "0 bytes",
            else => std.fmt.bufPrint(&number, "{d:.2}", .{value}) catch return "0 bytes",
        };
        const parsed = std.fmt.parseFloat(f64, shown) catch value;
        // 999.99 MB rounds to 1000.0 MB; Finder says 1 GB.
        if (parsed >= 1_000.0 and unit + 1 < units.len) {
            value /= 1_000.0;
            unit += 1;
            continue;
        }
        const trimmed = trimZeros(shown);
        return std.fmt.bufPrint(buf, "{s} {s}", .{ trimmed, units[unit].name }) catch "0 bytes";
    }
}

fn trimZeros(text: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, text, '.') == null) return text;
    var end = text.len;
    while (end > 0 and (text[end - 1] == '0' or text[end - 1] == '.')) end -= 1;
    return text[0..end];
}

test "formats like Finder" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0 bytes", formatBytes(&buf, 0));
    try std.testing.expectEqualStrings("598 KB", formatBytes(&buf, 598_016));
    try std.testing.expectEqualStrings("33.6 MB", formatBytes(&buf, 33_600_000));
    try std.testing.expectEqualStrings("910.2 MB", formatBytes(&buf, 910_200_000));
    try std.testing.expectEqualStrings("1.6 GB", formatBytes(&buf, 1_600_000_000));
    try std.testing.expectEqualStrings("78.41 GB", formatBytes(&buf, 78_410_000_000));
    try std.testing.expectEqualStrings("205.94 GB", formatBytes(&buf, 205_940_000_000));
    try std.testing.expectEqualStrings("202 MB", formatBytes(&buf, 202_000_000));
    try std.testing.expectEqualStrings("1 GB", formatBytes(&buf, 999_990_000));
}

test "idle labels need a fortnight" {
    const now: i64 = 400 * 86_400;
    var item = Item{
        .id = "x",
        .category = .other,
        .name = "x",
        .detail = "",
        .size = 1,
        .safety = .review,
        .action = .{ .manual = "" },
    };
    var buf: [32]u8 = undefined;
    item.modified = now - 13 * 86_400;
    try std.testing.expect(item.idleLabel(&buf, now) == null);
    item.modified = now - 20 * 86_400;
    try std.testing.expectEqualStrings("20 days idle", item.idleLabel(&buf, now).?);
    item.modified = now - 65 * 86_400;
    try std.testing.expectEqualStrings("2 months idle", item.idleLabel(&buf, now).?);
    item.modified = now - 370 * 86_400;
    try std.testing.expectEqualStrings("1 year idle", item.idleLabel(&buf, now).?);
}

test "the plan lists every operation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const action = Action{ .steps = &.{
        .shutdown_simulators,
        .{ .empty_directories = &[_][]const u8{ "/a", "/b" } },
    } };
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(a);
    try action.planInto(a, &lines);
    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expectEqualStrings("Shut every simulator down first", lines.items[0]);
    try std.testing.expectEqualStrings("Delete everything inside /a", lines.items[1]);
    try std.testing.expectEqualStrings("Delete everything inside /b", lines.items[2]);
    try std.testing.expect(action.shutsDownSimulators());
}

test "claimed paths cover the action, reveal and extra claims" {
    const item = Item{
        .id = "x",
        .category = .other,
        .name = "x",
        .detail = "",
        .size = 1,
        .safety = .review,
        .action = .{ .remove_paths = &.{ "/a", "/b" } },
        .reveal = "/root",
        .also_claims = &.{"/extra"},
    };
    var buf: [8][]const u8 = undefined;
    const paths = item.claimedPaths(&buf);
    try std.testing.expectEqual(@as(usize, 4), paths.len);
    try std.testing.expectEqualStrings("/a", paths[0]);
    try std.testing.expectEqualStrings("/root", paths[2]);
    try std.testing.expectEqualStrings("/extra", paths[3]);
}
