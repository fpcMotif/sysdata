//! sysdata: what Finder calls System Data, explained and reclaimable, from
//! the menu bar.
//!
//!   sysdata                 the menu bar item, click for the panel
//!   --window                 start with the panel as a window
//!   --fixture                the fixed sample list; nothing touches the disk
//!   --json                   the whole inventory as JSON, largest first
//!   --list                   the inventory as a table
//!   --measure <path>         one folder's allocated size
//!   --open <path>            reveal a path in Finder
const std = @import("std");
const nanoui = @import("nanoui");
const app_mod = @import("app.zig");
const menubar = @import("menubar.zig");
const scan_mod = @import("scan.zig");
const item_mod = @import("item.zig");
const json_mod = @import("json.zig");
const fixture_mod = @import("fixture.zig");
const walker_mod = @import("walker.zig");
const mac = @import("mac.zig");

const Mode = enum { menubar, window, json, list, measure, open };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var mode: Mode = .menubar;
    var fixture = false;
    var pin = false;
    var measure_path: ?[]const u8 = null;
    var open_path: ?[]const u8 = null;
    {
        var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
        defer args.deinit();
        _ = args.next();
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--json")) {
                mode = .json;
            } else if (std.mem.eql(u8, arg, "--list")) {
                mode = .list;
            } else if (std.mem.eql(u8, arg, "--window")) {
                mode = .window;
            } else if (std.mem.eql(u8, arg, "--pin")) {
                pin = true;
            } else if (std.mem.eql(u8, arg, "--fixture")) {
                fixture = true;
            } else if (std.mem.eql(u8, arg, "--measure")) {
                measure_path = args.next();
            } else if (std.mem.eql(u8, arg, "--open")) {
                open_path = args.next();
            } else if (std.mem.eql(u8, arg, "--help")) {
                mode = .list;
                fixture = false;
                measure_path = null;
                open_path = "help";
                break;
            }
        }
    }

    // The modes that answer and quit, without touching the screen.
    if (measure_path) |path| return printMeasured(init, path);
    if (open_path) |path| {
        if (std.mem.eql(u8, path, "help")) return usage(init);
        _ = nanoui.shell.showInFolder(path);
        return;
    }
    switch (mode) {
        .json, .list => return report(init, mode, fixture),
        else => {},
    }

    const app = try nanoui.App.create(init, .{
        .name = "sysdata",
        // Closing the panel leaves sysdata running in the menu bar.
        .quit_on_last_window_closed = false,
    });
    defer app.destroy();
    const a = try app_mod.SysApp.init(gpa, init.io, fixture);
    defer a.deinit();
    a.nano = app;
    if (fixture) a.loadFixture();

    var bar: menubar.MenuBar = .{ .a = a, .app = app };
    defer bar.hidePopover();
    if (menubar.supported) {
        bar.start();
        a.tray = bar.tray;
    }
    if (mode == .window or pin) {
        a.openPanel();
    } else if (!fixture) {
        a.startScan(false);
    }
    try app.run();
}

fn usage(init: std.process.Init) !void {
    var out = std.Io.Writer.Allocating.init(init.gpa);
    defer out.deinit();
    try out.writer.print(
        "sysdata: what Finder calls System Data, explained and reclaimable.\n" ++
            "  sysdata                the menu bar item, click for the panel\n" ++
            "  --window               start with the panel as a window\n" ++
            "  --fixture              the fixed sample list\n" ++
            "  --json                 the whole inventory as JSON\n" ++
            "  --list                 the inventory as a table\n" ++
            "  --measure <path>       one folder's allocated size\n" ++
            "  --open <path>          reveal a path in Finder\n",
        .{}
    );
    try std.Io.File.stdout().writeStreamingAll(init.io, out.written());
}

fn printMeasured(init: std.process.Init, path: []const u8) !void {
    walker_mod.prepare();
    var walker: walker_mod.Walker = undefined;
    walker.init(init.gpa, walker_mod.threadCount());
    defer walker.deinit();
    const measured = walker.measure(path);
    var buf: [32]u8 = undefined;
    var out = std.Io.Writer.Allocating.init(init.gpa);
    defer out.deinit();
    try out.writer.print("{d} bytes on disk ({s})\n", .{ measured.bytes, item_mod.formatBytes(&buf, measured.bytes) });
    try std.Io.File.stdout().writeStreamingAll(init.io, out.written());
}

/// `--json` and `--list`: run a scan, print the inventory, quit.
fn report(init: std.process.Init, mode: Mode, fixture: bool) !void {
    const gpa = init.gpa;
    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const arena = state.allocator();
    const space: mac.DiskSpace = if (fixture)
        .{ .free = 212_000_000_000, .capacity = 994_000_000_000 }
    else
        mac.diskSpace();
    // The scan's arenas own every item string: it lives until printing ends.
    var scan: ?*scan_mod.Scan = null;
    defer if (scan) |s| s.deinit();
    const items: []item_mod.Item = if (fixture)
        try fixture_mod.items(arena)
    else blk: {
        scan = try scan_mod.Scan.start(gpa, true);
        break :blk scan.?.scan(null, null);
    };

    var out = std.Io.Writer.Allocating.init(gpa);
    defer out.deinit();
    const w = &out.writer;
    if (mode == .json) {
        const text = try json_mod.inventory(arena, items, space, @import("clock.zig").now());
        try w.print("{s}\n", .{text});
    } else {
        var size: [32]u8 = undefined;
        try w.print("System Data found {s}\n", .{item_mod.formatBytes(&size, total(items))});
        for (items) |*i| {
            if (i.size) |bytes| {
                try w.print("{s}  {s}  {s}  {s}\n", .{ item_mod.formatBytes(&size, bytes), i.category.title(), i.name, i.safety.label() });
            } else {
                try w.print("—          {s}  {s}  {s}\n", .{ i.category.title(), i.name, i.safety.label() });
            }
        }
    }
    try std.Io.File.stdout().writeStreamingAll(init.io, out.written());
}

fn total(items: []const item_mod.Item) u64 {
    var sum: u64 = 0;
    for (items) |*i| sum += i.bytes();
    return sum;
}
