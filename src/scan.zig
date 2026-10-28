//! Where a scan looks, what it may touch while looking, and how the probes
//! run: each probe measures one family of locations and never changes
//! anything. Probes run concurrently, one thread each with its own arena —
//! several wait on child processes, which must not hold the walkers — and
//! the catch-all runs last with everything they claimed.
//!
//! A scan's items are freed whole with the scan, never item by item.
const std = @import("std");
const item_mod = @import("item.zig");
const walker_mod = @import("walker.zig");
const proc = @import("proc.zig");
const sync = @import("sync.zig");
const clock = @import("clock.zig");

pub const probes = struct {
    pub const developer = @import("probes/developer.zig");
    pub const packages = @import("probes/packages.zig");
    pub const tools = @import("probes/tools.zig");
    pub const system = @import("probes/system.zig");
    pub const media = @import("probes/media.zig");
    pub const user_data = @import("probes/user_data.zig");
    pub const catchall = @import("probes/catchall.zig");
};

pub const Item = item_mod.Item;
pub const Category = item_mod.Category;
pub const Safety = item_mod.Safety;
pub const Action = item_mod.Action;
pub const MB = walker_mod.MB;
pub const Error = error{OutOfMemory};

/// Where a scan looks and what it may touch while looking.
pub const Env = struct {
    /// Every probe's strings and paths are allocated here: freed whole at
    /// the end of the scan.
    arena: std.mem.Allocator,
    home: []const u8,
    /// Without it, locations macOS guards with a prompt are skipped
    /// entirely, so a scan never raises a queue of permission dialogs.
    full_disk_access: bool,
    /// System locations and system tools (`/Library`, `simctl`, `docker`,
    /// `tmutil`). Off in tests, which scan a throwaway home only.
    system: bool,

    /// A path in the home folder, allocated from the scan's arena.
    pub fn at(env: *const Env, relative: []const u8) []const u8 {
        return std.fmt.allocPrint(env.arena, "{s}/{s}", .{ env.home, relative }) catch env.home;
    }

    /// Folders macOS asks about one dialog at a time without Full Disk Access.
    pub fn isProtected(env: *const Env, path: []const u8) bool {
        if (env.full_disk_access) return false;
        const guarded = [_][]const u8{
            "Library/Containers", "Library/Group Containers", "Desktop",
            "Documents",          "Downloads",
            "Music",              "Pictures",
            "Movies",
        };
        for (guarded) |relative| {
            const base = std.fmt.allocPrint(env.arena, "{s}/{s}", .{ env.home, relative }) catch continue;
            if (std.mem.eql(u8, path, base)) return true;
            if (path.len > base.len and std.mem.startsWith(u8, path, base) and path[base.len] == '/') return true;
        }
        return false;
    }
};

/// `~/Library/Safari` refuses a listing without Full Disk Access instead of
/// prompting, so asking costs nothing and warns nobody.
pub fn hasFullDiskAccess(home: []const u8) bool {
    if (walker_mod.env("SYSDATA_NO_FULL_DISK_ACCESS") != null) return false;
    var buf: [walker_mod.max_path]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/Library/Safari", .{home}) catch return false;
    const fd = @import("sys.zig").openDir(path) catch return false;
    @import("sys.zig").close(fd);
    return true;
}

pub const Probe = *const fn (*Scan) Error!std.ArrayList(Item);

pub const Entry = struct { name: []const u8, func: Probe };

/// Every probe, in display order.
pub const registry = [_]Entry{
    .{ .name = "snapshots", .func = probes.developer.snapshots },
    .{ .name = "simulators", .func = probes.developer.simulators },
    .{ .name = "runtimes", .func = probes.developer.runtimes },
    .{ .name = "xcode", .func = probes.developer.xcode },
    .{ .name = "packages", .func = probes.packages.probe },
    .{ .name = "tools", .func = probes.tools.probe },
    .{ .name = "logs", .func = probes.system.logs },
    .{ .name = "temp", .func = probes.system.temp },
    .{ .name = "docker", .func = probes.system.docker },
    .{ .name = "vms", .func = probes.media.virtualMachines },
    .{ .name = "trash", .func = probes.system.trash },
    .{ .name = "backups", .func = probes.user_data.backups },
    .{ .name = "shared", .func = probes.user_data.shared },
    .{ .name = "android", .func = probes.user_data.android },
    .{ .name = "app caches", .func = probes.media.appCaches },
    .{ .name = "app data", .func = probes.user_data.appData },
    .{ .name = "projects", .func = probes.user_data.projects },
    .{ .name = "system", .func = probes.system.misc },
};

pub const Progress = union(enum) {
    /// One probe finished with these items.
    batch: struct { items: []const Item, finished: usize, total: usize },
    /// Every probe is done; the catch-all walk has started.
    catch_all: void,
};

pub const Notify = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, progress: Progress) void,
};

/// What the probes share: the walker pool, the known-sizes map, the shell
/// search path and the selected developer directory. The shared allocator
/// is thread-safe; nothing here is written without its lock.
pub const Shared = struct {
    gpa: std.mem.Allocator,
    walk: walker_mod.Walker,
    known: walker_mod.Known = .empty,
    path_dirs: [][]const u8 = &.{},
    /// The selected developer directory, asked once per scan; three probes
    /// want it and `xcrun` without tools opens an install dialog.
    developer_dir: ?[]const u8 = null,
    developer_asked: bool = false,
    developer_mutex: sync.Mutex = .{},
};

/// One probe's run: its own arena, so parallel probes never share an
/// allocator, and its own view of the scan.
pub const Run = struct {
    entry: *const Entry = undefined,
    arena_state: std.heap.ArenaAllocator,
    view: Scan,
    thread: ?std.Thread = null,
    items: std.ArrayList(Item) = .empty,
};

pub const Scan = struct {
    /// Thread-safe: the walker's nodes, the known-sizes keys, thread handles.
    gpa: std.mem.Allocator,
    shared: *Shared,
    /// The scan's own arena: the home path, the merged item list, the
    /// catch-all's results. Only the scan thread and the catch-all use it.
    arena_state: std.heap.ArenaAllocator,
    env: Env,
    walk: *walker_mod.Walker,
    path_dirs: [][]const u8,
    /// One run per probe; the arenas are freed whole in `deinit`. Empty in
    /// a probe's own view.
    runs: []Run = &.{},
    run_count: usize = 0,

    pub fn start(gpa: std.mem.Allocator, system: bool) Error!*Scan {
        walker_mod.prepare();
        const self = try gpa.create(Scan);
        errdefer gpa.destroy(self);
        self.gpa = gpa;
        self.arena_state = std.heap.ArenaAllocator.init(gpa);
        errdefer self.arena_state.deinit();
        self.runs = try gpa.alloc(Run, registry.len);
        errdefer gpa.free(self.runs);
        self.run_count = 0;
        self.shared = try gpa.create(Shared);
        errdefer gpa.destroy(self.shared);
        self.shared.* = .{ .gpa = gpa, .walk = undefined };
        self.shared.walk.init(gpa, walker_mod.threadCount());
        errdefer self.shared.walk.deinit();
        self.shared.developer_mutex.init();
        self.shared.walk.known = &self.shared.known;
        var dirs: std.ArrayList([]const u8) = .empty;
        errdefer dirs.deinit(gpa);
        const arena = self.arena_state.allocator();
        const home = try arena.dupe(u8, proc.home());
        self.env = .{
            .arena = arena,
            .home = home,
            .full_disk_access = hasFullDiskAccess(home),
            .system = system,
        };
        try proc.searchPath(gpa, home, &dirs);
        self.shared.path_dirs = try dirs.toOwnedSlice(gpa);
        self.walk = &self.shared.walk;
        self.path_dirs = self.shared.path_dirs;
        return self;
    }

    pub fn deinit(s: *Scan) void {
        for (s.runs[0..s.run_count]) |*run| {
            run.view.arena_state.deinit();
            run.arena_state.deinit();
        }
        s.gpa.free(s.runs);
        var it = s.shared.known.iterator();
        while (it.next()) |entry| s.gpa.free(entry.key_ptr.*);
        s.shared.known.deinit(s.gpa);
        s.shared.walk.deinit();
        for (s.shared.path_dirs) |d| s.gpa.free(d);
        s.gpa.free(s.shared.path_dirs);
        s.gpa.destroy(s.shared);
        s.arena_state.deinit();
        s.gpa.destroy(s);
    }

    /// The selected developer directory, or null when there is none. Asked
    /// before any `xcrun` call, because `xcrun` without tools opens an
    /// install dialog.
    pub fn developerDir(s: *Scan) ?[]const u8 {
        const shared = s.shared;
        shared.developer_mutex.lock();
        defer shared.developer_mutex.unlock();
        if (shared.developer_asked) return shared.developer_dir;
        shared.developer_asked = true;
        if (proc.probe(s.gpa, "/usr/bin/xcode-select", &.{"-p"})) |text| {
            defer s.gpa.free(text);
            const trimmed = std.mem.trim(u8, text, " \t\r\n");
            if (trimmed.len > 0 and walker_mod.exists(trimmed)) {
                shared.developer_dir = s.env.arena.dupe(u8, trimmed) catch null;
            }
        }
        return shared.developer_dir;
    }

    /// `xcrun simctl …` as JSON, or null when there are no developer tools.
    pub fn simctl(s: *Scan, args: []const []const u8) ?std.json.Value {
        if (s.developerDir() == null) return null;
        var full: std.ArrayList([]const u8) = .empty;
        defer full.deinit(s.env.arena);
        full.append(s.env.arena, "simctl") catch return null;
        full.appendSlice(s.env.arena, args) catch return null;
        const text = proc.probe(s.gpa, "/usr/bin/xcrun", full.items) orelse return null;
        defer s.gpa.free(text);
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            s.env.arena,
            text,
            .{},
        ) catch return null;
        return parsed.value;
    }

    /// Runs every probe in parallel, streaming each batch as it lands, then
    /// the catch-all for anything large no probe explained. Returns
    /// everything, largest-first per group is the view's business.
    pub fn scan(s: *Scan, only: ?[]const u8, notify: ?Notify) []Item {
        const arena = s.env.arena;
        var count: usize = 0;
        for (&registry) |*entry| {
            if (only) |name| {
                if (!std.mem.eql(u8, name, entry.name)) continue;
            }
            const run = &s.runs[count];
            run.entry = entry;
            run.arena_state = std.heap.ArenaAllocator.init(s.gpa);
            run.items = .empty;
            const probe_arena = run.arena_state.allocator();
            run.view = .{
                .gpa = s.gpa,
                .shared = s.shared,
                .arena_state = std.heap.ArenaAllocator.init(s.gpa),
                .env = .{
                    .arena = probe_arena,
                    .home = probe_arena.dupe(u8, s.env.home) catch s.env.home,
                    .full_disk_access = s.env.full_disk_access,
                    .system = s.env.system,
                },
                .walk = s.walk,
                .path_dirs = s.path_dirs,
            };
            count += 1;
        }
        s.run_count = count;
        var finished: std.atomic.Value(usize) = .init(0);
        for (s.runs[0..count]) |*run| {
            run.thread = std.Thread.spawn(.{}, probeThread, .{ run, &finished, notify, count }) catch null;
            if (run.thread == null) {
                // The probe still runs, here, without its own thread.
                probeThread(run, &finished, notify, count);
            }
        }
        var all: std.ArrayList(Item) = .empty;
        for (s.runs[0..count]) |*run| {
            if (run.thread) |t| t.join();
            all.appendSlice(arena, run.items.items) catch continue;
        }
        if (notify) |n| n.func(n.ctx, .{ .catch_all = {} });
        const started = clock.monotonicMs();
        // Everything the probes claimed, so the catch-all walks none of it again.
        var claimed: walker_mod.Skip = .empty;
        for (all.items) |*it| {
            var scratch: [64][]const u8 = undefined;
            for (it.claimedPaths(&scratch)) |p| {
                const key = arena.dupe(u8, p) catch continue;
                claimed.put(arena, key, {}) catch {};
            }
        }
        if (only == null) {
            const extra: std.ArrayList(Item) = probes.catchall.largeFolders(s, &claimed) catch .empty;
            all.appendSlice(arena, extra.items) catch {};
        }
        trace("catch-all", started);
        return all.items;
    }

    fn probeThread(
        run: *Run,
        finished: *std.atomic.Value(usize),
        notify: ?Notify,
        total: usize,
    ) void {
        const started = clock.monotonicMs();
        run.items = run.entry.func(&run.view) catch .empty;
        trace(run.entry.name, started);
        const done = finished.fetchAdd(1, .monotonic) + 1;
        if (notify) |n| {
            n.func(n.ctx, .{ .batch = .{ .items = run.items.items, .finished = done, .total = total } });
        }
    }

    fn trace(name: []const u8, started: i64) void {
        if (walker_mod.env("SYSDATA_TRACE") == null) return;
        const elapsed = clock.monotonicMs() - started;
        std.debug.print("{d:>8} ms {s}\n", .{ elapsed, name });
    }
};

/// An item for a location on disk, or null when it is missing or under
/// `min_bytes`.
pub fn dirItem(
    s: *Scan,
    id: []const u8,
    category: Category,
    name: []const u8,
    detail: []const u8,
    path: []const u8,
    safety: Safety,
    action: Action,
    min_bytes: u64,
) ?Item {
    if (!walker_mod.exists(path)) return null;
    const measured = s.walk.measure(path);
    if (measured.bytes < @max(min_bytes, 1)) return null;
    return Item{
        .id = id,
        .category = category,
        .name = name,
        .detail = detail,
        .size = measured.bytes,
        .safety = safety,
        .action = action,
        .reveal = path,
        .modified = measured.newest,
    };
}

/// Largest first, equal sizes by id, so a scan is reproducible.
pub fn bySize(items: []Item) void {
    std.mem.sort(Item, items, {}, struct {
        fn lt(_: void, x: Item, y: Item) bool {
            if (x.bytes() != y.bytes()) return x.bytes() > y.bytes();
            return std.mem.lessThan(u8, x.id, y.id);
        }
    }.lt);
}

pub fn nameOf(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

pub fn stemOf(path: []const u8) []const u8 {
    const name = std.fs.path.basename(path);
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
        if (dot > 0) return name[0..dot];
    }
    return name;
}

pub fn extensionIs(path: []const u8, extension: []const u8) bool {
    const name = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    if (dot == 0) return false;
    return std.mem.eql(u8, name[dot + 1 ..], extension);
}

/// `~/…` for paths in the home folder.
pub fn abbreviate(arena: std.mem.Allocator, path: []const u8, home: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, home)) {
        if (path.len == home.len) return "~";
        if (path[home.len] == '/') {
            return std.fmt.allocPrint(arena, "~{s}", .{path[home.len..]}) catch path;
        }
    }
    return path;
}

test "names, stems and abbreviations" {
    try std.testing.expectEqualStrings("Slack", nameOf("/a/b/Slack"));
    try std.testing.expectEqualStrings("UTM", stemOf("/a/b/UTM.utm"));
    try std.testing.expect(extensionIs("/a/b/UTM.utm", "utm"));
    try std.testing.expect(!extensionIs("/a/b/.git", "git"));
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("~/devv", abbreviate(arena_state.allocator(), "/Users/x/devv", "/Users/x"));
}
