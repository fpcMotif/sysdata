//! Logs, temporary files, Docker, the Trash and macOS's own locations.
use super::{Env, MB, dir_item, name_of, stem_of};
use crate::{
    item::{Action, Category, Item, Safety},
    shell, size,
};
use rayon::prelude::*;
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    time::{Duration, SystemTime},
};

pub fn logs(env: &Env) -> Vec<Item> {
    let mut items = Vec::new();
    if env.system {
        // The unified log store must be cleared with `log erase`; deleting its
        // files by hand corrupts it.
        let diagnostics = PathBuf::from("/private/var/db/diagnostics");
        let uuidtext = PathBuf::from("/private/var/db/uuidtext");
        let store = size::measure(&diagnostics).bytes + size::measure(&uuidtext).bytes;
        if store > 0 {
            let mut item = Item::new(
                "log-unified",
                Category::Logs,
                "Unified log store",
                "The persisted system log in /private/var/db/diagnostics. Cleared with `log erase --all`.",
                Some(store),
                Safety::Safe,
                Action::Privileged("log erase --all".into()),
            );
            item.reveal = Some(diagnostics);
            item.also_claims = vec![uuidtext];
            items.push(item);
        }
        items.extend(dir_item(
            "log-system-reports",
            Category::Logs,
            "System crash reports",
            "Crash and hang reports for system processes.",
            Path::new("/Library/Logs/DiagnosticReports"),
            Safety::Safe,
            Action::Privileged("rm -rf /Library/Logs/DiagnosticReports/*".into()),
            1,
        ));
        items.extend(dir_item(
            "log-asl",
            Category::Logs,
            "Legacy ASL logs",
            "Old-style system logs in /private/var/log/asl.",
            Path::new("/private/var/log/asl"),
            Safety::Safe,
            Action::Privileged("rm -f /private/var/log/asl/*.asl".into()),
            1,
        ));
    }
    let user_logs = env.home("Library/Logs");
    items.extend(dir_item(
        "log-user",
        Category::Logs,
        "User app logs",
        "~/Library/Logs, including your own crash reports and simulator logs.",
        &user_logs,
        Safety::Safe,
        Action::EmptyDirectories(vec![user_logs.clone()]),
        1,
    ));
    items
}

/// macOS sweeps the per-user cache and temp folders only on reboot or under
/// disk pressure. Files touched in the last few days are kept.
pub fn temp(env: &Env) -> Vec<Item> {
    const KEEP_DAYS: u32 = 3;
    const USER_TEMP_DIR: i32 = 65_537;
    const USER_CACHE_DIR: i32 = 65_538;
    if !env.system {
        return Vec::new();
    }
    let cutoff = SystemTime::now() - Duration::from_secs(u64::from(KEEP_DAYS) * 86_400);
    [
        ("temp-cache", "User cache folder", USER_CACHE_DIR),
        ("temp-tmp", "User temp folder", USER_TEMP_DIR),
    ]
    .into_iter()
    .filter_map(|(id, name, key)| {
        let dir = confstr(key)?;
        let measured = size::measure_older_than(&dir, cutoff);
        if measured.bytes < MB {
            return None;
        }
        let mut item = Item::new(
            id,
            Category::Temp,
            name,
            format!(
                "{}. Only files older than {KEEP_DAYS} days are removed.",
                dir.display()
            ),
            Some(measured.bytes),
            Safety::Safe,
            Action::PruneOlderThan {
                dir: dir.clone(),
                days: KEEP_DAYS,
            },
        );
        item.reveal = Some(dir);
        item.modified = measured.modified();
        Some(item)
    })
    .collect()
}

fn confstr(name: i32) -> Option<PathBuf> {
    let mut buffer = vec![0u8; libc::PATH_MAX as usize];
    // SAFETY: the buffer and its length are passed together.
    let len = unsafe { libc::confstr(name, buffer.as_mut_ptr().cast(), buffer.len()) };
    if len == 0 || len > buffer.len() {
        return None;
    }
    buffer.truncate(len - 1);
    let path = PathBuf::from(String::from_utf8(buffer).ok()?);
    Some(std::fs::canonicalize(&path).unwrap_or(path))
}

pub fn docker(env: &Env) -> Vec<Item> {
    if !env.system {
        return Vec::new();
    }
    let vms = env.home("Library/Containers/com.docker.docker/Data/vms");
    let usage = shell::which("docker").and_then(|docker| {
        shell::probe(&docker, &["info"])?;
        let df = shell::probe(&docker, &["system", "df", "--format", "{{json .}}"])?;
        Some((docker, df))
    });
    let Some((docker, df)) = usage else {
        if env.is_protected(&vms) {
            return Vec::new();
        }
        return dir_item(
            "docker-vm",
            Category::Docker,
            "Docker disk image",
            "Docker is not running, so it cannot prune right now.",
            &vms,
            Safety::Manual,
            Action::Manual(
                "Start Docker Desktop, then:\ndocker system prune -f\ndocker builder prune -f"
                    .into(),
            ),
            100 * MB,
        )
        .into_iter()
        .collect();
    };
    docker_items(&df, &docker, size::exists(&vms).then_some(vms))
}

/// One row per kind of thing Docker can let go of, each sized by what its
/// own prune command frees. Volumes, where databases live, stay separate.
pub fn docker_items(df: &str, docker: &Path, reveal: Option<PathBuf>) -> Vec<Item> {
    /// `docker system df` type, id, name, detail, safety, prune arguments.
    type Kind = (
        &'static str,
        &'static str,
        &'static str,
        &'static str,
        Safety,
        &'static [&'static str],
    );
    let reclaimable = reclaimable_by_type(df);
    let kinds: [Kind; 4] = [
        (
            "Build Cache",
            "docker-build-cache",
            "Docker build cache",
            "Layers kept to speed up the next build. `docker builder prune -a`; the next build recreates them.",
            Safety::Safe,
            &["builder", "prune", "-a", "-f"],
        ),
        (
            "Images",
            "docker-images",
            "Unused Docker images",
            "Images no container uses. `docker image prune -a`; pulled again when something runs them.",
            Safety::Review,
            &["image", "prune", "-a", "-f"],
        ),
        (
            "Containers",
            "docker-containers",
            "Stopped Docker containers",
            "Stopped containers and anything written inside them. `docker container prune`.",
            Safety::Review,
            &["container", "prune", "-f"],
        ),
        (
            "Local Volumes",
            "docker-volumes",
            "Unused Docker volumes",
            "Volumes no container is attached to. Databases often keep data here. `docker volume prune -a`.",
            Safety::Review,
            &["volume", "prune", "-a", "-f"],
        ),
    ];
    kinds
        .iter()
        .filter_map(|(kind, id, name, detail, safety, args)| {
            let bytes = *reclaimable.get(*kind)?;
            if bytes == 0 {
                return None;
            }
            let mut item = Item::new(
                *id,
                Category::Docker,
                *name,
                *detail,
                Some(bytes),
                *safety,
                Action::Command {
                    program: docker.to_path_buf(),
                    args: args.iter().map(|a| a.to_string()).collect(),
                },
            );
            item.reveal = reveal.clone();
            Some(item)
        })
        .collect()
}

/// `docker system df --format '{{json .}}'` prints one object per line.
fn reclaimable_by_type(output: &str) -> HashMap<String, u64> {
    let mut result = HashMap::new();
    for line in output.lines() {
        let Ok(row) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        if let (Some(kind), Some(text)) = (row["Type"].as_str(), row["Reclaimable"].as_str()) {
            *result.entry(kind.to_string()).or_default() += parse_docker_size(text);
        }
    }
    result
}

/// "1.211GB (45%)" → bytes.
pub fn parse_docker_size(text: &str) -> u64 {
    let text = text.trim();
    let number_end = text
        .find(|c: char| !(c.is_ascii_digit() || c == '.'))
        .unwrap_or(text.len());
    let Ok(value) = text[..number_end].parse::<f64>() else {
        return 0;
    };
    let unit: String = text[number_end..]
        .chars()
        .take_while(char::is_ascii_alphabetic)
        .collect::<String>()
        .to_uppercase();
    let multiplier = match unit.as_str() {
        "KB" => 1e3,
        "MB" => 1e6,
        "GB" => 1e9,
        "TB" => 1e12,
        _ => 1.,
    };
    (value * multiplier) as u64
}

pub fn trash(env: &Env) -> Vec<Item> {
    let trash = env.home(".Trash");
    dir_item(
        "trash",
        Category::Trash,
        "Trash",
        "Items waiting in the Trash. Emptying it is permanent.",
        &trash,
        Safety::Safe,
        Action::EmptyDirectories(vec![trash.clone()]),
        1,
    )
    .into_iter()
    .collect()
}

pub fn misc(env: &Env) -> Vec<Item> {
    let mut items = Vec::new();
    for folder in size::subdirectories(&env.home("Library/iTunes")) {
        let name = name_of(&folder);
        if name.ends_with("Software Updates") {
            items.extend(dir_item(
                format!("sys-ipsw-{name}"),
                Category::System,
                name,
                "Downloaded device firmware (.ipsw).",
                &folder,
                Safety::Safe,
                Action::EmptyDirectories(vec![folder.clone()]),
                1,
            ));
        }
    }
    let mail = env.home("Library/Containers/com.apple.mail/Data/Library/Mail Downloads");
    if !env.is_protected(&mail) {
        items.extend(dir_item(
            "sys-mail-downloads",
            Category::System,
            "Mail attachment downloads",
            "Attachments opened from Mail. The originals stay in the messages.",
            &mail,
            Safety::Safe,
            Action::EmptyDirectories(vec![mail.clone()]),
            MB,
        ));
    }
    items.extend(dir_item(
        "sys-icloud",
        Category::System,
        "iCloud Drive local copies",
        "Files kept on this Mac for offline use.",
        &env.home("Library/Mobile Documents"),
        Safety::Manual,
        Action::Manual("System Settings > Apple Account > iCloud > Drive > turn on Optimize Mac Storage,\nor right-click a folder in Finder > Remove Download.".into()),
        500 * MB,
    ));
    items.extend(dir_item(
        "sys-daemon-containers",
        Category::System,
        "macOS service data",
        "Containers of macOS's own background services. This app does not delete them.",
        &env.home("Library/Daemon Containers"),
        Safety::Manual,
        Action::Manual("macOS manages these. If one keeps growing, restart the Mac or update macOS; deleting them can break the service that owns them.".into()),
        500 * MB,
    ));
    if env.system {
        items.extend(system_wide(env));
    }
    items
}

fn system_wide(_env: &Env) -> Vec<Item> {
    let mut items = Vec::new();
    for installer in size::subdirectories(Path::new("/Applications")) {
        let name = name_of(&installer);
        if name.starts_with("Install macOS") && name.ends_with(".app") {
            items.extend(dir_item(
                format!("sys-installer-{name}"),
                Category::System,
                stem_of(&installer),
                "A downloaded macOS installer. Software Update can download it again.",
                &installer,
                Safety::Review,
                Action::RemovePaths(vec![installer.clone()]),
                1,
            ));
        }
    }

    // Named one by one, and only entries macOS lets anyone remove: data
    // vaults and restricted entries refuse even root.
    let caches = PathBuf::from("/Library/Caches");
    let removable: Vec<PathBuf> = size::children(&caches)
        .into_iter()
        .map(|child| child.path)
        .filter(|path| !size::is_protected(path))
        .collect();
    let measured: Vec<size::Measurement> = removable.par_iter().map(|p| size::measure(p)).collect();
    let bytes: u64 = measured.iter().map(|m| m.bytes).sum();
    if !removable.is_empty() && bytes >= 10 * MB {
        let mut item = Item::new(
            "sys-library-caches",
            Category::System,
            "System-wide caches",
            "/Library/Caches. The daemons that own them rebuild them.",
            Some(bytes),
            Safety::Safe,
            Action::Privileged(format!(
                "rm -rf {}",
                removable
                    .iter()
                    .map(|p| shell::quote(p))
                    .collect::<Vec<_>>()
                    .join(" ")
            )),
        );
        item.reveal = Some(caches);
        item.modified = measured
            .iter()
            .filter_map(|m| m.newest)
            .max()
            .map(|secs| SystemTime::UNIX_EPOCH + Duration::from_secs(secs.max(0) as u64));
        items.push(item);
    }

    let app_support: Vec<Item> = size::subdirectories(Path::new("/Library/Application Support"))
        .par_iter()
        .filter_map(|entry| {
            dir_item(
                format!("sys-app-support-{}", name_of(entry)),
                Category::System,
                format!("System app data: {}", name_of(entry)),
                "/Library/Application Support, shared by every user. Prefer the app's own uninstaller.",
                entry,
                Safety::Review,
                Action::RemovePaths(vec![entry.clone()]),
                200 * MB,
            )
        })
        .collect();
    items.extend(app_support);

    // Redundant only when an Xcode is installed and is the selected developer directory.
    let tools = PathBuf::from("/Library/Developer/CommandLineTools");
    let active = super::developer::active_developer_dir();
    let has_xcode = size::subdirectories(Path::new("/Applications"))
        .iter()
        .any(|app| {
            let name = name_of(app);
            name.starts_with("Xcode") && name.ends_with(".app")
        })
        && active.is_some_and(|dir| !dir.starts_with("/Library/Developer/CommandLineTools"));
    items.extend(dir_item(
        "sys-clt",
        Category::System,
        "Command Line Tools",
        if has_xcode {
            "Xcode is installed and already provides these tools. `xcode-select --install` brings them back."
        } else {
            "Compilers and SDKs for the terminal. Needed while Xcode is not installed."
        },
        &tools,
        if has_xcode { Safety::Review } else { Safety::Manual },
        if has_xcode {
            Action::Privileged("rm -rf /Library/Developer/CommandLineTools".into())
        } else {
            Action::Manual("Keep them, or remove with:\nsudo rm -rf /Library/Developer/CommandLineTools".into())
        },
        1,
    ));
    items.extend(dir_item(
        "sys-cryptex",
        Category::System,
        "macOS cryptexes",
        "Sealed system components (Safari, dyld caches) under /private/var/run. Part of macOS.",
        Path::new("/private/var/run/com.apple.security.cryptexd"),
        Safety::Manual,
        Action::Manual("Managed by macOS. It cannot be removed.".into()),
        100 * MB,
    ));
    items.push(Item::new(
        "sys-spotlight",
        Category::System,
        "Spotlight index",
        "/.Spotlight-V100 is readable only by root, so its size is unknown. Rebuilding drops stale entries.",
        None,
        Safety::Manual,
        Action::Manual("sudo mdutil -E /".into()),
    ));
    items.extend(dir_item(
        "sys-vm",
        Category::System,
        "Swap and sleep image",
        "Managed by the kernel. It shrinks after a restart.",
        Path::new("/private/var/vm"),
        Safety::Manual,
        Action::Manual("Restart the Mac. To drop the sleep image for good:\nsudo pmset -a hibernatemode 0\nsudo rm /private/var/vm/sleepimage".into()),
        100 * MB,
    ));
    items
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn docker_sizes_parse() {
        assert_eq!(parse_docker_size("1.211GB (45%)"), 1_211_000_000);
        assert_eq!(parse_docker_size("512MB"), 512_000_000);
        assert_eq!(parse_docker_size("0B (0%)"), 0);
        let df = r#"{"Type":"Images","Reclaimable":"1.5GB (45%)"}
{"Type":"Build Cache","Reclaimable":"300MB"}
{"Type":"Local Volumes","Reclaimable":"0B (0%)"}"#;
        let items = docker_items(df, Path::new("/usr/local/bin/docker"), None);
        let ids: Vec<_> = items.iter().map(|i| i.id.as_str()).collect();
        assert_eq!(ids, ["docker-build-cache", "docker-images"]);
        assert_eq!(items[1].size, Some(1_500_000_000));
    }
}
