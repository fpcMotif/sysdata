//! Allocated size of directory trees, measured the way Finder counts System Data.
//!
//! One `getattrlistbulk` call returns the name, type, device, modification
//! time and allocated size of many directory entries at once, so a walk costs
//! roughly one syscall per directory instead of one `lstat` per file.
//! Subdirectories fan out across every core through rayon's work stealing.
use rayon::prelude::*;
use std::{
    cell::RefCell,
    collections::{HashMap, HashSet},
    ffi::{CString, OsStr},
    os::unix::ffi::OsStrExt,
    path::{Path, PathBuf},
    sync::Mutex,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Measurement {
    pub bytes: u64,
    /// Newest regular-file modification, in seconds since the epoch.
    pub newest: Option<i64>,
}

impl Measurement {
    fn add(self, other: Measurement) -> Measurement {
        Measurement {
            bytes: self.bytes + other.bytes,
            newest: self.newest.max(other.newest),
        }
    }

    pub fn modified(&self) -> Option<SystemTime> {
        self.newest
            .map(|secs| UNIX_EPOCH + Duration::from_secs(secs.max(0) as u64))
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    File,
    Dir,
    Other,
}

struct Entry<'a> {
    name: &'a OsStr,
    kind: Kind,
    device: i32,
    modified: i64,
    allocated: u64,
}

// Not exported by libc; values from <sys/attr.h>.
const ATTR_CMN_ERROR: u32 = 0x2000_0000;
const VREG: u32 = 1;
const VDIR: u32 = 2;
// The kernel prepares the whole buffer on every call, and most directories
// are small: a large buffer turns into seconds of system time.
const BUFFER: usize = 32 * 1024;

thread_local! {
    static SCRATCH: RefCell<Vec<u8>> = RefCell::new(vec![0; BUFFER]);
}

const OPEN_DIR: i32 = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC;

/// Opens `dir`, relative to its already-open parent when there is one: a
/// path lookup from `/` for every directory is where parallel walks contend.
fn open_dir(parent: Option<i32>, dir: &Path) -> Option<i32> {
    let relative = parent.zip(dir.file_name());
    let path = match relative {
        Some((_, name)) => CString::new(name.as_bytes()),
        None => CString::new(dir.as_os_str().as_bytes()),
    }
    .ok()?;
    // SAFETY: a valid NUL-terminated path; callers close the descriptor.
    let fd = unsafe {
        match relative {
            Some((parent, _)) => libc::openat(parent, path.as_ptr(), OPEN_DIR | libc::O_NOFOLLOW),
            None => libc::open(path.as_ptr(), OPEN_DIR),
        }
    };
    if fd >= 0 {
        return Some(fd);
    }
    // Out of descriptors: fall back to the full path, one at a time.
    let full = CString::new(dir.as_os_str().as_bytes()).ok()?;
    let fd = unsafe { libc::open(full.as_ptr(), OPEN_DIR | libc::O_NOFOLLOW) };
    (fd >= 0).then_some(fd)
}

fn close(fd: i32) {
    // SAFETY: fd came from open_dir.
    unsafe { libc::close(fd) };
}

/// Calls `each` for every entry of `dir`.
fn list(dir: &Path, each: impl FnMut(Entry<'_>)) -> bool {
    let Some(fd) = open_dir(None, dir) else {
        return false;
    };
    list_fd(fd, each);
    close(fd);
    true
}

/// Entries the kernel reports an error for are skipped, like an unreadable
/// file in Finder's count.
fn list_fd(fd: i32, mut each: impl FnMut(Entry<'_>)) {
    // SAFETY: attrlist is plain data; zero is its empty value.
    let mut request: libc::attrlist = unsafe { std::mem::zeroed() };
    request.bitmapcount = libc::ATTR_BIT_MAP_COUNT;
    request.commonattr = libc::ATTR_CMN_RETURNED_ATTRS
        | libc::ATTR_CMN_NAME
        | libc::ATTR_CMN_DEVID
        | libc::ATTR_CMN_OBJTYPE
        | libc::ATTR_CMN_MODTIME
        | ATTR_CMN_ERROR;
    request.fileattr = libc::ATTR_FILE_ALLOCSIZE;
    SCRATCH.with_borrow_mut(|buffer| {
        loop {
            // SAFETY: the buffer outlives the call and its length is passed.
            let count = unsafe {
                libc::getattrlistbulk(
                    fd,
                    (&raw mut request).cast(),
                    buffer.as_mut_ptr().cast(),
                    buffer.len(),
                    libc::FSOPT_PACK_INVAL_ATTRS as u64,
                )
            };
            if count < 0 {
                if std::io::Error::last_os_error().raw_os_error() == Some(libc::EINTR) {
                    continue;
                }
                break;
            }
            if count == 0 {
                break;
            }
            let mut offset = 0;
            for _ in 0..count {
                let Some(length) = buffer
                    .get(offset..offset + 4)
                    .map(|b| read::<u32>(b, 0) as usize)
                else {
                    break;
                };
                if length < 4 || offset + length > buffer.len() {
                    break;
                }
                let record = &buffer[offset..offset + length];
                offset += length;
                // Layout: length, returned set (20), error, name reference,
                // device, type, modification time, then the allocated size
                // only for files. Directory records end before it, so the
                // returned set decides whether it is there.
                if length < 60 || read::<u32>(record, 24) != 0 {
                    continue;
                }
                let has_size =
                    read::<u32>(record, 16) & libc::ATTR_FILE_ALLOCSIZE != 0 && length >= 68;
                let name_offset = read::<i32>(record, 28) as usize + 28;
                let name_length = read::<u32>(record, 32) as usize;
                let Some(name) =
                    record.get(name_offset..name_offset + name_length.saturating_sub(1))
                else {
                    continue;
                };
                each(Entry {
                    name: OsStr::from_bytes(name),
                    kind: match read::<u32>(record, 40) {
                        VREG => Kind::File,
                        VDIR => Kind::Dir,
                        _ => Kind::Other,
                    },
                    device: read::<i32>(record, 36),
                    modified: read::<i64>(record, 44),
                    allocated: if has_size {
                        read::<i64>(record, 60).max(0) as u64
                    } else {
                        0
                    },
                });
            }
        }
    });
}

fn read<T: Copy>(bytes: &[u8], at: usize) -> T {
    assert!(at + size_of::<T>() <= bytes.len());
    // SAFETY: bounds checked above; records are only 4-byte aligned.
    unsafe { bytes.as_ptr().add(at).cast::<T>().read_unaligned() }
}

/// Everything a walk needs to decide what counts.
struct Walk<'a> {
    /// Only regular files modified at or before this second count.
    cutoff: Option<i64>,
    /// Stay on this device; `None` follows mounts like Finder's own walk.
    device: Option<i32>,
    skip: &'a HashSet<PathBuf>,
    /// Totals measured earlier in this scan; used instead of walking again.
    known: Option<&'a HashMap<PathBuf, u64>>,
    /// A directory holding `.git` counts as nothing, like a skipped one.
    skip_repositories: bool,
    /// Records the total of every directory down to this depth.
    record: Option<(usize, &'a Mutex<HashMap<PathBuf, u64>>)>,
}

fn walk(parent: Option<i32>, dir: &Path, depth: usize, walk_opts: &Walk<'_>) -> Measurement {
    let Some(fd) = open_dir(parent, dir) else {
        return Measurement::default();
    };
    let total = walk_fd(fd, dir, depth, walk_opts);
    close(fd);
    total
}

fn walk_fd(fd: i32, dir: &Path, depth: usize, walk_opts: &Walk<'_>) -> Measurement {
    let mut total = Measurement::default();
    let mut children = Vec::new();
    let mut repository = false;
    list_fd(fd, |entry| match entry.kind {
        _ if walk_opts.skip_repositories && entry.name == ".git" => repository = true,
        Kind::File => {
            if walk_opts
                .cutoff
                .is_none_or(|cutoff| entry.modified <= cutoff)
            {
                total.bytes += entry.allocated;
                total.newest = total.newest.max(Some(entry.modified));
            }
        }
        Kind::Dir => {
            if walk_opts.device.is_none_or(|device| device == entry.device) {
                let child = dir.join(entry.name);
                if walk_opts.skip.contains(&child) {
                } else if let Some(&bytes) = walk_opts.known.and_then(|k| k.get(&child)) {
                    total.bytes += bytes;
                    if let Some((max_depth, sizes)) = walk_opts.record
                        && depth < max_depth
                        && bytes > 0
                    {
                        sizes.lock().expect("size table").insert(child, bytes);
                    }
                } else {
                    children.push(child);
                }
            }
        }
        Kind::Other => {}
    });
    if repository {
        return Measurement::default();
    }
    let below = children
        .par_iter()
        .map(|child| walk(Some(fd), child, depth + 1, walk_opts))
        .reduce(Measurement::default, Measurement::add);
    let total = total.add(below);
    if let Some((max_depth, sizes)) = walk_opts.record
        && depth <= max_depth
        && total.bytes > 0
    {
        sizes
            .lock()
            .expect("size table")
            .insert(dir.to_path_buf(), total.bytes);
    }
    total
}

fn stat(path: &Path) -> Option<libc::stat> {
    let path = CString::new(path.as_os_str().as_bytes()).ok()?;
    // SAFETY: plain data out-parameter and a valid path.
    let mut info: libc::stat = unsafe { std::mem::zeroed() };
    (unsafe { libc::stat(path.as_ptr(), &mut info) } == 0).then_some(info)
}

fn lstat(path: &Path) -> Option<libc::stat> {
    let path = CString::new(path.as_os_str().as_bytes()).ok()?;
    // SAFETY: plain data out-parameter and a valid path.
    let mut info: libc::stat = unsafe { std::mem::zeroed() };
    (unsafe { libc::lstat(path.as_ptr(), &mut info) } == 0).then_some(info)
}

/// Allocated bytes under `path` and its newest file. A regular file is its
/// own size; a missing path is zero. Symlinks are never followed inside.
pub fn measure(path: &Path) -> Measurement {
    let measured = measure_with(path, None);
    if let Some(known) = KNOWN.lock().expect("known sizes").as_mut() {
        known.insert(path.to_path_buf(), measured.bytes);
    }
    measured
}

/// Directory totals the probes measured during the current scan.
static KNOWN: Mutex<Option<HashMap<PathBuf, u64>>> = Mutex::new(None);

/// Starts remembering what `measure` finds.
pub fn remember() {
    *KNOWN.lock().expect("known sizes") = Some(HashMap::new());
}

/// Stops remembering and hands back what was measured.
pub fn remembered() -> HashMap<PathBuf, u64> {
    KNOWN
        .lock()
        .expect("known sizes")
        .take()
        .unwrap_or_default()
}

/// Like `measure`, counting only files last modified before `cutoff`.
pub fn measure_older_than(path: &Path, cutoff: SystemTime) -> Measurement {
    let secs = cutoff
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64);
    measure_with(path, Some(secs))
}

fn measure_with(path: &Path, cutoff: Option<i64>) -> Measurement {
    let Some(info) = stat(path) else {
        return Measurement::default();
    };
    match info.st_mode & libc::S_IFMT {
        libc::S_IFDIR => walk(
            None,
            path,
            0,
            &Walk {
                cutoff,
                device: None,
                skip: &HashSet::new(),
                known: None,
                skip_repositories: false,
                record: None,
            },
        ),
        libc::S_IFREG if cutoff.is_none_or(|c| info.st_mtime <= c) => Measurement {
            bytes: info.st_blocks as u64 * 512,
            newest: Some(info.st_mtime),
        },
        _ => Measurement::default(),
    }
}

/// Totals of every directory under `root` down to `max_depth` levels, from
/// one walk that stays on the root's volume and never enters `skipping` or
/// a git repository. A directory in `known` adds its total without a walk.
pub fn directory_sizes(
    root: &Path,
    max_depth: usize,
    skipping: &HashSet<PathBuf>,
    known: &HashMap<PathBuf, u64>,
) -> HashMap<PathBuf, u64> {
    let Some(info) = stat(root) else {
        return HashMap::new();
    };
    let sizes = Mutex::new(HashMap::new());
    walk(
        None,
        root,
        0,
        &Walk {
            cutoff: None,
            device: Some(info.st_dev),
            skip: skipping,
            known: Some(known),
            skip_repositories: true,
            record: Some((max_depth, &sizes)),
        },
    );
    sizes.into_inner().expect("size table")
}

pub struct Child {
    pub path: PathBuf,
    pub kind: Kind,
    /// Seconds since the epoch.
    pub modified: i64,
}

/// Direct children of `dir`, hidden ones included, sorted by name.
pub fn children(dir: &Path) -> Vec<Child> {
    let mut found = Vec::new();
    list(dir, |entry| {
        found.push(Child {
            path: dir.join(entry.name),
            kind: entry.kind,
            modified: entry.modified,
        })
    });
    found.sort_by(|a, b| a.path.cmp(&b.path));
    found
}

/// Direct subdirectories of `dir`, sorted by name. Symlinks are not followed.
pub fn subdirectories(dir: &Path) -> Vec<PathBuf> {
    children(dir)
        .into_iter()
        .filter(|child| child.kind == Kind::Dir)
        .map(|child| child.path)
        .collect()
}

/// Newest modification among `dir` and its direct children, from one listing.
pub fn shallow_modified(dir: &Path) -> Option<SystemTime> {
    let mut newest = stat(dir).map(|info| info.st_mtime);
    list(dir, |entry| newest = newest.max(Some(entry.modified)));
    newest.map(|secs| UNIX_EPOCH + Duration::from_secs(secs.max(0) as u64))
}

/// The `limit` largest direct children of `dir`, measured in parallel.
pub fn largest_children(dir: &Path, limit: usize) -> Vec<(PathBuf, u64, bool)> {
    let mut sized: Vec<(PathBuf, u64, bool)> = children(dir)
        .into_par_iter()
        .map(|child| {
            let bytes = measure(&child.path).bytes;
            (child.path, bytes, child.kind == Kind::Dir)
        })
        .filter(|(_, bytes, _)| *bytes > 0)
        .collect();
    sized.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    sized.truncate(limit);
    sized
}

pub fn exists(path: &Path) -> bool {
    stat(path).is_some()
}

pub fn is_dir(path: &Path) -> bool {
    stat(path).is_some_and(|info| info.st_mode & libc::S_IFMT == libc::S_IFDIR)
}

pub fn is_symlink(path: &Path) -> bool {
    lstat(path).is_some_and(|info| info.st_mode & libc::S_IFMT == libc::S_IFLNK)
}

/// Device of `path` itself, not following a final symlink.
pub fn device(path: &Path) -> Option<i32> {
    lstat(path).map(|info| info.st_dev)
}

/// File flags macOS uses to protect data even from root.
pub fn is_protected(path: &Path) -> bool {
    match lstat(path) {
        Some(info) => info.st_flags & (SF_RESTRICTED | UF_DATAVAULT) != 0,
        None => true,
    }
}
// From <sys/stat.h>.
const SF_RESTRICTED: u32 = 0x0008_0000;
const UF_DATAVAULT: u32 = 0x0000_0080;

/// Whether `path` lives on the startup volume. Unknown counts as yes, so an
/// unreadable location is measured rather than silently dropped.
pub fn on_boot_volume(path: &Path) -> bool {
    match (stat(Path::new("/")), stat(path)) {
        (Some(root), Some(info)) => {
            root.st_dev == info.st_dev || boot_data_volume().is_some_and(|dev| dev == info.st_dev)
        }
        _ => true,
    }
}

/// Home folders live on the Data volume, a sibling of the sealed system
/// volume in the same APFS container. It is still the startup disk.
fn boot_data_volume() -> Option<i32> {
    stat(Path::new("/System/Volumes/Data")).map(|info| info.st_dev)
}

/// Once per process, before the first walk.
pub fn prepare() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        never_materialize_dataless_files();
        raise_descriptor_limit();
        // Past the performance cores, the walkers only contend in the kernel:
        // on an M4 Pro, 12 threads took three times as long as 8.
        let threads = std::env::var("SYSDATA_THREADS")
            .ok()
            .and_then(|n| n.parse().ok())
            .unwrap_or_else(performance_cores);
        let _ = rayon::ThreadPoolBuilder::new()
            .num_threads(threads)
            .thread_name(|n| format!("sysdata-walk-{n}"))
            .build_global();
    });
}

fn performance_cores() -> usize {
    let mut cores: i32 = 0;
    let mut len = size_of::<i32>();
    // SAFETY: a valid name and an out-parameter of the stated size.
    let found = unsafe {
        libc::sysctlbyname(
            c"hw.perflevel0.physicalcpu".as_ptr(),
            (&raw mut cores).cast(),
            &mut len,
            std::ptr::null_mut(),
            0,
        )
    } == 0;
    if found && cores > 0 {
        cores as usize
    } else {
        std::thread::available_parallelism().map_or(4, |n| n.get())
    }
}

/// Apps launched from Finder start with 256 descriptors; each walk level
/// keeps its parent open while its children are measured.
fn raise_descriptor_limit() {
    // SAFETY: plain data in and out.
    unsafe {
        let mut limit: libc::rlimit = std::mem::zeroed();
        if libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) == 0 {
            limit.rlim_cur = limit.rlim_max.min(10_240);
            libc::setrlimit(libc::RLIMIT_NOFILE, &limit);
        }
    }
}

/// Stops the walks from downloading iCloud and File Provider placeholders.
/// A scan must never fill the disk it is measuring.
fn never_materialize_dataless_files() {
    const IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES: i32 = 3;
    const IOPOL_SCOPE_PROCESS: i32 = 0;
    const IOPOL_MATERIALIZE_DATALESS_FILES_OFF: i32 = 1;
    unsafe extern "C" {
        fn setiopolicy_np(kind: i32, scope: i32, policy: i32) -> i32;
    }
    // SAFETY: documented constants; failure only leaves the default policy.
    unsafe {
        setiopolicy_np(
            IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
            IOPOL_SCOPE_PROCESS,
            IOPOL_MATERIALIZE_DATALESS_FILES_OFF,
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs, os::unix::fs::MetadataExt};

    fn tree() -> PathBuf {
        static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let root = std::env::temp_dir().join(format!(
            "sysdata-size-{}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        for dir in ["a/b/c", "d", "e/f"] {
            fs::create_dir_all(root.join(dir)).unwrap();
        }
        for (file, len) in [
            ("top.bin", 10_000),
            ("a/one.bin", 70_000),
            ("a/b/two.bin", 5),
            ("a/b/c/three.bin", 300_000),
            ("e/f/four.bin", 4_097),
        ] {
            fs::write(root.join(file), vec![7u8; len]).unwrap();
        }
        std::os::unix::fs::symlink("/usr", root.join("d/link")).unwrap();
        root
    }

    /// The reference: `lstat` every file, like `du`, without following links.
    fn reference(dir: &Path) -> u64 {
        let mut total = 0;
        for entry in fs::read_dir(dir).unwrap() {
            let entry = entry.unwrap();
            let meta = fs::symlink_metadata(entry.path()).unwrap();
            if meta.is_dir() {
                total += reference(&entry.path());
            } else if meta.is_file() {
                total += meta.blocks() * 512;
            }
        }
        total
    }

    #[test]
    fn bulk_walk_matches_lstat_walk() {
        let root = tree();
        let measured = measure(&root);
        assert_eq!(measured.bytes, reference(&root));
        assert!(measured.bytes >= 384_102);
        assert!(measured.newest.is_some());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn directory_sizes_record_each_level_and_skip() {
        let root = tree();
        let skip: HashSet<PathBuf> = [root.join("e")].into();
        let sizes = directory_sizes(&root, 2, &skip, &HashMap::new());
        assert_eq!(sizes[&root.join("a")], reference(&root.join("a")));
        assert_eq!(sizes[&root.join("a/b")], reference(&root.join("a/b")));
        assert!(
            !sizes.contains_key(&root.join("a/b/c")),
            "deeper than max depth"
        );
        assert!(!sizes.contains_key(&root.join("e")), "skipped");
        assert_eq!(sizes[&root], reference(&root) - reference(&root.join("e")));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cutoff_counts_only_old_files() {
        let root = tree();
        assert_eq!(measure_older_than(&root, UNIX_EPOCH).bytes, 0);
        let later = SystemTime::now() + Duration::from_secs(60);
        assert_eq!(measure_older_than(&root, later).bytes, reference(&root));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn largest_children_are_sorted() {
        let root = tree();
        let top = largest_children(&root, 2);
        assert_eq!(top[0].0, root.join("a"));
        assert!(top[0].2, "a is a directory");
        assert_eq!(top.len(), 2);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn a_file_or_missing_path() {
        let root = tree();
        let file = root.join("top.bin");
        assert_eq!(
            measure(&file).bytes,
            fs::metadata(&file).unwrap().blocks() * 512
        );
        assert_eq!(measure(&root.join("missing")), Measurement::default());
        fs::remove_dir_all(root).unwrap();
    }
}
