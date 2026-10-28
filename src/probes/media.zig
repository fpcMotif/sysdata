//! Virtual machines, plus the caches professional media apps keep inside
//! their libraries and projects.
const std = @import("std");
const scan_mod = @import("../scan.zig");
const walker_mod = @import("../walker.zig");
const item_mod = @import("../item.zig");

const Scan = scan_mod.Scan;
const Item = item_mod.Item;
const MB = scan_mod.MB;

const vm_sources = [_]struct { relative: []const u8, app: []const u8 }{
    .{ .relative = "Library/Containers/com.apple.mail/Data/Library/Virtual Machines/compacted", .app = "Mail" },
    .{ .relative = "Library/Containers/com.apple.sharekit.mail.compose/Data/Library/Virtual Machines/compacted", .app = "Mail" },
    .{ .relative = "Library/Group Containers/J7Q8627H8P.developer.itunes", .app = "Apple Developer" },
    .{ .relative = "Library/Containers/com.apple.dt.Xcode", .app = "Xcode" },
    .{ .relative = "Library/Containers/com.apple.VoiceMemos", .app = "Voice Memos" },
    .{ .relative = "Library/Containers/UBF8T346G9.com.microsoft.onenotemac", .app = "OneNote" },
    .{ .relative = "Library/Containers/UBF8T346G9.ms-onenote", .app = "OneNote" },
    .{ .relative = "Library/Containers/com.apple.dt.Xcode/Library", .app = "Xcode" },
};

pub fn virtualMachines(s: *Scan) scan_mod.Error!std.ArrayList(Item) {
    const arena = s.env.arena;
    var out: std.ArrayList(Item) = .empty;
    if (!s.env.system) return out;
    for (vm_sources) |source| {
        const root = s.env.at(source.relative);
        var entries: std.ArrayList(walker_mod.Child) = .empty;
        walker_mod.children(root, arena, &entries) catch continue;
        for (entries.items) |entry| {
            const path = entry.path;
            const name = scan_mod.nameOf(path);
            const ok = std.mem.endsWith(u8, name, ".chatbundle") or
                std.mem.endsWith(u8, name, ".photoslibrary") or
                std.mem.endsWith(u8, name, ".migratedPhotosLibrary") or
                std.mem.endsWith(u8, name, ".bundle");
            if (!ok) continue;
            const dirs = try arena.alloc([]const u8, 1);
            dirs[0] = path;
            if (scan_mod.dirItem(
                s,
                try std.fmt.allocPrint(arena, "vm-{s}", .{path}),
                .vms,
                try std.fmt.allocPrint(arena, "{s} virtual machine", .{source.app}),
                try std.fmt.allocPrint(arena, "{s} keeps an APFS virtual machine, rebuilt on the fly from your data.", .{source.app}),
                path,
                .review,
                .{ .remove_paths = dirs },
                50 * MB,
            )) |found| try out.append(arena, found);
        }
    }
    scan_mod.bySize(out.items);
    return out;
}

const media_cache = [_]struct {
    suffix: []const u8,
    name: []const u8,
    detail: []const u8,
    safety: item_mod.Safety,
}{
    .{ .suffix = "Library/Application Support/ProApps/Render Files", .name = "ProApps render files", .detail = "Final Cut Pro and Motion render files.", .safety = .review },
    .{ .suffix = "Library/Application Support/Compressor/Cache", .name = "Compressor cache", .detail = "Compressor temporary media.", .safety = .safe },
    .{ .suffix = "Library/Application Support/ProApps/Event Cache", .name = "ProApps event cache", .detail = "Final Cut Pro and Motion thumbnails and metadata.", .safety = .safe },
    .{ .suffix = "Library/Caches/Final Cut Pro", .name = "Final Cut Pro caches", .detail = "Final Cut Pro temporary media.", .safety = .safe },
    .{ .suffix = "Library/Caches/Motion", .name = "Motion cache", .detail = "Motion thumbnails.", .safety = .safe },
    .{ .suffix = "Library/Caches/a52ff2ca-1c24-4b86-9c82-92d399b6b9be", .name = "Final Cut Pro browser cache", .detail = "Final Cut Pro thumbnails.", .safety = .safe },
    .{ .suffix = "Library/Caches/com.apple.motion", .name = "Motion cache", .detail = "Motion thumbnails.", .safety = .safe },
    .{ .suffix = "Library/Application Support/Motion/Managed Cache", .name = "Motion managed cache", .detail = "Motion thumbnails and rendered media.", .safety = .safe },
    .{ .suffix = "Library/Application Support/Logic/Apple Loops Index", .name = "Logic loops index", .detail = "The Apple Loops index, rebuilt after loops are reindexed.", .safety = .safe },
    .{ .suffix = "Library/Application Support/MobileSync/Backup.tmp", .name = "iPhone backup temp", .detail = "An interrupted iOS backup.", .safety = .safe },
    .{ .suffix = "Library/Application Support/Caches/Blackmagic Design/Fusion", .name = "Fusion cache", .detail = "Fusion temporary media.", .safety = .safe },
    .{ .suffix = "Library/Application Support/Blackmagic Design/Fusion/Caches", .name = "Fusion cache", .detail = "Fusion temporary media.", .safety = .safe },
    .{ .suffix = "Library/Application Support/DaVinci Resolve/support/resolve cache", .name = "DaVinci Resolve cache", .detail = "Optimised and render media.", .safety = .review },
    .{ .suffix = "Library/Application Support/DaVinci Resolve/support/Fusion/Caches", .name = "Fusion cache in Resolve", .detail = "Fusion temporary media.", .safety = .safe },
    .{ .suffix = "Library/Caches/Adobe", .name = "Adobe caches", .detail = "Premiere, After Effects, Media Encoder and Lightroom temporary media.", .safety = .safe },
    .{ .suffix = "Library/Application Support/Adobe/Camera Raw", .name = "Camera Raw cache", .detail = "Lightroom previews and Camera Raw cache.", .safety = .safe },
};

pub fn appCaches(s: *Scan) scan_mod.Error!std.ArrayList(Item) {
    const arena = s.env.arena;
    var out: std.ArrayList(Item) = .empty;
    for (media_cache) |entry| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ s.env.home, entry.suffix });
        const dirs = try arena.alloc([]const u8, 1);
        dirs[0] = path;
        if (scan_mod.dirItem(
            s,
            try std.fmt.allocPrint(arena, "media-{s}", .{entry.suffix}),
            .apps,
            entry.name,
            entry.detail,
            path,
            entry.safety,
            .{ .empty_directories = dirs },
            20 * MB,
        )) |found| try out.append(arena, found);
    }
    // A .fcpbundle is both a project and its render cache. If the render
    // cache inside it is missing, the library is what gets measured, so
    // Finder shows almost all of it: render it before deleting.
    if (s.env.full_disk_access) {
        for ([_][]const u8{ "Movies", "Documents" }) |top| {
            const root = s.env.at(top);
            var entries: std.ArrayList(walker_mod.Child) = .empty;
            walker_mod.children(root, arena, &entries) catch continue;
            for (entries.items) |entry| {
                const path = entry.path;
                const name = scan_mod.nameOf(path);
                if (!std.mem.endsWith(u8, name, ".fcpbundle")) continue;
                if (scan_mod.dirItem(
                    s,
                    try std.fmt.allocPrint(arena, "media-render-{s}", .{path}),
                    .apps,
                    "Final Cut render files",
                    "Projects with a render cache are missing from this list and the project size in Finder counts render media. Empty the render cache from inside Final Cut Pro; it has no cache folder of its own.",
                    path,
                    .review,
                    .{ .manual = "Open the library in Final Cut Pro and use File > Delete Generated Library Render Files." },
                    100 * MB,
                )) |found| try out.append(arena, found);
            }
        }
    }
    scan_mod.bySize(out.items);
    return out;
}
