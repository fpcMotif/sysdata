//! Pulls every module into the build's test step.
const std = @import("std");

test {
    std.testing.refAllDecls(@This());
    _ = @import("item.zig");
    _ = @import("walker.zig");
    _ = @import("guard.zig");
    _ = @import("proc.zig");
    _ = @import("mac.zig");
    _ = @import("scan.zig");
    _ = @import("model.zig");
    _ = @import("reclaim.zig");
    _ = @import("json.zig");
    _ = @import("fixture.zig");
    _ = @import("probes/developer.zig");
    _ = @import("probes/packages.zig");
    _ = @import("probes/tools.zig");
    _ = @import("probes/system.zig");
    _ = @import("probes/media.zig");
    _ = @import("probes/user_data.zig");
    _ = @import("probes/catchall.zig");
}
