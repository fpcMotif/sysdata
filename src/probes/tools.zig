//! Developer tool folders hidden in the home folder: the ones with names
//! this app knows, then any other hidden or `~/.cache` folder over 100 MB.
const std = @import("std");
const scan_mod = @import("../scan.zig");
const walker_mod = @import("../walker.zig");
const proc = @import("../proc.zig");
const item_mod = @import("../item.zig");

const Scan = scan_mod.Scan;
const Item = item_mod.Item;
const MB = scan_mod.MB;

const Tool = struct { program: []const u8, args: []const []const u8 };

const Known = struct {
    path: []const u8,
    name: []const u8,
    detail: []const u8,
    safety: item_mod.Safety,
    tool: ?Tool,
};

const known = [_]Known{
    .{ .path = ".ollama/models", .name = "Ollama models", .detail = "Downloaded model weights. `ollama pull` fetches them again.", .safety = .review, .tool = null },
    .{ .path = ".cache/huggingface", .name = "Hugging Face cache", .detail = "Downloaded models and datasets.", .safety = .review, .tool = null },
    .{ .path = ".cache/torch", .name = "PyTorch cache", .detail = "Downloaded model weights.", .safety = .review, .tool = null },
    .{ .path = ".lmstudio", .name = "LM Studio models", .detail = "Downloaded model weights.", .safety = .review, .tool = null },
    .{ .path = ".nvm/versions", .name = "nvm Node versions", .detail = "Every Node.js installed with nvm. `nvm install` brings one back.", .safety = .review, .tool = null },
    .{ .path = ".rustup/toolchains", .name = "Rust toolchains", .detail = "`rustup toolchain install` brings one back.", .safety = .review, .tool = null },
    .{ .path = ".pyenv/versions", .name = "pyenv Python versions", .detail = "`pyenv install` brings one back.", .safety = .review, .tool = null },
    .{ .path = ".rbenv/versions", .name = "rbenv Ruby versions", .detail = "`rbenv install` brings one back.", .safety = .review, .tool = null },
    .{ .path = ".sdkman/candidates", .name = "SDKMAN toolchains", .detail = "`sdk install` brings one back.", .safety = .review, .tool = null },
    .{ .path = ".local/share/mise/installs", .name = "mise tool versions", .detail = "Every tool version mise installed. `mise install` fetches them again.", .safety = .review, .tool = null },
    .{ .path = ".local/share/uv/python", .name = "uv Python versions", .detail = "Interpreters uv downloaded. `uv python install` fetches them again.", .safety = .review, .tool = null },
    .{ .path = ".local/share/uv/tools", .name = "uv tools", .detail = "Tools installed with `uv tool install`.", .safety = .review, .tool = null },
    .{ .path = "miniconda3", .name = "Miniconda", .detail = "Conda environments and packages.", .safety = .review, .tool = null },
    .{ .path = "anaconda3", .name = "Anaconda", .detail = "Conda environments and packages.", .safety = .review, .tool = null },
    .{ .path = ".conda/pkgs", .name = "Conda package cache", .detail = "Downloaded packages.", .safety = .safe, .tool = .{ .program = "conda", .args = &.{ "clean", "--all", "-y" } } },
    .{ .path = ".m2/repository", .name = "Maven repository", .detail = "Downloaded jars, fetched again on the next build.", .safety = .safe, .tool = null },
    .{ .path = ".ivy2", .name = "Ivy cache", .detail = "Downloaded jars for sbt.", .safety = .safe, .tool = null },
    .{ .path = ".cocoapods/repos", .name = "CocoaPods specs repos", .detail = "`pod setup` rebuilds them.", .safety = .safe, .tool = null },
    .{ .path = ".gradle/wrapper/dists", .name = "Gradle distributions", .detail = "Downloaded Gradle versions.", .safety = .safe, .tool = null },
    .{ .path = ".android/cache", .name = "Android SDK download cache", .detail = "Downloaded again on demand.", .safety = .safe, .tool = null },
    .{ .path = "go/pkg/mod", .name = "Go module cache", .detail = "Downloaded modules.", .safety = .safe, .tool = .{ .program = "go", .args = &.{ "clean", "-modcache" } } },
    .{ .path = ".cargo/git", .name = "Cargo git checkouts", .detail = "Git dependencies Cargo checked out, fetched again on the next build.", .safety = .safe, .tool = null },
    .{ .path = ".bun/install/cache", .name = "Bun cache", .detail = "Package tarballs.", .safety = .safe, .tool = null },
    .{ .path = ".npm/_npx", .name = "npx cache", .detail = "Packages npx fetched to run once. npx fetches them again.", .safety = .safe, .tool = null },
    .{ .path = ".deno", .name = "Deno cache", .detail = "Cached modules.", .safety = .safe, .tool = null },
    .{ .path = ".moon", .name = "moon toolchain", .detail = "Tools moonrepo downloaded. moon installs them again on demand.", .safety = .review, .tool = null },
    .{ .path = ".vscode/extensions", .name = "VS Code extensions", .detail = "Installed extensions. The marketplace reinstalls them.", .safety = .review, .tool = null },
    .{ .path = ".cursor/extensions", .name = "Cursor extensions", .detail = "Installed extensions.", .safety = .review, .tool = null },
    .{ .path = ".antigravity-ide/extensions", .name = "Antigravity extensions", .detail = "Installed extensions. The marketplace reinstalls them.", .safety = .review, .tool = null },
    .{ .path = ".docker", .name = "Docker CLI data", .detail = "Contexts and build history, not images.", .safety = .review, .tool = null },
    .{ .path = ".orbstack", .name = "OrbStack data", .detail = "Virtual machines and containers.", .safety = .review, .tool = null },
    .{ .path = ".lima", .name = "Lima virtual machines", .detail = "Virtual machine disks.", .safety = .review, .tool = null },
    .{ .path = ".colima", .name = "Colima virtual machine", .detail = "A virtual machine disk.", .safety = .review, .tool = null },
    .{ .path = ".claude", .name = "Claude Code data", .detail = "Session transcripts, memory, plugins and caches. Deleting it loses history.", .safety = .review, .tool = null },
    .{ .path = ".codex", .name = "Codex CLI data", .detail = "Sessions and caches.", .safety = .review, .tool = null },
    .{ .path = ".grok", .name = "Grok CLI data", .detail = "Sessions, settings and caches. Deleting it loses history.", .safety = .review, .tool = null },
    .{ .path = ".copilot", .name = "GitHub Copilot CLI data", .detail = "Sessions, settings and caches. Deleting it signs you out.", .safety = .review, .tool = null },
    .{ .path = ".kilo", .name = "Kilo Code data", .detail = "Sessions, settings and caches. Deleting it loses history.", .safety = .review, .tool = null },
    .{ .path = ".gemini", .name = "Gemini CLI data", .detail = "Settings and IDE support files.", .safety = .review, .tool = null },
    .{ .path = ".factory", .name = "Factory CLI data", .detail = "Sessions, settings and caches. Deleting it loses history.", .safety = .review, .tool = null },
};

/// Top-level dot-folders another probe already reports.
const covered_top = [_][]const u8{ ".npm", ".cargo", ".Trash", ".android", ".gradle", ".cache" };
const covered_cache = [_][]const u8{ "uv", "huggingface", "torch" };
const hidden_threshold: u64 = 100 * MB;

pub fn probe(s: *Scan) scan_mod.Error!std.ArrayList(Item) {
    var out: std.ArrayList(Item) = .empty;
    const arena = s.env.arena;
    var claimed_top: std.StringHashMapUnmanaged(void) = .empty;
    var claimed_cache: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        claimed_top.deinit(arena);
        claimed_cache.deinit(arena);
    }
    for (covered_top) |top| try claimed_top.put(arena, top, {});
    for (covered_cache) |sub| try claimed_cache.put(arena, sub, {});
    for (known) |entry| {
        var it = std.mem.splitScalar(u8, entry.path, '/');
        const top = it.next() orelse continue;
        try claimed_top.put(arena, top, {});
        if (std.mem.eql(u8, top, ".cache")) {
            if (it.next()) |sub| try claimed_cache.put(arena, sub, {});
        }
        const path = s.env.at(entry.path);
        const id = try std.fmt.allocPrint(arena, "tool-{s}", .{entry.path});
        var action: item_mod.Action = undefined;
        if (findTool(s, arena, entry.tool)) |program| {
            action = .{ .command = .{ .program = program, .args = entry.tool.?.args } };
        } else {
            const dirs = try arena.alloc([]const u8, 1);
            dirs[0] = path;
            action = .{ .remove_paths = dirs };
        }
        if (scan_mod.dirItem(s, id, .tools, entry.name, entry.detail, path, entry.safety, action, 10 * MB)) |found| {
            try out.append(arena, found);
        }
    }

    // Any other hidden folder over 100 MB: usually a tool's data or cache.
    const home_subs = walker_mod.subdirectories(s.env.home, arena) catch return bySizeReturn(out);
    defer arena.free(home_subs);
    for (home_subs) |folder| {
        const name = scan_mod.nameOf(folder);
        if (!std.mem.startsWith(u8, name, ".")) continue;
        if (claimed_top.contains(name)) continue;
        const id = try std.fmt.allocPrint(arena, "tool-hidden-{s}", .{name});
        const dirs = try arena.alloc([]const u8, 1);
        dirs[0] = folder;
        const label = try std.fmt.allocPrint(arena, "Hidden folder {s}", .{name});
        if (scan_mod.dirItem(
            s,
            id,
            .tools,
            label,
            "Not one this app recognises. Usually a tool's data or cache; check what made it before deleting.",
            folder,
            .review,
            .{ .remove_paths = dirs },
            hidden_threshold,
        )) |found| try out.append(arena, found);
    }

    // Anything else in ~/.cache.
    const cache_root = s.env.at(".cache");
    const cache_subs = walker_mod.subdirectories(cache_root, arena) catch return bySizeReturn(out);
    defer arena.free(cache_subs);
    for (cache_subs) |folder| {
        const name = scan_mod.nameOf(folder);
        if (claimed_cache.contains(name)) continue;
        const id = try std.fmt.allocPrint(arena, "tool-cache-{s}", .{name});
        const dirs = try arena.alloc([]const u8, 1);
        dirs[0] = folder;
        const label = try std.fmt.allocPrint(arena, "Cache: {s}", .{name});
        if (scan_mod.dirItem(
            s,
            id,
            .tools,
            label,
            "An entry in ~/.cache. Tools rebuild their caches on demand.",
            folder,
            .safe,
            .{ .remove_paths = dirs },
            hidden_threshold,
        )) |found| try out.append(arena, found);
    }
    scan_mod.bySize(out.items);
    return out;
}

fn bySizeReturn(out: std.ArrayList(Item)) std.ArrayList(Item) {
    scan_mod.bySize(out.items);
    return out;
}

fn findTool(s: *Scan, arena: std.mem.Allocator, tool: ?Tool) ?[]const u8 {
    const t = tool orelse return null;
    const found = proc.which(s.gpa, t.program, s.path_dirs) orelse return null;
    defer s.gpa.free(found);
    return arena.dupe(u8, found) catch null;
}
