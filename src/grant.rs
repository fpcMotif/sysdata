//! Granting Full Disk Access by dragging the app into System Settings' list.
//!
//! GPUI draws the guide, but its drag and drop stays inside the app. Handing a
//! file to another app needs an AppKit dragging source, so a transparent view
//! over the guide's app card starts a real file drag of this app's bundle.
use crate::mac::{Rect, id, nil, ns_string, ns_window, pooled};
use objc::{
    class,
    declare::ClassDecl,
    msg_send,
    runtime::{BOOL, Class, Object, Protocol, Sel, YES},
    sel, sel_impl,
};
use std::path::{Path, PathBuf};

/// Opens Privacy & Security > Full Disk Access, with the pre-Ventura URL as a fallback.
pub fn open_settings() {
    if !crate::mac::open_url(
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
    ) {
        crate::mac::open_url(
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        );
    }
}

/// What a person drags into the list: the .app bundle, or the bare binary
/// when running unbundled from a build folder.
pub fn app_path() -> PathBuf {
    let exe = std::env::current_exe().unwrap_or_default();
    exe.ancestors()
        .find(|p| p.extension().is_some_and(|e| e == "app"))
        .map(Path::to_path_buf)
        .unwrap_or(exe)
}

/// Where the guide goes: centered on the Settings window's bottom edge, or
/// near the bottom of the screen until that window appears. Kept on screen.
pub fn anchor(settings: Option<Rect>, screen: Rect, width: f64, height: f64) -> Rect {
    let (x, y) = match settings {
        Some(s) => (
            s.origin.x + s.size.x / 2. - width / 2.,
            s.origin.y - height + 20.,
        ),
        None => (
            screen.origin.x + screen.size.x / 2. - width / 2.,
            screen.origin.y + 80.,
        ),
    };
    let min_x = screen.origin.x + 12.;
    let max_x = (screen.origin.x + screen.size.x - width - 12.).max(min_x);
    let min_y = screen.origin.y + 8.;
    let max_y = (screen.origin.y + screen.size.y - height - 8.).max(min_y);
    Rect::new(x.clamp(min_x, max_x), y.clamp(min_y, max_y), width, height)
}

#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    fn CGWindowListCopyWindowInfo(option: u32, relative_to: u32) -> id;
}

/// The System Settings window's frame in AppKit coordinates, if one is on screen.
/// Owner names and bounds need no screen-recording permission.
pub fn settings_window() -> Option<Rect> {
    const ON_SCREEN_ONLY: u32 = 1;
    const EXCLUDE_DESKTOP: u32 = 16;
    pooled(|| unsafe {
        let windows = CGWindowListCopyWindowInfo(ON_SCREEN_ONLY | EXCLUDE_DESKTOP, 0);
        if windows == nil {
            return None;
        }
        let _: id = msg_send![windows, autorelease];
        let screens: id = msg_send![class!(NSScreen), screens];
        let primary: id = msg_send![screens, firstObject];
        let primary_height = if primary == nil {
            900.
        } else {
            let frame: Rect = msg_send![primary, frame];
            frame.size.y
        };
        let number = |dict: id, key: &str| -> f64 {
            let value: id = msg_send![dict, objectForKey: ns_string(key)];
            if value == nil {
                0.
            } else {
                msg_send![value, doubleValue]
            }
        };
        let count: usize = msg_send![windows, count];
        (0..count).find_map(|n| {
            let window: id = msg_send![windows, objectAtIndex: n];
            let owner: id = msg_send![window, objectForKey: ns_string("kCGWindowOwnerName")];
            let owner = crate::mac::rust_string(owner).unwrap_or_default();
            let bounds: id = msg_send![window, objectForKey: ns_string("kCGWindowBounds")];
            if !(owner == "System Settings" || owner == "System Preferences")
                || number(window, "kCGWindowLayer") != 0.
                || number(window, "kCGWindowAlpha") <= 0.5
                || bounds == nil
            {
                return None;
            }
            let (x, y) = (number(bounds, "X"), number(bounds, "Y"));
            let (w, h) = (number(bounds, "Width"), number(bounds, "Height"));
            // Quartz counts from the primary screen's top; AppKit from its bottom.
            (w > 100. && h > 100.).then(|| Rect::new(x, primary_height - (y + h), w, h))
        })
    })
}

/// The visible part of the main screen, in AppKit coordinates.
pub fn main_screen() -> Rect {
    pooled(|| unsafe {
        let screen: id = msg_send![class!(NSScreen), mainScreen];
        if screen == nil {
            Rect::new(0., 0., 1440., 900.)
        } else {
            msg_send![screen, visibleFrame]
        }
    })
}

/// Moves a GPUI window to `frame`, in AppKit coordinates.
pub fn place(window: &gpui_kit::Window, frame: Rect) {
    let native = ns_window(window);
    if native != nil {
        unsafe {
            let _: () = msg_send![native, setFrame: frame display: YES];
        }
    }
}

const PATH_IVAR: &str = "sysdataPath";

fn drag_class() -> &'static Class {
    if let Some(class) = Class::get("SysDataDragSource") {
        return class;
    }
    let mut decl = ClassDecl::new("SysDataDragSource", class!(NSView)).expect("new class");
    decl.add_ivar::<id>(PATH_IVAR);
    if let Some(protocol) = Protocol::get("NSDraggingSource") {
        decl.add_protocol(protocol);
    }
    // SAFETY: each signature matches the AppKit method it overrides.
    unsafe {
        decl.add_method(
            sel!(mouseDown:),
            mouse_down as extern "C" fn(&Object, Sel, id),
        );
        decl.add_method(
            sel!(mouseDragged:),
            mouse_dragged as extern "C" fn(&Object, Sel, id),
        );
        decl.add_method(
            sel!(acceptsFirstMouse:),
            accepts_first_mouse as extern "C" fn(&Object, Sel, id) -> BOOL,
        );
        decl.add_method(
            sel!(draggingSession:sourceOperationMaskForDraggingContext:),
            operation_mask as extern "C" fn(&Object, Sel, id, isize) -> usize,
        );
        decl.add_method(
            sel!(resetCursorRects),
            reset_cursor_rects as extern "C" fn(&Object, Sel),
        );
    }
    decl.register()
}

/// Taking the press is what makes AppKit send the drag that follows.
extern "C" fn mouse_down(_: &Object, _: Sel, _: id) {}

extern "C" fn accepts_first_mouse(_: &Object, _: Sel, _: id) -> BOOL {
    YES
}

/// Copy: the list records the app; nothing moves.
extern "C" fn operation_mask(_: &Object, _: Sel, _: id, _: isize) -> usize {
    1
}

extern "C" fn reset_cursor_rects(this: &Object, _: Sel) {
    unsafe {
        let view = this as *const Object as id;
        let bounds: Rect = msg_send![view, bounds];
        let cursor: id = msg_send![class!(NSCursor), openHandCursor];
        let _: () = msg_send![view, addCursorRect: bounds cursor: cursor];
    }
}

extern "C" fn mouse_dragged(this: &Object, _: Sel, event: id) {
    unsafe {
        let view = this as *const Object as id;
        let path: id = *this.get_ivar::<id>(PATH_IVAR);
        if path == nil {
            return;
        }
        let url: id = msg_send![class!(NSURL), fileURLWithPath: path];
        let item: id = msg_send![class!(NSDraggingItem), alloc];
        let item: id = msg_send![item, initWithPasteboardWriter: url];
        let _: id = msg_send![item, autorelease];
        let workspace: id = msg_send![class!(NSWorkspace), sharedWorkspace];
        let icon: id = msg_send![workspace, iconForFile: path];
        let bounds: Rect = msg_send![view, bounds];
        let frame = Rect::new(8., (bounds.size.y - 32.) / 2., 32., 32.);
        let _: () = msg_send![item, setDraggingFrame: frame contents: icon];
        let items: id = msg_send![class!(NSArray), arrayWithObject: item];
        let _: id = msg_send![view, beginDraggingSessionWithItems: items event: event source: view];
    }
}

/// Puts a transparent dragging source over `card`, given in the window's
/// top-left coordinates. Returns the view, to remove it later.
pub fn install_drag_source(window: &gpui_kit::Window, card: Rect, path: &Path) -> id {
    let native = ns_window(window);
    if native == nil {
        return nil;
    }
    unsafe {
        let content: id = msg_send![native, contentView];
        let bounds: Rect = msg_send![content, bounds];
        let flipped: BOOL = msg_send![content, isFlipped];
        let y = if flipped == YES {
            card.origin.y
        } else {
            bounds.size.y - card.origin.y - card.size.y
        };
        let view: id = msg_send![drag_class(), alloc];
        let view: id =
            msg_send![view, initWithFrame: Rect::new(card.origin.x, y, card.size.x, card.size.y)];
        let path: id = msg_send![class!(NSString), stringWithUTF8String: std::ffi::CString::new(path.to_string_lossy().as_bytes()).unwrap_or_default().as_ptr()];
        let path: id = msg_send![path, retain];
        (*view).set_ivar::<id>(PATH_IVAR, path);
        let _: () = msg_send![content, addSubview: view];
        let _: () = msg_send![view, release];
        let _: () = msg_send![native, invalidateCursorRectsForView: view];
        view
    }
}

/// # Safety
/// `view` must be nil or a view `install_drag_source` returned, while its window is open.
pub unsafe fn remove_drag_source(view: id) {
    if view != nil {
        unsafe {
            let _: () = msg_send![view, removeFromSuperview];
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SCREEN: Rect = Rect {
        origin: crate::mac::Point { x: 0., y: 0. },
        size: crate::mac::Point { x: 1512., y: 944. },
    };

    #[test]
    fn the_guide_sits_on_the_settings_windows_bottom_edge() {
        let settings = Rect::new(400., 300., 700., 500.);
        let frame = anchor(Some(settings), SCREEN, 380., 112.);
        assert_eq!(frame, Rect::new(560., 208., 380., 112.));
    }

    #[test]
    fn without_a_settings_window_it_waits_near_the_bottom() {
        assert_eq!(
            anchor(None, SCREEN, 380., 112.),
            Rect::new(566., 80., 380., 112.)
        );
    }

    #[test]
    fn it_stays_on_screen() {
        let low_left = Rect::new(-300., 10., 400., 300.);
        let frame = anchor(Some(low_left), SCREEN, 380., 112.);
        assert_eq!(frame.origin.x, 12.);
        assert_eq!(frame.origin.y, 8.);
    }

    #[test]
    fn a_bundle_is_found_above_the_executable() {
        let path = app_path();
        assert!(path.exists(), "{}", path.display());
    }
}
