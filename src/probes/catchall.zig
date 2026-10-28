//! The safety net: every large folder no other probe explained.
const std = @import("std");
const scan_mod = @import("../scan.zig");
const walker_mod = @import("../walker.zig");
const proc = @import("../proc.zig");
const item_mod = @import("../item.zig");
const mac = @import("../mac.zig");
const guard = @import("../guard.zig");
const user_data = @import("user_data.zig");

const Scan = scan_mod.Scan;
const Item = item_mod.Item;
const MB = scan_mod.MB;

const large_threshold: u64 = 500 * MB;
const large_depth: u32 = 4;

/// `path` is inside `prefix`, or equal to it, at a path-component boundary.
fn pathStartsWith(path: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    if (path.len == prefix.len) return true;
    if (prefix.len == 0) return true;
    return path[prefix.len] == '/' or prefix[prefix.len - 1] == '/';
}

/// Walks the places Finder folds into System Data and reports every folder
/// over 500 MB that no other item accounts for. `claimed` holds the paths
/// the probes already cover, so those trees are not walked twice.
pub fn largeFolders(s: *Scan, claimed: *const walker_mod.Skip) scan_mod.Error!std.ArrayList(Item) {
    const arena = s.env.arena;
    var out: std.ArrayList(Item) = .empty;

    var roots: std.ArrayList([]const u8) = .empty;
    try roots.append(arena, s.env.home);
    if (s.env.system) {
        try roots.appendSlice(arena, &.{ "/Library", "/private/var", "/opt", "/usr/local", "/Users/Shared" });
    }
    // Other categories in Storage settings, or the person's own work, which
    // no delete regenerates. Their build folders still get their own rows.
    var excluded: std.ArrayList([]const u8) = .empty;
    try excluded.appendSlice(arena, &.{
        "Pictures",                    "Music",
        "Movies",                      "Desktop",
        "Documents",                   "Downloads",
        "Library/Messages",            "Library/Mail",
        "Library/Containers/com.apple.mail", "Library/Mobile Documents",
        "Applications",                "Library/CloudStorage",
    });
    try excluded.appendSlice(arena, &user_data.project_roots_outside_documents);
    for (excluded.items, 0..) |relative, i| excluded.items[i] = s.env.at(relative);
    if (!s.env.full_disk_access) {
        try excluded.append(arena, s.env.at("Library/Containers"));
        try excluded.append(arena, s.env.at("Library/Group Containers"));
    }
    // Every user's live temp and cache folders; the temp probe prunes your
    // own safely.
    try excluded.append(arena, "/private/var/folders");

    // One skip set for the walk: the claimed trees plus the excluded ones.
    var skip: walker_mod.Skip = .empty;
    for (excluded.items) |p| {
        const key = try arena.dupe(u8, p);
        try skip.put(arena, key, {});
    }
    var claimed_it = claimed.iterator();
    while (claimed_it.next()) |entry| {
        const key = try arena.dupe(u8, entry.key_ptr.*);
        try skip.put(arena, key, {});
    }

    const apps = try InstalledApps.current(s);

    var sizes: std.StringHashMapUnmanaged(u64) = .empty;
    const context = Visit{
        .s = s,
        .claimed = claimed,
        .excluded = excluded.items,
        .apps = &apps,
        .sizes = &sizes,
    };
    for (roots.items) |root| {
        if (!walker_mod.exists(root) or !walker_mod.onBootVolume(root)) continue;
        s.walk.directorySizes(root, large_depth, &skip, &sizes, arena);
        if (walker_mod.subdirectories(root, arena)) |children| {
            for (children) |child| try context.visit(child, 1, &out);
        } else |_| {}
    }
    scan_mod.bySize(out.items);
    return out;
}

const Visit = struct {
    s: *Scan,
    claimed: *const walker_mod.Skip,
    excluded: []const []const u8,
    apps: *const InstalledApps,
    sizes: *const std.StringHashMapUnmanaged(u64),

    fn blocked(self: *const Visit, dir: []const u8) bool {
        for (self.excluded) |p| {
            if (pathStartsWith(dir, p)) return true;
        }
        var it = self.claimed.iterator();
        while (it.next()) |entry| {
            if (pathStartsWith(dir, entry.key_ptr.*)) return true;
        }
        return false;
    }

    fn visit(self: *const Visit, dir: []const u8, depth: u32, out: *std.ArrayList(Item)) scan_mod.Error!void {
        const arena = self.s.env.arena;
        if (self.blocked(dir)) return;
        const bytes = self.sizes.get(dir) orelse return;
        if (bytes < large_threshold) return;
        const name = scan_mod.nameOf(dir);
        var holds_claimed = false;
        var it = self.claimed.iterator();
        while (it.next()) |entry| {
            const p = entry.key_ptr.*;
            if (!std.mem.eql(u8, p, dir) and pathStartsWith(p, dir)) {
                holds_claimed = true;
                break;
            }
        }
        // A folder the reclaimer would refuse, such as ~/Library/Caches, is
        // never one row: what is inside it is the answer.
        if (holds_claimed or std.mem.eql(u8, name, "Library") or
            std.mem.eql(u8, name, "Application Support") or
            guard.protected(dir, self.s.env.home))
        {
            if (depth < large_depth) {
                if (walker_mod.subdirectories(dir, arena)) |children| {
                    for (children) |child| try self.visit(child, depth + 1, out);
                } else |_| {}
            }
            return;
        }
        const owner = describeOwner(arena, dir, self.apps);
        // Outside your home and /Users/Shared, an unexplained folder belongs
        // to macOS or an installer. It is shown, never offered for deletion.
        const yours = pathStartsWith(dir, self.s.env.home) or pathStartsWith(dir, "/Users/Shared");
        const detail = if (yours)
            try std.fmt.allocPrint(arena, "{s} Open it in Finder and decide.", .{owner orelse "Not one this app recognises."})
        else
            owner orelse "System data this app does not recognise.";
        try out.append(arena, .{
            .id = try std.fmt.allocPrint(arena, "other-{s}", .{dir}),
            .category = .other,
            .name = scan_mod.abbreviate(arena, dir, self.s.env.home),
            .detail = detail,
            .size = bytes,
            .safety = if (yours) .review else .manual,
            .action = if (yours) blk: {
                const dirs = try arena.alloc([]const u8, 1);
                dirs[0] = dir;
                break :blk item_mod.Action{ .remove_paths = dirs };
            } else item_mod.Action{
                .manual = "macOS or an installer manages this folder. Remove the software that owns it, or leave it to macOS.",
            },
            .reveal = dir,
            .modified = walker_mod.shallowModified(dir),
        });
    }
};

/// Installed apps by bundle identifier and by name, to say who made a folder
/// and, more usefully, when that app is gone.
pub const InstalledApps = struct {
    by_identifier: std.StringHashMapUnmanaged([]const u8) = .empty,
    names: std.ArrayList([]const u8) = .empty,

    pub fn current(s: *Scan) scan_mod.Error!InstalledApps {
        const arena = s.env.arena;
        var self = InstalledApps{};
        var locations: std.ArrayList([]const u8) = .empty;
        try locations.append(arena, s.env.at("Applications"));
        if (s.env.system) {
            try locations.appendSlice(arena, &.{
                "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
            });
        }
        for (locations.items) |location| {
            if (walker_mod.subdirectories(location, arena)) |entries| {
                for (entries) |app| {
                    if (!scan_mod.extensionIs(app, "app")) continue;
                    const name = scan_mod.stemOf(app);
                    const plist = try std.fmt.allocPrint(arena, "{s}/Contents/Info.plist", .{app});
                    if (mac.plistString(s.gpa, plist, "CFBundleIdentifier")) |raw| {
                        defer s.gpa.free(raw);
                        const lower = std.ascii.allocLowerString(arena, raw) catch continue;
                        try self.by_identifier.put(arena, lower, name);
                    }
                    try self.names.append(arena, name);
                }
            } else |_| {}
        }
        return self;
    }
};

/// A sentence naming who made `dir`, or null when its path does not say.
pub fn describeOwner(arena: std.mem.Allocator, dir: []const u8, apps: *const InstalledApps) ?[]const u8 {
    var parts: [16][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, dir, '/');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (count >= parts.len) return null;
        parts[count] = part;
        count += 1;
    }
    const slice = parts[0..count];
    var library: usize = 0;
    var found = false;
    for (slice, 0..) |part, i| {
        if (std.mem.eql(u8, part, "Library")) {
            library = i;
            found = true;
        }
    }
    if (!found) return null;
    if (library + 1 < slice.len and std.mem.eql(u8, slice[library + 1], "Metadata")) {
        return "Spotlight's index of this Mac's files. macOS maintains it; excluding folders in System Settings > Spotlight shrinks it.";
    }
    if (library + 2 >= slice.len) return null;
    const parent = slice[library + 1];
    const owner = slice[library + 2];
    const known = [_][]const u8{
        "Application Support", "Containers", "Group Containers", "Caches",
        "Logs",                 "HTTPStorages", "WebKit",          "Saved Application State",
    };
    var known_parent = false;
    for (known) |candidate| {
        if (std.mem.eql(u8, candidate, parent)) {
            known_parent = true;
            break;
        }
    }
    if (!known_parent) return null;
    if (looksLikeBundleId(owner)) {
        const id = std.ascii.allocLowerString(arena, stripTeamPrefix(owner)) catch return null;
        if (apps.by_identifier.get(id)) |name| {
            return std.fmt.allocPrint(arena, "Belongs to {s}.", .{name}) catch null;
        }
        return std.fmt.allocPrint(arena, "Left by {s}, which is no longer installed on this Mac.", .{owner}) catch null;
    }
    var exact: ?[]const u8 = null;
    var prefix: ?[]const u8 = null;
    for (apps.names.items) |candidate| {
        if (std.mem.eql(u8, candidate, owner)) {
            exact = candidate;
            break;
        }
        if (std.mem.startsWith(u8, candidate, owner) and candidate.len > owner.len and candidate[owner.len] == ' ') {
            if (prefix == null) prefix = candidate;
        }
    }
    const name = exact orelse prefix orelse return null;
    return std.fmt.allocPrint(arena, "Belongs to {s}.", .{name}) catch null;
}

fn looksLikeBundleId(name: []const u8) bool {
    var dots: usize = 0;
    for (name) |c| {
        if (c == '.') dots += 1;
        if (c == ' ') return false;
    }
    return dots >= 2;
}

/// Group containers carry a team prefix (`UBF8T346G9.Office`) or `group.`.
fn stripTeamPrefix(name: []const u8) []const u8 {
    const first = name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len];
    var team = first.len == 10;
    if (team) {
        for (first) |c| {
            if (!std.ascii.isDigit(c) and !std.ascii.isUpper(c)) {
                team = false;
                break;
            }
        }
    }
    if (team or std.mem.eql(u8, first, "group")) {
        return name[@min(first.len + 1, name.len)..];
    }
    return name;
}

test "owners come from the path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var apps = InstalledApps{};
    try apps.by_identifier.put(arena, "com.tinyspeck.slackmacgap", "Slack");
    try apps.by_identifier.put(arena, "com.microsoft.word", "Microsoft Word");
    try apps.names.append(arena, "Slack");
    try apps.names.append(arena, "Microsoft Word");

    const describe = struct {
        fn d(a: std.mem.Allocator, p: []const u8, app_list: *const InstalledApps) ?[]const u8 {
            return describeOwner(a, p, app_list);
        }
    }.d;
    try std.testing.expectEqualStrings("Belongs to Slack.", describe(arena, "/Users/a/Library/Caches/com.tinyspeck.slackmacgap", &apps).?);
    try std.testing.expectEqualStrings("Left by com.gone.app, which is no longer installed on this Mac.", describe(arena, "/Users/a/Library/Containers/com.gone.app", &apps).?);
    try std.testing.expectEqualStrings("Belongs to Microsoft Word.", describe(arena, "/Users/a/Library/Group Containers/UBF8T346G9.com.microsoft.Word", &apps).?);
    try std.testing.expectEqualStrings("Belongs to Slack.", describe(arena, "/Users/a/Library/Application Support/Slack", &apps).?);
    try std.testing.expect(describe(arena, "/Users/a/Library/Application Support/Unknown", &apps) == null);
    try std.testing.expect(describe(arena, "/Users/a/devv", &apps) == null);
}
