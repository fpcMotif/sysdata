//! What the window shows and what the person has chosen, without any UI.
//! Every selection rule is written against what is actually on screen: a
//! delete must never reach a row the person cannot see without saying so.
//!
//! Item strings live in the scan's arena; the app keeps each scan's arena
//! alive until its results are replaced and no batch is still using them.
//! Everything the model owns out of a scan (hidden ids, the filter, notice
//! and phase text) is allocated here and freed on replace.
const std = @import("std");
const sys = @import("sys.zig");
const item_mod = @import("item.zig");
const scan_mod = @import("scan.zig");
const mac = @import("mac.zig");
const reclaim = @import("reclaim.zig");

const Item = item_mod.Item;
const Category = item_mod.Category;
const Safety = item_mod.Safety;

/// The delete waiting for confirmation.
pub const Pending = union(enum) {
    one: []const u8,
    selection,
};

/// Largest direct children, measured when a row is expanded.
pub const Breakdown = struct { path: []const u8, bytes: u64, is_dir: bool };

pub const Group = struct {
    category: Category,
    items: []const *const Item,
    total: u64,
};

pub const Model = struct {
    gpa: std.mem.Allocator,
    /// Shallow copies on `gpa`; every string inside them belongs to the
    /// scan's arena, so it stays valid until the next scan's results land.
    items: std.ArrayList(Item) = .empty,
    scanning: bool = false,
    scanned: bool = false,
    phase: []u8 = &.{},
    space: mac.DiskSpace = .{},
    reclaimed: u64 = 0,
    /// Keyed by item id slices borrowed from the scan's arena.
    busy: std.StringHashMapUnmanaged(void) = .empty,
    selected: std.StringHashMapUnmanaged(void) = .empty,
    expanded: std.StringHashMapUnmanaged(void) = .empty,
    /// Ids deleted while a rescan runs, so they do not come back.
    deleted_during_scan: std.StringHashMapUnmanaged(void) = .empty,
    anchor: ?[]const u8 = null,
    /// The person's own state: hidden ids outlive scans, so they are owned.
    hidden: std.StringHashMapUnmanaged(void) = .empty,
    filter: std.ArrayList(u8) = .empty,
    collapsed: std.AutoHashMapUnmanaged(Category, void) = .empty,
    /// Breakdown paths come from the live scan's arena.
    breakdowns: std.StringHashMapUnmanaged([]Breakdown) = .empty,
    full_disk_access: bool = false,
    pending: ?Pending = null,
    notice: []u8 = &.{},
    error_text: []u8 = &.{},
    /// Send Safe items to the Trash as well. Off: Safe items regenerate, and
    /// the Trash frees nothing until it is emptied.
    safe_to_trash: bool = false,
    batch_failures: std.ArrayList([]u8) = .empty,
    batch_trashed: bool = false,
    state_file: ?[]const u8 = null,

    pub fn load(gpa: std.mem.Allocator, state_file: ?[]const u8) !*Model {
        const self = try gpa.create(Model);
        self.* = .{ .gpa = gpa };
        if (state_file) |path| {
            self.state_file = try gpa.dupe(u8, path);
            self.readState(path) catch {};
        }
        return self;
    }

    pub fn deinit(m: *Model) void {
        const gpa = m.gpa;
        m.items.deinit(gpa);
        if (m.phase.len > 0) gpa.free(m.phase);
        m.busy.deinit(gpa);
        m.selected.deinit(gpa);
        m.expanded.deinit(gpa);
        m.deleted_during_scan.deinit(gpa);
        {
            var it = m.hidden.keyIterator();
            while (it.next()) |key| gpa.free(key.*);
            m.hidden.deinit(gpa);
        }
        m.filter.deinit(gpa);
        m.collapsed.deinit(gpa);
        m.breakdowns.deinit(gpa);
        if (m.notice.len > 0) gpa.free(m.notice);
        if (m.error_text.len > 0) gpa.free(m.error_text);
        for (m.batch_failures.items) |message| gpa.free(message);
        m.batch_failures.deinit(gpa);
        if (m.state_file) |path| gpa.free(path);
        gpa.destroy(m);
    }

    fn readState(m: *Model, path: []const u8) !void {
        const text = try sys.readFile(m.gpa, path, 1 << 20);
        defer m.gpa.free(text);
        const parsed = try std.json.parseFromSlice(std.json.Value, m.gpa, text, .{});
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |o| o,
            else => return,
        };
        if (object.get("hidden")) |hidden| {
            switch (hidden) {
                .array => |array| {
                    for (array.items) |value| {
                        if (value != .string) continue;
                        const owned = try m.gpa.dupe(u8, value.string);
                        m.hidden.put(m.gpa, owned, {}) catch {
                            m.gpa.free(owned);
                        };
                    }
                },
                else => {},
            }
        }
        if (object.get("safeToTrash")) |flag| {
            if (flag == .bool) m.safe_to_trash = flag.bool;
        }
    }

    fn save(m: *Model) void {
        const path = m.state_file orelse return;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(m.gpa);
        out.appendSlice(m.gpa, "{\"hidden\": [") catch return;
        // Sorted, so the file changes only when the state does.
        var keys: [256][]const u8 = undefined;
        var n: usize = 0;
        var it = m.hidden.keyIterator();
        while (it.next()) |key| {
            if (n < keys.len) {
                keys[n] = key.*;
                n += 1;
            }
        }
        std.mem.sort([]const u8, keys[0..n], {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        for (keys[0..n], 0..) |key, i| {
            if (i > 0) out.appendSlice(m.gpa, ", ") catch return;
            appendJsonString(m.gpa, &out, key) catch return;
        }
        out.appendSlice(m.gpa, "], \"safeToTrash\": ") catch return;
        out.appendSlice(m.gpa, if (m.safe_to_trash) "true}" else "false}") catch return;
        if (std.fs.path.dirname(path)) |dir| sys.makePath(dir) catch {};
        sys.publishFile(path, out.items) catch {};
    }

    fn setPhase(m: *Model, comptime fmt: []const u8, args: anytype) void {
        if (m.phase.len > 0) m.gpa.free(m.phase);
        m.phase = std.fmt.allocPrint(m.gpa, fmt, args) catch &.{};
    }

    fn setPhaseText(m: *Model, text: []const u8) void {
        if (m.phase.len > 0) m.gpa.free(m.phase);
        if (text.len == 0) {
            m.phase = &.{};
            return;
        }
        m.phase = m.gpa.dupe(u8, text) catch &.{};
    }

    fn setNoticeText(m: *Model, text: []const u8) void {
        if (m.notice.len > 0) m.gpa.free(m.notice);
        if (text.len == 0) {
            m.notice = &.{};
            return;
        }
        m.notice = m.gpa.dupe(u8, text) catch &.{};
    }

    fn setNoticeFmt(m: *Model, comptime fmt: []const u8, args: anytype) void {
        if (m.notice.len > 0) m.gpa.free(m.notice);
        m.notice = std.fmt.allocPrint(m.gpa, fmt, args) catch &.{};
    }

    pub fn setErrorText(m: *Model, text: []const u8) void {
        if (m.error_text.len > 0) m.gpa.free(m.error_text);
        if (text.len == 0) {
            m.error_text = &.{};
            return;
        }
        m.error_text = m.gpa.dupe(u8, text) catch &.{};
    }

    // Looking

    pub fn item(m: *const Model, id: []const u8) ?*const Item {
        for (m.items.items) |*i| {
            if (std.mem.eql(u8, i.id, id)) return i;
        }
        return null;
    }

    pub fn isHidden(m: *const Model, i: *const Item) bool {
        return m.hidden.contains(i.id);
    }

    /// Listed: visible and matching the filter.
    pub fn isListed(m: *const Model, i: *const Item) bool {
        return !m.isHidden(i) and i.matches(m.filter.items);
    }

    pub fn isOnScreen(m: *const Model, i: *const Item) bool {
        return m.isListed(i) and !m.collapsed.contains(i.category);
    }

    /// The System Data this scan found: the headline and the menu bar number.
    pub fn measuredBytes(m: *const Model) u64 {
        var total: u64 = 0;
        for (m.items.items) |*i| {
            if (!m.isHidden(i)) total += i.bytes();
        }
        return total;
    }

    pub fn safeBytes(m: *const Model) u64 {
        var total: u64 = 0;
        for (m.items.items) |*i| {
            if (!m.isHidden(i) and i.safety == .safe and !i.action.isManual()) total += i.bytes();
        }
        return total;
    }

    pub fn hiddenCount(m: *const Model) usize {
        return m.hidden.count();
    }

    /// Pointers into `m.items`, stable while the list is not mutated.
    pub fn selectedItems(m: *const Model, arena: std.mem.Allocator) ![]const *const Item {
        var out: std.ArrayList(*const Item) = .empty;
        for (m.items.items) |*i| {
            if (!m.isHidden(i) and m.selected.contains(i.id)) try out.append(arena, i);
        }
        return out.items;
    }

    pub fn selectedBytes(m: *const Model) u64 {
        var total: u64 = 0;
        for (m.items.items) |*i| {
            if (!m.isHidden(i) and m.selected.contains(i.id)) total += i.bytes();
        }
        return total;
    }

    /// Selected rows a filter or a folded group is hiding. They are still in
    /// the batch.
    pub fn selectedOffScreen(m: *const Model) usize {
        var count: usize = 0;
        for (m.items.items) |*i| {
            if (m.selected.contains(i.id) and !m.isHidden(i) and !m.isOnScreen(i)) count += 1;
        }
        return count;
    }

    /// Groups in display order: fixed while results stream in, so headers do
    /// not jump under the pointer; largest first once the scan is done.
    pub fn groups(m: *const Model, arena: std.mem.Allocator) ![]Group {
        var out: std.ArrayList(Group) = .empty;
        for (item_mod.every_category) |category| {
            var members: std.ArrayList(*const Item) = .empty;
            for (m.items.items) |*i| {
                if (i.category == category and m.isListed(i)) try members.append(arena, i);
            }
            if (members.items.len == 0) continue;
            std.mem.sort(*const Item, members.items, {}, struct {
                fn lt(_: void, x: *const Item, y: *const Item) bool {
                    if (x.bytes() != y.bytes()) return x.bytes() > y.bytes();
                    return std.mem.lessThan(u8, x.name, y.name);
                }
            }.lt);
            var total: u64 = 0;
            for (members.items) |i| total += i.bytes();
            try out.append(arena, .{ .category = category, .items = members.items, .total = total });
        }
        if (!m.scanning) {
            std.mem.sort(Group, out.items, {}, struct {
                fn lt(_: void, x: Group, y: Group) bool {
                    return x.total > y.total;
                }
            }.lt);
        }
        return out.items;
    }

    /// Rows in the order the list draws them, for shift-click ranges.
    fn selectableOnScreen(m: *const Model, arena: std.mem.Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        const grouped = try m.groups(arena);
        for (grouped) |group| {
            if (m.collapsed.contains(group.category)) continue;
            for (group.items) |i| {
                if (!i.action.isManual()) try out.append(arena, i.id);
            }
        }
        return out.items;
    }

    fn selectableIn(m: *const Model, category: Category, arena: std.mem.Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (m.items.items) |*i| {
            if (i.category == category and m.isListed(i) and !i.action.isManual()) {
                try out.append(arena, i.id);
            }
        }
        return out.items;
    }

    // Choosing

    /// Ticks or unticks one row; with `extend`, everything from the last
    /// clicked row to this one.
    pub fn setSelected(m: *Model, id: []const u8, selected: bool, extend: bool) void {
        const found = m.item(id) orelse return;
        if (found.action.isManual()) return;
        var arena_state = std.heap.ArenaAllocator.init(m.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        if (extend) {
            if (m.anchor) |anchor| {
                const order = m.selectableOnScreen(arena) catch return;
                var a: ?usize = null;
                var b: ?usize = null;
                for (order, 0..) |candidate, i| {
                    if (std.mem.eql(u8, candidate, anchor)) a = i;
                    if (std.mem.eql(u8, candidate, id)) b = i;
                }
                if (a != null and b != null) {
                    var i = @min(a.?, b.?);
                    const hi = @max(a.?, b.?);
                    while (i <= hi) : (i += 1) {
                        m.setTick(order[i], selected);
                    }
                    return;
                }
            }
        }
        m.setTick(id, selected);
        m.anchor = id;
    }

    fn setTick(m: *Model, id: []const u8, on: bool) void {
        if (on) {
            m.selected.put(m.gpa, id, {}) catch {};
        } else {
            _ = m.selected.remove(id);
        }
    }

    pub fn categorySelectable(m: *const Model, category: Category) bool {
        var arena_state = std.heap.ArenaAllocator.init(m.gpa);
        defer arena_state.deinit();
        const ids = m.selectableIn(category, arena_state.allocator()) catch return false;
        return ids.len > 0;
    }

    pub fn categorySelected(m: *const Model, category: Category) bool {
        var arena_state = std.heap.ArenaAllocator.init(m.gpa);
        defer arena_state.deinit();
        const ids = m.selectableIn(category, arena_state.allocator()) catch return false;
        if (ids.len == 0) return false;
        for (ids) |id| {
            if (!m.selected.contains(id)) return false;
        }
        return true;
    }

    pub fn setCategorySelected(m: *Model, category: Category, on: bool) void {
        var arena_state = std.heap.ArenaAllocator.init(m.gpa);
        defer arena_state.deinit();
        const ids = m.selectableIn(category, arena_state.allocator()) catch return;
        for (ids) |id| m.setTick(id, on);
        m.anchor = null;
    }

    /// Listed Safe rows, excluding the Trash: emptying it is permanent and it
    /// holds what Review deletions just put there.
    fn listedSafe(m: *const Model, arena: std.mem.Allocator) ![]const *const Item {
        var out: std.ArrayList(*const Item) = .empty;
        for (m.items.items) |*i| {
            if (m.isListed(i) and i.safety == .safe and !i.action.isManual() and i.category != .trash) {
                try out.append(arena, i);
            }
        }
        return out.items;
    }

    pub fn allSafeSelected(m: *const Model) bool {
        var arena_state = std.heap.ArenaAllocator.init(m.gpa);
        defer arena_state.deinit();
        const safe = m.listedSafe(arena_state.allocator()) catch return false;
        if (safe.len == 0) return false;
        for (safe) |i| {
            if (!m.selected.contains(i.id)) return false;
        }
        return true;
    }

    /// Ticks every listed Safe row and opens the groups holding them; a
    /// second press unticks them. Rows the filter hides are left as they are.
    pub fn toggleSafe(m: *Model) void {
        var arena_state = std.heap.ArenaAllocator.init(m.gpa);
        defer arena_state.deinit();
        const safe = m.listedSafe(arena_state.allocator()) catch return;
        if (safe.len == 0) return;
        var all = true;
        for (safe) |i| {
            if (!m.selected.contains(i.id)) {
                all = false;
                break;
            }
        }
        for (safe) |i| {
            if (all) {
                _ = m.selected.remove(i.id);
            } else {
                m.selected.put(m.gpa, i.id, {}) catch {};
                _ = m.collapsed.remove(i.category);
            }
        }
        m.anchor = null;
    }

    pub fn clearSelection(m: *Model) void {
        m.selected.clearRetainingCapacity();
        m.anchor = null;
    }

    pub fn setFilter(m: *Model, filter: []const u8) void {
        if (!std.mem.eql(u8, filter, m.filter.items)) {
            m.filter.clearRetainingCapacity();
            m.filter.appendSlice(m.gpa, filter) catch {};
            m.anchor = null;
        }
    }

    pub fn toggleCollapsed(m: *Model, category: Category) void {
        if (!m.collapsed.remove(category)) {
            m.collapsed.put(m.gpa, category, {}) catch {};
        }
        m.anchor = null;
    }

    pub fn toggleExpanded(m: *Model, id: []const u8) bool {
        if (m.expanded.remove(id)) return false;
        m.expanded.put(m.gpa, id, {}) catch return true;
        return true;
    }

    pub fn hide(m: *Model, id: []const u8) void {
        const owned = m.gpa.dupe(u8, id) catch return;
        m.hidden.put(m.gpa, owned, {}) catch {
            m.gpa.free(owned);
            return;
        };
        _ = m.selected.remove(id);
        if (m.anchor) |anchor| {
            if (std.mem.eql(u8, anchor, id)) m.anchor = null;
        }
        m.save();
    }

    pub fn unhideAll(m: *Model) void {
        var it = m.hidden.keyIterator();
        while (it.next()) |key| m.gpa.free(key.*);
        m.hidden.clearRetainingCapacity();
        m.save();
    }

    pub fn setSafeToTrash(m: *Model, on: bool) void {
        m.safe_to_trash = on;
        m.save();
    }

    // Scanning

    /// Starts a scan. A quiet rescan keeps the current list, selection and
    /// filter until the new results replace them.
    pub fn beginScan(m: *Model, quiet: bool) void {
        const keep = quiet and m.scanned;
        m.scanning = true;
        m.setPhaseText("Measuring known locations…");
        m.deleted_during_scan.clearRetainingCapacity();
        if (!m.scanned) {
            m.collapsed.clearRetainingCapacity();
            for (item_mod.every_category) |category| {
                m.collapsed.put(m.gpa, category, {}) catch {};
            }
        }
        if (!keep) {
            m.items.clearRetainingCapacity();
            m.clearSelection();
            m.filter.clearRetainingCapacity();
            m.setErrorText("");
            m.anchor = null;
            m.breakdowns.clearRetainingCapacity();
        }
    }

    pub fn acceptProgress(m: *Model, progress: scan_mod.Progress, quiet: bool) void {
        switch (progress) {
            .batch => |batch| {
                if (!(quiet and m.scanned)) {
                    for (batch.items) |*i| {
                        if (m.deleted_during_scan.contains(i.id)) continue;
                        m.items.append(m.gpa, i.*) catch {};
                    }
                }
                m.setPhase("Measuring… {d} of {d} places", .{ batch.finished, batch.total });
            },
            .catch_all => m.setPhaseText("Looking for anything else over 500 MB…"),
        }
    }

    pub fn finishScan(m: *Model, items: []const Item, space: mac.DiskSpace) void {
        m.items.clearRetainingCapacity();
        for (items) |*i| {
            if (m.deleted_during_scan.contains(i.id)) continue;
            m.items.append(m.gpa, i.*) catch {};
        }
        // Ids the new scan still has keep their tick; the map re-keys onto
        // the new arena's id slices.
        m.selected = rekey(m.gpa, &m.selected, m.items.items);
        m.expanded = rekey(m.gpa, &m.expanded, m.items.items);
        var breakdown_kept: std.StringHashMapUnmanaged([]Breakdown) = .empty;
        var it = m.breakdowns.iterator();
        while (it.next()) |entry| {
            if (findId(m.items.items, entry.key_ptr.*)) |id| {
                breakdown_kept.put(m.gpa, id, entry.value_ptr.*) catch {};
            }
        }
        m.breakdowns = breakdown_kept;
        if (m.anchor) |anchor| {
            if (!m.selected.contains(anchor)) m.anchor = null;
        }
        m.space = space;
        m.scanning = false;
        m.scanned = true;
        m.setPhaseText("");
    }

    // Deleting

    pub fn pendingItems(m: *const Model, arena: std.mem.Allocator) ![]const *const Item {
        switch (m.pending orelse return &.{}) {
            .one => |id| {
                if (m.item(id)) |found| {
                    const out = try arena.alloc(*const Item, 1);
                    out[0] = found;
                    return out;
                }
                return &.{};
            },
            .selection => return m.selectedItems(arena),
        }
    }

    /// Every operation the pending delete will run, one per line.
    pub fn pendingPlan(m: *const Model, arena: std.mem.Allocator) ![]const []const u8 {
        var lines: std.ArrayList([]const u8) = .empty;
        const items = try m.pendingItems(arena);
        for (items) |i| try i.action.planInto(arena, &lines);
        return lines.items;
    }

    pub const Confirmation = struct { title: []const u8, body: []const u8 };

    pub fn confirmation(m: *const Model, arena: std.mem.Allocator) !Confirmation {
        const items = try m.pendingItems(arena);
        var bytes: u64 = 0;
        var all_safe = true;
        var trashed: std.ArrayList([]const u8) = .empty;
        var admin: usize = 0;
        for (items) |i| {
            bytes += i.bytes();
            if (i.safety != .safe) all_safe = false;
            if (reclaim.goesToTrash(i, m.safe_to_trash)) try trashed.append(arena, i.name);
            if (i.action.needsAdmin()) admin += 1;
        }
        const title = switch (m.pending orelse return .{ .title = "", .body = "" }) {
            .one => |id| blk: {
                const found = m.item(id) orelse
                    break :blk try std.fmt.allocPrint(arena, "Delete {d} items?", .{items.len});
                break :blk try std.fmt.allocPrint(arena, "Delete {s}?", .{found.name});
            },
            .selection => try std.fmt.allocPrint(arena, "Delete {d} items?", .{items.len}),
        };
        var body: std.ArrayList(u8) = .empty;
        if (bytes > 0) {
            var size_buf: [32]u8 = undefined;
            const head = try std.fmt.allocPrint(arena, "Frees about {s}. ", .{item_mod.formatBytes(&size_buf, bytes)});
            try body.appendSlice(arena, head);
        }
        if (items.len > 0 and trashed.items.len == 0) {
            if (all_safe) {
                if (items.len == 1) {
                    try body.appendSlice(arena, "It is regenerated automatically when needed.");
                } else {
                    try body.appendSlice(arena, "All of it is regenerated automatically when needed.");
                }
            }
        } else if (items.len == 1 and trashed.items.len == 1) {
            try body.appendSlice(arena, "It goes to the Trash first.");
        } else if (trashed.items.len > 0) {
            const head = try std.fmt.allocPrint(arena, "{d} go to the Trash first: ", .{trashed.items.len});
            try body.appendSlice(arena, head);
            for (trashed.items, 0..) |name, i| {
                if (i > 0) try body.appendSlice(arena, ", ");
                try body.appendSlice(arena, name);
            }
            try body.append(arena, '.');
        }
        if (admin > 0) {
            const tail = try std.fmt.allocPrint(arena, " {d} need{s} an administrator password, asked once.", .{ admin, if (admin == 1) "s" else "" });
            try body.appendSlice(arena, tail);
        }
        return .{ .title = title, .body = std.mem.trim(u8, body.items, " ") };
    }

    /// The batch to run, with busy and Manual rows left out. Clears the
    /// pending delete. Item strings and action payloads are duplicated into
    /// `arena`, so the batch survives the scan arena it came from.
    pub fn takePending(m: *Model, arena: std.mem.Allocator) ![]Item {
        const chosen = try m.pendingItems(arena);
        var batch: std.ArrayList(Item) = .empty;
        for (chosen) |i| {
            if (i.action.isManual()) continue;
            if (m.busy.contains(i.id)) continue;
            var copy = i.*;
            copy.id = try arena.dupe(u8, i.id);
            copy.name = try arena.dupe(u8, i.name);
            copy.detail = try arena.dupe(u8, i.detail);
            if (copy.reveal) |p| copy.reveal = try arena.dupe(u8, p);
            copy.action = try cloneAction(arena, i.action);
            if (copy.modified != null) copy.modified = i.modified;
            try batch.append(arena, copy);
        }
        if (m.pending != null and m.pending.? == .selection) m.clearSelection();
        m.pending = null;
        m.setNoticeText("");
        m.setErrorText("");
        for (m.batch_failures.items) |message| m.gpa.free(message);
        m.batch_failures.clearRetainingCapacity();
        m.batch_trashed = false;
        return batch.items;
    }

    pub fn apply(m: *Model, event: reclaim.Event) void {
        switch (event) {
            .busy => |ids| {
                for (ids) |id| m.busy.put(m.gpa, id, {}) catch {};
            },
            .done => |done| {
                for (done.ids) |id| {
                    m.removeOne(id);
                    _ = m.busy.remove(id);
                    _ = m.selected.remove(id);
                    _ = m.expanded.remove(id);
                    if (m.scanning) m.deleted_during_scan.put(m.gpa, id, {}) catch {};
                }
                m.reclaimed += done.freed;
                if (done.trashed) {
                    m.batch_trashed = true;
                    m.setNoticeText("Moved to the Trash. Empty the Trash to free the space.");
                }
            },
            .failed => |failed| {
                for (failed.ids) |id| _ = m.busy.remove(id);
                const copy = m.gpa.dupe(u8, failed.message) catch return;
                m.batch_failures.append(m.gpa, copy) catch {
                    m.gpa.free(copy);
                    return;
                };
                var joined: std.ArrayList(u8) = .empty;
                for (m.batch_failures.items, 0..) |message, i| {
                    if (i > 0) joined.append(m.gpa, '\n') catch {};
                    joined.appendSlice(m.gpa, message) catch {};
                }
                m.setErrorText(joined.items);
                joined.deinit(m.gpa);
            },
            .stopped => |stopped| {
                for (stopped.remaining) |id| _ = m.busy.remove(id);
                m.selected.clearRetainingCapacity();
                for (stopped.remaining) |id| {
                    if (m.item(id)) |found| m.selected.put(m.gpa, found.id, {}) catch {};
                }
                m.setErrorText("");
                if (stopped.deleted == 0) {
                    m.setNoticeText("Cancelled. Nothing was deleted.");
                } else {
                    m.setNoticeFmt("Cancelled. {d} already deleted, the rest left alone.", .{stopped.deleted});
                }
            },
        }
    }

    fn removeOne(m: *Model, id: []const u8) void {
        for (m.items.items, 0..) |*i, index| {
            if (std.mem.eql(u8, i.id, id)) {
                _ = m.items.orderedRemove(index);
                return;
            }
        }
    }
};

fn findId(items: []Item, id: []const u8) ?[]const u8 {
    for (items) |*i| {
        if (std.mem.eql(u8, i.id, id)) return i.id;
    }
    return null;
}

/// A deep copy of an action, so a batch owns every string it runs with.
fn cloneAction(arena: std.mem.Allocator, action: item_mod.Action) !item_mod.Action {
    switch (action) {
        .remove_paths => |paths| return .{ .remove_paths = try clonePaths(arena, paths) },
        .empty_directories => |dirs| return .{ .empty_directories = try clonePaths(arena, dirs) },
        .prune_older_than => |p| return .{ .prune_older_than = .{
            .dir = try arena.dupe(u8, p.dir),
            .days = p.days,
        } },
        .command => |c| return .{ .command = .{
            .program = try arena.dupe(u8, c.program),
            .args = try clonePaths(arena, c.args),
        } },
        .privileged => |script| return .{ .privileged = try arena.dupe(u8, script) },
        .shutdown_simulators => return action,
        .erase_simulator => |udid| return .{ .erase_simulator = try arena.dupe(u8, udid) },
        .steps => |steps| {
            const copies = try arena.alloc(item_mod.Action, steps.len);
            for (steps, 0..) |step, i| copies[i] = try cloneAction(arena, step);
            return .{ .steps = copies };
        },
        .manual => |text| return .{ .manual = try arena.dupe(u8, text) },
    }
}

fn clonePaths(arena: std.mem.Allocator, paths: []const []const u8) ![]const []const u8 {
    const copies = try arena.alloc([]const u8, paths.len);
    for (paths, 0..) |p, i| copies[i] = try arena.dupe(u8, p);
    return copies;
}

/// Keeps the entries whose id the new scan still has, keyed by the new
/// arena's id slice.
fn rekey(
    gpa: std.mem.Allocator,
    old: *std.StringHashMapUnmanaged(void),
    items: []Item,
) std.StringHashMapUnmanaged(void) {
    var kept: std.StringHashMapUnmanaged(void) = .empty;
    var it = old.iterator();
    while (it.next()) |entry| {
        if (findId(items, entry.key_ptr.*)) |id| {
            kept.put(gpa, id, {}) catch {};
        }
    }
    old.deinit(gpa);
    return kept;
}

fn appendJsonString(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(gpa, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(gpa, "\\\""),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            else => {
                if (c < 0x20) {
                    const escaped = try std.fmt.allocPrint(gpa, "\\u{x:0>4}", .{c});
                    defer gpa.free(escaped);
                    try out.appendSlice(gpa, escaped);
                } else {
                    try out.append(gpa, c);
                }
            },
        }
    }
    try out.append(gpa, '"');
}

fn testItem(arena: std.mem.Allocator, id: []const u8, category: Category, safety: Safety, bytes: u64) Item {
    const action: item_mod.Action = if (safety == .manual)
        .{ .manual = "by hand" }
    else
        .{ .remove_paths = arena.dupe([]const u8, &.{"/tmp/none"}) catch @panic("out of memory") };
    return .{
        .id = arena.dupe(u8, id) catch @panic("out of memory"),
        .category = category,
        .name = std.fmt.allocPrint(arena, "{c}", .{id[0] - 32}) catch @panic("out of memory"),
        .detail = "",
        .size = bytes,
        .safety = safety,
        .action = action,
    };
}

test "a model selects against what is on screen" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = try Model.load(std.testing.allocator, null);
    defer m.deinit();
    try m.items.append(m.gpa, testItem(arena, "a", .packages, .safe, 10));
    try m.items.append(m.gpa, testItem(arena, "b", .packages, .review, 20));
    try m.items.append(m.gpa, testItem(arena, "c", .simulators, .safe, 30));
    try m.items.append(m.gpa, testItem(arena, "d", .simulators, .manual, 40));

    // Manual rows cannot be selected.
    m.setSelected("d", true, false);
    try std.testing.expect(!m.selected.contains("d"));
    m.setSelected("a", true, false);
    try std.testing.expect(m.selected.contains("a"));

    // Hidden rows leave the totals.
    m.hide("a");
    try std.testing.expectEqual(@as(u64, 90), m.measuredBytes());
    try std.testing.expectEqual(@as(u64, 0), m.selectedBytes());

    // A group tick reaches only the group's selectable rows.
    m.setCategorySelected(.packages, true);
    try std.testing.expect(m.categorySelected(.packages));
    m.setCategorySelected(.packages, false);
    try std.testing.expect(!m.categorySelected(.packages));

    // Toggle Safe ticks the listed Safe rows and opens their groups.
    try m.collapsed.put(m.gpa, .simulators, {});
    m.toggleSafe();
    try std.testing.expect(m.selected.contains("c"));
    try std.testing.expect(!m.collapsed.contains(.simulators));
    try std.testing.expect(m.allSafeSelected());
    m.toggleSafe();
    try std.testing.expect(!m.selected.contains("c"));
}

test "shift click selects the drawn range" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = try Model.load(std.testing.allocator, null);
    defer m.deinit();
    try m.items.append(m.gpa, testItem(arena, "a", .packages, .safe, 10));
    try m.items.append(m.gpa, testItem(arena, "b", .packages, .safe, 20));
    try m.items.append(m.gpa, testItem(arena, "c", .packages, .safe, 30));
    try m.items.append(m.gpa, testItem(arena, "d", .packages, .manual, 40));

    m.setSelected("a", true, false);
    m.setSelected("c", true, true);
    try std.testing.expect(m.selected.contains("a"));
    try std.testing.expect(m.selected.contains("b"));
    try std.testing.expect(m.selected.contains("c"));
    try std.testing.expect(!m.selected.contains("d"));

    // The anchor stays at "a", so this range unticks a and b only.
    m.setSelected("b", false, true);
    try std.testing.expect(!m.selected.contains("a"));
    try std.testing.expect(!m.selected.contains("b"));
    try std.testing.expect(m.selected.contains("c"));
}

test "the confirmation names what goes to the trash" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = try Model.load(std.testing.allocator, null);
    defer m.deinit();
    try m.items.append(m.gpa, testItem(arena, "a", .packages, .safe, 10));
    try m.items.append(m.gpa, testItem(arena, "b", .xcode, .review, 20));
    m.safe_to_trash = true;
    m.pending = .selection;
    m.setSelected("a", true, false);
    m.setSelected("b", true, false);
    const text = try m.confirmation(arena);
    try std.testing.expectEqualStrings("Delete 2 items?", text.title);
    try std.testing.expect(std.mem.indexOf(u8, text.body, "2 go to the Trash first") != null);

    m.safe_to_trash = false;
    m.pending = .{ .one = "a" };
    const single = try m.confirmation(arena);
    try std.testing.expectEqualStrings("Delete A?", single.title);
    try std.testing.expectEqualStrings("Frees about 10 bytes. It is regenerated automatically when needed.", single.body);
}

test "deletions update the list and a cancel restores the selection" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = try Model.load(std.testing.allocator, null);
    defer m.deinit();
    try m.items.append(m.gpa, testItem(arena, "a", .packages, .safe, 10));
    try m.items.append(m.gpa, testItem(arena, "b", .packages, .review, 20));

    m.apply(.{ .busy = &.{"a"} });
    try std.testing.expect(m.busy.contains("a"));
    m.apply(.{ .done = .{ .ids = &.{"a"}, .trashed = false, .freed = 10 } });
    try std.testing.expectEqual(@as(usize, 1), m.items.items.len);
    try std.testing.expectEqual(@as(u64, 10), m.reclaimed);

    m.setSelected("b", true, false);
    m.apply(.{ .stopped = .{ .deleted = 0, .remaining = &.{"b"} } });
    try std.testing.expect(m.selected.contains("b"));
    try std.testing.expectEqualStrings("Cancelled. Nothing was deleted.", m.notice);

    m.apply(.{ .failed = .{ .ids = &.{"b"}, .message = "no" } });
    try std.testing.expectEqualStrings("no", m.error_text);
}
