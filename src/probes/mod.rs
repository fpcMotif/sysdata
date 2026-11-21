//! Each probe measures one family of locations and never changes anything.
//! Probes run concurrently; the catch-all runs last with what they claimed.
mod catch_all;
mod developer;
mod media;
mod packages;
mod system;
mod user_data;

use crate::{
    item::{Action, Category, Item, Safety},
    shell, size,
};
use std::{
    path::{Path, PathBuf},
    sync::atomic::{AtomicUsize, Ordering},
};

pub const MB: u64 = 1_048_576;

/// Where a scan looks and what it may touch while looking.
#[derive(Clone, Debug)]
pub struct Env {
    pub home: PathBuf,
    /// Without it, locations macOS guards with a prompt are skipped entirely,
    /// so a scan never raises a queue of permission dialogs.
    pub full_disk_access: bool,
    /// System locations and system tools (`/Library`, `simctl`, `docker`,
    /// `tmutil`). Off in tests, which scan a throwaway home only.
    pub system: bool,
}

impl Env {
    pub fn current() -> Self {
        let home = shell::home();
        Self {
            full_disk_access: has_full_disk_access(&home),
            home,
            system: true,
        }
    }

    pub fn home(&self, relative: &str) -> PathBuf {
        self.home.join(relative)
    }

    /// Folders macOS asks about one dialog at a time without Full Disk Access.
    fn protected_locations(&self) -> Vec<PathBuf> {
        [
            "Library/Containers",
            "Library/Group Containers",
            "Desktop",
            "Documents",
            "Downloads",
            "Music",
            "Pictures",
            "Movies",
        ]
        .iter()
        .map(|p| self.home(p))
        .collect()
    }

    fn is_protected(&self, path: &Path) -> bool {
        !self.full_disk_access
            && self
                .protected_locations()
                .iter()
                .any(|p| path == p || path.starts_with(p))
    }
}

/// `~/Library/Safari` refuses a listing without Full Disk Access instead of
/// prompting, so asking costs nothing and warns nobody.
pub fn has_full_disk_access(home: &Path) -> bool {
    std::env::var_os("SYSDATA_NO_FULL_DISK_ACCESS").is_none()
        && std::fs::read_dir(home.join("Library/Safari")).is_ok()
}

/// An item for a location on disk, or `None` when it is missing or under `min_bytes`.
#[allow(clippy::too_many_arguments)]
fn dir_item(
    id: impl Into<String>,
    category: Category,
    name: impl Into<String>,
    detail: impl Into<String>,
    path: &Path,
    safety: Safety,
    action: Action,
    min_bytes: u64,
) -> Option<Item> {
    if !size::exists(path) {
        return None;
    }
    let measured = size::measure(path);
    if measured.bytes < min_bytes.max(1) {
        return None;
    }
    let mut item = Item::new(
        id,
        category,
        name,
        detail,
        Some(measured.bytes),
        safety,
        action,
    );
    item.reveal = Some(path.to_path_buf());
    item.modified = measured.modified();
    Some(item)
}

fn by_size(mut items: Vec<Item>) -> Vec<Item> {
    items.sort_by(|a, b| b.bytes().cmp(&a.bytes()).then_with(|| a.id.cmp(&b.id)));
    items
}

fn name_of(path: &Path) -> String {
    path.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn stem_of(path: &Path) -> String {
    path.file_stem()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn extension_is(path: &Path, extension: &str) -> bool {
    path.extension().is_some_and(|e| e == extension)
}

/// `~/…` for paths in the home folder.
pub fn abbreviate(path: &Path, home: &Path) -> String {
    match path.strip_prefix(home) {
        Ok(rest) if rest.as_os_str().is_empty() => "~".into(),
        Ok(rest) => format!("~/{}", rest.display()),
        Err(_) => path.display().to_string(),
    }
}

type Probe = fn(&Env) -> Vec<Item>;

/// Every probe, in display order.
const PROBES: [(&str, Probe); 18] = [
    ("snapshots", developer::snapshots),
    ("simulators", developer::simulators),
    ("runtimes", developer::runtimes),
    ("xcode", developer::xcode),
    ("packages", packages::probe),
    ("tools", catch_all::developer_tools),
    ("logs", system::logs),
    ("temp", system::temp),
    ("docker", system::docker),
    ("vms", media::virtual_machines),
    ("trash", system::trash),
    ("backups", user_data::backups),
    ("shared", user_data::shared),
    ("android", user_data::android),
    ("app caches", media::app_caches),
    ("app data", user_data::app_data),
    ("projects", user_data::projects),
    ("system", system::misc),
];

pub enum Progress {
    /// One probe finished with these items.
    Batch {
        items: Vec<Item>,
        finished: usize,
        total: usize,
    },
    /// Every probe is done; the catch-all walk has started.
    CatchAll,
}

/// Runs every probe in parallel, streaming each batch as it lands, then the
/// catch-all for anything large that no probe explained. Returns everything.
pub fn scan(env: &Env, on_progress: &(dyn Fn(Progress) + Sync)) -> Vec<Item> {
    size::prepare();
    size::remember();
    let finished = AtomicUsize::new(0);
    // One thread per probe: several wait on child processes (simctl, docker),
    // which must not hold rayon's walker threads while they wait.
    let found: Vec<Item> = std::thread::scope(|scope| {
        // `SYSDATA_ONLY=projects` runs one probe, for tuning with SYSDATA_TRACE.
        let only = std::env::var("SYSDATA_ONLY").ok();
        let running: Vec<_> = PROBES
            .iter()
            .filter(|(name, _)| only.as_deref().is_none_or(|o| o == *name))
            .map(|(name, probe)| {
                let finished = &finished;
                scope.spawn(move || {
                    let started = std::time::Instant::now();
                    let items = probe(env);
                    trace(name, started);
                    on_progress(Progress::Batch {
                        items: items.clone(),
                        finished: finished.fetch_add(1, Ordering::Relaxed) + 1,
                        total: PROBES.len(),
                    });
                    items
                })
            })
            .collect();
        running
            .into_iter()
            .flat_map(|probe| probe.join().unwrap_or_default())
            .collect()
    });
    on_progress(Progress::CatchAll);
    let started = std::time::Instant::now();
    let claimed: Vec<PathBuf> = found.iter().flat_map(Item::claimed_paths).collect();
    let known = size::remembered();
    let mut all = found;
    all.extend(catch_all::large_folders(env, &claimed, &known));
    trace("catch-all", started);
    all
}

/// `SYSDATA_TRACE=1` prints how long each probe took, for tuning.
fn trace(name: &str, started: std::time::Instant) {
    if std::env::var_os("SYSDATA_TRACE").is_some() {
        eprintln!("{:>8.0?} {name}", started.elapsed());
    }
}

#[cfg(test)]
mod tests;
