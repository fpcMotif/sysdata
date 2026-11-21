//! The few Foundation and AppKit calls the scanner and the view need.
use objc::{
    class, msg_send,
    runtime::{BOOL, Object, YES},
    sel, sel_impl,
};
use std::{
    ffi::{CStr, CString},
    path::{Path, PathBuf},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

#[link(name = "Foundation", kind = "framework")]
unsafe extern "C" {}
#[link(name = "AppKit", kind = "framework")]
unsafe extern "C" {}

#[allow(non_camel_case_types)]
pub type id = *mut Object;
#[allow(non_upper_case_globals)]
pub const nil: id = std::ptr::null_mut();

/// Every call here may run on a scan thread, which has no pool of its own.
pub fn pooled<T>(body: impl FnOnce() -> T) -> T {
    // SAFETY: the pool is drained on the thread that created it.
    unsafe {
        let pool: id = msg_send![class!(NSAutoreleasePool), new];
        let result = body();
        let _: () = msg_send![pool, drain];
        result
    }
}

/// An autoreleased NSString.
///
/// # Safety
/// Call inside an autorelease pool.
pub unsafe fn ns_string(text: &str) -> id {
    let text = CString::new(text.replace('\0', "")).unwrap_or_default();
    unsafe { msg_send![class!(NSString), stringWithUTF8String: text.as_ptr()] }
}

/// A Rust copy of an NSString.
///
/// # Safety
/// `value` must be nil or an NSString.
pub unsafe fn rust_string(value: id) -> Option<String> {
    if value == nil {
        return None;
    }
    let utf8: *const std::ffi::c_char = unsafe { msg_send![value, UTF8String] };
    (!utf8.is_null()).then(|| {
        unsafe { CStr::from_ptr(utf8) }
            .to_string_lossy()
            .into_owned()
    })
}

unsafe fn file_url(path: &Path) -> id {
    unsafe { msg_send![class!(NSURL), fileURLWithPath: ns_string(&path.to_string_lossy())] }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct DiskSpace {
    pub free: u64,
    pub capacity: u64,
    /// What macOS says it could give back if something important needed room:
    /// available-for-important-usage minus available. An estimate, not an allocation.
    pub purgeable: u64,
}

pub fn disk_space() -> DiskSpace {
    pooled(|| unsafe {
        let url = file_url(Path::new("/"));
        let value = |key: &str| -> i64 {
            let mut out: id = nil;
            let mut error: id = nil;
            let ok: BOOL =
                msg_send![url, getResourceValue: &mut out forKey: ns_string(key) error: &mut error];
            if ok == YES && out != nil {
                msg_send![out, longLongValue]
            } else {
                0
            }
        };
        let free = value("NSURLVolumeAvailableCapacityKey").max(0) as u64;
        let capacity = value("NSURLVolumeTotalCapacityKey").max(0) as u64;
        let important = value("NSURLVolumeAvailableCapacityForImportantUsageKey").max(0) as u64;
        DiskSpace {
            free,
            capacity,
            purgeable: important.saturating_sub(free),
        }
    })
}

/// Moves `path` to the user's Trash with Finder's Put Back record. Tests set
/// `SYSDATA_TRASH_DIR` so nothing reaches the real Trash.
pub fn trash(path: &Path) -> Result<(), String> {
    if let Some(dir) = std::env::var_os("SYSDATA_TRASH_DIR") {
        let name = path.file_name().unwrap_or_default().to_string_lossy();
        let target = PathBuf::from(dir).join(format!(
            "{name}.{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        return std::fs::rename(path, target).map_err(|e| e.to_string());
    }
    pooled(|| unsafe {
        let manager: id = msg_send![class!(NSFileManager), defaultManager];
        let mut error: id = nil;
        let ok: BOOL = msg_send![manager, trashItemAtURL: file_url(path) resultingItemURL: std::ptr::null_mut::<id>() error: &mut error];
        if ok == YES {
            Ok(())
        } else {
            let text: id = msg_send![error, localizedDescription];
            Err(rust_string(text).unwrap_or_else(|| "could not move it to the Trash".into()))
        }
    })
}

/// Selects `path` in a Finder window.
pub fn reveal(path: &Path) {
    pooled(|| unsafe {
        let workspace: id = msg_send![class!(NSWorkspace), sharedWorkspace];
        let urls: id = msg_send![class!(NSArray), arrayWithObject: file_url(path)];
        let _: () = msg_send![workspace, activateFileViewerSelectingURLs: urls];
    })
}

/// Opens a URL; false when nothing could open it.
pub fn open_url(url: &str) -> bool {
    pooled(|| unsafe {
        let workspace: id = msg_send![class!(NSWorkspace), sharedWorkspace];
        let url: id = msg_send![class!(NSURL), URLWithString: ns_string(url)];
        if url == nil {
            return false;
        }
        let opened: BOOL = msg_send![workspace, openURL: url];
        opened == YES
    })
}

/// AppKit geometry: bottom-left origin, in points.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rect {
    pub origin: Point,
    pub size: Point,
}

impl Rect {
    pub fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Rect {
            origin: Point { x, y },
            size: Point {
                x: width,
                y: height,
            },
        }
    }
}

unsafe impl objc::Encode for Point {
    fn encode() -> objc::Encoding {
        unsafe { objc::Encoding::from_str("{CGPoint=dd}") }
    }
}

unsafe impl objc::Encode for Rect {
    fn encode() -> objc::Encoding {
        unsafe { objc::Encoding::from_str("{CGRect={CGPoint=dd}{CGSize=dd}}") }
    }
}

/// The NSWindow behind a GPUI window.
pub fn ns_window(window: &gpui_kit::Window) -> id {
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};
    match HasWindowHandle::window_handle(window).map(|h| h.as_raw()) {
        Ok(RawWindowHandle::AppKit(handle)) => unsafe {
            let view = handle.ns_view.as_ptr() as id;
            msg_send![view, window]
        },
        _ => nil,
    }
}

/// The accent color chosen in System Settings, as 0xRRGGBB.
pub fn accent_color() -> Option<u32> {
    pooled(|| unsafe {
        let color: id = msg_send![class!(NSColor), controlAccentColor];
        let space: id = msg_send![class!(NSColorSpace), sRGBColorSpace];
        let color: id = msg_send![color, colorUsingColorSpace: space];
        if color == nil {
            return None;
        }
        let channel = |value: f64| (value.clamp(0., 1.) * 255.).round() as u32;
        let r: f64 = msg_send![color, redComponent];
        let g: f64 = msg_send![color, greenComponent];
        let b: f64 = msg_send![color, blueComponent];
        Some(channel(r) << 16 | channel(g) << 8 | channel(b))
    })
}

pub enum PlistValue {
    Text(String),
    Date(SystemTime),
}

/// Top-level values of a property list, XML or binary.
pub fn plist_values(path: &Path, keys: &[&str]) -> Vec<Option<PlistValue>> {
    pooled(|| unsafe {
        let dictionary: id =
            msg_send![class!(NSDictionary), dictionaryWithContentsOfURL: file_url(path)];
        keys.iter()
            .map(|key| {
                if dictionary == nil {
                    return None;
                }
                let value: id = msg_send![dictionary, objectForKey: ns_string(key)];
                if value == nil {
                    return None;
                }
                let is_string: BOOL = msg_send![value, isKindOfClass: class!(NSString)];
                let is_date: BOOL = msg_send![value, isKindOfClass: class!(NSDate)];
                if is_string == YES {
                    rust_string(value).map(PlistValue::Text)
                } else if is_date == YES {
                    let seconds: f64 = msg_send![value, timeIntervalSince1970];
                    Some(PlistValue::Date(
                        UNIX_EPOCH + Duration::from_secs_f64(seconds.max(0.)),
                    ))
                } else {
                    None
                }
            })
            .collect()
    })
}

pub fn plist_string(path: &Path, key: &str) -> Option<String> {
    match plist_values(path, &[key]).pop().flatten() {
        Some(PlistValue::Text(text)) => Some(text),
        _ => None,
    }
}

/// Seconds since the epoch as a UTC calendar date.
pub fn civil(seconds: i64) -> (i64, u32, u32, u32, u32, u32) {
    let days = seconds.div_euclid(86_400);
    let rest = seconds.rem_euclid(86_400);
    // Howard Hinnant's days-to-civil.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let year = yoe + era * 400 + i64::from(month <= 2);
    (
        year,
        month,
        day,
        (rest / 3_600) as u32,
        (rest / 60 % 60) as u32,
        (rest % 60) as u32,
    )
}

pub fn iso8601(time: SystemTime) -> String {
    let secs = time
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64);
    let (y, mo, d, h, mi, s) = civil(secs);
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z")
}

pub fn date(time: SystemTime) -> String {
    iso8601(time)[..10].to_string()
}

/// Parses `2026-09-26T10:36:28Z`, with or without fractional seconds.
pub fn parse_iso8601(text: &str) -> Option<SystemTime> {
    let text = text.trim().trim_end_matches('Z');
    let (date, time) = text.split_once('T')?;
    let mut date = date.split('-').map(|p| p.parse::<i64>().ok());
    let (y, m, d) = (date.next()??, date.next()??, date.next()??);
    let time = time.split(['+', '.']).next()?;
    let mut time = time.split(':').map(|p| p.parse::<i64>().ok());
    let (h, mi, s) = (time.next()??, time.next()??, time.next()??);
    // Days-from-civil, the inverse of `civil`.
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    let secs = days * 86_400 + h * 3_600 + mi * 60 + s;
    (secs >= 0).then(|| UNIX_EPOCH + Duration::from_secs(secs as u64))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iso_dates_round_trip() {
        let t = parse_iso8601("2026-09-26T10:36:28Z").unwrap();
        assert_eq!(iso8601(t), "2026-09-26T10:36:28Z");
        assert_eq!(
            parse_iso8601("2024-02-29T00:00:00.123Z")
                .map(date)
                .as_deref(),
            Some("2024-02-29")
        );
        assert_eq!(iso8601(UNIX_EPOCH), "1970-01-01T00:00:00Z");
    }

    #[test]
    fn disk_space_is_plausible() {
        let space = disk_space();
        assert!(space.capacity > space.free && space.free > 0);
    }
}
