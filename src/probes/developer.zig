//! Time Machine snapshots, simulators, simulator runtimes and Xcode.
const std = @import("std");
const scan_mod = @import("../scan.zig");
const walker_mod = @import("../walker.zig");
const proc = @import("../proc.zig");
const item_mod = @import("../item.zig");

const Scan = scan_mod.Scan;
const Item = item_mod.Item;
const MB = scan_mod.MB;

const xcrun = "/usr/bin/xcrun";

fn obj(v: std.json.Value) ?std.json.ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

fn str(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn integer(v: std.json.Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn boolean(v: std.json.Value) bool {
    return switch (v) {
        .bool => |b| b,
        else => false,
    };
}

/// APFS keeps hourly Time Machine snapshots on the boot volume. Finder
/// counts their blocks as System Data, and APFS does not report their size.
pub fn snapshots(s: *Scan) scan_mod.Error!std.ArrayList(Item) {
    if (!s.env.system) return .empty;
    const arena = s.env.arena;
    var out: std.ArrayList(Item) = .empty;
    const listing = proc.probe(s.gpa, "/usr/bin/tmutil", &.{ "listlocalsnapshots", "/" }) orelse return out;
    defer s.gpa.free(listing);
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, listing, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "com.apple.TimeMachine") != null) count += 1;
    }
    if (count == 0) return out;
    try out.append(arena, .{
        .id = "snapshots",
        .category = .snapshots,
        .name = try std.fmt.allocPrint(arena, "{d} local snapshot{s}", .{ count, if (count == 1) "" else "s" }),
        .detail = "APFS snapshots Time Machine keeps between backups. APFS does not report their size; the next backup makes a new one.",
        .size = null,
        .safety = .safe,
        .action = .{ .privileged = "tmutil deletelocalsnapshots / ; tmutil thinlocalsnapshots / 9999999999999 4" },
    });
    return out;
}

pub fn simulators(s: *Scan) scan_mod.Error!std.ArrayList(Item) {
    const arena = s.env.arena;
    var out: std.ArrayList(Item) = .empty;
    const root = s.env.at("Library/Developer/CoreSimulator");
    if (!s.env.system or !walker_mod.exists(root) or s.developerDir() == null) return out;

    var caches: std.ArrayList([]const u8) = .empty;
    var cache_bytes: u64 = 0;
    var devices_counted: usize = 0;
    if (s.simctl(&.{ "list", "devices", "-j" })) |listing| {
        const by_runtime = obj(listing) orelse return out;
        const devices = obj(by_runtime.get("devices") orelse return out) orelse return out;
        var runtime_iter = devices.iterator();
        while (runtime_iter.next()) |entry| {
            const runtime = runtimeName(arena, entry.key_ptr.*) catch continue;
            const list = switch (entry.value_ptr.*) {
                .array => |a| a.items,
                else => continue,
            };
            for (list) |device_value| {
                const device = obj(device_value) orelse continue;
                const name = str(device.get("name") orelse continue) orelse continue;
                const udid = str(device.get("udid") orelse continue) orelse continue;
                const data_path = str(device.get("dataPath") orelse continue) orelse continue;
                const data_size: ?u64 = blk: {
                    const n = integer(device.get("dataPathSize") orelse break :blk null) orelse break :blk null;
                    if (n < 0) break :blk null;
                    break :blk @intCast(n);
                };
                if (!boolean(device.get("isAvailable") orelse continue)) {
                    try out.append(arena, .{
                        .id = try std.fmt.allocPrint(arena, "sim-unavailable-{s}", .{udid}),
                        .category = .simulators,
                        .name = try std.fmt.allocPrint(arena, "Unavailable: {s}", .{name}),
                        .detail = try std.fmt.allocPrint(arena, "Its runtime ({s}) is no longer installed, so this device cannot boot again.", .{runtime}),
                        .size = data_size,
                        .safety = .safe,
                        .action = .{ .command = .{ .program = xcrun, .args = arena.dupe([]const u8, &.{ "simctl", "delete", arena.dupe(u8, udid) catch continue }) catch continue } },
                        .reveal = data_path,
                    });
                    continue;
                }
                devices_counted += 1;
                var device_bytes: u64 = 0;
                for ([_][]const u8{ "/Library/Caches", "/tmp" }) |sub| {
                    const path = try std.fmt.allocPrint(arena, "{s}{s}", .{ data_path, sub });
                    if (!walker_mod.exists(path)) continue;
                    const measured = s.walk.measure(path);
                    device_bytes += measured.bytes;
                    try caches.append(arena, path);
                }
                cache_bytes += device_bytes;
                const erase_size: ?u64 = if (data_size) |size| size -| device_bytes else null;
                if (erase_size) |size| {
                    if (size < 100 * MB) continue;
                    try out.append(arena, .{
                        .id = try std.fmt.allocPrint(arena, "sim-erase-{s}", .{udid}),
                        .category = .simulators,
                        .name = try std.fmt.allocPrint(arena, "Erase {s}", .{name}),
                        .detail = try std.fmt.allocPrint(arena, "Resets this {s} simulator to factory state. Installed apps and their data are lost.", .{runtime}),
                        .size = size,
                        .safety = .review,
                        .action = .{ .erase_simulator = arena.dupe(u8, udid) catch continue },
                        .reveal = data_path,
                    });
                }
            }
        }
    }

    // The shared dyld cache, rebuilt at the next boot.
    const dyld = try std.fmt.allocPrint(arena, "{s}/Caches/dyld", .{root});
    if (walker_mod.exists(dyld)) {
        cache_bytes += s.walk.measure(dyld).bytes;
        try caches.append(arena, dyld);
    }
    if (caches.items.len > 0 and cache_bytes > 0) {
        const steps = try arena.alloc(item_mod.Action, 2);
        steps[0] = .shutdown_simulators;
        steps[1] = .{ .empty_directories = try arena.dupe([]const u8, caches.items) };
        const row = Item{
            .id = "sim-caches",
            .category = .simulators,
            .name = try std.fmt.allocPrint(arena, "Device caches ({d} devices)", .{devices_counted}),
            .detail = "Each simulator's Caches and tmp, plus the shared dyld cache. Rebuilt at the next boot.",
            .size = cache_bytes,
            .safety = .safe,
            .action = .{ .steps = steps },
            .reveal = try std.fmt.allocPrint(arena, "{s}/Devices", .{root}),
        };
        try out.insert(arena, 0, row);
    }

    // macOS refuses to unlink anything here, root included. It goes when
    // its runtime goes.
    if (scan_mod.dirItem(
        s,
        "sim-system-dyld",
        .simulators,
        "System dyld cache",
        "One shared cache per installed runtime, built by CoreSimulator and protected by macOS.",
        "/Library/Developer/CoreSimulator/Caches/dyld",
        .manual,
        .{ .manual = "Delete the runtime it belongs to (Simulator runtimes), or:\nxcrun simctl runtime delete <UUID>\nThe cache is rebuilt when the runtime is installed again." },
        50 * MB,
    )) |found| try out.append(arena, found);
    scan_mod.bySize(out.items);
    return out;
}

fn runtimeName(arena: std.mem.Allocator, full: []const u8) ![]const u8 {
    const prefix = "com.apple.CoreSimulator.SimRuntime.";
    if (std.mem.startsWith(u8, full, prefix)) return full[prefix.len..];
    _ = arena;
    return full;
}

pub fn runtimes(s: *Scan) scan_mod.Error!std.ArrayList(Item) {
    const arena = s.env.arena;
    var out: std.ArrayList(Item) = .empty;
    if (!s.env.system or s.developerDir() == null) return out;
    const listing = s.simctl(&.{ "runtime", "list", "-j" }) orelse return out;
    // Which runtime each SDK builds against, and which runtimes still carry
    // a device. Missing either answer means "unused" is never claimed.
    var chosen: ?std.StringHashMapUnmanaged(void) = null;
    if (s.simctl(&.{ "runtime", "match", "list", "-j" })) |matches| {
        if (obj(matches)) |m| {
            var set: std.StringHashMapUnmanaged(void) = .empty;
            var values = m.iterator();
            while (values.next()) |entry| {
                const per_target = obj(entry.value_ptr.*) orelse continue;
                const build = str(per_target.get("chosenRuntimeBuild") orelse continue) orelse continue;
                try set.put(arena, build, {});
            }
            chosen = set;
        }
    }
    var devices: ?std.json.ObjectMap = null;
    if (s.simctl(&.{ "list", "devices", "-j" })) |list| {
        if (obj(list)) |top| {
            if (obj(top.get("devices") orelse return out)) |map| devices = map;
        }
    }
    const list = obj(listing) orelse return out;
    var it = list.iterator();
    while (it.next()) |entry| {
        const runtime = obj(entry.value_ptr.*) orelse continue;
        if (!boolean(runtime.get("deletable") orelse continue)) continue;
        const version = str(runtime.get("version") orelse continue) orelse continue;
        const build = str(runtime.get("build") orelse continue) orelse continue;
        const identifier = entry.key_ptr.*;
        const platform = platformName(runtime.get("platformIdentifier") orelse .null);
        const last_used = runtime.get("lastUsedAt");
        const runtime_id = str(runtime.get("runtimeIdentifier") orelse continue) orelse continue;
        var unused = false;
        if (chosen) |*set| {
            if (!set.contains(build)) {
                const empty = if (devices) |*map| !map.contains(runtime_id) else true;
                unused = empty;
            }
        }
        const size: ?u64 = blk: {
            const n = integer(runtime.get("sizeBytes") orelse break :blk null) orelse break :blk null;
            if (n < 0) break :blk null;
            break :blk @intCast(n);
        };
        var modified: ?i64 = null;
        if (last_used) |value| {
            if (str(value)) |text| modified = @import("../mac.zig").parseIso8601(text);
        }
        const name = if (unused)
            try std.fmt.allocPrint(arena, "{s} {s} ({s}) · unused", .{ platform, version, build })
        else
            try std.fmt.allocPrint(arena, "{s} {s} ({s})", .{ platform, version, build });
        const detail = if (unused)
            "No installed Xcode builds against it and no simulator uses it. Xcode > Settings > Components can download it again."
        else
            "Simulators on this runtime stop working. Xcode > Settings > Components can download it again.";
        var full_detail: []const u8 = detail;
        if (last_used) |value| {
            if (str(value)) |text| {
                if (text.len >= 10) {
                    full_detail = try std.fmt.allocPrint(arena, "Last used {s}. {s}", .{ text[0..10], detail });
                }
            }
        }
        try out.append(arena, .{
            .id = try std.fmt.allocPrint(arena, "runtime-{s}", .{identifier}),
            .category = .runtimes,
            .name = name,
            .detail = full_detail,
            .size = size,
            .safety = .review,
            .action = .{ .command = .{ .program = xcrun, .args = try arena.dupe([]const u8, &.{ "simctl", "runtime", "delete", arena.dupe(u8, identifier) catch continue }) } },
            .reveal = if (runtime.get("path")) |p| str(p) else null,
            .modified = modified,
        });
    }
    scan_mod.bySize(out.items);
    return out;
}

fn platformName(identifier: std.json.Value) []const u8 {
    const full = str(identifier) orelse "";
    const known = [_]struct { from: []const u8, to: []const u8 }{
        .{ .from = "com.apple.platform.iphonesimulator", .to = "iOS" },
        .{ .from = "com.apple.platform.watchsimulator", .to = "watchOS" },
        .{ .from = "com.apple.platform.appletvsimulator", .to = "tvOS" },
        .{ .from = "com.apple.platform.xrsimulator", .to = "visionOS" },
    };
    for (known) |pair| {
        if (std.mem.eql(u8, full, pair.from)) return pair.to;
    }
    if (std.mem.lastIndexOfScalar(u8, full, '.')) |dot| return full[dot + 1 ..];
    return full;
}

pub fn xcode(s: *Scan) scan_mod.Error!std.ArrayList(Item) {
    const arena = s.env.arena;
    var out: std.ArrayList(Item) = .empty;
    const root = s.env.at("Library/Developer/Xcode");
    const entries = [_]struct {
        name: []const u8,
        relative: []const u8,
        detail: []const u8,
        safety: item_mod.Safety,
    }{
        .{ .name = "DerivedData", .relative = "DerivedData", .detail = "Build products and indexes. Xcode rebuilds them on the next build.", .safety = .safe },
        .{ .name = "iOS DeviceSupport", .relative = "iOS DeviceSupport", .detail = "Symbols copied from iPhones and iPads. Copied again on the next connection.", .safety = .safe },
        .{ .name = "watchOS DeviceSupport", .relative = "watchOS DeviceSupport", .detail = "Symbols copied from Apple Watches.", .safety = .safe },
        .{ .name = "tvOS DeviceSupport", .relative = "tvOS DeviceSupport", .detail = "Symbols copied from Apple TVs.", .safety = .safe },
        .{ .name = "visionOS DeviceSupport", .relative = "visionOS DeviceSupport", .detail = "Symbols copied from Vision Pro.", .safety = .safe },
        .{ .name = "Preview simulators", .relative = "UserData/Previews/Simulator Devices", .detail = "Devices SwiftUI previews start. Created again on demand.", .safety = .safe },
        .{ .name = "Archives", .relative = "Archives", .detail = "Release archives with dSYMs. Keep any build whose crashes you still symbolicate.", .safety = .review },
    };
    for (entries) |entry| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, entry.relative });
        const dirs = try arena.alloc([]const u8, 1);
        dirs[0] = path;
        if (scan_mod.dirItem(
            s,
            try std.fmt.allocPrint(arena, "xcode-{s}", .{entry.relative}),
            .xcode,
            entry.name,
            entry.detail,
            path,
            entry.safety,
            .{ .empty_directories = dirs },
            1,
        )) |found| try out.append(arena, found);
    }
    const xcode_caches = s.env.at("Library/Caches/com.apple.dt.Xcode");
    const dirs = try arena.alloc([]const u8, 1);
    dirs[0] = xcode_caches;
    if (scan_mod.dirItem(
        s,
        "xcode-caches",
        .xcode,
        "Xcode caches",
        "Documentation and download caches.",
        xcode_caches,
        .safe,
        .{ .empty_directories = dirs },
        MB,
    )) |found| try out.append(arena, found);

    if (!s.env.system) return out;
    // Without an answer there is no telling which Xcode is in use, and
    // offering the active one is the mistake to avoid.
    const active = s.developerDir() orelse return out;
    const apps = walker_mod.subdirectories("/Applications", arena) catch return out;
    defer arena.free(apps);
    for (apps) |app| {
        const name = scan_mod.nameOf(app);
        if (std.mem.startsWith(u8, name, "Xcode") and std.mem.endsWith(u8, name, ".app")) {
            if (std.mem.startsWith(u8, active, app)) continue;
            const app_dirs = try arena.alloc([]const u8, 1);
            app_dirs[0] = app;
            if (scan_mod.dirItem(
                s,
                try std.fmt.allocPrint(arena, "xcode-app-{s}", .{name}),
                .xcode,
                try std.fmt.allocPrint(arena, "Inactive {s}", .{name}),
                try std.fmt.allocPrint(arena, "Not the selected developer directory ({s}).", .{active}),
                app,
                .review,
                .{ .remove_paths = app_dirs },
                1,
            )) |found| try out.append(arena, found);
        }
    }
    scan_mod.bySize(out.items);
    return out;
}
