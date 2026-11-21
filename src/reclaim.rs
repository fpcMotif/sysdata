//! Every filesystem change the app makes goes through here.
//!
//! A path must pass the guard before anything touches it. Review items go to
//! the Trash, and if the Trash refuses them they are reported, never deleted
//! outright in its place.
use crate::{
    item::{Action, Item, Safety, command_line, needs_root},
    mac, shell, size,
};
use rayon::prelude::*;
use std::{
    collections::HashSet,
    path::{Component, Path, PathBuf},
    time::{Duration, SystemTime},
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Failure {
    /// The person dismissed the administrator prompt.
    Cancelled,
    /// A run nobody is watching may not raise a password prompt.
    NeedsAdmin,
    /// The guard refused a path.
    Refused(String),
    Failed(String),
}

impl Failure {
    pub fn message(&self) -> String {
        match self {
            Failure::Cancelled => "Cancelled at the administrator prompt.".into(),
            Failure::NeedsAdmin => {
                "It needs an administrator password, so it was left for you to delete from the list.".into()
            }
            Failure::Refused(reason) | Failure::Failed(reason) => reason.clone(),
        }
    }
}

pub struct Options {
    pub home: PathBuf,
    /// Also send Safe items to the Trash, so a delete can be undone.
    pub safe_to_trash: bool,
    pub allow_admin: bool,
}

/// Paths nothing may delete, whatever an item claims. Their children may go.
pub fn protected(path: &Path, home: &Path) -> bool {
    const SYSTEM: [&str; 16] = [
        "/",
        "/System",
        "/Library",
        "/Applications",
        "/Users",
        "/Users/Shared",
        "/private",
        "/private/var",
        "/private/etc",
        "/usr",
        "/usr/local",
        "/opt",
        "/opt/homebrew",
        "/bin",
        "/sbin",
        "/Volumes",
    ];
    const HOME: [&str; 22] = [
        "",
        "Library",
        "Documents",
        "Desktop",
        "Downloads",
        "Pictures",
        "Movies",
        "Music",
        "Public",
        "Applications",
        "Developer",
        ".Trash",
        ".ssh",
        ".gnupg",
        "Library/Keychains",
        "Library/Preferences",
        "Library/Caches",
        "Library/Application Support",
        "Library/Containers",
        "Library/Group Containers",
        "Library/Mobile Documents",
        "Library/CloudStorage",
    ];
    SYSTEM.iter().any(|p| path == Path::new(p))
        || HOME.iter().any(|p| {
            path == if p.is_empty() {
                home.to_path_buf()
            } else {
                home.join(p)
            }
        })
}

/// The ladder every path descends before it is trashed or deleted.
pub fn check(path: &Path, home: &Path) -> Result<(), String> {
    let refuse = |why: &str| Err(format!("Refused {}: {why}.", path.display()));
    if !path.is_absolute() {
        return refuse("not an absolute path");
    }
    if path
        .components()
        .any(|c| matches!(c, Component::ParentDir | Component::CurDir))
    {
        return refuse("it contains . or ..");
    }
    if protected(path, home) {
        return refuse("it is a folder macOS or you depend on");
    }
    if std::env::current_exe().is_ok_and(|exe| exe.starts_with(path)) {
        return refuse("this app is running from inside it");
    }
    // A symlinked ancestor must not smuggle the target somewhere else.
    if let (Some(parent), Some(name)) = (path.parent(), path.file_name())
        && let Ok(real_parent) = std::fs::canonicalize(parent)
    {
        let real = real_parent.join(name);
        if protected(&real, home)
            || std::fs::canonicalize(home).is_ok_and(|real_home| protected(&real, &real_home))
        {
            return refuse("it resolves to a protected folder");
        }
        if let (Some(dev), Some(parent_dev)) = (size::device(path), size::device(&real_parent))
            && dev != parent_dev
            && !size::is_symlink(path)
        {
            return refuse("it is a mounted volume");
        }
    }
    Ok(())
}

/// Runs one action. Returns whether anything went to the Trash rather than
/// being deleted, because the Trash frees nothing until it is emptied.
pub fn perform(action: &Action, to_trash: bool, options: &Options) -> Result<bool, Failure> {
    match action {
        Action::RemovePaths(paths) => remove(paths, to_trash, options),
        Action::EmptyDirectories(dirs) => {
            let mut trashed = false;
            for dir in dirs {
                if !size::exists(dir) {
                    continue;
                }
                if size::is_symlink(dir) {
                    return Err(Failure::Refused(format!(
                        "Refused {}: it is a symlink, and emptying it would reach elsewhere.",
                        dir.display()
                    )));
                }
                let children: Vec<PathBuf> =
                    size::children(dir).into_iter().map(|c| c.path).collect();
                trashed |= remove(&children, to_trash, options)?;
            }
            Ok(trashed)
        }
        Action::PruneOlderThan { dir, days } => {
            check(dir, &options.home).map_err(Failure::Refused)?;
            prune(dir, *days);
            Ok(false)
        }
        Action::Command { program, args } => {
            let args: Vec<&str> = args.iter().map(String::as_str).collect();
            let line = command_line(
                program,
                &args.iter().map(|a| a.to_string()).collect::<Vec<_>>(),
            );
            let out = shell::run(program, &args, true, shell::CLEAN_TIMEOUT)
                .map_err(|e| Failure::Failed(format!("{line}: {e}")))?;
            if out.ok() {
                Ok(false)
            } else {
                Err(Failure::Failed(shell::describe_failure(&line, &out)))
            }
        }
        Action::Privileged(script) => {
            privileged(script, options)?;
            Ok(false)
        }
        Action::ShutdownSimulators => {
            let _ = shell::run(
                Path::new("/usr/bin/xcrun"),
                &["simctl", "shutdown", "all"],
                true,
                shell::PROBE_TIMEOUT,
            );
            Ok(false)
        }
        Action::EraseSimulator(udid) => {
            let xcrun = Path::new("/usr/bin/xcrun");
            let run = |args: &[&str]| shell::run(xcrun, args, true, shell::CLEAN_TIMEOUT);
            // A booted device refuses to erase; shut it down and retry once.
            let _ = run(&["simctl", "shutdown", udid]);
            let mut out = run(&["simctl", "erase", udid]);
            if !out.as_ref().is_ok_and(shell::Output::ok) {
                let _ = run(&["simctl", "shutdown", "all"]);
                out = run(&["simctl", "erase", udid]);
            }
            match out {
                Ok(out) if out.ok() => Ok(false),
                Ok(out) if out.text.contains("Booted") => Err(Failure::Failed(
                    "The simulator is still running. Quit Simulator and Xcode, then try again."
                        .into(),
                )),
                Ok(out) => Err(Failure::Failed(shell::describe_failure(
                    &format!("xcrun simctl erase {udid}"),
                    &out,
                ))),
                Err(e) => Err(Failure::Failed(e.to_string())),
            }
        }
        Action::Steps(steps) => {
            let mut trashed = false;
            for step in steps {
                trashed |= perform(step, to_trash, options)?;
            }
            Ok(trashed)
        }
        Action::Manual(_) => Ok(false),
    }
}

fn privileged(script: &str, options: &Options) -> Result<(), Failure> {
    if !options.allow_admin {
        return Err(Failure::NeedsAdmin);
    }
    let out = shell::run_privileged(script).map_err(|e| Failure::Failed(e.to_string()))?;
    if out.ok() {
        Ok(())
    } else if shell::was_cancelled(&out) {
        Err(Failure::Cancelled)
    } else {
        Err(Failure::Failed(shell::describe_failure(script, &out)))
    }
}

fn remove(paths: &[PathBuf], to_trash: bool, options: &Options) -> Result<bool, Failure> {
    let present: Vec<&PathBuf> = paths
        .iter()
        .filter(|p| std::fs::symlink_metadata(p).is_ok())
        .collect();
    // Every path is screened before any is touched.
    for path in &present {
        check(path, &options.home).map_err(Failure::Refused)?;
    }
    let mut as_root = Vec::new();
    let mut trashed = false;
    for path in present {
        if needs_root(path) {
            as_root.push(path.clone());
        } else if to_trash {
            mac::trash(path).map_err(|e| {
                Failure::Failed(format!(
                    "{} could not go to the Trash ({e}), so it was left in place.",
                    path.display()
                ))
            })?;
            trashed = true;
        } else if remove_tree(path).is_err() {
            as_root.push(path.clone());
        }
    }
    if !as_root.is_empty() {
        if to_trash {
            return Err(Failure::Failed(format!(
                "{} belongs to another user and cannot go to your Trash, so it was left in place.",
                as_root[0].display()
            )));
        }
        let script = format!(
            "rm -rf {}",
            as_root
                .iter()
                .map(|p| shell::quote(p))
                .collect::<Vec<_>>()
                .join(" ")
        );
        privileged(&script, options)?;
    }
    Ok(trashed)
}

/// Deletes a tree with its top-level entries removed in parallel.
fn remove_tree(path: &Path) -> std::io::Result<()> {
    let meta = std::fs::symlink_metadata(path)?;
    if !meta.is_dir() {
        return std::fs::remove_file(path);
    }
    let children: Vec<PathBuf> = size::children(path).into_iter().map(|c| c.path).collect();
    children.par_iter().try_for_each(|child| {
        if std::fs::symlink_metadata(child)?.is_dir() {
            std::fs::remove_dir_all(child)
        } else {
            std::fs::remove_file(child)
        }
    })?;
    std::fs::remove_dir(path)
}

/// Deletes regular files not modified for `days`, then only the folders this
/// pass emptied. Sockets, pipes and links are never touched: running apps
/// keep live ones in these folders, and they hold no data.
pub fn prune(dir: &Path, days: u32) {
    let cutoff = SystemTime::now() - Duration::from_secs(u64::from(days) * 86_400);
    let cutoff = cutoff
        .duration_since(SystemTime::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64);
    let mut emptied: HashSet<PathBuf> = HashSet::new();
    let mut queue = vec![dir.to_path_buf()];
    while let Some(current) = queue.pop() {
        for child in size::children(&current) {
            match child.kind {
                size::Kind::Dir => queue.push(child.path),
                size::Kind::File
                    if child.modified < cutoff && std::fs::remove_file(&child.path).is_ok() =>
                {
                    emptied.insert(current.clone());
                }
                _ => {}
            }
        }
    }
    // Deepest first, so a parent holding only an emptied folder goes too.
    let mut candidates: Vec<PathBuf> = emptied.into_iter().collect();
    while let Some(deepest) = candidates
        .iter()
        .max_by_key(|p| p.components().count())
        .cloned()
    {
        candidates.retain(|p| p != &deepest);
        if deepest != dir
            && deepest.starts_with(dir)
            && std::fs::read_dir(&deepest).is_ok_and(|mut d| d.next().is_none())
            && std::fs::remove_dir(&deepest).is_ok()
            && let Some(parent) = deepest.parent()
        {
            candidates.push(parent.to_path_buf());
        }
    }
}

/// What one batch reports as it goes.
#[derive(Clone, Debug, PartialEq)]
pub enum Event {
    Busy(Vec<String>),
    /// Removed. `freed` is what the disk gained, or the item's size when the
    /// disk under-reports it; zero for anything moved to the Trash.
    Done {
        ids: Vec<String>,
        trashed: bool,
        freed: u64,
    },
    Failed {
        ids: Vec<String>,
        message: String,
    },
    /// The person dismissed the password prompt; these were left alone.
    Stopped {
        deleted: usize,
        remaining: Vec<String>,
    },
}

/// Review items go to the Trash; Safe items are deleted unless the person
/// asked for the Trash for those too.
pub fn goes_to_trash(item: &Item, safe_to_trash: bool) -> bool {
    if item.category == crate::item::Category::Trash {
        return false;
    }
    match item.safety {
        Safety::Review => true,
        Safety::Safe => safe_to_trash,
        Safety::Manual => false,
    }
}

/// Runs a batch in order. Several administrator scripts share one prompt,
/// and each script's failure is reported against its own item.
pub fn run_batch(items: &[Item], options: &Options, report: &mut dyn FnMut(Event)) {
    let runnable: Vec<&Item> = items.iter().filter(|i| !i.action.is_manual()).collect();
    let (scripts, mut direct): (Vec<&Item>, Vec<&Item>) = runnable
        .into_iter()
        .partition(|i| matches!(i.action, Action::Privileged(_)));
    if scripts.len() == 1 || !options.allow_admin {
        direct.splice(0..0, scripts.iter().copied());
    } else if scripts.len() > 1 {
        let ids: Vec<String> = scripts.iter().map(|i| i.id.clone()).collect();
        report(Event::Busy(ids.clone()));
        let bodies: Vec<&str> = scripts
            .iter()
            .map(|i| match &i.action {
                Action::Privileged(s) => s.as_str(),
                _ => unreachable!("partitioned on Privileged"),
            })
            .collect();
        let before = mac::disk_space().free;
        match privileged(&combined_script(&bodies), options) {
            Ok(()) => report(done(&scripts, false, before)),
            Err(Failure::Cancelled) => {
                report(Event::Stopped {
                    deleted: 0,
                    remaining: ids
                        .into_iter()
                        .chain(direct.iter().map(|i| i.id.clone()))
                        .collect(),
                });
                return;
            }
            Err(failure) => {
                let message = failure.message();
                let failed =
                    failed_indices(&message).unwrap_or_else(|| (0..scripts.len()).collect());
                let good: Vec<&Item> = (0..scripts.len())
                    .filter(|n| !failed.contains(n))
                    .map(|n| scripts[n])
                    .collect();
                if !good.is_empty() {
                    report(done(&good, false, before));
                }
                report(Event::Failed {
                    ids: (0..scripts.len())
                        .filter(|n| failed.contains(n))
                        .map(|n| scripts[n].id.clone())
                        .collect(),
                    message: without_marker(&message),
                });
            }
        }
    }
    for (index, item) in direct.iter().enumerate() {
        report(Event::Busy(vec![item.id.clone()]));
        let before = mac::disk_space().free;
        match perform(
            &item.action,
            goes_to_trash(item, options.safe_to_trash),
            options,
        ) {
            Ok(trashed) => report(done(&[item], trashed, before)),
            Err(Failure::Cancelled) => {
                report(Event::Stopped {
                    deleted: index,
                    remaining: direct[index..].iter().map(|i| i.id.clone()).collect(),
                });
                return;
            }
            Err(failure) => report(Event::Failed {
                ids: vec![item.id.clone()],
                message: format!("{}: {}", item.name, failure.message()),
            }),
        }
    }
}

fn done(items: &[&Item], trashed: bool, free_before: u64) -> Event {
    let gained = mac::disk_space().free.saturating_sub(free_before);
    let expected: u64 = items.iter().map(|i| i.bytes()).sum();
    Event::Done {
        ids: items.iter().map(|i| i.id.clone()).collect(),
        trashed,
        // A trashed item is renamed on the same volume; crediting its size
        // would claim room the disk does not have.
        freed: if trashed {
            gained
        } else {
            gained.max(expected)
        },
    }
}

const MARKER: &str = "SYSDATA_FAILED:";

/// Each script in its own subshell, its failure noted by position.
pub fn combined_script(scripts: &[&str]) -> String {
    let mut steps = vec!["failed=''".to_string()];
    steps.extend(
        scripts
            .iter()
            .enumerate()
            .map(|(n, s)| format!("( {s} ) || failed=\"$failed {n}\"")),
    );
    steps.push(format!(
        "[ -z \"$failed\" ] || {{ echo \"{MARKER}$failed\" >&2; exit 1; }}"
    ));
    steps.join(" ; ")
}

/// Positions the combined script reported as failed, or `None` when it never got that far.
pub fn failed_indices(output: &str) -> Option<HashSet<usize>> {
    let at = output.find(MARKER)? + MARKER.len();
    let line: String = output[at..]
        .chars()
        .take_while(|c| *c != '\n' && *c != '\r' && *c != '"')
        .collect();
    Some(
        line.split_whitespace()
            .filter_map(|n| n.parse().ok())
            .collect(),
    )
}

fn without_marker(text: &str) -> String {
    text.lines()
        .filter(|l| !l.contains(MARKER))
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_guard_refuses_what_matters() {
        let home = Path::new("/Users/someone");
        for path in [
            "/",
            "/Users/someone",
            "/Users/someone/Library",
            "/Users/someone/Documents",
            "/Applications",
            "/Users/someone/.ssh",
        ] {
            assert!(
                check(Path::new(path), home).is_err(),
                "{path} must be refused"
            );
        }
        assert!(check(Path::new("relative/path"), home).is_err());
        assert!(
            check(
                Path::new("/Users/someone/Library/Caches/../Documents"),
                home
            )
            .is_err()
        );
        assert!(check(Path::new("/Users/someone/Library/Caches/com.example"), home).is_ok());
    }

    #[test]
    fn combined_script_reports_failures_by_position() {
        let script = combined_script(&["true", "false", "exit 3"]);
        let out = shell::run(
            Path::new("/bin/sh"),
            &["-c", &script],
            true,
            Duration::from_secs(5),
        )
        .unwrap();
        assert_eq!(out.status, 1);
        assert_eq!(failed_indices(&out.text), Some([1, 2].into()));
        assert_eq!(failed_indices("osascript said nothing useful"), None);
        assert_eq!(
            without_marker("rm: x: denied\nSYSDATA_FAILED: 1"),
            "rm: x: denied"
        );
    }
}
