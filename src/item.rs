//! What a scan finds: one row per reclaimable (or explainable) location.
use std::{
    path::{Path, PathBuf},
    time::{Duration, SystemTime},
};

/// Groups in the list, in their fixed display order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Category {
    Snapshots,
    Simulators,
    Runtimes,
    Xcode,
    Packages,
    Tools,
    Logs,
    Temp,
    Docker,
    Vms,
    Trash,
    Backups,
    Shared,
    Android,
    Apps,
    Projects,
    System,
    Other,
}

impl Category {
    pub const ALL: [Category; 18] = [
        Category::Snapshots,
        Category::Simulators,
        Category::Runtimes,
        Category::Xcode,
        Category::Packages,
        Category::Tools,
        Category::Logs,
        Category::Temp,
        Category::Docker,
        Category::Vms,
        Category::Trash,
        Category::Backups,
        Category::Shared,
        Category::Android,
        Category::Apps,
        Category::Projects,
        Category::System,
        Category::Other,
    ];

    /// Stable machine name, shared with the `--json` output.
    pub fn key(self) -> &'static str {
        match self {
            Category::Snapshots => "snapshots",
            Category::Simulators => "simulators",
            Category::Runtimes => "runtimes",
            Category::Xcode => "xcode",
            Category::Packages => "packages",
            Category::Tools => "tools",
            Category::Logs => "logs",
            Category::Temp => "temp",
            Category::Docker => "docker",
            Category::Vms => "vms",
            Category::Trash => "trash",
            Category::Backups => "backups",
            Category::Shared => "shared",
            Category::Android => "android",
            Category::Apps => "apps",
            Category::Projects => "projects",
            Category::System => "system",
            Category::Other => "other",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Category::Snapshots => "Time Machine snapshots",
            Category::Simulators => "Simulator devices",
            Category::Runtimes => "Simulator runtimes",
            Category::Xcode => "Xcode",
            Category::Packages => "Package managers",
            Category::Tools => "Developer tool data",
            Category::Logs => "Logs & diagnostics",
            Category::Temp => "Temporary files",
            Category::Docker => "Docker",
            Category::Vms => "Virtual machines",
            Category::Trash => "Trash",
            Category::Backups => "iOS device backups",
            Category::Shared => "Shared & other users",
            Category::Android => "Android",
            Category::Apps => "App data & caches",
            Category::Projects => "Project build folders",
            Category::System => "System",
            Category::Other => "Other large folders",
        }
    }
}

/// How much thought a deletion needs.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Safety {
    /// The owning tool or macOS rebuilds it on demand.
    Safe,
    /// Deletable, but something real is lost: a device, a login, a download.
    Review,
    /// This app never deletes it; the row shows how instead.
    Manual,
}

impl Safety {
    pub fn label(self) -> &'static str {
        match self {
            Safety::Safe => "Safe",
            Safety::Review => "Review",
            Safety::Manual => "Manual",
        }
    }

    pub fn key(self) -> &'static str {
        match self {
            Safety::Safe => "safe",
            Safety::Review => "review",
            Safety::Manual => "manual",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Action {
    RemovePaths(Vec<PathBuf>),
    /// Deletes every entry inside each directory and keeps the directories.
    EmptyDirectories(Vec<PathBuf>),
    /// Deletes regular files not modified for `days`, then folders that left empty.
    PruneOlderThan {
        dir: PathBuf,
        days: u32,
    },
    Command {
        program: PathBuf,
        args: Vec<String>,
    },
    /// A shell script run as root behind the administrator prompt.
    Privileged(String),
    /// Files a booted simulator has mapped cannot be deleted, not even by root.
    ShutdownSimulators,
    EraseSimulator(String),
    /// Runs in order and stops at the first failure.
    Steps(Vec<Action>),
    Manual(String),
}

impl Action {
    pub fn is_manual(&self) -> bool {
        matches!(self, Action::Manual(_))
    }

    pub fn manual_instructions(&self) -> Option<&str> {
        match self {
            Action::Manual(text) => Some(text),
            _ => None,
        }
    }

    /// Exactly what runs, one line per operation, shown before anything does.
    pub fn plan(&self) -> Vec<String> {
        match self {
            Action::RemovePaths(paths) => paths
                .iter()
                .map(|p| format!("Delete {}", p.display()))
                .collect(),
            Action::EmptyDirectories(paths) => paths
                .iter()
                .map(|p| format!("Delete everything inside {}", p.display()))
                .collect(),
            Action::PruneOlderThan { dir, days } => vec![format!(
                "Delete files older than {days} days in {}",
                dir.display()
            )],
            Action::Command { program, args } => {
                vec![command_line(program, args)]
            }
            Action::Privileged(script) => vec![format!("As administrator: {script}")],
            Action::ShutdownSimulators => vec!["Shut every simulator down first".into()],
            Action::EraseSimulator(udid) => vec![
                format!("/usr/bin/xcrun simctl shutdown {udid}"),
                format!("/usr/bin/xcrun simctl erase {udid}"),
            ],
            Action::Steps(steps) => steps.iter().flat_map(Action::plan).collect(),
            Action::Manual(_) => Vec::new(),
        }
    }

    /// Filesystem locations this action deletes from.
    pub fn paths(&self) -> Vec<&Path> {
        match self {
            Action::RemovePaths(paths) | Action::EmptyDirectories(paths) => {
                paths.iter().map(PathBuf::as_path).collect()
            }
            Action::PruneOlderThan { dir, .. } => vec![dir.as_path()],
            Action::Steps(steps) => steps.iter().flat_map(Action::paths).collect(),
            _ => Vec::new(),
        }
    }

    /// Whether running it shows the administrator prompt: a script always
    /// does, and so does deleting a path this user cannot unlink.
    pub fn needs_admin(&self) -> bool {
        match self {
            Action::Privileged(_) => true,
            Action::Steps(steps) => steps.iter().any(Action::needs_admin),
            _ => self.paths().iter().any(|p| needs_root(p)),
        }
    }

    pub fn shuts_down_simulators(&self) -> bool {
        match self {
            Action::ShutdownSimulators | Action::EraseSimulator(_) => true,
            Action::Steps(steps) => steps.iter().any(Action::shuts_down_simulators),
            _ => false,
        }
    }
}

pub fn command_line(program: &Path, args: &[String]) -> String {
    std::iter::once(program.display().to_string())
        .chain(args.iter().cloned())
        .collect::<Vec<_>>()
        .join(" ")
}

/// Exists, and the current user cannot unlink it from its parent.
pub fn needs_root(path: &Path) -> bool {
    use std::os::unix::ffi::OsStrExt;
    if std::fs::symlink_metadata(path).is_err() {
        return false;
    }
    let Some(parent) = path.parent() else {
        return true;
    };
    let Ok(parent) = std::ffi::CString::new(parent.as_os_str().as_bytes()) else {
        return true;
    };
    // SAFETY: a valid NUL-terminated path.
    unsafe { libc::access(parent.as_ptr(), libc::W_OK) != 0 }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Item {
    pub id: String,
    pub category: Category,
    pub name: String,
    pub detail: String,
    /// `None` when the size cannot be measured, such as APFS snapshots.
    pub size: Option<u64>,
    pub safety: Safety,
    pub action: Action,
    pub reveal: Option<PathBuf>,
    /// Newest modification under the location. `None` means not measured, not "never used".
    pub modified: Option<SystemTime>,
    /// Locations counted here beyond the action and reveal paths.
    pub also_claims: Vec<PathBuf>,
}

impl Item {
    pub fn new(
        id: impl Into<String>,
        category: Category,
        name: impl Into<String>,
        detail: impl Into<String>,
        size: Option<u64>,
        safety: Safety,
        action: Action,
    ) -> Self {
        Self {
            id: id.into(),
            category,
            name: name.into(),
            detail: detail.into(),
            size,
            safety,
            action,
            reveal: None,
            modified: None,
            also_claims: Vec::new(),
        }
    }

    pub fn bytes(&self) -> u64 {
        self.size.unwrap_or(0)
    }

    pub fn idle_days(&self, now: SystemTime) -> Option<u64> {
        let modified = self.modified?;
        Some(
            now.duration_since(modified)
                .unwrap_or(Duration::ZERO)
                .as_secs()
                / 86_400,
        )
    }

    /// "3 months idle", or `None` below a fortnight, where age says nothing.
    pub fn idle_label(&self, now: SystemTime) -> Option<String> {
        let days = self.idle_days(now)?;
        if days < 14 {
            return None;
        }
        let (count, unit) = if days >= 365 {
            (days / 365, "year")
        } else if days >= 30 {
            (days / 30, "month")
        } else {
            (days, "day")
        };
        Some(format!(
            "{count} {unit}{} idle",
            if count == 1 { "" } else { "s" }
        ))
    }

    /// Every location this item accounts for, so the catch-all skips it.
    pub fn claimed_paths(&self) -> Vec<PathBuf> {
        let mut paths: Vec<PathBuf> = self
            .action
            .paths()
            .into_iter()
            .map(Path::to_path_buf)
            .collect();
        paths.extend(self.reveal.iter().cloned());
        paths.extend(self.also_claims.iter().cloned());
        paths
    }

    /// Matches the name, the detail, or the category title, so "simulator"
    /// keeps a whole group rather than only rows that repeat the word.
    pub fn matches(&self, filter: &str) -> bool {
        let needle = filter.trim().to_lowercase();
        needle.is_empty()
            || self.name.to_lowercase().contains(&needle)
            || self.detail.to_lowercase().contains(&needle)
            || self.category.title().to_lowercase().contains(&needle)
    }
}

/// Finder-style decimal sizes: whole KB, one decimal for MB, two for GB and
/// up, trailing zeros dropped: "598 KB", "33.6 MB", "1.6 GB", "205.94 GB".
pub fn format_bytes(bytes: u64) -> String {
    const UNITS: [(&str, usize); 5] = [("KB", 0), ("MB", 1), ("GB", 2), ("TB", 2), ("PB", 2)];
    if bytes < 1_000 {
        return format!("{bytes} bytes");
    }
    let mut value = bytes as f64 / 1_000.;
    let mut unit = 0;
    loop {
        let (name, decimals) = UNITS[unit];
        let shown = format!("{value:.decimals$}");
        // 999.99 MB rounds to 1000.0 MB; Finder says 1 GB.
        if shown.parse::<f64>().unwrap_or(value) >= 1_000. && unit + 1 < UNITS.len() {
            value /= 1_000.;
            unit += 1;
            continue;
        }
        return format!("{} {name}", trim_zeros(&shown));
    }
}

fn trim_zeros(text: &str) -> &str {
    if text.contains('.') {
        text.trim_end_matches('0').trim_end_matches('.')
    } else {
        text
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_like_finder() {
        assert_eq!(format_bytes(0), "0 bytes");
        assert_eq!(format_bytes(598_016), "598 KB");
        assert_eq!(format_bytes(33_600_000), "33.6 MB");
        assert_eq!(format_bytes(910_200_000), "910.2 MB");
        assert_eq!(format_bytes(1_600_000_000), "1.6 GB");
        assert_eq!(format_bytes(78_410_000_000), "78.41 GB");
        assert_eq!(format_bytes(205_940_000_000), "205.94 GB");
        assert_eq!(format_bytes(202_000_000), "202 MB");
        assert_eq!(format_bytes(999_990_000), "1 GB");
    }

    #[test]
    fn idle_label_needs_a_fortnight() {
        let now = SystemTime::UNIX_EPOCH + Duration::from_secs(400 * 86_400);
        let mut item = Item::new(
            "x",
            Category::Other,
            "x",
            "",
            Some(1),
            Safety::Review,
            Action::Manual(String::new()),
        );
        item.modified = Some(now - Duration::from_secs(13 * 86_400));
        assert_eq!(item.idle_label(now), None);
        item.modified = Some(now - Duration::from_secs(20 * 86_400));
        assert_eq!(item.idle_label(now).as_deref(), Some("20 days idle"));
        item.modified = Some(now - Duration::from_secs(65 * 86_400));
        assert_eq!(item.idle_label(now).as_deref(), Some("2 months idle"));
        item.modified = Some(now - Duration::from_secs(370 * 86_400));
        assert_eq!(item.idle_label(now).as_deref(), Some("1 year idle"));
    }

    #[test]
    fn plan_lists_every_operation() {
        let action = Action::Steps(vec![
            Action::ShutdownSimulators,
            Action::EmptyDirectories(vec!["/a".into(), "/b".into()]),
        ]);
        assert_eq!(
            action.plan(),
            [
                "Shut every simulator down first",
                "Delete everything inside /a",
                "Delete everything inside /b"
            ]
        );
        assert!(action.shuts_down_simulators());
    }
}
