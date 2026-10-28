//! Fixed sample items for `--fixture` and the interaction tests. The paths
//! do not exist, and fixture mode never touches the disk.
const std = @import("std");
const item_mod = @import("item.zig");

const Item = item_mod.Item;
const Category = item_mod.Category;
const Safety = item_mod.Safety;
const Action = item_mod.Action;

const MB: u64 = 1_000_000;

fn at(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "/tmp/sysdata-fixture/{s}", .{path});
}

fn paths(arena: std.mem.Allocator, id: []const u8) ![]const []const u8 {
    const one = try arena.alloc([]const u8, 1);
    one[0] = try at(arena, id);
    return one;
}

fn row(
    arena: std.mem.Allocator,
    id: []const u8,
    category: Category,
    name: []const u8,
    detail: []const u8,
    bytes: u64,
    safety: Safety,
    action: Action,
    idle_days: u64,
) !Item {
    return .{
        .id = id,
        .category = category,
        .name = name,
        .detail = detail,
        .size = bytes,
        .safety = safety,
        .action = action,
        .reveal = try at(arena, id),
        .modified = @import("clock.zig").now() - @as(i64, @intCast(idle_days)) * 86_400,
    };
}

pub fn items(arena: std.mem.Allocator) ![]Item {
    var out: std.ArrayList(Item) = .empty;
    try out.append(arena, try row(arena, "pkg-npm", .packages, "npm cache", "Package tarballs and their metadata.", 33_600_000, .safe, .{ .empty_directories = try paths(arena, "pkg-npm") }, 2));
    try out.append(arena, try row(arena, "pkg-cargo", .packages, "Cargo registry", "Crate sources and downloaded archives.", 1_526 * MB, .safe, .{ .empty_directories = try paths(arena, "pkg-cargo") }, 1));
    try out.append(arena, try row(arena, "tool-hidden-.local", .tools, "Hidden folder .local", "Not one this app recognises. Usually a tool's data or cache; check what made it before deleting.", 1_600 * MB, .review, .{ .remove_paths = try paths(arena, "tool-hidden-.local") }, 0));
    try out.append(arena, try row(arena, "tool-.codex", .tools, "Codex CLI data", "Sessions and caches.", 1_300 * MB, .review, .{ .remove_paths = try paths(arena, "tool-.codex") }, 3));
    try out.append(arena, try row(arena, "tool-.rustup/toolchains", .tools, "Rust toolchains", "`rustup toolchain install` brings one back.", 622_100_000, .review, .{ .remove_paths = try paths(arena, "tool-.rustup/toolchains") }, 40));
    try out.append(arena, try row(arena, "tool-cache-hyperframes", .tools, "Cache: hyperframes", "An entry in ~/.cache. Tools rebuild their caches on demand.", 202 * MB, .safe, .{ .remove_paths = try paths(arena, "tool-cache-hyperframes") }, 90));
    try out.append(arena, try row(arena, "xcode-DerivedData", .xcode, "DerivedData", "Build products and indexes. Xcode rebuilds them on the next build.", 4_200 * MB, .safe, .{ .empty_directories = try paths(arena, "xcode-DerivedData") }, 20));
    try out.append(arena, try row(arena, "log-unified", .logs, "Unified log store", "The persisted system log. Cleared with `log erase --all`.", 924_600_000, .safe, .{ .privileged = "log erase --all" }, 0));
    try out.append(arena, try row(arena, "pkg-homebrew-/opt/homebrew", .packages, "Homebrew installation", "/opt/homebrew: every formula and cask installed with brew.", 3_100 * MB, .manual, .{ .manual = "brew leaves\nbrew autoremove" }, 5));
    try out.append(arena, try row(arena, "project-demo/node_modules", .projects, "demo/node_modules", "~/devv/demo. Recreated by npm install.", 607 * MB, .review, .{ .remove_paths = try paths(arena, "project-demo/node_modules") }, 120));
    return out.items;
}
