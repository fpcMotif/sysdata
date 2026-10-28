//! `sysdata --json`: the whole inventory for scripts, largest first. Same
//! shape as the Swift app's `--json`, so the two can be compared line by
//! line.
const std = @import("std");
const item_mod = @import("item.zig");
const mac = @import("mac.zig");

const Item = item_mod.Item;

pub fn inventory(arena: std.mem.Allocator, items: []const Item, space: mac.DiskSpace, now: i64) ![]const u8 {
    var sorted: std.ArrayList(*const Item) = .empty;
    for (items) |*i| try sorted.append(arena, i);
    std.mem.sort(*const Item, sorted.items, {}, struct {
        fn lt(_: void, x: *const Item, y: *const Item) bool {
            if (x.bytes() != y.bytes()) return x.bytes() > y.bytes();
            return std.mem.lessThan(u8, x.id, y.id);
        }
    }.lt);

    var total: u64 = 0;
    for (sorted.items) |i| total += i.bytes();

    var out: std.ArrayList(u8) = .empty;
    var generated: [32]u8 = undefined;
    var modified: [32]u8 = undefined;
    try out.appendSlice(arena, "{\"generatedAt\": \"");
    try out.appendSlice(arena, mac.iso8601(&generated, now));
    try out.appendSlice(arena, "\", \"freeBytes\": ");
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{space.free}));
    try out.appendSlice(arena, ", \"purgeableBytes\": ");
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{space.purgeable}));
    try out.appendSlice(arena, ", \"totalBytes\": ");
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{total}));
    try out.appendSlice(arena, ", \"items\": [");
    for (sorted.items, 0..) |item, n| {
        if (n > 0) try out.appendSlice(arena, ",");
        try out.appendSlice(arena, "{\"id\": ");
        try appendString(arena, &out, item.id);
        try out.appendSlice(arena, ", \"category\": ");
        try appendString(arena, &out, item.category.key());
        try out.appendSlice(arena, ", \"name\": ");
        try appendString(arena, &out, item.name);
        try out.appendSlice(arena, ", \"detail\": ");
        try appendString(arena, &out, item.detail);
        try out.appendSlice(arena, ", \"sizeBytes\": ");
        try out.appendSlice(arena, if (item.size) |size| try std.fmt.allocPrint(arena, "{d}", .{size}) else "null");
        try out.appendSlice(arena, ", \"safety\": ");
        try appendString(arena, &out, item.safety.key());
        try out.appendSlice(arena, ", \"manual\": ");
        try out.appendSlice(arena, if (item.action.isManual()) "true" else "false");
        try out.appendSlice(arena, ", \"path\": ");
        if (item.reveal) |path| {
            try appendString(arena, &out, path);
        } else {
            try out.appendSlice(arena, "null");
        }
        try out.appendSlice(arena, ", \"lastModified\": ");
        if (item.modified) |seconds| {
            try out.appendSlice(arena, "\"");
            try out.appendSlice(arena, mac.iso8601(&modified, seconds));
            try out.appendSlice(arena, "\"");
        } else {
            try out.appendSlice(arena, "null");
        }
        try out.appendSlice(arena, ", \"idleDays\": ");
        try out.appendSlice(arena, if (item.idleDays(now)) |days| try std.fmt.allocPrint(arena, "{d}", .{days}) else "null");
        try out.appendSlice(arena, "}");
    }
    try out.appendSlice(arena, "]}");
    return out.items;
}

fn appendString(arena: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(arena, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(arena, "\\\""),
            '\\' => try out.appendSlice(arena, "\\\\"),
            '\n' => try out.appendSlice(arena, "\\n"),
            '\r' => try out.appendSlice(arena, "\\r"),
            '\t' => try out.appendSlice(arena, "\\t"),
            else => {
                if (c < 0x20) {
                    const escaped = try std.fmt.allocPrint(arena, "\\u{x:0>4}", .{c});
                    defer arena.free(escaped);
                    try out.appendSlice(arena, escaped);
                } else {
                    try out.append(arena, c);
                }
            },
        }
    }
    try out.append(arena, '"');
}

test "the inventory lists the largest first" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var size_buf: [32]u8 = undefined;
    _ = &size_buf;
    const a = Item{
        .id = "small",
        .category = .packages,
        .name = "Small",
        .detail = "",
        .size = 100,
        .safety = .safe,
        .action = .{ .remove_paths = &.{"/tmp/a"} },
    };
    const b = Item{
        .id = "big",
        .category = .tools,
        .name = "Big",
        .detail = "quoted \"name\"",
        .size = 900,
        .safety = .review,
        .action = .{ .manual = "" },
        .reveal = "/tmp/b",
        .modified = 100,
    };
    const text = try inventory(arena, &.{ a, b }, .{ .free = 5 }, 100);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"id\": \"big\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"id\": \"small\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "quoted \\\"name\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"idleDays\": null") != null);
    const big_at = std.mem.indexOf(u8, text, "\"id\": \"big\"").?;
    const small_at = std.mem.indexOf(u8, text, "\"id\": \"small\"").?;
    try std.testing.expect(big_at < small_at);
}
