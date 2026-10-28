//! Package-manager download caches. Each is refilled on demand, and the
//! tool's own clean command runs when it is installed, so its bookkeeping
//! stays right.
const std = @import("std");
const scan_mod = @import("../scan.zig");
const walker_mod = @import("../walker.zig");
const proc = @import("../proc.zig");
const item_mod = @import("../item.zig");

const Scan = scan_mod.Scan;
const Item = item_mod.Item;
const MB = scan_mod.MB;

const Tool = struct { program: []const u8, args: []const []const u8 };

const Cache = struct {
    id: []const u8,
    name: []const u8,
    relative: []const u8,
    tool: ?Tool,
    detail: []const u8,
    safety: item_mod.Safety,
};

const caches = [_]Cache{
    .{ .id = "brew", .name = "Homebrew downloads", .relative = "Library/Caches/Homebrew", .tool = .{ .program = "brew", .args = &.{ "cleanup", "--prune=all", "-s" } }, .detail = "Downloaded bottles and source archives.", .safety = .safe },
    .{ .id = "npm", .name = "npm cache", .relative = ".npm/_cacache", .tool = .{ .program = "npm", .args = &.{ "cache", "clean", "--force" } }, .detail = "Package tarballs and their metadata.", .safety = .safe },
    .{ .id = "yarn", .name = "Yarn cache", .relative = "Library/Caches/Yarn", .tool = .{ .program = "yarn", .args = &.{ "cache", "clean" } }, .detail = "Package tarballs.", .safety = .safe },
    .{ .id = "pip", .name = "pip cache", .relative = "Library/Caches/pip", .tool = .{ .program = "pip3", .args = &.{ "cache", "purge" } }, .detail = "Wheels and the HTTP cache.", .safety = .safe },
    .{ .id = "uv", .name = "uv cache", .relative = ".cache/uv", .tool = .{ .program = "uv", .args = &.{ "cache", "clean" } }, .detail = "Python wheels, sources and interpreters.", .safety = .safe },
    .{ .id = "pods", .name = "CocoaPods cache", .relative = "Library/Caches/CocoaPods", .tool = .{ .program = "pod", .args = &.{ "cache", "clean", "--all" } }, .detail = "Pod specs and sources.", .safety = .safe },
    .{ .id = "gradle", .name = "Gradle caches", .relative = ".gradle/caches", .tool = null, .detail = "Dependency jars and the build cache. Downloaded again on the next build.", .safety = .safe },
    .{ .id = "cargo", .name = "Cargo registry", .relative = ".cargo/registry", .tool = null, .detail = "Crate sources and downloaded archives.", .safety = .safe },
    .{ .id = "swiftpm", .name = "SwiftPM cache", .relative = "Library/Caches/org.swift.swiftpm", .tool = null, .detail = "Package repository clones.", .safety = .safe },
    .{ .id = "go", .name = "Go build cache", .relative = "Library/Caches/go-build", .tool = null, .detail = "Compiled Go packages.", .safety = .safe },
    .{ .id = "cypress", .name = "Cypress binaries", .relative = "Library/Caches/Cypress", .tool = null, .detail = "Downloaded Cypress versions.", .safety = .safe },
    .{ .id = "playwright", .name = "Playwright browsers", .relative = "Library/Caches/ms-playwright", .tool = null, .detail = "Downloaded browser builds. `playwright install` fetches them again.", .safety = .safe },
};

pub fn probe(s: *Scan) scan_mod.Error!std.ArrayList(Item) {
    var out: std.ArrayList(Item) = .empty;
    const arena = s.env.arena;
    // uvx programs (MCP servers among them) hold uv's cache lock for hours.
    // Cleaning would wait on them and remove the environments they run from.
    var running_uv: usize = 0;
    if (s.env.system) running_uv = countRunningUv(s);
    for (caches) |c| {
        const path = s.env.at(c.relative);
        var safety = c.safety;
        var detail = c.detail;
        var action: item_mod.Action = undefined;
        if (std.mem.eql(u8, c.id, "uv") and running_uv > 0) {
            safety = .manual;
            detail = try std.fmt.allocPrint(
                arena,
                "{d} uv process{s} running, such as tools started with uvx. They hold this cache; quit them first.",
                .{ running_uv, if (running_uv == 1) " is" else "es are" },
            );
            action = .{ .manual = "# Quit the programs started with uvx first, then:\nuv cache clean" };
        } else if (findTool(s, c.tool)) |program| {
            action = .{ .command = .{ .program = program, .args = c.tool.?.args } };
        } else {
            const dirs = try arena.alloc([]const u8, 1);
            dirs[0] = path;
            action = .{ .empty_directories = dirs };
        }
        if (scan_mod.dirItem(s, try std.fmt.allocPrint(arena, "pkg-{s}", .{c.id}), .packages, c.name, detail, path, safety, action, MB)) |found| {
            try out.append(arena, found);
        }
    }

    // Only pnpm knows where a custom store lives, and an uninstalled pnpm
    // leaves its store with nothing referencing it.
    try pnpm(s, &out);

    if (s.env.system) {
        // The whole prefix: formulae also install into share/ and lib/,
        // casks into Caskroom.
        for ([_][]const u8{ "/opt/homebrew", "/usr/local" }) |prefix| {
            const brew = try std.fmt.allocPrint(arena, "{s}/bin/brew", .{prefix});
            if (!walker_mod.exists(brew)) continue;
            const dirs = try arena.alloc([]const u8, 1);
            dirs[0] = prefix;
            if (scan_mod.dirItem(
                s,
                try std.fmt.allocPrint(arena, "pkg-homebrew-{s}", .{prefix}),
                .packages,
                "Homebrew installation",
                try std.fmt.allocPrint(arena, "{s}: every formula and cask installed with brew. Remove what you no longer use.", .{prefix}),
                prefix,
                .manual,
                .{ .manual = "brew leaves            # formulae you asked for\nbrew list --cask\nbrew uninstall <formula>\nbrew uninstall --cask <name>\nbrew autoremove" },
                100 * MB,
            )) |found| try out.append(arena, found);
        }
    }
    scan_mod.bySize(out.items);
    return out;
}

fn pnpm(s: *Scan, out: *std.ArrayList(Item)) scan_mod.Error!void {
    const arena = s.env.arena;
    if (proc.which(s.gpa, "pnpm", s.path_dirs)) |found| {
        defer s.gpa.free(found);
        const raw = proc.probe(s.gpa, found, &.{ "store", "path" }) orelse return;
        defer s.gpa.free(raw);
        const path = std.mem.trim(u8, raw, " \t\r\n");
        if (path.len == 0 or !walker_mod.exists(path)) return;
        const dirs = try arena.alloc([]const u8, 1);
        dirs[0] = try arena.dupe(u8, path);
        if (scan_mod.dirItem(
            s,
            "pkg-pnpm",
            .packages,
            "pnpm store",
            "Packages no project references any more, in the content-addressable store.",
            dirs[0],
            .safe,
            .{ .command = .{ .program = try arena.dupe(u8, found), .args = &.{ "store", "prune" } } },
            MB,
        )) |found_item| try out.append(arena, found_item);
        return;
    }
    const defaults = [_][]const u8{ "Library/pnpm/store", ".local/share/pnpm/store", ".pnpm-store" };
    for (defaults) |relative| {
        const path = s.env.at(relative);
        if (!walker_mod.exists(path)) continue;
        const dirs = try arena.alloc([]const u8, 1);
        dirs[0] = path;
        if (scan_mod.dirItem(
            s,
            "pkg-pnpm",
            .packages,
            "pnpm store",
            "pnpm is not on this Mac, so nothing appears to use this store. A version manager may still run pnpm from elsewhere.",
            path,
            .review,
            .{ .remove_paths = dirs },
            MB,
        )) |found_item| try out.append(arena, found_item);
        return;
    }
}

fn countRunningUv(s: *Scan) usize {
    const raw = proc.probe(s.gpa, "/usr/bin/pgrep", &.{ "-x", "uv" }) orelse return 0;
    defer s.gpa.free(raw);
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len > 0) n += 1;
    }
    return n;
}

/// A tool's absolute path, found the way a login shell would, or null.
fn findTool(s: *Scan, tool: ?Tool) ?[]const u8 {
    const t = tool orelse return null;
    const found = proc.which(s.gpa, t.program, s.path_dirs) orelse return null;
    defer s.gpa.free(found);
    return s.env.arena.dupe(u8, found) catch null;
}
