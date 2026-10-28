//! One `getattrlistbulk` call returns the name, type, device, modification
//! time and allocated size of many directory entries at once, so a walk
//! costs roughly one syscall per directory instead of one `lstat` per file.
//!
//! The walker owns a fixed set of worker threads and a queue of directory
//! nodes. Each node keeps its own file descriptor open until every child
//! below it is done, so children open their subdirectories relative to
//! their parent (`openat`) and the kernel never re-resolves a full path —
//! and no descriptor is ever closed while someone still opens from it.
//! Subtree totals climb the node tree on completion, so every figure is
//! exact without joining threads. There is no global state: what a scan
//! measured lives in the scan's own known-sizes map, passed in here.
const std = @import("std");
const sync = @import("sync.zig");
const clock = @import("clock.zig");
const sys = @import("sys.zig");

pub const max_path = 1024;
pub const MB: u64 = 1_048_576;

pub const Measurement = struct {
    bytes: u64 = 0,
    /// Newest regular-file modification, in seconds since the epoch.
    newest: ?i64 = null,
};

pub const Kind = enum { file, dir, other };

pub const Child = struct {
    /// Owned by the caller's allocator.
    path: []u8,
    kind: Kind,
    /// Seconds since the epoch.
    modified: i64,
};

/// Directory totals the probes measured during the current scan.
pub const Known = std.StringHashMapUnmanaged(u64);
/// Directory trees a walk must not enter.
pub const Skip = std.StringHashMapUnmanaged(void);

// Not exported by Zig's std; values from <sys/attr.h>.
const ATTR_BIT_MAP_COUNT: u16 = 5;
const ATTR_CMN_RETURNED_ATTRS: u32 = 0x8000_0000;
const ATTR_CMN_NAME: u32 = 0x0000_0001;
const ATTR_CMN_DEVID: u32 = 0x0000_0002;
const ATTR_CMN_OBJTYPE: u32 = 0x0000_0008;
const ATTR_CMN_MODTIME: u32 = 0x0000_0400;
const ATTR_CMN_ERROR: u32 = 0x2000_0000;
const ATTR_FILE_ALLOCSIZE: u32 = 0x0000_0004;
const FSOPT_PACK_INVAL_ATTRS: u64 = 0x0008;
const VREG: u32 = 1;
const VDIR: u32 = 2;
const EINTR: c_int = 4;
// The kernel prepares the whole buffer on every call, and most directories
// are small: a large buffer turns into seconds of system time.
pub const buffer_len = 32 * 1024;

const AttrList = extern struct {
    bitmapcount: u16 = ATTR_BIT_MAP_COUNT,
    reserved: u16 = 0,
    commonattr: u32 = 0,
    volattr: u32 = 0,
    dirattr: u32 = 0,
    fileattr: u32 = 0,
    forkattr: u32 = 0,
};

extern "c" fn getattrlistbulk(fd: c_int, attrs: *AttrList, buffer: [*]u8, size: usize, options: u64) c_int;
// Intel Macs keep the 32-bit-inode `stat` under the plain name; Apple
// silicon only has the 64-bit one.
const intel = @import("builtin").cpu.arch == .x86_64;
const StatFn = *const fn (path: [*:0]const u8, out: *Stat) callconv(.c) c_int;
const c_stat = @extern(StatFn, .{ .name = if (intel) "stat$INODE64" else "stat" });
const c_lstat = @extern(StatFn, .{ .name = if (intel) "lstat$INODE64" else "lstat" });
extern "c" fn sysctlbyname(name: [*:0]const u8, out: *anyopaque, out_len: *usize, new: ?*const anyopaque, new_len: usize) c_int;
extern "c" fn confstr(name: c_int, buf: ?[*]u8, len: usize) usize;
extern "c" fn getrlimit(resource: c_int, limit: *Rlimit) c_int;
extern "c" fn setrlimit(resource: c_int, limit: *const Rlimit) c_int;
extern "c" fn setiopolicy_np(kind: c_int, scope: c_int, policy: c_int) c_int;

const RLIMIT_NOFILE: c_int = 8;
const TimeSpec = extern struct { sec: i64, nsec: i64 };
const Rlimit = extern struct { cur: u64, max: u64 };

/// `struct stat`, Darwin's 64-bit layout.
pub const Stat = extern struct {
    dev: i32,
    mode: u16,
    nlink: u16,
    ino: u64,
    uid: u32,
    gid: u32,
    rdev: i32,
    atime: TimeSpec,
    mtime: TimeSpec,
    ctime: TimeSpec,
    birth: TimeSpec,
    size: i64,
    blocks: i64,
    blksize: i32,
    flags: u32,
    gen: u32,
    lspare: u32,
    pad: u32,
    qspare: [2]i64,

    pub fn isDir(s: *const Stat) bool {
        return s.mode & 0o170000 == 0o040000;
    }

    pub fn isRegular(s: *const Stat) bool {
        return s.mode & 0o170000 == 0o100000;
    }

    pub fn isSymlink(s: *const Stat) bool {
        return s.mode & 0o170000 == 0o120000;
    }
};

fn pathZ(buf: []u8, path: []const u8) ?[*:0]const u8 {
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @ptrCast(buf.ptr);
}

/// `stat`, following symlinks. Null when the path cannot be stat'ed.
pub fn statOf(path: []const u8) ?Stat {
    var buf: [max_path]u8 = undefined;
    const z = pathZ(&buf, path) orelse return null;
    var out: Stat = undefined;
    if (c_stat(z, &out) != 0) return null;
    return out;
}

/// `lstat`, never following the final symlink.
pub fn lstat(path: []const u8) ?Stat {
    var buf: [max_path]u8 = undefined;
    const z = pathZ(&buf, path) orelse return null;
    var out: Stat = undefined;
    if (c_lstat(z, &out) != 0) return null;
    return out;
}

/// Once per process, before the first walk: stop iCloud and File Provider
/// placeholders from downloading (a scan must never fill the disk it is
/// measuring) and raise the descriptor limit a GUI app starts with.
pub fn prepare() void {
    const holder = struct {
        var once = std.atomic.Value(bool).init(false);
    };
    if (holder.once.swap(true, .acq_rel)) return;
    // IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, process scope, off.
    _ = setiopolicy_np(3, 0, 1);
    var limit: Rlimit = undefined;
    if (getrlimit(RLIMIT_NOFILE, &limit) == 0) {
        limit.cur = @min(limit.max, 10_240);
        _ = setrlimit(RLIMIT_NOFILE, &limit);
    }
}

fn performanceCores() u32 {
    var cores: c_int = 0;
    var len: usize = @sizeOf(c_int);
    if (sysctlbyname("hw.perflevel0.physicalcpu", &cores, &len, null, 0) == 0 and cores > 0) {
        return @intCast(cores);
    }
    return @intCast(@min(64, @max(4, std.Thread.getCpuCount() catch 4)));
}

/// How many workers a scan uses. Past the performance cores the walkers
/// only contend in the kernel: on an M4 Pro, 12 threads took three times
/// as long as 8.
pub fn threadCount() u32 {
    if (env("SYSDATA_THREADS")) |n| {
        const trimmed = std.mem.trim(u8, n, " ");
        if (std.fmt.parseInt(u32, trimmed, 10) catch null) |threads| {
            if (threads > 0) return threads;
        }
    }
    return performanceCores();
}

/// An environment variable's value, or null. Zig 0.17's std moved getenv
/// to the C layer the process already links.
pub fn env(name: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const value = std.c.getenv(@ptrCast(&buf)) orelse return null;
    return std.mem.span(value);
}

/// One entry, as the kernel reported it. `name` borrows the walker's or
/// caller's scratch buffer: copy or use it before the next `next()`.
const Entry = struct {
    name: []const u8,
    kind: Kind,
    device: i32,
    modified: i64,
    allocated: u64,
};

/// The record parser shared by the walker and the plain listings.
const List = struct {
    fd: c_int,
    buffer: []u8,
    request: AttrList = .{
        .commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_DEVID |
            ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_ERROR,
        .fileattr = ATTR_FILE_ALLOCSIZE,
    },
    /// Entries left in the last bulk result.
    left: usize = 0,
    offset: usize = 0,

    /// The next entry, or null when the listing ends. Entries the kernel
    /// reports an error for are skipped, like an unreadable file in
    /// Finder's count.
    fn next(l: *List) ?Entry {
        while (true) {
            if (l.left == 0) {
                const count = getattrlistbulk(
                    l.fd,
                    &l.request,
                    l.buffer.ptr,
                    l.buffer.len,
                    FSOPT_PACK_INVAL_ATTRS,
                );
                if (count <= 0) {
                    // A signal only interrupts the call; anything else ends it.
                    if (count < 0 and std.c._errno().* == EINTR) continue;
                    return null;
                }
                l.left = @intCast(count);
                l.offset = 0;
            }
            l.left -= 1;
            const b = l.buffer;
            if (l.offset + 4 > b.len) {
                l.left = 0;
                continue;
            }
            const length: usize = readInt(u32, b, l.offset);
            if (length < 4 or l.offset + length > b.len) {
                l.left = 0;
                continue;
            }
            const record = b[l.offset .. l.offset + length];
            l.offset += length;
            // Layout: length, returned set, error, name reference, device,
            // type, modification time, then the allocated size only for
            // files. Directory records end before it, so the returned set
            // decides whether it is there.
            if (length < 60 or readInt(u32, record, 24) != 0) continue;
            const name_offset: usize = @as(usize, @intCast(readInt(i32, record, 28))) + 28;
            const name_length: usize = readInt(u32, record, 32);
            if (name_length == 0 or name_length - 1 > record.len or name_offset > record.len - (name_length - 1)) continue;
            const name = record[name_offset .. name_offset + name_length - 1];
            const kind: Kind = switch (readInt(u32, record, 40)) {
                VREG => .file,
                VDIR => .dir,
                else => .other,
            };
            const returned = readInt(u32, record, 16);
            const has_size = (returned & ATTR_FILE_ALLOCSIZE) != 0 and length >= 68;
            return .{
                .name = name,
                .kind = kind,
                .device = readInt(i32, record, 36),
                .modified = readInt(i64, record, 44),
                .allocated = if (has_size) @intCast(@max(0, readInt(i64, record, 60))) else 0,
            };
        }
    }
};

fn readInt(comptime T: type, bytes: []const u8, at: usize) T {
    var raw: [@sizeOf(T)]u8 = undefined;
    @memcpy(&raw, bytes[at .. at + @sizeOf(T)]);
    return std.mem.readInt(T, &raw, .little);
}

fn joinPath(gpa: std.mem.Allocator, parent: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ parent, name });
}

/// A measure() in flight: the calling thread waits until its tree is done.
const Done = struct {
    mutex: sync.Mutex = .{},
    cond: sync.Condition = .{},
    ready: bool = false,
    total: Measurement = .{},

    fn init(d: *Done) void {
        d.mutex.init();
        d.cond.init();
    }
};

/// Everything one walk needs to decide what counts. It lives on the stack
/// of the thread that started the walk, for exactly as long as the walk.
const TreeOpts = struct {
    /// Only regular files modified at or before this second count.
    cutoff: ?i64 = null,
    /// Stay on this device; null follows mounts like Finder's own walk.
    device: ?i32 = null,
    skip: ?*const Skip = null,
    /// A directory holding `.git` counts as nothing, like a skipped one.
    skip_repositories: bool = false,
    /// Records the total of every directory down to this depth.
    record: ?Record = null,

    const Record = struct {
        max_depth: u32,
        map: *std.StringHashMapUnmanaged(u64),
        gpa: std.mem.Allocator,
    };
};

const Node = struct {
    opts: *const TreeOpts,
    done: *Done,
    /// Null only for the root of a measure() call.
    parent: ?*Node,
    /// This directory's own descriptor, open until the subtree is done.
    fd: sys.fd_t,
    /// Owned by the node, freed when it finishes.
    path: []u8,
    depth: u32,
    /// Unfinished children plus this node's own work, guarded by the
    /// walker's tree mutex. It reaches zero exactly once.
    pending: u32 = 1,
    own: u64 = 0,
    subtree: u64 = 0,
    newest: ?i64 = null,
    repository: bool = false,
};

pub const Walker = struct {
    gpa: std.mem.Allocator,
    threads: []?std.Thread = &.{},
    /// Totals the probes measured during the current scan, reused by the
    /// catch-all so no tree is walked twice.
    known: ?*Known = null,
    known_mutex: sync.Mutex = .{},

    queue: std.ArrayList(*Node) = .empty,
    queue_mutex: sync.Mutex = .{},
    queue_cond: sync.Condition = .{},
    tree_mutex: sync.Mutex = .{},
    stopping: bool = false,

    /// Spawns the workers once; they serve every measure of this scan. In
    /// place: the workers hold `w`, so it must not move until `deinit`.
    pub fn init(w: *Walker, gpa: std.mem.Allocator, workers: u32) void {
        w.* = .{ .gpa = gpa };
        w.queue_mutex.init();
        w.queue_cond.init();
        w.tree_mutex.init();
        w.known_mutex.init();
        const n = @max(1, workers);
        w.threads = gpa.alloc(?std.Thread, n) catch return;
        for (w.threads, 0..) |*t, i| {
            t.* = std.Thread.spawn(.{ .stack_size = 512 * 1024 }, worker, .{ w, i }) catch null;
        }
    }

    pub fn deinit(w: *Walker) void {
        w.queue_mutex.lock();
        w.stopping = true;
        w.queue_mutex.unlock();
        w.queue_cond.broadcast();
        for (w.threads) |t| {
            if (t) |thread| thread.join();
        }
        w.gpa.free(w.threads);
        w.queue.deinit(w.gpa);
    }

    /// Allocated bytes under `path` and its newest file. A regular file is
    /// its own size; a missing path is zero. Symlinks are never followed
    /// inside. The total is remembered in the scan's known-sizes map.
    pub fn measure(w: *Walker, path: []const u8) Measurement {
        const m = w.measureWith(path, null);
        w.remember(path, m.bytes);
        return m;
    }

    /// Like `measure`, counting only files last modified before `cutoff`.
    pub fn measureOlderThan(w: *Walker, path: []const u8, cutoff: i64) Measurement {
        return w.measureWith(path, cutoff);
    }

    fn remember(w: *Walker, path: []const u8, bytes: u64) void {
        const map = w.known orelse return;
        const key = w.gpa.dupe(u8, path) catch return;
        w.known_mutex.lock();
        defer w.known_mutex.unlock();
        const gop = map.getOrPut(w.gpa, key) catch {
            w.gpa.free(key);
            return;
        };
        if (gop.found_existing) w.gpa.free(key) else gop.value_ptr.* = bytes;
    }

    fn measureWith(w: *Walker, path: []const u8, cutoff: ?i64) Measurement {
        const info = statOf(path) orelse return .{};
        if (info.isRegular()) {
            if (cutoff) |c| {
                if (info.mtime.sec > c) return .{};
            }
            return .{
                .bytes = @as(u64, @intCast(@max(0, info.blocks))) * 512,
                .newest = info.mtime.sec,
            };
        }
        if (!info.isDir()) return .{};
        var opts = TreeOpts{ .cutoff = cutoff };
        return w.walkTree(path, &opts);
    }

    fn walkTree(w: *Walker, path: []const u8, opts: *const TreeOpts) Measurement {
        const fd = sys.openDir(path) catch return .{};
        var done = Done{};
        done.init();
        const owned = w.gpa.dupe(u8, path) catch {
            sys.close(fd);
            return .{};
        };
        const root = w.gpa.create(Node) catch {
            w.gpa.free(owned);
            sys.close(fd);
            return .{};
        };
        root.* = .{ .opts = opts, .done = &done, .parent = null, .fd = fd, .path = owned, .depth = 0 };
        w.push(root);
        done.mutex.lock();
        while (!done.ready) done.cond.wait(&done.mutex);
        done.mutex.unlock();
        return done.total;
    }

    /// Totals of every directory under `root` down to `max_depth` levels,
    /// from one walk that stays on the root's volume and never enters
    /// `skip` or a git repository. A directory in the scan's known map adds
    /// its total without a walk. Fills `sizes`, keyed by paths allocated
    /// from `sizes_gpa`.
    pub fn directorySizes(
        w: *Walker,
        root: []const u8,
        max_depth: u32,
        skip: *const Skip,
        sizes: *std.StringHashMapUnmanaged(u64),
        sizes_gpa: std.mem.Allocator,
    ) void {
        const info = statOf(root) orelse return;
        var opts = TreeOpts{
            .device = info.dev,
            .skip = skip,
            .skip_repositories = true,
            .record = .{ .max_depth = max_depth, .map = sizes, .gpa = sizes_gpa },
        };
        _ = w.walkTree(root, &opts);
    }

    fn push(w: *Walker, node: *Node) void {
        w.queue_mutex.lock();
        w.queue.append(w.gpa, node) catch {
            w.queue_mutex.unlock();
            w.finishNode(node);
            return;
        };
        w.queue_mutex.unlock();
        w.queue_cond.signal();
    }

    fn worker(w: *Walker, index: usize) void {
        _ = index;
        // Each worker keeps its own scratch buffer: no sharing, no locks.
        var scratch: [buffer_len]u8 = undefined;
        while (true) {
            w.queue_mutex.lock();
            while (w.queue.items.len == 0) {
                if (w.stopping) {
                    w.queue_mutex.unlock();
                    return;
                }
                w.queue_cond.wait(&w.queue_mutex);
            }
            const node = w.queue.pop().?;
            w.queue_mutex.unlock();
            w.process(node, &scratch);
        }
    }

    fn process(w: *Walker, node: *Node, scratch: []u8) void {
        // The root of a measure() call arrives opened; children open here,
        // relative to their parent's still-open descriptor.
        if (node.fd < 0) {
            node.fd = openChild(node.parent.?.fd, node.path) catch {
                w.finishNode(node);
                return;
            };
        }
        var subs: std.ArrayList([]u8) = .empty;
        defer subs.deinit(w.gpa);
        var own: u64 = 0;
        var newest: ?i64 = null;
        var repository = false;
        var list = List{ .fd = node.fd, .buffer = scratch };
        while (list.next()) |e| {
            if (node.opts.skip_repositories and std.mem.eql(u8, e.name, ".git")) {
                repository = true;
                continue;
            }
            switch (e.kind) {
                .file => {
                    if (node.opts.cutoff) |c| {
                        if (e.modified > c) continue;
                    }
                    own += e.allocated;
                    newest = if (newest) |n| @max(n, e.modified) else e.modified;
                },
                .dir => {
                    if (node.opts.device) |d| {
                        if (e.device != d) continue;
                    }
                    const child_path = joinPath(w.gpa, node.path, e.name) catch continue;
                    if (node.opts.skip) |skip| {
                        if (skip.contains(child_path)) {
                            w.gpa.free(child_path);
                            continue;
                        }
                    }
                    var known_bytes: ?u64 = null;
                    if (w.known) |map| {
                        w.known_mutex.lock();
                        known_bytes = map.get(child_path);
                        w.known_mutex.unlock();
                    }
                    if (known_bytes) |bytes| {
                        // Measured earlier in this scan: add its total, no walk.
                        own += bytes;
                        if (node.opts.record) |r| {
                            if (node.depth < r.max_depth and bytes > 0) {
                                putRecord(r, child_path, bytes, w.gpa);
                            }
                        }
                        w.gpa.free(child_path);
                        continue;
                    }
                    subs.append(w.gpa, child_path) catch w.gpa.free(child_path);
                },
                .other => {},
            }
        }
        node.own = own;
        node.newest = newest;
        node.repository = repository;
        if (repository) {
            // A git repository is source a person cares about; the
            // catch-all must not offer it as one blob.
            node.own = 0;
            node.newest = null;
            for (subs.items) |p| w.gpa.free(p);
            w.finishNode(node);
            return;
        }
        for (subs.items) |child_path| {
            const child = w.gpa.create(Node) catch {
                w.gpa.free(child_path);
                continue;
            };
            child.* = .{
                .opts = node.opts,
                .done = node.done,
                .parent = node,
                .fd = -1,
                .path = child_path,
                .depth = node.depth + 1,
            };
            w.tree_mutex.lock();
            node.pending += 1;
            w.tree_mutex.unlock();
            w.push(child);
        }
        w.finishNode(node);
    }

    /// One node's work is done; when it was the last below its parent, the
    /// subtree total climbs the tree, and the root reports to `done`.
    fn finishNode(w: *Walker, node_in: *Node) void {
        var node = node_in;
        w.tree_mutex.lock();
        node.pending -= 1;
        if (node.pending != 0) {
            w.tree_mutex.unlock();
            return;
        }
        while (true) {
            const total = node.own + node.subtree;
            if (node.opts.record) |r| {
                if (node.depth <= r.max_depth and total > 0 and !node.repository) {
                    putRecord(r, node.path, total, w.gpa);
                }
            }
            const parent = node.parent;
            const done = node.done;
            const newest = node.newest;
            if (node.fd >= 0) sys.close(node.fd);
            w.gpa.free(node.path);
            w.gpa.destroy(node);
            if (parent) |p| {
                p.subtree += total;
                if (newest) |n| {
                    p.newest = if (p.newest) |pn| @max(pn, n) else n;
                }
                p.pending -= 1;
                if (p.pending != 0) {
                    w.tree_mutex.unlock();
                    return;
                }
                node = p;
                continue;
            }
            // The root: the measure that started this tree can return.
            w.tree_mutex.unlock();
            done.mutex.lock();
            done.total = .{ .bytes = total, .newest = newest };
            done.ready = true;
            done.cond.signal();
            done.mutex.unlock();
            return;
        }
    }
};

fn putRecord(r: TreeOpts.Record, path: []const u8, bytes: u64, walker_gpa: std.mem.Allocator) void {
    const key = r.gpa.dupe(u8, path) catch return;
    const gop = r.map.getOrPut(r.gpa, key) catch {
        r.gpa.free(key);
        return;
    };
    if (gop.found_existing) {
        r.gpa.free(key);
    } else {
        gop.value_ptr.* = bytes;
    }
    _ = walker_gpa;
}

fn openChild(parent_fd: sys.fd_t, path: []const u8) !sys.fd_t {
    return sys.openDirAt(parent_fd, std.fs.path.basename(path), true);
}

/// Direct children of `dir`, hidden ones included, sorted by name. Paths are
/// allocated from `gpa`; the caller owns them.
pub fn children(dir: []const u8, gpa: std.mem.Allocator, out: *std.ArrayList(Child)) !void {
    const fd = sys.openDir(dir) catch return;
    defer sys.close(fd);
    var scratch: [buffer_len]u8 = undefined;
    var list = List{ .fd = fd, .buffer = &scratch };
    while (list.next()) |e| {
        try out.append(gpa, .{
            .path = try joinPath(gpa, dir, e.name),
            .kind = e.kind,
            .modified = e.modified,
        });
    }
    std.mem.sort(Child, out.items, {}, struct {
        fn lt(_: void, x: Child, y: Child) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.lt);
}

/// Direct subdirectories of `dir`, sorted by name. Symlinks are not followed.
pub fn subdirectories(dir: []const u8, gpa: std.mem.Allocator) ![][]u8 {
    var all: std.ArrayList(Child) = .empty;
    defer {
        for (all.items) |c| gpa.free(c.path);
        all.deinit(gpa);
    }
    try children(dir, gpa, &all);
    var dirs: std.ArrayList([]u8) = .empty;
    errdefer {
        for (dirs.items) |d| gpa.free(d);
        dirs.deinit(gpa);
    }
    // Directory paths move to the caller; the deferred free skips them.
    for (all.items) |*c| {
        if (c.kind != .dir) continue;
        try dirs.append(gpa, c.path);
        c.path = &.{};
    }
    return dirs.toOwnedSlice(gpa);
}

/// Newest modification among `dir` and its direct children, from one listing.
pub fn shallowModified(dir: []const u8) ?i64 {
    const info = statOf(dir) orelse return null;
    var newest: ?i64 = info.mtime.sec;
    const fd = sys.openDir(dir) catch return newest;
    defer sys.close(fd);
    var scratch: [buffer_len]u8 = undefined;
    var list = List{ .fd = fd, .buffer = &scratch };
    while (list.next()) |e| {
        if (e.kind == .file) newest = if (newest) |n| @max(n, e.modified) else e.modified;
    }
    return newest;
}

pub fn exists(path: []const u8) bool {
    return statOf(path) != null;
}

pub fn isDir(path: []const u8) bool {
    const info = statOf(path) orelse return false;
    return info.isDir();
}

pub fn isSymlink(path: []const u8) bool {
    const info = lstat(path) orelse return false;
    return info.isSymlink();
}

/// Device of `path` itself, not following a final symlink.
pub fn deviceOf(path: []const u8) ?i32 {
    const info = lstat(path) orelse return null;
    return info.dev;
}

/// File flags macOS uses to protect data even from root.
pub fn isProtected(path: []const u8) bool {
    const info = lstat(path) orelse return true;
    return (info.flags & (0x0008_0000 | 0x0000_0080)) != 0;
}

/// Whether `path` lives on the startup volume. Unknown counts as yes, so an
/// unreadable location is measured rather than silently dropped.
pub fn onBootVolume(path: []const u8) bool {
    const root = statOf("/") orelse return true;
    const info = statOf(path) orelse return true;
    if (root.dev == info.dev) return true;
    const data = statOf("/System/Volumes/Data") orelse return true;
    return data.dev == info.dev;
}

/// `getconf DARWIN_USER_CACHE_DIR` and friends, resolved by the kernel.
pub fn confstrPath(name: c_int, buf: []u8) ?[]const u8 {
    const len = confstr(name, buf.ptr, buf.len);
    if (len == 0 or len > buf.len) return null;
    return buf[0 .. len - 1];
}

/// The reference: `lstat` every file, like `du`, without following links.
fn lstatWalk(gpa: std.mem.Allocator, base: []const u8) u64 {
    var total: u64 = 0;
    var kids: std.ArrayList(Child) = .empty;
    defer {
        for (kids.items) |k| gpa.free(k.path);
        kids.deinit(gpa);
    }
    children(base, gpa, &kids) catch return 0;
    for (kids.items) |k| {
        if (k.kind == .dir) {
            total += lstatWalk(gpa, k.path);
        } else if (lstat(k.path)) |info| {
            if (info.isRegular()) total += @as(u64, @intCast(@max(0, info.blocks))) * 512;
        }
    }
    return total;
}

/// A private directory for a test, removed afterwards.
pub const TestDir = struct {
    gpa: std.mem.Allocator,
    root: []u8,

    pub fn make(gpa: std.mem.Allocator) !TestDir {
        return .{ .gpa = gpa, .root = try sys.makeTempDir(gpa) };
    }

    fn sub(t: *TestDir, buf: []u8, rel: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ t.root, rel });
    }

    pub fn dir(t: *TestDir, rel: []const u8) !void {
        var buf: [max_path]u8 = undefined;
        try sys.makePath(try t.sub(&buf, rel));
    }

    pub fn file(t: *TestDir, rel: []const u8, data: []const u8) !void {
        var buf: [max_path]u8 = undefined;
        try sys.publishFile(try t.sub(&buf, rel), data);
    }

    pub fn link(t: *TestDir, target: []const u8, rel: []const u8) !void {
        var buf: [max_path]u8 = undefined;
        try sys.symlinkAt(target, try t.sub(&buf, rel));
    }

    pub fn cleanup(t: *TestDir) void {
        removeAll(t.gpa, t.root);
        t.gpa.free(t.root);
    }

    fn removeAll(gpa: std.mem.Allocator, path: []const u8) void {
        var kids: std.ArrayList(Child) = .empty;
        defer {
            for (kids.items) |k| gpa.free(k.path);
            kids.deinit(gpa);
        }
        children(path, gpa, &kids) catch {};
        for (kids.items) |k| {
            if (k.kind == .dir) removeAll(gpa, k.path) else sys.unlink(k.path) catch {};
        }
        sys.rmdir(path) catch {};
    }
};

test "the walker matches an lstat walk, skips and records" {
    const gpa = std.testing.allocator;
    var tmp = try TestDir.make(gpa);
    defer tmp.cleanup();
    const root = tmp.root;

    try tmp.dir("a/b/c");
    try tmp.dir("d");
    try tmp.dir("e/f");
    for ([_][]const u8{ "top.bin", "a/one.bin", "a/b/two.bin", "a/b/c/three.bin", "e/f/four.bin" }) |file| {
        try tmp.file(file, "0123456789");
    }
    // A symlink into a system tree: never followed, never counted.
    try tmp.link("/usr", "d/link");

    var walker: Walker = undefined;
    walker.init(gpa, 4);
    defer walker.deinit();
    prepare();

    const measured = walker.measure(root);
    const reference = lstatWalk(gpa, root);
    try std.testing.expectEqual(reference, measured.bytes);
    try std.testing.expect(measured.bytes >= 5 * 512);
    try std.testing.expect(measured.newest != null);

    // A file and a missing path.
    var file_buf: [max_path]u8 = undefined;
    const file = try std.fmt.bufPrint(&file_buf, "{s}/top.bin", .{root});
    const file_info = statOf(file).?;
    try std.testing.expectEqual(@as(u64, @intCast(file_info.blocks)) * 512, walker.measure(file).bytes);
    try std.testing.expectEqual(@as(u64, 0), walker.measure("/no/such/path").bytes);

    // Depth-capped totals, with a skipped subtree.
    const e_dir = try std.fmt.allocPrint(gpa, "{s}/e", .{root});
    defer gpa.free(e_dir);
    var skip: Skip = .empty;
    defer skip.deinit(gpa);
    try skip.put(gpa, e_dir, {});
    var sizes: std.StringHashMapUnmanaged(u64) = .empty;
    defer {
        var it = sizes.iterator();
        while (it.next()) |entry| gpa.free(entry.key_ptr.*);
        sizes.deinit(gpa);
    }
    walker.directorySizes(root, 2, &skip, &sizes, gpa);
    const a = try std.fmt.allocPrint(gpa, "{s}/a", .{root});
    defer gpa.free(a);
    const ab = try std.fmt.allocPrint(gpa, "{s}/a/b", .{root});
    defer gpa.free(ab);
    const abc = try std.fmt.allocPrint(gpa, "{s}/a/b/c", .{root});
    defer gpa.free(abc);
    try std.testing.expectEqual(lstatWalk(gpa, a), sizes.get(a).?);
    try std.testing.expectEqual(lstatWalk(gpa, ab), sizes.get(ab).?);
    try std.testing.expect(sizes.get(abc) == null); // deeper than the cap
    try std.testing.expect(sizes.get(e_dir) == null); // skipped
    try std.testing.expectEqual(reference - lstatWalk(gpa, e_dir), sizes.get(root).?);
}

test "a cutoff counts only old files" {
    const gpa = std.testing.allocator;
    var tmp = try TestDir.make(gpa);
    defer tmp.cleanup();
    const root = tmp.root;
    try tmp.file("now.bin", "x");

    var walker: Walker = undefined;
    walker.init(gpa, 2);
    defer walker.deinit();
    try std.testing.expectEqual(@as(u64, 0), walker.measureOlderThan(root, 0).bytes);
    try std.testing.expect(walker.measureOlderThan(root, clock.now() + 60).bytes >= 512);
}
