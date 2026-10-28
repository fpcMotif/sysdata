//! The few Foundation calls the scanner needs: the disk's figures and the
//! small property lists that name things (a backup's device, the app that
//! owns a folder). Finder's own calls — the Trash, reveal — live in
//! nanoui's shell, and are used directly where they are needed.
const std = @import("std");
const nanoui = @import("nanoui");

/// Seconds since the epoch, now.
pub fn now() i64 {
    return @import("clock.zig").now();
}

pub const DiskSpace = struct {
    free: u64 = 0,
    capacity: u64 = 0,
    /// What macOS says it could give back if something important needed
    /// room: available-for-important-usage minus available. An estimate,
    /// not an allocation.
    purgeable: u64 = 0,
};

/// The startup volume's free, total and purgeable bytes, from the same
/// keys Storage settings reads.
pub fn diskSpace() DiskSpace {
    const objc = nanoui.objc;
    const pool = objc.Pool.push();
    defer pool.pop();
    const url = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString("/")});
    const value = struct {
        fn read(u: objc.Object, key: []const u8) i64 {
            var out: ?objc.Object = null;
            var err: ?objc.Object = null;
            const found = objc.msg(objc.BOOL, u, "getResourceValue:forKey:error:", .{
                &out, objc.nsString(key), &err,
            });
            if (!found) return 0;
            const v = out orelse return 0;
            return objc.msg(i64, v, "longLongValue", .{});
        }
    }.read;
    const free = @max(0, value(url, "NSURLVolumeAvailableCapacityKey"));
    const capacity = @max(0, value(url, "NSURLVolumeTotalCapacityKey"));
    const important = @max(0, value(url, "NSURLVolumeAvailableCapacityForImportantUsageKey"));
    return .{
        .free = free,
        .capacity = capacity,
        .purgeable = important -| free,
    };
}

pub const PlistValue = union(enum) {
    text: []const u8,
    /// Seconds since the epoch.
    date: i64,
};

/// Top-level values of a property list, XML or binary. Text is copied into
/// `gpa`; missing keys stay null.
pub fn plistValues(
    gpa: std.mem.Allocator,
    path: []const u8,
    keys: []const []const u8,
    out: []?PlistValue,
) void {
    for (out) |*slot| slot.* = null;
    const objc = nanoui.objc;
    const pool = objc.Pool.push();
    defer pool.pop();
    const dict = objc.msg(?objc.Object, objc.class("NSDictionary"), "dictionaryWithContentsOfFile:", .{
        objc.nsString(path),
    }) orelse return;
    for (keys, 0..) |key, i| {
        const value = objc.msg(?objc.Object, dict, "objectForKey:", .{objc.nsString(key)}) orelse continue;
        if (objc.msg(objc.BOOL, value, "isKindOfClass:", .{objc.class("NSString")})) {
            out[i] = .{ .text = gpa.dupe(u8, objc.fromNSString(value)) catch continue };
        } else if (objc.msg(objc.BOOL, value, "isKindOfClass:", .{objc.class("NSDate")})) {
            const secs = objc.msg(f64, value, "timeIntervalSince1970", .{});
            out[i] = .{ .date = @intFromFloat(@max(0, secs)) };
        }
    }
}

/// One string from a property list, copied into `gpa`.
pub fn plistString(gpa: std.mem.Allocator, path: []const u8, key: []const u8) ?[]u8 {
    var value: [1]?PlistValue = .{null};
    plistValues(gpa, path, &.{key}, &value);
    return switch (value[0] orelse return null) {
        .text => |t| @constCast(t),
        .date => null,
    };
}

/// Seconds since the epoch as a UTC calendar date, Howard Hinnant's
/// days-to-civil.
pub const Civil = struct { year: i64, month: u32, day: u32, hour: u32, minute: u32, second: u32 };

pub fn civil(seconds: i64) Civil {
    const days = @divFloor(seconds, 86_400);
    const rest = @mod(seconds, 86_400);
    const z = days + 719_468;
    const era = @divFloor(z, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divFloor(doe - @divFloor(doe, 1_460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day: u32 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const month: u32 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    const year = yoe + era * 400 + @as(i64, if (month <= 2) 1 else 0);
    return .{
        .year = year,
        .month = month,
        .day = day,
        .hour = @intCast(@divFloor(rest, 3_600)),
        .minute = @intCast(@mod(@divFloor(rest, 60), 60)),
        .second = @intCast(@mod(rest, 60)),
    };
}

pub fn iso8601(buf: []u8, seconds: i64) []const u8 {
    const c = civil(seconds);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u64, @intCast(@max(0, c.year))), c.month, c.day, c.hour, c.minute, c.second,
    }) catch "1970-01-01T00:00:00Z";
}

pub fn date(buf: []u8, seconds: i64) []const u8 {
    const c = civil(seconds);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(@max(0, c.year))), c.month, c.day }) catch "1970-01-01";
}

/// Parses `2026-09-26T10:36:28Z`, with or without fractional seconds.
pub fn parseIso8601(text: []const u8) ?i64 {
    const trimmed = std.mem.trim(u8, text, " \t");
    const without_z = if (trimmed.len > 0 and trimmed[trimmed.len - 1] == 'Z')
        trimmed[0 .. trimmed.len - 1]
    else
        trimmed;
    const t = std.mem.indexOfScalar(u8, without_z, 'T') orelse return null;
    const date_part = without_z[0..t];
    var time_part = without_z[t + 1 ..];
    if (std.mem.indexOfAny(u8, time_part, "+.")) |cut| time_part = time_part[0..cut];
    var date_it = std.mem.splitScalar(u8, date_part, '-');
    const y = std.fmt.parseInt(i64, date_it.next() orelse return null, 10) catch return null;
    const m = std.fmt.parseInt(i64, date_it.next() orelse return null, 10) catch return null;
    const d = std.fmt.parseInt(i64, date_it.next() orelse return null, 10) catch return null;
    var time_it = std.mem.splitScalar(u8, time_part, ':');
    const h = std.fmt.parseInt(i64, time_it.next() orelse return null, 10) catch return null;
    const mi = std.fmt.parseInt(i64, time_it.next() orelse return null, 10) catch return null;
    const s = std.fmt.parseInt(i64, time_it.next() orelse return null, 10) catch return null;
    // Days-from-civil, the inverse of `civil`.
    const y_adj = if (m <= 2) y - 1 else y;
    const era = @divFloor(y_adj, 400);
    const yoe = y_adj - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146_097 + doe - 719_468;
    const secs = days * 86_400 + h * 3_600 + mi * 60 + s;
    if (secs < 0) return null;
    return secs;
}

test "iso dates round trip" {
    var buf: [32]u8 = undefined;
    const t = parseIso8601("2026-09-26T10:36:28Z").?;
    try std.testing.expectEqualStrings("2026-09-26T10:36:28Z", iso8601(&buf, t));
    var short: [16]u8 = undefined;
    try std.testing.expectEqualStrings("2024-02-29", date(&short, parseIso8601("2024-02-29T00:00:00.123Z").?));
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", iso8601(&buf, 0));
}

test "disk space is plausible" {
    const space = diskSpace();
    try std.testing.expect(space.capacity > space.free);
    try std.testing.expect(space.free > 0);
}
