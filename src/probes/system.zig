//! Logs, temporary files, Docker, the Trash and macOS's own locations.
const std = @import("std");
const scan_mod = @import("../scan.zig");
const walker_mod = @import("../walker.zig");
const proc = @import("../proc.zig");
const item_mod = @import("../item.zig");

const Scan = scan_mod.Scan;
const Item = item_mod.Item;
const MB = scan_mod.MB;

pub fn logs(s: *Scan) scan_mod.Error!std.ArrayList(Item) {
    const arena = s.env.arena;
    var out: std.ArrayList(Item) = .empty;
    if (s.env.system) {
        // The unified log store must be cleared with `log erase`; deleting
        // its files by hand corrupts it.
        const diagnostics = "/private/var/db/diagnostics";
        const uuidtext = "/private/var/db/uuidtext";
        const store = s.walk.measure(diagnostics).bytes + s.walk.measure(uuidtext).bytes;
        if (store > 0) {
            try out.append(arena, .{
                .id = "log-unified",
                .category = .logs,
                .name = "Unified log store",
                .detail = "The persisted system log in /private/var/db/diagnostics. Cleared with `log erase --all`.",
                .size = store,
                .safety = .safe,
                .action = .{ .privileged = "log erase --all" },
                .reveal = diagnostics,
                .also_claims = try arena.dupe([]const u8, &.{uuidtext}),
            });
        }
        for ([_]struct { id: []const u8, name: []const u8, detail: []const u8, path: []const u8, script: []const u8 }{
            .{ .id = "log-system-reports", .name = "System crash reports", .detail = "Crash and hang reports for system processes.", .path = "/Library/Logs/DiagnosticReports", .script = "rm -rf /Library/Logs/DiagnosticReports/*" },
            .{ .id = "log-asl", .name = "Legacy ASL logs", .detail = "Old-style system logs in /private/var/log/asl.", .path = "/private/var/log/asl", .script = "rm -f /private/var/log/asl/*.asl" },
        }) |entry| {
            const measured = s.walk.measure(entry.path);
            if (measured.bytes == 0) continue;
            try out.append(arena, .{
                .id = entry.id,
                .category = .logs,
                .name = entry.name,
                .detail = entry.detail,
                .size = measured.bytes,
                .safety = .safe,
                .action = .{ .privileged = entry.script },
                .reveal = entry.path,
                .modified = measured.newest,
            });
        }
    }
    const user_logs = s.env.at("Library/Logs");
    const dirs = try arena.alloc([]const u8, 1);
    dirs[0] = user_logs;
    if (scan_mod.dirItem(
        s,
        "log-user",
        .logs,
        "User app logs",
        "~/Library/Logs, including your own crash reports and simulator logs.",
        user_logs,
        .safe,
        .{ .empty_directories = dirs },
        1,
    )) |found| try out.append(arena, found);
    return out;
}

/// macOS sweeps the per-user cache and temp folders only on reboot or under
/// disk pressure. Files touched in the last few days are kept.
pub fn temp(s: *Scan) scan_mod.Error!std.ArrayList(Item) {
    var out: std.ArrayList(Item) = .empty;
    if (!s.env.system) return out;
    const arena = s.env.arena;
    const keep_days: u32 = 3;
    const cutoff = @import("../clock.zig").now() - @as(i64, keep_days) * 86_400;
    const folders = [_]struct { id: []const u8, name: []const u8, key: c_int }{
        .{ .id = "temp-cache", .name = "User cache folder", .key = 65_538 },
        .{ .id = "temp-tmp", .name = "User temp folder", .key = 65_537 },
    };
    for (folders) |folder| {
        var buf: [walker_mod.max_path]u8 = undefined;
        const raw = walker_mod.confstrPath(folder.key, &buf) orelse continue;
        const dir = @import("../sys.zig").realpath(arena, raw) catch (arena.dupe(u8, raw) catch continue);
        const measured = s.walk.measureOlderThan(dir, cutoff);
        if (measured.bytes < MB) continue;
        try out.append(arena, .{
            .id = folder.id,
            .category = .temp,
            .name = folder.name,
            .detail = try std.fmt.allocPrint(arena, "{s}. Only files older than {d} days are removed.", .{ dir, keep_days }),
            .size = measured.bytes,
            .safety = .safe,
            .action = .{ .prune_older_than = .{ .dir = dir, .days = keep_days } },
            .reveal = dir,
            .modified = measured.newest,
        });
    }
    return out;
}

pub fn docker(s: *Scan) scan_mod.Error!std.ArrayList(Item) {
    var out: std.ArrayList(Item) = .empty;
    if (!s.env.system) return out;
    const arena = s.env.arena;
    const vms = s.env.at("Library/Containers/com.docker.docker/Data/vms");
    var program: ?[]const u8 = null;
    var df: ?[]const u8 = null;
    if (proc.which(s.gpa, "docker", s.path_dirs)) |found| {
        defer s.gpa.free(found);
        if (proc.probe(s.gpa, found, &.{"info"}) != null) {
            program = try arena.dupe(u8, found);
            if (proc.probe(s.gpa, found, &.{ "system", "df", "--format", "{{json .}}" })) |text| {
                defer s.gpa.free(text);
                df = try arena.dupe(u8, text);
            }
        }
    }
    if (program == null or df == null) {
        if (s.env.isProtected(vms)) return out;
        if (scan_mod.dirItem(
            s,
            "docker-vm",
            .docker,
            "Docker disk image",
            "Docker is not running, so it cannot prune right now.",
            vms,
            .manual,
            .{ .manual = "Start Docker Desktop, then:\ndocker system prune -f\ndocker builder prune -f" },
            100 * MB,
        )) |found_item| try out.append(arena, found_item);
        return out;
    }
    const reveal: ?[]const u8 = if (walker_mod.exists(vms)) vms else null;
    try dockerItems(s, &out, df.?, program.?, reveal);
    return out;
}

/// One row per kind of thing Docker can let go of, each sized by what its
/// own prune command frees. Volumes, where databases live, stay separate.
fn dockerItems(s: *Scan, out: *std.ArrayList(Item), df: []const u8, program: []const u8, reveal: ?[]const u8) scan_mod.Error!void {
    const arena = s.env.arena;
    var by_type: std.StringHashMapUnmanaged(u64) = .empty;
    var lines = std.mem.splitScalar(u8, df, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const row = std.json.parseFromSliceLeaky(std.json.Value, arena, trimmed, .{}) catch continue;
        const kind = jsonString(row, "Type") orelse continue;
        const reclaimable = jsonString(row, "Reclaimable") orelse continue;
        const gop = try by_type.getOrPut(arena, kind);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += parseDockerSize(reclaimable);
    }
    const Kind = struct {
        kind: []const u8,
        id: []const u8,
        name: []const u8,
        detail: []const u8,
        safety: item_mod.Safety,
        args: []const []const u8,
    };
    const kinds = [_]Kind{
        .{ .kind = "Build Cache", .id = "docker-build-cache", .name = "Docker build cache", .detail = "Layers kept to speed up the next build. `docker builder prune -a`; the next build recreates them.", .safety = .safe, .args = &.{ "builder", "prune", "-a", "-f" } },
        .{ .kind = "Images", .id = "docker-images", .name = "Unused Docker images", .detail = "Images no container uses. `docker image prune -a`; pulled again when something runs them.", .safety = .review, .args = &.{ "image", "prune", "-a", "-f" } },
        .{ .kind = "Containers", .id = "docker-containers", .name = "Stopped Docker containers", .detail = "Stopped containers and anything written inside them. `docker container prune`.", .safety = .review, .args = &.{ "container", "prune", "-f" } },
        .{ .kind = "Local Volumes", .id = "docker-volumes", .name = "Unused Docker volumes", .detail = "Volumes no container is attached to. Databases often keep data here. `docker volume prune -a`.", .safety = .review, .args = &.{ "volume", "prune", "-a", "-f" } },
    };
    for (kinds) |k| {
        const bytes = by_type.get(k.kind) orelse continue;
        if (bytes == 0) continue;
        try out.append(arena, .{
            .id = k.id,
            .category = .docker,
            .name = k.name,
            .detail = k.detail,
            .size = bytes,
            .safety = k.safety,
            .action = .{ .command = .{ .program = program, .args = try arena.dupe([]const u8, k.args) } },
            .reveal = reveal,
        });
    }
    scan_mod.bySize(out.items);
}

fn jsonString(v: std.json.Value, key: []const u8) ?[]const u8 {
    return switch (v) {
        .object => |o| switch (o.get(key) orelse return null) {
            .string => |text| text,
            else => null,
        },
        else => null,
    };
}

/// "1.211GB (45%)" → bytes.
pub fn parseDockerSize(text: []const u8) u64 {
    const t = std.mem.trim(u8, text, " \t");
    var end: usize = 0;
    while (end < t.len and (std.ascii.isDigit(t[end]) or t[end] == '.')) end += 1;
    const value = std.fmt.parseFloat(f64, t[0..end]) catch return 0;
    var unit_end = end;
    while (unit_end < t.len and std.ascii.isAlphabetic(t[unit_end])) unit_end += 1;
    const unit = t[end..unit_end];
    const multiplier: f64 = if (std.ascii.eqlIgnoreCase(unit, "KB"))
        1e3
    else if (std.ascii.eqlIgnoreCase(unit, "MB"))
        1e6
    else if (std.ascii.eqlIgnoreCase(unit, "GB"))
        1e9
    else if (std.ascii.eqlIgnoreCase(unit, "TB"))
        1e12
    else
        1;
    const bytes = value * multiplier;
    if (bytes <= 0) return 0;
    return @intFromFloat(bytes);
}

pub fn trash(s: *Scan) scan_mod.Error!std.ArrayList(Item) {
    const arena = s.env.arena;
    var out: std.ArrayList(Item) = .empty;
    const path = s.env.at(".Trash");
    const dirs = try arena.alloc([]const u8, 1);
    dirs[0] = path;
    if (scan_mod.dirItem(
        s,
        "trash",
        .trash,
        "Trash",
        "Items waiting in the Trash. Emptying it is permanent.",
        path,
        .safe,
        .{ .empty_directories = dirs },
        1,
    )) |found| try out.append(arena, found);
    return out;
}

pub fn misc(s: *Scan) scan_mod.Error!std.ArrayList(Item) {
    const arena = s.env.arena;
    var out: std.ArrayList(Item) = .empty;
    const itunes = s.env.at("Library/iTunes");
    if (walker_mod.subdirectories(itunes, arena) catch null) |folders| {
        for (folders) |folder| {
            const name = scan_mod.nameOf(folder);
            if (!std.mem.endsWith(u8, name, "Software Updates")) continue;
            const dirs = try arena.alloc([]const u8, 1);
            dirs[0] = folder;
            if (scan_mod.dirItem(
                s,
                try std.fmt.allocPrint(arena, "sys-ipsw-{s}", .{name}),
                .system,
                name,
                "Downloaded device firmware (.ipsw).",
                folder,
                .safe,
                .{ .empty_directories = dirs },
                1,
            )) |found| try out.append(arena, found);
        }
    }
    const mail = s.env.at("Library/Containers/com.apple.mail/Data/Library/Mail Downloads");
    if (!s.env.isProtected(mail)) {
        const dirs = try arena.alloc([]const u8, 1);
        dirs[0] = mail;
        if (scan_mod.dirItem(
            s,
            "sys-mail-downloads",
            .system,
            "Mail attachment downloads",
            "Attachments opened from Mail. The originals stay in the messages.",
            mail,
            .safe,
            .{ .empty_directories = dirs },
            MB,
        )) |found| try out.append(arena, found);
    }
    const icloud = s.env.at("Library/Mobile Documents");
    if (scan_mod.dirItem(
        s,
        "sys-icloud",
        .system,
        "iCloud Drive local copies",
        "Files kept on this Mac for offline use.",
        icloud,
        .manual,
        .{ .manual = "System Settings > Apple Account > iCloud > Drive > turn on Optimize Mac Storage,\nor right-click a folder in Finder > Remove Download." },
        500 * MB,
    )) |found| try out.append(arena, found);
    if (scan_mod.dirItem(
        s,
        "sys-daemon-containers",
        .system,
        "macOS service data",
        "Containers of macOS's own background services. This app does not delete them.",
        s.env.at("Library/Daemon Containers"),
        .manual,
        .{ .manual = "macOS manages these. If one keeps growing, restart the Mac or update macOS; deleting them can break the service that owns them." },
        500 * MB,
    )) |found| try out.append(arena, found);
    if (s.env.system) try systemWide(s, &out);
    return out;
}

/// macOS's own locations, named one by one, and only entries macOS lets
/// anyone remove: data vaults and restricted entries refuse even root.
fn systemWide(s: *Scan, out: *std.ArrayList(Item)) scan_mod.Error!void {
    const arena = s.env.arena;
    var none: [0][]u8 = .{};
    const apps: [][]u8 = walker_mod.subdirectories("/Applications", arena) catch none[0..];
    for (apps) |installer| {
        const name = scan_mod.nameOf(installer);
        if (!(std.mem.startsWith(u8, name, "Install macOS") and std.mem.endsWith(u8, name, ".app"))) continue;
        const dirs = try arena.alloc([]const u8, 1);
        dirs[0] = installer;
        if (scan_mod.dirItem(
            s,
            try std.fmt.allocPrint(arena, "sys-installer-{s}", .{name}),
            .system,
            scan_mod.stemOf(installer),
            "A downloaded macOS installer. Software Update can download it again.",
            installer,
            .review,
            .{ .remove_paths = dirs },
            1,
        )) |found| try out.append(arena, found);
    }

    const caches = "/Library/Caches";
    var all: std.ArrayList(walker_mod.Child) = .empty;
    walker_mod.children(caches, arena, &all) catch {};
    var removable: std.ArrayList([]const u8) = .empty;
    var bytes: u64 = 0;
    var newest: ?i64 = null;
    for (all.items) |child| {
        if (walker_mod.isProtected(child.path)) continue;
        const measured = s.walk.measure(child.path);
        bytes += measured.bytes;
        if (measured.newest) |n| newest = if (newest) |old| @max(old, n) else n;
        try removable.append(arena, child.path);
    }
    if (removable.items.len > 0 and bytes >= 10 * MB) {
        var script: std.ArrayList(u8) = .empty;
        try script.appendSlice(arena, "rm -rf");
        for (removable.items) |p| {
            try script.append(arena, ' ');
            try script.appendSlice(arena, try proc.quote(arena, p));
        }
        try out.append(arena, .{
            .id = "sys-library-caches",
            .category = .system,
            .name = "System-wide caches",
            .detail = "/Library/Caches. The daemons that own them rebuild them.",
            .size = bytes,
            .safety = .safe,
            .action = .{ .privileged = script.items },
            .reveal = caches,
            .modified = newest,
        });
    }

    var support_none: [0][]u8 = .{};
    const support: [][]u8 = walker_mod.subdirectories("/Library/Application Support", arena) catch support_none[0..];
    for (support) |entry| {
        const name = scan_mod.nameOf(entry);
        const dirs = try arena.alloc([]const u8, 1);
        dirs[0] = entry;
        if (scan_mod.dirItem(
            s,
            try std.fmt.allocPrint(arena, "sys-app-support-{s}", .{name}),
            .system,
            try std.fmt.allocPrint(arena, "System app data: {s}", .{name}),
            "/Library/Application Support, shared by every user. Prefer the app's own uninstaller.",
            entry,
            .review,
            .{ .remove_paths = dirs },
            200 * MB,
        )) |found| try out.append(arena, found);
    }

    // Redundant only when an Xcode is installed and is the selected
    // developer directory.
    const tools = "/Library/Developer/CommandLineTools";
    var has_xcode = false;
    for (apps) |app| {
        const name = scan_mod.nameOf(app);
        if (std.mem.startsWith(u8, name, "Xcode") and std.mem.endsWith(u8, name, ".app")) {
            has_xcode = true;
            break;
        }
    }
    const active = s.developerDir();
    if (active) |dir| {
        if (std.mem.startsWith(u8, dir, tools)) has_xcode = false;
    } else {
        has_xcode = false;
    }
    const clt_redundant = has_xcode;
    if (scan_mod.dirItem(
        s,
        "sys-clt",
        .system,
        "Command Line Tools",
        if (clt_redundant)
            "Xcode is installed and already provides these tools. `xcode-select --install` brings them back."
        else
            "Compilers and SDKs for the terminal. Needed while Xcode is not installed.",
        tools,
        if (clt_redundant) .review else .manual,
        if (clt_redundant)
            item_mod.Action{ .privileged = "rm -rf /Library/Developer/CommandLineTools" }
        else
            item_mod.Action{ .manual = "Keep them, or remove with:\nsudo rm -rf /Library/Developer/CommandLineTools" },
        1,
    )) |found| try out.append(arena, found);
    if (scan_mod.dirItem(
        s,
        "sys-cryptex",
        .system,
        "macOS cryptexes",
        "Sealed system components (Safari, dyld caches) under /private/var/run. Part of macOS.",
        "/private/var/run/com.apple.security.cryptexd",
        .manual,
        .{ .manual = "Managed by macOS. It cannot be removed." },
        100 * MB,
    )) |found| try out.append(arena, found);
    try out.append(arena, .{
        .id = "sys-spotlight",
        .category = .system,
        .name = "Spotlight index",
        .detail = "/.Spotlight-V100 is readable only by root, so its size is unknown. Rebuilding drops stale entries.",
        .size = null,
        .safety = .manual,
        .action = .{ .manual = "sudo mdutil -E /" },
    });
    if (scan_mod.dirItem(
        s,
        "sys-vm",
        .system,
        "Swap and sleep image",
        "Managed by the kernel. It shrinks after a restart.",
        "/private/var/vm",
        .manual,
        .{ .manual = "Restart the Mac. To drop the sleep image for good:\nsudo pmset -a hibernatemode 0\nsudo rm /private/var/vm/sleepimage" },
        100 * MB,
    )) |found| try out.append(arena, found);
}

test "docker sizes parse" {
    try std.testing.expectEqual(@as(u64, 1_211_000_000), parseDockerSize("1.211GB (45%)"));
    try std.testing.expectEqual(@as(u64, 512_000_000), parseDockerSize("512MB"));
    try std.testing.expectEqual(@as(u64, 0), parseDockerSize("0B (0%)"));
}
