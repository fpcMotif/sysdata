//! sysdata's application state: the model, the scan running underneath it,
//! the delete batch, and the windows. Work happens on its own threads and
//! lands on the main thread through `objc.dispatchMain`, in order.
const std = @import("std");
const nanoui = @import("nanoui");
const model_mod = @import("model.zig");
const scan_mod = @import("scan.zig");
const reclaim = @import("reclaim.zig");
const mac = @import("mac.zig");
const proc = @import("proc.zig");
const walker_mod = @import("walker.zig");
const item_mod = @import("item.zig");

const Model = model_mod.Model;
const Item = item_mod.Item;

pub const popover_w: f64 = 480;
pub const popover_h: f64 = 660;

pub const SysApp = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    nano: ?*nanoui.App = null,
    model: *Model,
    home: []const u8,
    filter: nanoui.ui.TextBuffer = .{},
    /// The scan whose results the model shows; its arena keeps their strings.
    scan: ?*scan_mod.Scan = null,
    /// The previous scan, kept until the next results land (a quiet rescan
    /// still shows its rows).
    retired: ?*scan_mod.Scan = null,
    scan_thread: ?std.Thread = null,
    scan_quiet: bool = false,
    /// A pinned panel window (--window), or the menu bar's popover.
    window: ?*nanoui.Window = null,
    popover: ?*nanoui.Window = null,
    tray: ?*nanoui.Tray = null,
    /// Fixture mode: the list is fixed and nothing touches the disk.
    fixture: bool = false,
    /// The batch being deleted: its own arena, outliving the scan's.
    batch_arena: ?*std.heap.ArenaAllocator = null,
    batch_running: bool = false,
    /// Per-frame scratch, reset at the top of each frame.
    frame_arena: std.heap.ArenaAllocator,
    /// Breakdowns (a row's largest children) measured outside a scan.
    expand_arena: std.heap.ArenaAllocator,
    /// Fixture mode's items live for as long as the model shows them.
    fixture_arena: std.heap.ArenaAllocator,
    walker: walker_mod.Walker = undefined,
    walker_ready: bool = false,
    /// The window the next frame draws: pinned window or popover.
    prefer_window: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, fixture: bool) !*SysApp {
        const state_file = try std.fmt.allocPrint(gpa, "{s}/Library/Application Support/sysdata-zig/state.json", .{proc.home()});
        defer gpa.free(state_file);
        const self = try gpa.create(SysApp);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .model = try Model.load(gpa, state_file),
            .home = try gpa.dupe(u8, proc.home()),
            .fixture = fixture,
            .frame_arena = std.heap.ArenaAllocator.init(gpa),
            .expand_arena = std.heap.ArenaAllocator.init(gpa),
            .fixture_arena = std.heap.ArenaAllocator.init(gpa),
        };
        self.model.full_disk_access = scan_mod.hasFullDiskAccess(self.home);
        return self;
    }

    pub fn deinit(a: *SysApp) void {
        const gpa = a.gpa;
        if (a.scan_thread) |t| t.join();
        if (a.scan) |s| s.deinit();
        if (a.retired) |s| s.deinit();
        if (a.batch_arena) |arena| {
            arena.deinit();
            gpa.destroy(arena);
        }
        if (a.walker_ready) a.walker.deinit();
        a.expand_arena.deinit();
        a.frame_arena.deinit();
        a.fixture_arena.deinit();
        a.model.deinit();
        gpa.free(a.home);
        gpa.destroy(a);
    }

    // Scanning

    /// Starts a scan. A quiet rescan keeps the current list, selection and
    /// filter until the new results replace them.
    pub fn startScan(a: *SysApp, quiet: bool) void {
        if (a.model.scanning) return;
        if (a.fixture) return;
        if (a.scan_thread) |t| {
            // The previous scan's thread, long done; reclaim its handle.
            t.join();
            a.scan_thread = null;
        }
        a.scan_quiet = quiet;
        a.model.beginScan(quiet);
        const s = scan_mod.Scan.start(a.gpa, true) catch |e| {
            a.model.scanning = false;
            a.model.setErrorText(@errorName(e));
            a.redraw();
            return;
        };
        const run = a.gpa.create(ScanRun) catch {
            s.deinit();
            a.model.scanning = false;
            a.model.setErrorText("Out of memory.");
            a.redraw();
            return;
        };
        run.* = .{ .app = a, .scan = s };
        a.retired = a.scan;
        a.scan = s;
        a.scan_thread = std.Thread.spawn(.{}, scanThread, .{run}) catch blk: {
            // Rare: the scan still runs, on this thread.
            scanThread(run);
            break :blk null;
        };
        a.redraw();
    }

    const ScanRun = struct { app: *SysApp, scan: *scan_mod.Scan };
    const ScanDone = struct { app: *SysApp, scan: *scan_mod.Scan, items: []Item };
    const ProgressHop = struct { app: *SysApp, progress: scan_mod.Progress };

    fn scanThread(run_in: *ScanRun) void {
        const run = run_in.*;
        run.app.gpa.destroy(run_in);
        const items = run.scan.scan(null, .{ .ctx = run.app, .func = onProgress });
        // Preallocated would be nicer, but a failed hop must still end the
        // scan: spin until the main thread can hear about it.
        while (true) {
            const done = run.app.gpa.create(ScanDone) catch {
                @import("clock.zig").sleepMs(50);
                continue;
            };
            done.* = .{ .app = run.app, .scan = run.scan, .items = items };
            nanoui.objc.dispatchMain(done, scanDoneOnMain);
            return;
        }
    }

    /// Called on the scan's thread: hops to the main thread.
    fn onProgress(ctx: *anyopaque, progress: scan_mod.Progress) void {
        const a: *SysApp = @ptrCast(@alignCast(ctx));
        const hop = a.gpa.create(ProgressHop) catch return;
        hop.* = .{ .app = a, .progress = progress };
        nanoui.objc.dispatchMain(hop, progressOnMain);
    }

    fn progressOnMain(ctx: ?*anyopaque) callconv(.c) void {
        const hop: *ProgressHop = @ptrCast(@alignCast(ctx));
        defer hop.app.gpa.destroy(hop);
        hop.app.model.acceptProgress(hop.progress, hop.app.scan_quiet);
        hop.app.redraw();
    }

    fn scanDoneOnMain(ctx: ?*anyopaque) callconv(.c) void {
        const done: *ScanDone = @ptrCast(@alignCast(ctx));
        defer done.app.gpa.destroy(done);
        const a = done.app;
        a.model.finishScan(done.items, mac.diskSpace());
        // The rows the model used to show are gone from it; the scan that
        // held their strings can go.
        if (a.retired) |old| {
            old.deinit();
            a.retired = null;
        }
        a.updateTray();
        a.redraw();
    }

    // Deleting

    /// Runs the pending delete after its confirmation. The batch owns its
    /// strings, so it survives the scan it came from.
    pub fn runPending(a: *SysApp) void {
        if (a.batch_running) return;
        if (a.model.pending == null) return;
        const arena = a.gpa.create(std.heap.ArenaAllocator) catch return;
        arena.* = std.heap.ArenaAllocator.init(a.gpa);
        const batch = a.model.takePending(arena.allocator()) catch {
            arena.deinit();
            a.gpa.destroy(arena);
            return;
        };
        if (batch.len == 0) {
            arena.deinit();
            a.gpa.destroy(arena);
            a.redraw();
            return;
        }
        const run = a.gpa.create(BatchRun) catch {
            arena.deinit();
            a.gpa.destroy(arena);
            return;
        };
        run.* = .{ .app = a, .arena = arena, .items = batch, .home = a.home };
        a.batch_running = true;
        a.batch_arena = arena;
        a.redraw();
        const thread = std.Thread.spawn(.{}, batchThread, .{run}) catch null;
        if (thread == null) batchThread(run) else thread.?.detach();
    }

    const BatchRun = struct { app: *SysApp, arena: *std.heap.ArenaAllocator, items: []Item, home: []const u8 };
    const EventHop = struct { app: *SysApp, event: reclaim.Event };

    fn batchThread(run: *BatchRun) void {
        reclaim.runBatch(
            run.items,
            .{ .home = run.home, .safe_to_trash = run.app.model.safe_to_trash, .allow_admin = true },
            run.arena.allocator(),
            run.app.gpa,
            .{ .ctx = run, .func = onBatchEvent },
        );
        // The last hop, after every event's, frees the batch.
        nanoui.objc.dispatchMain(run, batchDoneOnMain);
    }

    /// Called on the batch's thread: hops to the main thread.
    fn onBatchEvent(ctx: *anyopaque, event: reclaim.Event) void {
        const run: *BatchRun = @ptrCast(@alignCast(ctx));
        const hop = run.app.gpa.create(EventHop) catch return;
        hop.* = .{ .app = run.app, .event = event };
        nanoui.objc.dispatchMain(hop, eventOnMain);
    }

    fn eventOnMain(ctx: ?*anyopaque) callconv(.c) void {
        const hop: *EventHop = @ptrCast(@alignCast(ctx));
        defer hop.app.gpa.destroy(hop);
        hop.app.model.apply(hop.event);
        hop.app.updateTray();
        hop.app.redraw();
    }

    fn batchDoneOnMain(ctx: ?*anyopaque) callconv(.c) void {
        const run: *BatchRun = @ptrCast(@alignCast(ctx));
        const a = run.app;
        run.arena.deinit();
        a.gpa.destroy(run.arena);
        a.gpa.destroy(run);
        a.batch_running = false;
        a.batch_arena = null;
        a.updateTray();
        a.redraw();
    }

    // Rows expanded outside a scan: the largest direct children.

    pub fn breakdown(a: *SysApp, id: []const u8, reveal: []const u8) ?[]model_mod.Breakdown {
        if (a.model.breakdowns.get(id)) |found| return found;
        if (!a.walker_ready) {
            a.walker.init(a.gpa, walker_mod.threadCount());
            a.walker.known = null;
            a.walker_ready = true;
        }
        var children: std.ArrayList(walker_mod.Child) = .empty;
        const arena = a.expand_arena.allocator();
        walker_mod.children(reveal, arena, &children) catch return null;
        var rows: std.ArrayList(model_mod.Breakdown) = .empty;
        for (children.items) |child| {
            const measured = a.walker.measure(child.path);
            rows.append(arena, .{ .path = child.path, .bytes = measured.bytes, .is_dir = child.kind == .dir }) catch {};
        }
        std.mem.sort(model_mod.Breakdown, rows.items, {}, struct {
            fn lt(_: void, x: model_mod.Breakdown, y: model_mod.Breakdown) bool {
                if (x.bytes != y.bytes) return x.bytes > y.bytes;
                return std.mem.lessThan(u8, x.path, y.path);
            }
        }.lt);
        const shown = if (rows.items.len > 6) rows.items[0..6] else rows.items;
        a.model.breakdowns.put(a.gpa, id, shown) catch {};
        return shown;
    }

    /// Fixture mode: the list is fixed and nothing touches the disk.
    pub fn loadFixture(a: *SysApp) void {
        a.fixture = true;
        const items = @import("fixture.zig").items(a.fixture_arena.allocator()) catch return;
        a.model.finishScan(items, .{ .free = 212_000_000_000, .capacity = 994_000_000_000 });
        a.updateTray();
    }

    // Windows

    pub fn openPanel(a: *SysApp) void {
        const app = a.nano orelse return;
        if (a.window) |w| return w.focus();
        a.window = app.newWindow(.{
            .title = "System Data",
            .width = 560,
            .height = 680,
            .min_width = 480,
            .min_height = 420,
            .resizable = true,
            .theme = @import("theme.zig").ui(nanoui.isDark()),
            .content = .{ .view = .init(a, @import("panel.zig").view) },
        }) catch return;
        a.window.?.focus();
        a.startScan(false);
    }

    /// Draws the panel, the popover, or both.
    pub fn redraw(a: *SysApp) void {
        if (a.window) |w| w.redraw();
        if (a.popover) |p| if (p.isVisible()) p.redraw();
    }

    pub fn updateTray(a: *SysApp) void {
        const tray = a.tray orelse return;
        var buf: [32]u8 = undefined;
        tray.setTitle(item_mod.formatBytes(&buf, a.model.measuredBytes()));
    }

    pub fn windowHeight(a: *SysApp) f64 {
        _ = a;
        return popover_h;
    }
};
