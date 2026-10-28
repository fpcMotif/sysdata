//! sysdata in the menu bar: the System Data total beside the clock, a click
//! opens the panel under it. The title is plain text, so it takes the menu
//! bar's color by itself; no window is shown until it is asked for.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const app_mod = @import("app.zig");
const theme = @import("theme.zig");
const item_mod = @import("item.zig");

pub const supported = builtin.os.tag == .macos;

pub const MenuBar = struct {
    a: *app_mod.SysApp,
    app: *nanoui.App,
    tray: ?*nanoui.Tray = null,
    popover: ?*nanoui.Window = null,

    pub fn start(m: *MenuBar) void {
        if (comptime !supported) return;
        m.tray = m.app.newTray(.{
            .tooltip = "System Data",
            .on_click = .{ .ctx = m, .func = clicked },
        }) catch return;
        m.update();
    }

    pub fn update(m: *MenuBar) void {
        const tray = m.tray orelse return;
        var buf: [32]u8 = undefined;
        tray.setTitle(item_mod.formatBytes(&buf, m.a.model.measuredBytes()));
    }

    fn clicked(ctx: *anyopaque, _: *nanoui.Tray) void {
        const m: *MenuBar = @ptrCast(@alignCast(ctx));
        m.toggle();
    }

    /// Opens the panel under the title, or closes it.
    pub fn toggle(m: *MenuBar) void {
        if (m.popover) |p| {
            if (p.isVisible()) return p.hide();
            if (p.justHidden()) return;
        } else {
            m.popover = m.app.newWindow(.{
                .title = "System Data",
                .width = app_mod.popover_w,
                .height = app_mod.popover_h,
                .resizable = false,
                .title_bar = .popover,
                .visible = false,
                .theme = theme.ui(nanoui.isDark()),
                .content = .{ .view = .init(m.a, @import("panel.zig").view) },
            }) catch return;
        }
        m.fit();
        m.popover.?.show();
        m.popover.?.redraw();
    }

    /// The panel's top right under the title.
    pub fn fit(m: *MenuBar) void {
        const p = m.popover orelse return;
        const tray = m.tray orelse return;
        const at = tray.anchor();
        p.setSize(app_mod.popover_w, app_mod.popover_h);
        p.setPosition(@max(8, at.x + at.width - app_mod.popover_w), at.y + at.height + 5);
    }

    pub fn hidePopover(m: *MenuBar) void {
        if (m.popover) |p| p.hide();
    }
};
