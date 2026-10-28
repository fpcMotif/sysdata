//! Device backups, shared folders, Android, per-app data and project build
//! folders.
const std = @import("std");
const scan_mod = @import("../scan.zig");
const walker_mod = @import("../walker.zig");
const proc = @import("../proc.zig");
const item_mod = @import("../item.zig");
const mac = @import("../mac.zig");

const Scan = scan_mod.Scan;
const Item = item_mod.Item;
const MB = scan_mod.MB;

pub fn backups(s: *Scan) scan_mod.Error!std.ArrayList(Item) {
    const arena = s.env.arena;
    var out: std.ArrayList(Item) = .empty;
    const root = s.env.at("Library/Application Support/MobileSync/Backup");
    const subs = walker_mod.subdirectories(root, arena) catch return out;
    for (subs) |backup| {
        var values: [3]?mac.PlistValue = .{ null, null, null };
        const plist = try std.fmt.allocPrint(arena, "{s}/Info.plist", .{backup});
        mac.plistValues(s.gpa, plist, &.{ "Device Name", "Product Version", "Last Backup Date" }, &values);
        const device = arenaText(s, values[0]) orelse scan_mod.nameOf(backup);
        const version = arenaText(s, values[1]) orelse "unknown iOS";
        const backed_up: []const u8 = blk: {
            const value = values[2] orelse break :blk "an unknown date";
            switch (value) {
                .date => |secs| {
                    var buf: [16]u8 = undefined;
                    break :blk try arena.dupe(u8, mac.date(&buf, secs));
                },
                else => break :blk "an unknown date",
            }
        };
        const dirs = try arena.alloc([]const u8, 1);
        dirs[0] = backup;
        if (scan_mod.dirItem(
            s,
            try std.fmt.allocPrint(arena, "backup-{s}", .{scan_mod.nameOf(backup)}),
            .backups,
            device,
            try std.fmt.allocPrint(arena, "{s}, last backed up {s}. The only local copy of this device unless iCloud has one too.", .{ version, backed_up }),
            backup,
            .review,
            .{ .remove_paths = dirs },
            1,
        )) |found| try out.append(arena, found);
    }
    scan_mod.bySize(out.items);
    return out;
}

/// Plist text is copied to the scan's long-lived allocator; items keep
/// arena copies only.
fn arenaText(s: *Scan, value: ?mac.PlistValue) ?[]const u8 {
    const v = value orelse return null;
    switch (v) {
        .text => |t| {
            defer s.gpa.free(@constCast(t));
            return s.env.arena.dupe(u8, t) catch null;
        },
        else => return null,
    }
}

pub fn shared(s: *Scan) scan_mod.Error!std.ArrayList(Item) {
    const arena = s.env.arena;
    var out: std.ArrayList(Item) = .empty;
    if (!s.env.system) return out;
    var candidates: std.ArrayList([]const u8) = .empty;
    if (walker_mod.subdirectories("/Users/Shared", arena)) |entries| {
        for (entries) |entry| {
            // Apps such as BlueStacks keep whole disks under
            // Shared/Library/Application Support.
            if (std.mem.eql(u8, scan_mod.nameOf(entry), "Library")) {
                const app_support = try std.fmt.allocPrint(arena, "{s}/Application Support", .{entry});
                if (walker_mod.exists(app_support)) {
                    if (walker_mod.subdirectories(app_support, arena)) |inner| {
                        for (inner) |folder| try candidates.append(arena, folder);
                    } else |_| {}
                    continue;
                }
            }
            try candidates.append(arena, entry);
        }
    } else |_| {}
    for (candidates.items) |candidate| {
        const dirs = try arena.alloc([]const u8, 1);
        dirs[0] = candidate;
        if (scan_mod.dirItem(
            s,
            try std.fmt.allocPrint(arena, "shared-{s}", .{candidate}),
            .shared,
            scan_mod.nameOf(candidate),
            "In /Users/Shared, which Storage settings counts as Other Users & Shared. Owned by the app that made it.",
            candidate,
            .review,
            .{ .remove_paths = dirs },
            20 * MB,
        )) |found| try out.append(arena, found);
    }

    const me = scan_mod.nameOf(s.env.home);
    if (walker_mod.subdirectories("/Users", arena)) |accounts| {
        for (accounts) |account| {
            const name = scan_mod.nameOf(account);
            if (std.mem.eql(u8, name, me) or std.mem.eql(u8, name, "Shared")) continue;
            const bytes = s.walk.measure(account).bytes;
            try out.append(arena, .{
                .id = try std.fmt.allocPrint(arena, "shared-user-{s}", .{name}),
                .category = .shared,
                .name = try std.fmt.allocPrint(arena, "Account: {s}", .{name}),
                .detail = if (bytes > 0) "Another user's home folder." else "Another user's home folder, not readable from this account.",
                .size = if (bytes > 0) bytes else null,
                .safety = .manual,
                .action = .{ .manual = "System Settings > Users & Groups > select the account > remove." },
                .reveal = account,
            });
        }
    } else |_| {}
    scan_mod.bySize(out.items);
    return out;
}

const Job = struct {
    id: []const u8,
    name: []const u8,
    detail: []const u8,
    path: []const u8,
    safety: item_mod.Safety,
    action: item_mod.Action,
    min: u64,
};

pub fn android(s: *Scan) scan_mod.Error!std.ArrayList(Item) {
    const arena = s.env.arena;
    var out: std.ArrayList(Item) = .empty;
    var jobs: std.ArrayList(Job) = .empty;

    const avd_root = s.env.at(".android/avd");
    if (walker_mod.subdirectories(avd_root, arena)) |avds| {
        for (avds) |avd| {
            if (!scan_mod.extensionIs(avd, "avd")) continue;
            const ini = try std.fmt.allocPrint(arena, "{s}/{s}.ini", .{ avd_root, scan_mod.stemOf(avd) });
            const paths = try arena.dupe([]const u8, &.{ avd, ini });
            try jobs.append(arena, .{
                .id = try std.fmt.allocPrint(arena, "android-avd-{s}", .{scan_mod.nameOf(avd)}),
                .name = try std.fmt.allocPrint(arena, "Emulator: {s}", .{scan_mod.stemOf(avd)}),
                .detail = "Android Virtual Device disk. Everything installed on this emulator is lost.",
                .path = avd,
                .safety = .review,
                .action = .{ .remove_paths = paths },
                .min = 1,
            });
        }
    } else |_| {}

    const sdk: []const u8 = if (@import("../walker.zig").env("ANDROID_HOME")) |value|
        try arena.dupe(u8, value)
    else
        s.env.at("Library/Android/sdk");
    if (walker_mod.subdirectories(try std.fmt.allocPrint(arena, "{s}/system-images", .{sdk}), arena)) |images| {
        for (images) |image| {
            const dirs = try arena.alloc([]const u8, 1);
            dirs[0] = image;
            try jobs.append(arena, .{
                .id = try std.fmt.allocPrint(arena, "android-image-{s}", .{scan_mod.nameOf(image)}),
                .name = try std.fmt.allocPrint(arena, "System image {s}", .{scan_mod.nameOf(image)}),
                .detail = "Emulator OS image. Emulators built on it stop booting; SDK Manager reinstalls it.",
                .path = image,
                .safety = .review,
                .action = .{ .remove_paths = dirs },
                .min = 1,
            });
        }
    } else |_| {}
    const components = [_]struct { folder: []const u8, label: []const u8, min: u64 }{
        .{ .folder = "platforms", .label = "Platform", .min = 20 * MB },
        .{ .folder = "build-tools", .label = "Build tools", .min = 20 * MB },
        .{ .folder = "ndk", .label = "NDK", .min = 20 * MB },
        .{ .folder = "cmake", .label = "CMake", .min = 20 * MB },
        .{ .folder = "sources", .label = "Sources", .min = 20 * MB },
        .{ .folder = "emulator", .label = "SDK emulator", .min = 20 * MB },
        .{ .folder = "cmdline-tools", .label = "SDK cmdline-tools", .min = 20 * MB },
        .{ .folder = "platform-tools", .label = "SDK platform-tools", .min = 20 * MB },
        .{ .folder = "extras", .label = "SDK extras", .min = 20 * MB },
        .{ .folder = "skins", .label = "SDK skins", .min = 20 * MB },
        .{ .folder = "licenses", .label = "SDK licenses", .min = 20 * MB },
    };
    for (components) |component| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ sdk, component.folder });
        const dirs = try arena.alloc([]const u8, 1);
        dirs[0] = path;
        try jobs.append(arena, .{
            .id = try std.fmt.allocPrint(arena, "android-{s}", .{component.folder}),
            .name = try std.fmt.allocPrint(arena, "{s}", .{component.label}),
            .detail = "Android SDK component. SDK Manager reinstalls it.",
            .path = path,
            .safety = .review,
            .action = .{ .remove_paths = dirs },
            .min = component.min,
        });
    }
    const google = s.env.at("Library/Caches/Google");
    if (walker_mod.subdirectories(google, arena)) |caches| {
        for (caches) |cache| {
            const name = scan_mod.nameOf(cache);
            if (!std.mem.startsWith(u8, name, "AndroidStudio")) continue;
            const dirs = try arena.alloc([]const u8, 1);
            dirs[0] = cache;
            try jobs.append(arena, .{
                .id = try std.fmt.allocPrint(arena, "android-studio-cache-{s}", .{name}),
                .name = try std.fmt.allocPrint(arena, "{s} caches", .{name}),
                .detail = "IDE indexes. Rebuilt at the next launch.",
                .path = cache,
                .safety = .safe,
                .action = .{ .empty_directories = dirs },
                .min = 10 * MB,
            });
        }
    } else |_| {}

    for (jobs.items) |job| {
        if (scan_mod.dirItem(s, job.id, .android, job.name, job.detail, job.path, job.safety, job.action, job.min)) |found| {
            try out.append(arena, found);
        }
    }
    scan_mod.bySize(out.items);
    return out;
}

const app_threshold: u64 = 200 * MB;
const cache_threshold: u64 = 100 * MB;

const apple_detail = "Apple app data, partly synced with iCloud. This app does not delete it.";
const apple_action = "This is Apple's own app data, and part of it is the local copy of what syncs with iCloud. Clear it from the app that owns it, or see System Settings > General > Storage.";

pub fn isAppleOwned(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "com.apple.") or std.mem.startsWith(u8, name, "group.com.apple.");
}

pub fn appData(s: *Scan) scan_mod.Error!std.ArrayList(Item) {
    const arena = s.env.arena;
    var out: std.ArrayList(Item) = .empty;

    const claude_vm = s.env.at("Library/Application Support/Claude/vm_bundles");
    const dirs = try arena.alloc([]const u8, 1);
    dirs[0] = claude_vm;
    if (scan_mod.dirItem(
        s,
        "app-claude-vm",
        .apps,
        "Claude local VM bundles",
        "Virtual machine images for Claude's local sandbox. Downloaded again when the feature runs.",
        claude_vm,
        .review,
        .{ .remove_paths = dirs },
        app_threshold,
    )) |found| try out.append(arena, found);
    const chrome_model = s.env.at("Library/Application Support/Google/Chrome/OptGuideOnDeviceModel");
    const chrome_dirs = try arena.alloc([]const u8, 1);
    chrome_dirs[0] = chrome_model;
    if (scan_mod.dirItem(
        s,
        "app-chrome-model",
        .apps,
        "Chrome on-device AI model",
        "Gemini Nano. Disable chrome://flags/#optimization-guide-on-device-model first, or Chrome downloads it again.",
        chrome_model,
        .review,
        .{ .remove_paths = chrome_dirs },
        app_threshold,
    )) |found| try out.append(arena, found);

    const covered_support = [_][]const u8{
        "MobileSync", "Claude", "Google", "Slack", "discord", "zoom.us", "Spotify", "Adobe", "Steam", "Epic",
    };
    try scanChildren(s, &out, s.env.at("Library/Application Support"), "app-support", "App data", "Deleting it resets that app.", .review, app_threshold, &covered_support, false);
    // Each container is its own permission prompt until Full Disk Access
    // exists.
    if (s.env.full_disk_access) {
        const covered_containers = [_][]const u8{
            "com.microsoft.teams2", "com.apple.Safari", "com.apple.photolibraryd", "com.utmapp.UTM", "com.apple.mail", "com.docker.docker",
        };
        try scanChildren(s, &out, s.env.at("Library/Containers"), "app-container", "Sandboxed app data", "Deleting it resets that app.", .review, app_threshold, &covered_containers, true);
        try scanChildren(s, &out, s.env.at("Library/Group Containers"), "app-group", "App group data", "Shared by an app and its extensions. Deleting it resets them.", .review, app_threshold, &.{}, true);
    }
    const covered_caches = [_][]const u8{
        "Homebrew",         "Yarn",           "pip",
        "CocoaPods",        "org.swift.swiftpm", "go-build",
        "Cypress",          "ms-playwright",  "com.apple.dt.Xcode",
        "Google",           "Adobe",          "com.apple.QuickLook.thumbnailcache",
    };
    try scanChildren(s, &out, s.env.at("Library/Caches"), "app-cache", "Cache", "The app rebuilds it.", .safe, cache_threshold, &covered_caches, false);
    // Google nests Chrome and Android Studio caches one level down; Android
    // owns the latter.
    var android_studio: std.ArrayList([]const u8) = .empty;
    if (walker_mod.subdirectories(s.env.at("Library/Caches/Google"), arena)) |entries| {
        for (entries) |entry| {
            const name = scan_mod.nameOf(entry);
            if (std.mem.startsWith(u8, name, "AndroidStudio")) try android_studio.append(arena, name);
        }
    } else |_| {}
    try scanChildren(s, &out, s.env.at("Library/Caches/Google"), "app-cache-google", "Cache", "The app rebuilds it.", .safe, cache_threshold, android_studio.items, false);

    scan_mod.bySize(out.items);
    return out;
}

fn scanChildren(
    s: *Scan,
    out: *std.ArrayList(Item),
    root: []const u8,
    prefix: []const u8,
    label: []const u8,
    detail: []const u8,
    safety: item_mod.Safety,
    threshold: u64,
    skipping: []const []const u8,
    protects_apple_data: bool,
) scan_mod.Error!void {
    const arena = s.env.arena;
    if (walker_mod.subdirectories(root, arena)) |entries| {
        for (entries) |entry| {
            const name = scan_mod.nameOf(entry);
            var skip = false;
            for (skipping) |candidate| {
                if (std.mem.eql(u8, candidate, name)) {
                    skip = true;
                    break;
                }
            }
            if (skip) continue;
            const apple = protects_apple_data and isAppleOwned(name);
            const dirs = try arena.alloc([]const u8, 1);
            dirs[0] = entry;
            if (scan_mod.dirItem(
                s,
                try std.fmt.allocPrint(arena, "{s}-{s}", .{ prefix, name }),
                .apps,
                try std.fmt.allocPrint(arena, "{s}: {s}", .{ label, name }),
                if (apple) apple_detail else detail,
                entry,
                if (apple) .manual else safety,
                if (apple) item_mod.Action{ .manual = apple_action } else item_mod.Action{ .remove_paths = dirs },
                threshold,
            )) |found| try out.append(arena, found);
        }
    } else |_| {}
}

/// Build output folders and what recreates each. A folder named `target` or
/// `.venv` counts only beside the manifest that proves what made it.
const Target = struct { name: []const u8, tool: []const u8, manifest: ?[]const u8 };
pub const targets = [_]Target{
    .{ .name = "node_modules", .tool = "npm install", .manifest = null },
    .{ .name = ".build", .tool = "swift build", .manifest = null },
    .{ .name = "Pods", .tool = "pod install", .manifest = null },
    .{ .name = "DerivedData", .tool = "the next build", .manifest = null },
    .{ .name = ".next", .tool = "next build", .manifest = null },
    .{ .name = ".nuxt", .tool = "nuxt build", .manifest = null },
    .{ .name = ".svelte-kit", .tool = "vite build", .manifest = null },
    .{ .name = ".astro", .tool = "astro build", .manifest = null },
    .{ .name = ".angular", .tool = "the next build", .manifest = null },
    .{ .name = ".turbo", .tool = "the next build", .manifest = null },
    .{ .name = ".parcel-cache", .tool = "the next build", .manifest = null },
    .{ .name = ".expo", .tool = "the next build", .manifest = null },
    .{ .name = "target", .tool = "cargo build", .manifest = "Cargo.toml" },
    .{ .name = ".venv", .tool = "uv sync", .manifest = "pyproject.toml" },
    .{ .name = ".gradle", .tool = "the next Gradle build", .manifest = "settings.gradle" },
};

/// Code folders outside Documents. Their build folders are listed one by
/// one, and the catch-all never offers the folders themselves: they hold
/// source.
pub const project_roots_outside_documents = [_][]const u8{
    "Developer", "Projects", "Projeler", "devv", "dev", "src", "code", "repos",
};
const project_roots = [_][]const u8{
    "Desktop", "Documents",
} ++ project_roots_outside_documents;
const project_depth: u32 = 4;
const project_threshold: u64 = 30 * MB;

const Found = struct { folder: []const u8, tool: []const u8 };

pub fn projects(s: *Scan) scan_mod.Error!std.ArrayList(Item) {
    const arena = s.env.arena;
    var out: std.ArrayList(Item) = .empty;
    var found: std.ArrayList(Found) = .empty;
    for (project_roots) |relative| {
        const root = s.env.at(relative);
        if (s.env.isProtected(root)) continue;
        if (!walker_mod.isDir(root) or walker_mod.isSymlink(root)) continue;
        try collect(s, root, 0, &found);
    }
    for (found.items) |entry| {
        const project = std.fs.path.dirname(entry.folder) orelse continue;
        var item = scan_mod.dirItem(
            s,
            try std.fmt.allocPrint(arena, "project-{s}", .{entry.folder}),
            .projects,
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ scan_mod.nameOf(project), scan_mod.nameOf(entry.folder) }),
            try std.fmt.allocPrint(arena, "{s}. Recreated by {s}.", .{ scan_mod.abbreviate(arena, project, s.env.home), entry.tool }),
            entry.folder,
            .review,
            blk: {
                const dirs = try arena.alloc([]const u8, 1);
                dirs[0] = entry.folder;
                break :blk item_mod.Action{ .remove_paths = dirs };
            },
            project_threshold,
        ) orelse continue;
        // Dated by the project's own files: node_modules is as old as the
        // last install, which says nothing about the code beside it.
        item.modified = lastActivity(s, project) orelse item.modified;
        try out.append(arena, item);
    }
    scan_mod.bySize(out.items);
    return out;
}

fn collect(s: *Scan, dir: []const u8, depth: u32, found: *std.ArrayList(Found)) scan_mod.Error!void {
    if (depth > project_depth) return;
    const arena = s.env.arena;
    if (walker_mod.subdirectories(dir, arena)) |children| {
        for (children) |child| {
            const name = scan_mod.nameOf(child);
            var tool: ?[]const u8 = null;
            for (targets) |target| {
                if (!std.mem.eql(u8, target.name, name)) continue;
                if (target.manifest) |manifest| {
                    const manifest_path = std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, manifest }) catch continue;
                    if (!walker_mod.exists(manifest_path)) continue;
                }
                tool = target.tool;
                break;
            }
            if (tool) |t| {
                try found.append(arena, .{ .folder = child, .tool = t });
                continue;
            }
            if (!std.mem.startsWith(u8, name, ".") and !std.mem.eql(u8, name, "Library")) {
                try collect(s, child, depth + 1, found);
            }
        }
    } else |_| {}
}

/// Newest file a person changed in a project: build folders and git's
/// object store are left out, git's index is counted. Bounded so a huge
/// repository costs no more than a small one.
fn lastActivity(s: *Scan, project: []const u8) ?i64 {
    const arena = s.env.arena;
    var newest: ?i64 = null;
    const index_path = std.fmt.allocPrint(arena, "{s}/.git/index", .{project}) catch return null;
    if (walker_mod.lstat(index_path)) |info| newest = info.mtime.sec;
    var queue: std.ArrayList([]const u8) = .empty;
    queue.append(arena, project) catch return newest;
    var seen: usize = 0;
    while (queue.items.len > 0) {
        const dir = queue.items[queue.items.len - 1];
        queue.items.len -= 1;
        var children: std.ArrayList(walker_mod.Child) = .empty;
        walker_mod.children(dir, arena, &children) catch continue;
        for (children.items) |child| {
            seen += 1;
            if (seen > 20_000) return newest;
            const name = scan_mod.nameOf(child.path);
            if (std.mem.eql(u8, name, ".git")) continue;
            var is_target = false;
            for (targets) |target| {
                if (std.mem.eql(u8, target.name, name)) {
                    is_target = true;
                    break;
                }
            }
            if (is_target) continue;
            switch (child.kind) {
                .dir => queue.append(arena, child.path) catch {},
                .file => newest = if (newest) |n| @max(n, child.modified) else child.modified,
                .other => {},
            }
        }
    }
    return newest;
}
