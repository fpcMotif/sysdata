//! sysdata's colors: Storage settings' neutrals, with green for what any
//! tool rebuilds, amber for what a delete loses and red for what only the
//! owning app should touch; light or dark as the system shows.
const nanoui = @import("nanoui");
const Color = nanoui.ui.Color;

pub const Colors = struct {
    page: Color,
    card: Color,
    border: Color,
    separator: Color,
    text: Color,
    secondary: Color,
    tertiary: Color,
    accent: Color,
    selection: Color,
    hover: Color,
    control: Color,
    control_on: Color,
    /// Safety: Safe rebuilds, Review loses something, Manual keeps hands off.
    safe: Color,
    review: Color,
    manual: Color,
    danger: Color,
};

const white: Color = .{ .r = 1, .g = 1, .b = 1 };
const black: Color = .{};

pub fn colors(dark: bool) Colors {
    if (dark) {
        const bg = Color.hex(0x1e1e20);
        const blue = Color.hex(0x6c9bd1);
        return .{
            .page = bg,
            .card = Color.hex(0x26262a),
            .border = bg.mix(white, 0.10),
            .separator = bg.mix(white, 0.08),
            .text = Color.hex(0xececee),
            .secondary = Color.hex(0x9a9aa2),
            .tertiary = Color.hex(0x63636b),
            .accent = blue,
            .selection = bg.mix(blue, 0.22),
            .hover = white.alpha(0.05),
            .control = Color.hex(0x2c2c30),
            .control_on = Color.hex(0x34343a),
            .safe = Color.hex(0x7fa86b),
            .review = Color.hex(0xd9a441),
            .manual = Color.hex(0x8a9bb0),
            .danger = Color.hex(0xd2674f),
        };
    }
    const bg = Color.hex(0xf5f5f7);
    const blue = Color.hex(0x3b6fb0);
    return .{
        .page = bg,
        .card = Color.hex(0xffffff),
        .border = bg.mix(black, 0.10),
        .separator = bg.mix(black, 0.08),
        .text = Color.hex(0x1d1d1f),
        .secondary = Color.hex(0x6e6e73),
        .tertiary = Color.hex(0xa1a1a6),
        .accent = blue,
        .selection = bg.mix(blue, 0.16),
        .hover = black.alpha(0.04),
        .control = Color.hex(0xe9e9ee),
        .control_on = Color.hex(0xffffff),
        .safe = Color.hex(0x5c7e47),
        .review = Color.hex(0x9a6e1b),
        .manual = Color.hex(0x3b6fb0),
        .danger = Color.hex(0xb14228),
    };
}

pub fn ui(dark: bool) nanoui.ui.Theme {
    const k = colors(dark);
    var t = if (dark) nanoui.ui.Theme.dark_theme else nanoui.ui.Theme.light;
    t.background = k.page;
    t.surface = k.control_on;
    t.surface_hover = k.control;
    t.text = k.text;
    t.muted = k.secondary;
    t.border = k.border;
    t.accent = k.accent;
    t.accent_hover = k.accent.mix(if (dark) white else black, 0.12);
    t.accent_text = k.page;
    t.track = k.control;
    t.danger = k.danger;
    t.success = k.safe;
    t.font = "SF Pro Text";
    t.mono_font = "SF Mono";
    return t;
}
