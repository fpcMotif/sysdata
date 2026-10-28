//! The ladder every path descends before it is trashed or deleted.
//!
//! A path must pass every step. Children of a protected folder may go; the
//! folder itself never does. A symlinked ancestor must not smuggle the
//! target into one either: the parent is resolved first and the whole
//! path re-checked from its real location.
const std = @import("std");
const walker = @import("walker.zig");

extern "c" fn _NSGetExecutablePath(buf: [*]u8, size: *u32) c_int;

/// Why a path was refused; the message names the rule, the caller names the path.
pub const Refusal = error{
    NotAbsolute,
    ContainsDot,
    ProtectedFolder,
    AppInside,
    SymlinkedTarget,
    MountedVolume,
};

pub fn describe(refusal: Refusal) []const u8 {
    return switch (refusal) {
        Refusal.NotAbsolute => "not an absolute path",
        Refusal.ContainsDot => "it contains . or ..",
        Refusal.ProtectedFolder => "it is a folder macOS or you depend on",
        Refusal.AppInside => "this app is running from inside it",
        Refusal.SymlinkedTarget => "it resolves to a protected folder",
        Refusal.MountedVolume => "it is a mounted volume",
    };
}

/// Paths nothing may delete, whatever an item claims. Their children may go.
pub fn protected(path: []const u8, home: []const u8) bool {
    const system = [_][]const u8{
        "/",           "/System",  "/Library", "/Applications",   "/Users",
        "/Users/Shared", "/private", "/private/var", "/private/etc", "/usr",
        "/usr/local",  "/opt",     "/opt/homebrew", "/bin",        "/sbin",
        "/Volumes",
    };
    for (system) |p| {
        if (std.mem.eql(u8, path, p)) return true;
    }
    const home_tree = [_][]const u8{
        "Library",                    "Documents",
        "Desktop",                    "Downloads",
        "Pictures",                   "Movies",
        "Music",                     "Public",
        "Applications",              "Developer",
        ".Trash",                    ".ssh",
        ".gnupg",                     "Library/Keychains",
        "Library/Preferences",        "Library/Caches",
        "Library/Application Support", "Library/Containers",
        "Library/Group Containers",   "Library/Mobile Documents",
        "Library/CloudStorage",
    };
    if (std.mem.eql(u8, path, home)) return true;
    for (home_tree) |relative| {
        if (path.len == home.len + 1 + relative.len and
            std.mem.startsWith(u8, path, home) and
            path[home.len] == '/' and
            std.mem.eql(u8, path[home.len + 1 ..], relative)) return true;
    }
    return false;
}

/// Checks one path. Throws the first rule it breaks.
pub fn check(path: []const u8, home: []const u8, gpa: std.mem.Allocator) Refusal!void {
    if (!std.fs.path.isAbsolute(path)) return Refusal.NotAbsolute;
    var rest = path;
    while (rest.len > 0) {
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        const segment = rest[0..slash];
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) {
            return Refusal.ContainsDot;
        }
        rest = if (slash < rest.len) rest[slash + 1 ..] else rest[rest.len..];
    }
    if (protected(path, home)) return Refusal.ProtectedFolder;
    var exe_buf: [walker.max_path]u8 = undefined;
    var exe_len: u32 = exe_buf.len;
    if (_NSGetExecutablePath(&exe_buf, &exe_len) == 0) {
        const exe = exe_buf[0..exe_len];
        if (std.mem.startsWith(u8, exe, path)) return Refusal.AppInside;
    }
    // A symlinked ancestor must not smuggle the target somewhere else.
    const parent = std.fs.path.dirname(path) orelse return Refusal.ProtectedFolder;
    const name = std.fs.path.basename(path);
    if (@import("sys.zig").realpath(gpa, parent)) |real_parent| {
        defer gpa.free(real_parent);
        const real = std.fmt.allocPrint(gpa, "{s}/{s}", .{ real_parent, name }) catch
            return Refusal.SymlinkedTarget;
        defer gpa.free(real);
        const real_home = @import("sys.zig").realpath(gpa, home) catch home;
        const real_home_was_allocated = real_home.ptr != home.ptr;
        defer if (real_home_was_allocated) gpa.free(real_home);
        if (protected(real, home) or protected(real, real_home)) return Refusal.SymlinkedTarget;
        const dev = walker.deviceOf(path);
        const parent_dev = walker.deviceOf(real_parent);
        if (dev != null and parent_dev != null and dev.? != parent_dev.? and !walker.isSymlink(path)) {
            return Refusal.MountedVolume;
        }
    } else |_| {}
}

test "the guard refuses what matters" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    const home = "/Users/someone";
    for ([_][]const u8{
        "/",               "/Users/someone",  "/Users/someone/Library",
        "/Users/someone/Documents", "/Applications", "/Users/someone/.ssh",
    }) |path| {
        try std.testing.expectError(Refusal.ProtectedFolder, check(path, home, gpa));
    }
    try std.testing.expectError(Refusal.NotAbsolute, check("relative/path", home, gpa));
    try std.testing.expectError(Refusal.ContainsDot, check("/Users/someone/Library/Caches/../Documents", home, gpa));
    if (check("/Users/someone/Library/Caches/com.example", home, gpa)) |_| {} else |e| {
        // Only when the test binary itself runs from inside that folder.
        try std.testing.expectEqual(Refusal.AppInside, e);
    }
    // Children of a protected folder may go.
    try std.testing.expect(!protected("/Users/someone/Library/Caches/com.example", home));
    try std.testing.expect(protected("/Users/someone/Library/Caches", home));
    try std.testing.expect(protected("/usr", home));
}
