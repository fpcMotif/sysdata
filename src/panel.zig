//! The panel: a headline number, the groups of what a scan found with
//! their rows, and the sheet that confirms a delete. Every selection rule
//! lives in the model; this only draws and reports clicks.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_mod = @import("app.zig");
const theme = @import("theme.zig");
const model_mod = @import("model.zig");
const item_mod = @import("item.zig");
const scan_mod = @import("scan.zig");

const SysApp = app_mod.SysApp;
const Model = model_mod.Model;
const Item = item_mod.Item;

pub fn view(a: *SysApp, c: *ui.Context) void {
    _ = a.frame_arena.reset(.retain_capacity);
    const frame = a.frame_arena.allocator();
    const dark = nanoui.isDark();
    c.theme = theme.ui(dark);
    const k = theme.colors(dark);
    keys(c, a);
    const root = ui.div(c).column().sizeFull().bg(k.page);
    defer root.end();
    header(c, a, k);
    toolbar(c, a);
    banners(c, a, k);
    {
        const body = ui.div(c).column().grow().w(0).scrollY().px(16).pb(16).gap(10).clip();
        defer body.end();
        if (a.model.scanned and a.model.items.items.len == 0) {
            ui.text(c, "Nothing to reclaim: no known location reached its threshold.", .{ .size = 12, .color = k.secondary, .wrap = true });
        }
        const grouped = a.model.groups(frame) catch return;
        for (grouped) |group| {
            groupHeader(c, a, k, group);
            if (a.model.collapsed.contains(group.category)) continue;
            for (group.items) |i| row(c, a, k, i);
        }
    }
    sheet(c, a, k, frame);
}

/// Escape closes the sheet, ⌘R rescans, ⌘S ticks every listed Safe row.
fn keys(c: *ui.Context, a: *SysApp) void {
    const S = ui.Shortcut;
    if (c.shortcut(.{ .key = S.escape })) {
        if (a.model.pending != null) {
            a.model.pending = null;
            c.changed = true;
        }
    }
    if (c.shortcut(.{ .key = 'r', .cmd = true })) a.startScan(true);
    if (c.shortcut(.{ .key = 's', .cmd = true })) {
        a.model.toggleSafe();
        c.changed = true;
    }
}

fn header(c: *ui.Context, a: *SysApp, k: theme.Colors) void {
    const m = a.model;
    const head = ui.div(c).row().wFull().p(16).gap(10).itemsCenter();
    defer head.end();
    {
        const title = ui.div(c).column().gap(1);
        defer title.end();
        ui.text(c, "System Data", .{ .size = 16, .weight = .bold, .color = k.text });
        if (m.scanning) {
            ui.text(c, m.phase, .{ .size = 11, .color = k.secondary });
        } else if (m.space.capacity > 0) {
            var free: [32]u8 = undefined;
            var all: [32]u8 = undefined;
            ui.text(
                c,
                c.print("{s} free of {s}", .{
                    item_mod.formatBytes(&free, m.space.free),
                    item_mod.formatBytes(&all, m.space.capacity),
                }),
                .{ .size = 11, .color = k.secondary },
            );
        }
    }
    ui.spacer(c);
    if (m.reclaimed > 0) {
        var freed: [32]u8 = undefined;
        ui.text(c, c.print("{s} reclaimed", .{item_mod.formatBytes(&freed, m.reclaimed)}), .{ .size = 11, .color = k.safe });
    }
    var measured: [32]u8 = undefined;
    ui.text(c, item_mod.formatBytes(&measured, m.measuredBytes()), .{ .size = 22, .weight = .bold, .mono = true, .color = k.text });
}

fn toolbar(c: *ui.Context, a: *SysApp) void {
    const m = a.model;
    const bar = ui.div(c).row().wFull().px(16).pb(10).gap(8).itemsCenter();
    defer bar.end();
    const res = ui.textField(c, &a.filter, .{ .placeholder = "Filter", .width = .{ .px = 180 }, .size = 12 });
    if (res.changed) m.setFilter(a.filter.text());
    const safe_all = if (m.allSafeSelected()) "Clear Safe" else "Select Safe";
    if (ui.button(c, safe_all, .{ .variant = .secondary, .size = 12 }).clicked) {
        m.toggleSafe();
        c.changed = true;
    }
    if (ui.checkbox(c, "Safe to Trash", &m.safe_to_trash)) m.setSafeToTrash(m.safe_to_trash);
    ui.spacer(c);
    if (m.hiddenCount() > 0) {
        if (ui.button(c, c.print("Show {d} hidden", .{m.hiddenCount()}), .{ .variant = .secondary, .size = 12 }).clicked) {
            m.unhideAll();
            c.changed = true;
        }
    }
    const scan_label = if (m.scanning) "Scanning…" else "Rescan";
    const scan_button = ui.button(c, scan_label, .{ .variant = .secondary, .size = 12 });
    if (scan_button.clicked and !m.scanning) a.startScan(true);
    if (m.scanning) c.frameIn(0.25);
}

fn banners(c: *ui.Context, a: *SysApp, k: theme.Colors) void {
    const m = a.model;
    if (m.error_text.len == 0 and m.notice.len == 0) return;
    const outer = ui.div(c).column().wFull().px(16).gap(8);
    defer outer.end();
    if (m.error_text.len > 0) {
        const box = ui.div(c).row().wFull().p(10).rounded(8).bg(k.danger.alpha(0.12)).border(k.danger.alpha(0.4)).gap(8);
        defer box.end();
        ui.text(c, m.error_text, .{ .size = 11.5, .color = k.danger, .wrap = true });
    }
    if (m.notice.len > 0) {
        const box = ui.div(c).row().wFull().p(10).rounded(8).bg(k.card).border(k.border).gap(8);
        defer box.end();
        ui.text(c, m.notice, .{ .size = 11.5, .color = k.secondary, .wrap = true });
    }
}

fn groupHeader(c: *ui.Context, a: *SysApp, k: theme.Colors, group: model_mod.Group) void {
    const m = a.model;
    const collapsed = m.collapsed.contains(group.category);
    const head = ui.div(c).row().wFull().h(26).gap(6).itemsCenter();
    const hit = head.interaction();
    defer head.end();
    if (hit.clicked) {
        m.toggleCollapsed(group.category);
        c.changed = true;
    }
    const chevron = if (collapsed) "chevron.right" else "chevron.down";
    ui.icon(c, chevron, .{ .size = 10, .weight = .bold, .color = k.tertiary });
    if (m.categorySelectable(group.category)) {
        var tick = m.categorySelected(group.category);
        if (ui.checkbox(c, "", &tick)) {
            m.setCategorySelected(group.category, tick);
            c.changed = true;
        }
    }
    ui.text(c, group.category.title(), .{ .size = 12.5, .weight = .semibold, .color = k.text });
    ui.text(c, c.print("({d})", .{group.items.len}), .{ .size = 11, .color = k.tertiary });
    ui.spacer(c);
    var total: [32]u8 = undefined;
    ui.text(c, item_mod.formatBytes(&total, group.total), .{ .size = 11.5, .mono = true, .color = k.secondary });
}

fn row(c: *ui.Context, a: *SysApp, k: theme.Colors, i: *const Item) void {
    const m = a.model;
    ui.key(c, i.id);
    const manual = i.action.isManual();
    const busy = m.busy.contains(i.id);
    const card = ui.div(c).column().wFull().gap(5).p(10).rounded(8).bg(k.card).border(k.border);
    const it = card.interaction();
    defer card.end();

    {
        const line = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer line.end();
        if (manual) {
            ui.text(c, "Manual", .{ .size = 10, .weight = .bold, .color = k.manual });
        } else if (busy) {
            ui.text(c, "Deleting…", .{ .size = 10, .weight = .bold, .color = k.accent });
        } else {
            var tick = m.selected.contains(i.id);
            if (ui.checkbox(c, "", &tick)) {
                m.setSelected(i.id, tick, shiftClick(c));
                c.changed = true;
            }
        }
        ui.text(c, i.name, .{ .size = 12.5, .weight = .semibold, .color = k.text, .wrap = true });
        if (idleLabel(c, i)) |label| {
            ui.text(c, label, .{ .size = 10.5, .color = k.tertiary });
        }
        ui.spacer(c);
        var size: [32]u8 = undefined;
        ui.text(c, if (i.size) |b| item_mod.formatBytes(&size, b) else "—", .{ .size = 12, .mono = true, .color = k.text });
        ui.text(c, i.safety.label(), .{ .size = 10, .weight = .bold, .color = switch (i.safety) {
            .safe => k.safe,
            .review => k.review,
            .manual => k.manual,
        } });
        if (it.hovered or busy) {
            rowButtons(c, a, i, manual);
        }
    }
    ui.text(c, i.detail, .{ .size = 11.5, .color = k.secondary, .wrap = true });
    if (manual) {
        if (i.action.manualInstructions()) |text| {
            const box = ui.div(c).column().wFull().gap(2).p(8).rounded(6).bg(k.page).border(k.separator);
            defer box.end();
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |line| {
                ui.text(c, line, .{ .size = 11, .mono = true, .color = k.text });
            }
        }
    }
    if (m.expanded.contains(i.id)) {
        if (i.reveal) |path| {
            if (a.breakdown(i.id, path)) |entries| breakdown(c, a, k, entries);
        }
    }
}

/// A shift-click extends the selection from the last clicked row.
fn shiftClick(c: *ui.Context) bool {
    return c.input.shift;
}

fn idleLabel(c: *ui.Context, i: *const Item) ?[]const u8 {
    var buf: [40]u8 = undefined;
    const label = i.idleLabel(&buf, @import("clock.zig").now()) orelse return null;
    return c.print("{s}", .{label});
}

fn rowButtons(c: *ui.Context, a: *SysApp, i: *const Item, manual: bool) void {
    const m = a.model;
    if (i.reveal) |path| {
        if (ui.button(c, "Show", .{ .variant = .secondary, .size = 11 }).clicked) {
            _ = nanoui.shell.showInFolder(path);
        }
    }
    if (!manual and !m.busy.contains(i.id)) {
        if (ui.button(c, "Delete…", .{ .variant = .danger, .size = 11 }).clicked) {
            m.pending = .{ .one = i.id };
            c.changed = true;
        }
    }
    if (!m.busy.contains(i.id)) {
        if (ui.button(c, "Hide", .{ .variant = .secondary, .size = 11 }).clicked) {
            m.hide(i.id);
            c.changed = true;
        }
    }
}

fn breakdown(c: *ui.Context, a: *SysApp, k: theme.Colors, entries: []model_mod.Breakdown) void {
    const box = ui.div(c).column().wFull().gap(3).p(8).rounded(6).bg(k.page).border(k.separator);
    defer box.end();
    const top: f32 = if (entries.len > 0) @floatFromInt(entries[0].bytes) else 0;
    for (entries) |entry| {
        if (entry.bytes == 0) continue;
        const line = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer line.end();
        var size: [32]u8 = undefined;
        ui.text(c, item_mod.formatBytes(&size, entry.bytes), .{ .size = 10.5, .mono = true, .color = k.secondary });
        _ = c.leaf(.{ .width = .{ .px = @max(2, 160 * @as(f32, @floatFromInt(entry.bytes)) / @max(top, 1)) }, .height = .{ .px = 4 }, .radius = 2, .background = k.accent }, .none, null);
        ui.text(
            c,
            c.print("{s}", .{scan_mod.abbreviate(a.frame_arena.allocator(), entry.path, a.home)}),
            .{ .size = 10.5, .color = k.tertiary, .wrap = true },
        );
    }
}

/// "Delete this?": what runs, what goes to the Trash, and the buttons.
fn sheet(c: *ui.Context, a: *SysApp, k: theme.Colors, frame: std.mem.Allocator) void {
    const m = a.model;
    if (m.pending == null) return;
    const text = m.confirmation(frame) catch return;
    const off_screen = m.selectedOffScreen();
    const scrim = ui.div(c).absolute().sizeFull().column().itemsCenter().bg(.{ .a = 0.18 });
    defer scrim.end();
    if (scrim.clicked()) {
        m.pending = null;
        c.changed = true;
    }
    {
        const gap = ui.div(c).row().h(48);
        gap.end();
    }
    const box = ui.div(c).column().w(440).gap(10).p(18).rounded(12).bg(k.card).border(k.border).shadowLg();
    defer box.end();
    _ = box.interaction();
    ui.text(c, text.title, .{ .size = 14, .weight = .bold, .color = k.text });
    if (text.body.len > 0) ui.text(c, text.body, .{ .size = 11.5, .color = k.text, .wrap = true });
    const plan = m.pendingPlan(frame) catch return;
    if (plan.len > 0) {
        const list = ui.div(c).column().wFull().gap(2).p(8).rounded(8).bg(k.page).border(k.separator);
        defer list.end();
        for (plan) |line| {
            ui.text(c, line, .{ .size = 10.5, .mono = true, .color = k.secondary, .wrap = true });
        }
    }
    if (off_screen > 0) {
        ui.text(
            c,
            c.print("{d} selected row{s} hidden by the filter or a folded group are in this batch.", .{ off_screen, if (off_screen == 1) " is" else "s are" }),
            .{ .size = 11, .color = k.review, .wrap = true },
        );
    }
    {
        const buttons = ui.div(c).row().wFull().gap(8).pt(4);
        defer buttons.end();
        if (ui.button(c, "Cancel", .{ .variant = .secondary, .size = 12 }).clicked) {
            m.pending = null;
            c.changed = true;
        }
        ui.spacer(c);
        if (ui.button(c, "Delete", .{ .variant = .danger, .size = 12 }).clicked) {
            a.runPending();
            c.changed = true;
        }
    }
}
