//! The menu bar item and the panel under it. GPUI has no status-item API,
//! so this is AppKit through objc, on the main thread only.
use crate::mac::{Point, Rect, id, nil, ns_string, ns_window};
use objc::{
    class,
    declare::ClassDecl,
    msg_send,
    runtime::{BOOL, Class, Object, Sel, YES},
    sel, sel_impl,
};
use std::cell::{Cell, RefCell};

thread_local! {
    static ITEM: Cell<id> = const { Cell::new(std::ptr::null_mut()) };
    static PANEL: Cell<id> = const { Cell::new(std::ptr::null_mut()) };
    static ON_CLICK: RefCell<Option<Box<dyn Fn()>>> = const { RefCell::new(None) };
    static PINNED: Cell<bool> = const { Cell::new(false) };
}

/// A pinned panel stays open when focus leaves, for screenshots and automation.
pub fn set_pinned(pinned: bool) {
    PINNED.set(pinned);
}

pub fn pinned() -> bool {
    PINNED.get()
}

extern "C" fn clicked(_: &Object, _: Sel, _: id) {
    ON_CLICK.with_borrow(|on_click| {
        if let Some(on_click) = on_click {
            on_click();
        }
    });
}

fn target_class() -> &'static Class {
    if let Some(class) = Class::get("SysDataStatusTarget") {
        return class;
    }
    let mut decl = ClassDecl::new("SysDataStatusTarget", class!(NSObject)).expect("new class");
    // SAFETY: the signature matches an action method.
    unsafe { decl.add_method(sel!(clicked:), clicked as extern "C" fn(&Object, Sel, id)) };
    decl.register()
}

/// A menu-bar-only app: no Dock icon, no app menu.
pub fn become_accessory() {
    unsafe {
        let app: id = msg_send![class!(NSApplication), sharedApplication];
        let _: BOOL = msg_send![app, setActivationPolicy: 1i64];
    }
}

/// Puts the drive glyph in the menu bar; `on_click` runs on every click.
pub fn install(on_click: impl Fn() + 'static) {
    ON_CLICK.set(Some(Box::new(on_click)));
    unsafe {
        let bar: id = msg_send![class!(NSStatusBar), systemStatusBar];
        let item: id = msg_send![bar, statusItemWithLength: -1.0f64];
        let _: id = msg_send![item, retain];
        let button: id = msg_send![item, button];
        let image: id = msg_send![class!(NSImage), imageWithSystemSymbolName: ns_string("internaldrive") accessibilityDescription: ns_string("System Data")];
        if image != nil {
            let _: () = msg_send![image, setTemplate: YES];
            let _: () = msg_send![button, setImage: image];
            let _: () = msg_send![button, setImagePosition: 2u64];
        }
        let target: id = msg_send![target_class(), new];
        let _: () = msg_send![button, setTarget: target];
        let _: () = msg_send![button, setAction: sel!(clicked:)];
        ITEM.set(item);
    }
}

/// The number beside the glyph; empty for the glyph alone.
pub fn set_title(text: &str) {
    let item = ITEM.get();
    if item.is_null() {
        return;
    }
    unsafe {
        let button: id = msg_send![item, button];
        let title = if text.is_empty() {
            String::new()
        } else {
            format!(" {text}")
        };
        let _: () = msg_send![button, setTitle: ns_string(&title)];
        let tip = format!("System Data found: {text}");
        let _: () = msg_send![button, setToolTip: ns_string(&tip)];
    }
}

/// Remembers the panel GPUI opened, so a click can show and hide it.
pub fn adopt(window: &gpui_kit::Window) {
    PANEL.set(ns_window(window));
}

pub fn is_open() -> bool {
    let panel = PANEL.get();
    !panel.is_null() && unsafe { msg_send![panel, isVisible] }
}

pub fn hide() {
    let panel = PANEL.get();
    if !panel.is_null() {
        unsafe {
            let _: () = msg_send![panel, orderOut: nil];
        }
    }
}

/// Shows the panel under the menu bar item, centered on it and kept on screen.
pub fn show() {
    let (panel, item) = (PANEL.get(), ITEM.get());
    if panel.is_null() || item.is_null() {
        return;
    }
    unsafe {
        let button: id = msg_send![item, button];
        let bar_window: id = msg_send![button, window];
        let anchor: Option<Rect> = (bar_window != nil)
            .then(|| msg_send![bar_window, frame])
            .filter(|r: &Rect| r.size.x > 0. && r.size.y > 0.);
        let screen: id = if bar_window != nil {
            msg_send![bar_window, screen]
        } else {
            nil
        };
        let screen: id = if screen != nil {
            screen
        } else {
            msg_send![class!(NSScreen), mainScreen]
        };
        if screen != nil {
            let visible: Rect = msg_send![screen, visibleFrame];
            let frame: Rect = msg_send![panel, frame];
            let left = visible.origin.x + 8.;
            let right = (visible.origin.x + visible.size.x - frame.size.x - 8.).max(left);
            // Under the item; before the menu bar has placed it, the top right corner.
            let (x, y) = match anchor {
                Some(a) => (
                    a.origin.x + a.size.x / 2. - frame.size.x / 2.,
                    a.origin.y - 4.,
                ),
                None => (right, visible.origin.y + visible.size.y - 4.),
            };
            let top = Point {
                x: x.clamp(left, right),
                y,
            };
            let _: () = msg_send![panel, setFrameTopLeftPoint: top];
        }
        let app: id = msg_send![class!(NSApplication), sharedApplication];
        let _: () = msg_send![app, activateIgnoringOtherApps: YES];
        let _: () = msg_send![panel, makeKeyAndOrderFront: nil];
    }
}

pub fn toggle() {
    if is_open() { hide() } else { show() }
}
