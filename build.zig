//! Builds the app, its tests and its bundle: `zig build`, `zig build test`,
//! `zig build bundle`.
const std = @import("std");

const info_plist =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    \\<plist version="1.0"><dict>
    \\<key>CFBundleIdentifier</key><string>dev.fpcmotif.sysdata-zig</string>
    \\<key>CFBundleName</key><string>SysData Zig</string>
    \\<key>CFBundleDisplayName</key><string>SysData Zig</string>
    \\<key>CFBundleExecutable</key><string>sysdata</string>
    \\<key>CFBundlePackageType</key><string>APPL</string>
    \\<key>CFBundleShortVersionString</key><string>0.1.0</string>
    \\<key>CFBundleVersion</key><string>1</string>
    \\<key>LSMinimumSystemVersion</key><string>14.0</string>
    \\<key>LSUIElement</key><true/>
    \\<key>NSHighResolutionCapable</key><true/>
    \\</dict></plist>
    \\
;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const nanoui = b.dependency("nanoui", .{ .target = target, .optimize = optimize }).module("nanoui");
    const imports: []const std.Build.Module.Import = &.{.{ .name = "nanoui", .module = nanoui }};

    const exe = b.addExecutable(.{ .name = "sysdata", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports,
    }) });
    frameworks(exe.root_module);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run SysData").dependOn(&run.step);

    // The same binary, wrapped as a menu-bar-only app bundle (no Dock icon).
    // Ad-hoc signature, so macOS keeps one Full Disk Access grant for this path.
    const plist = b.addWriteFiles().add("Info.plist", info_plist);
    const bundle = b.addSystemCommand(&.{
        "/bin/sh", "-c",
        "set -e; mkdir -p \"$1/Contents/MacOS\"; cp \"$2\" \"$1/Contents/MacOS/sysdata\"; cp \"$3\" \"$1/Contents/Info.plist\"; /usr/bin/codesign --force --sign - \"$1\" 2>/dev/null; /usr/bin/codesign --verify --strict \"$1\"",
        "bundle",
    });
    const app_dir = bundle.addOutputDirectoryArg("SysData Zig.app");
    bundle.addFileArg(exe.getEmittedBin());
    bundle.addFileArg(plist);
    b.step("bundle", "Build zig-out/SysData Zig.app").dependOn(&b.addInstallDirectory(.{
        .source_dir = app_dir,
        .install_dir = .prefix,
        .install_subdir = "SysData Zig.app",
    }).step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports,
    }) });
    frameworks(tests.root_module);
    b.step("test", "Run SysData's tests").dependOn(&b.addRunArtifact(tests).step);
}

fn frameworks(module: *std.Build.Module) void {
    const result = module.resolved_target orelse return;
    if (result.result.os.tag != .macos) return;
    // plist reads and volume figures come straight from Foundation; AppKit
    // because the menu bar item and the Finder calls reach it.
    module.linkFramework("Foundation", .{});
    module.linkFramework("AppKit", .{});
}
