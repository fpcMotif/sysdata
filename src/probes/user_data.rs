//! Device backups, shared folders, Android, per-app data and project build folders.
use super::{Env, MB, abbreviate, by_size, dir_item, extension_is, name_of, stem_of};
use crate::{
    item::{Action, Category, Item, Safety},
    mac::{self, PlistValue},
    size,
};
use rayon::prelude::*;
use std::{
    collections::HashSet,
    path::{Path, PathBuf},
    time::SystemTime,
};

pub fn backups(env: &Env) -> Vec<Item> {
    let root = env.home("Library/Application Support/MobileSync/Backup");
    size::subdirectories(&root)
        .par_iter()
        .filter_map(|backup| {
            let values = mac::plist_values(
                &backup.join("Info.plist"),
                &["Device Name", "Product Version", "Last Backup Date"],
            );
            let mut values = values.into_iter();
            let text = |v: Option<Option<PlistValue>>| match v.flatten() {
                Some(PlistValue::Text(t)) => Some(t),
                _ => None,
            };
            let device = text(values.next()).unwrap_or_else(|| name_of(backup));
            let version = text(values.next()).unwrap_or_else(|| "unknown iOS".into());
            let date = match values.next().flatten() {
                Some(PlistValue::Date(d)) => mac::date(d),
                _ => "an unknown date".into(),
            };
            dir_item(
                format!("backup-{}", name_of(backup)),
                Category::Backups,
                device,
                format!("{version}, last backed up {date}. The only local copy of this device unless iCloud has one too."),
                backup,
                Safety::Review,
                Action::RemovePaths(vec![backup.clone()]),
                1,
            )
        })
        .collect()
}

pub fn shared(env: &Env) -> Vec<Item> {
    if !env.system {
        return Vec::new();
    }
    let mut candidates = Vec::new();
    for entry in size::subdirectories(Path::new("/Users/Shared")) {
        let app_support = entry.join("Application Support");
        // Apps such as BlueStacks keep whole disks under Shared/Library/Application Support.
        if name_of(&entry) == "Library" && size::exists(&app_support) {
            candidates.extend(size::subdirectories(&app_support));
        } else {
            candidates.push(entry);
        }
    }
    let mut items: Vec<Item> = candidates
        .par_iter()
        .filter_map(|candidate| {
            dir_item(
                format!("shared-{}", candidate.display()),
                Category::Shared,
                name_of(candidate),
                "In /Users/Shared, which Storage settings counts as Other Users & Shared. Owned by the app that made it.",
                candidate,
                Safety::Review,
                Action::RemovePaths(vec![candidate.clone()]),
                20 * MB,
            )
        })
        .collect();

    let me = name_of(&env.home);
    for account in size::subdirectories(Path::new("/Users")) {
        let name = name_of(&account);
        if name == me || name == "Shared" {
            continue;
        }
        let bytes = size::measure(&account).bytes;
        let mut item = Item::new(
            format!("shared-user-{name}"),
            Category::Shared,
            format!("Account: {name}"),
            if bytes > 0 {
                "Another user's home folder."
            } else {
                "Another user's home folder, not readable from this account."
            },
            (bytes > 0).then_some(bytes),
            Safety::Manual,
            Action::Manual(
                "System Settings > Users & Groups > select the account > remove.".into(),
            ),
        );
        item.reveal = Some(account);
        items.push(item);
    }
    by_size(items)
}

pub fn android(env: &Env) -> Vec<Item> {
    let mut jobs: Vec<(String, String, String, PathBuf, Safety, Action, u64)> = Vec::new();
    let avd_root = env.home(".android/avd");
    for avd in size::subdirectories(&avd_root) {
        if extension_is(&avd, "avd") {
            let ini = avd_root.join(format!("{}.ini", stem_of(&avd)));
            jobs.push((
                format!("android-avd-{}", name_of(&avd)),
                format!("Emulator: {}", stem_of(&avd)),
                "Android Virtual Device disk. Everything installed on this emulator is lost."
                    .into(),
                avd.clone(),
                Safety::Review,
                Action::RemovePaths(vec![avd, ini]),
                1,
            ));
        }
    }
    let sdk = std::env::var_os("ANDROID_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| env.home("Library/Android/sdk"));
    for image in size::subdirectories(&sdk.join("system-images")) {
        jobs.push((
            format!("android-image-{}", name_of(&image)),
            format!("System image {}", name_of(&image)),
            "Emulator OS image. Emulators built on it stop booting; SDK Manager reinstalls it."
                .into(),
            image.clone(),
            Safety::Review,
            Action::RemovePaths(vec![image]),
            1,
        ));
    }
    for (folder, label) in [
        ("platforms", "Platform"),
        ("build-tools", "Build tools"),
        ("ndk", "NDK"),
        ("cmake", "CMake"),
        ("sources", "Sources"),
    ] {
        for version in size::subdirectories(&sdk.join(folder)) {
            jobs.push((
                format!("android-{folder}-{}", name_of(&version)),
                format!("{label} {}", name_of(&version)),
                "Android SDK component. SDK Manager reinstalls it.".into(),
                version.clone(),
                Safety::Review,
                Action::RemovePaths(vec![version]),
                20 * MB,
            ));
        }
    }
    for folder in [
        "emulator",
        "cmdline-tools",
        "platform-tools",
        "extras",
        "skins",
        "licenses",
    ] {
        let path = sdk.join(folder);
        jobs.push((
            format!("android-{folder}"),
            format!("SDK {folder}"),
            "Android SDK component. SDK Manager reinstalls it.".into(),
            path.clone(),
            Safety::Review,
            Action::RemovePaths(vec![path]),
            20 * MB,
        ));
    }
    for cache in size::subdirectories(&env.home("Library/Caches/Google")) {
        let name = name_of(&cache);
        if name.starts_with("AndroidStudio") {
            jobs.push((
                format!("android-studio-cache-{name}"),
                format!("{name} caches"),
                "IDE indexes. Rebuilt at the next launch.".into(),
                cache.clone(),
                Safety::Safe,
                Action::EmptyDirectories(vec![cache]),
                10 * MB,
            ));
        }
    }
    by_size(
        jobs.into_par_iter()
            .filter_map(|(id, name, detail, path, safety, action, min)| {
                dir_item(
                    id,
                    Category::Android,
                    name,
                    detail,
                    &path,
                    safety,
                    action,
                    min,
                )
            })
            .collect(),
    )
}

const APP_THRESHOLD: u64 = 200 * MB;
const CACHE_THRESHOLD: u64 = 100 * MB;

pub fn app_data(env: &Env) -> Vec<Item> {
    let mut items = Vec::new();
    let claude_vm = env.home("Library/Application Support/Claude/vm_bundles");
    items.extend(dir_item(
        "app-claude-vm",
        Category::Apps,
        "Claude local VM bundles",
        "Virtual machine images for Claude's local sandbox. Downloaded again when the feature runs.",
        &claude_vm,
        Safety::Review,
        Action::RemovePaths(vec![claude_vm.clone()]),
        APP_THRESHOLD,
    ));
    let chrome_model = env.home("Library/Application Support/Google/Chrome/OptGuideOnDeviceModel");
    items.extend(dir_item(
        "app-chrome-model",
        Category::Apps,
        "Chrome on-device AI model",
        "Gemini Nano. Disable chrome://flags/#optimization-guide-on-device-model first, or Chrome downloads it again.",
        &chrome_model,
        Safety::Review,
        Action::RemovePaths(vec![chrome_model.clone()]),
        APP_THRESHOLD,
    ));

    let covered_support: HashSet<&str> = [
        "MobileSync",
        "Claude",
        "Google",
        "Slack",
        "discord",
        "zoom.us",
        "Spotify",
        "Adobe",
        "Steam",
        "Epic",
    ]
    .into();
    items.extend(scan_children(
        &env.home("Library/Application Support"),
        "app-support",
        "App data",
        "Deleting it resets that app.",
        Safety::Review,
        APP_THRESHOLD,
        &covered_support,
        false,
    ));
    // Each container is its own permission prompt until Full Disk Access exists.
    if env.full_disk_access {
        let covered_containers: HashSet<&str> = [
            "com.microsoft.teams2",
            "com.apple.Safari",
            "com.apple.photolibraryd",
            "com.utmapp.UTM",
            "com.apple.mail",
            "com.docker.docker",
        ]
        .into();
        items.extend(scan_children(
            &env.home("Library/Containers"),
            "app-container",
            "Sandboxed app data",
            "Deleting it resets that app.",
            Safety::Review,
            APP_THRESHOLD,
            &covered_containers,
            true,
        ));
        items.extend(scan_children(
            &env.home("Library/Group Containers"),
            "app-group",
            "App group data",
            "Shared by an app and its extensions. Deleting it resets them.",
            Safety::Review,
            APP_THRESHOLD,
            &HashSet::new(),
            true,
        ));
    }
    let covered_caches: HashSet<&str> = [
        "Homebrew",
        "Yarn",
        "pip",
        "CocoaPods",
        "org.swift.swiftpm",
        "go-build",
        "Cypress",
        "ms-playwright",
        "com.apple.dt.Xcode",
        "Google",
        "Adobe",
        "com.apple.QuickLook.thumbnailcache",
    ]
    .into();
    items.extend(scan_children(
        &env.home("Library/Caches"),
        "app-cache",
        "Cache",
        "The app rebuilds it.",
        Safety::Safe,
        CACHE_THRESHOLD,
        &covered_caches,
        false,
    ));
    // Google nests Chrome and Android Studio caches one level down; Android owns the latter.
    let google = env.home("Library/Caches/Google");
    let android_studio: Vec<String> = size::subdirectories(&google)
        .iter()
        .map(|p| name_of(p))
        .filter(|n| n.starts_with("AndroidStudio"))
        .collect();
    items.extend(scan_children(
        &google,
        "app-cache-google",
        "Cache",
        "The app rebuilds it.",
        Safety::Safe,
        CACHE_THRESHOLD,
        &android_studio.iter().map(String::as_str).collect(),
        false,
    ));
    by_size(items)
}

/// Apple's own containers are listed with their size but never offered:
/// they hold the local copy of what syncs with iCloud.
#[allow(clippy::too_many_arguments)]
fn scan_children(
    root: &Path,
    prefix: &str,
    label: &str,
    detail: &str,
    safety: Safety,
    threshold: u64,
    skipping: &HashSet<&str>,
    protects_apple_data: bool,
) -> Vec<Item> {
    size::subdirectories(root)
        .par_iter()
        .filter(|entry| !skipping.contains(name_of(entry).as_str()))
        .filter_map(|entry| {
            let name = name_of(entry);
            let apple = protects_apple_data && is_apple_owned(&name);
            dir_item(
                format!("{prefix}-{name}"),
                Category::Apps,
                format!("{label}: {name}"),
                if apple {
                    "Apple app data, partly synced with iCloud. This app does not delete it."
                } else {
                    detail
                },
                entry,
                if apple { Safety::Manual } else { safety },
                if apple {
                    Action::Manual("This is Apple's own app data, and part of it is the local copy of what syncs with iCloud. Clear it from the app that owns it, or see System Settings > General > Storage.".into())
                } else {
                    Action::RemovePaths(vec![entry.clone()])
                },
                threshold,
            )
        })
        .collect()
}

pub fn is_apple_owned(name: &str) -> bool {
    name.starts_with("com.apple.") || name.starts_with("group.com.apple.")
}

/// Build output folders and what recreates each. A folder named `target`
/// or `.venv` counts only beside the manifest that proves what made it.
const TARGETS: [(&str, &str, Option<&str>); 15] = [
    ("node_modules", "npm install", None),
    (".build", "swift build", None),
    ("Pods", "pod install", None),
    ("DerivedData", "the next build", None),
    (".next", "next build", None),
    (".nuxt", "nuxt build", None),
    (".svelte-kit", "vite build", None),
    (".astro", "astro build", None),
    (".angular", "the next build", None),
    (".turbo", "the next build", None),
    (".parcel-cache", "the next build", None),
    (".expo", "the next build", None),
    ("target", "cargo build", Some("Cargo.toml")),
    (".venv", "uv sync", Some("pyproject.toml")),
    (".gradle", "the next Gradle build", Some("settings.gradle")),
];
/// Code folders outside Documents. Their build folders are listed one by one,
/// and the catch-all never offers the folders themselves: they hold source.
pub const PROJECT_ROOTS_OUTSIDE_DOCUMENTS: [&str; 8] = [
    "Developer",
    "Projects",
    "Projeler",
    "devv",
    "dev",
    "src",
    "code",
    "repos",
];
const PROJECT_ROOTS: [&str; 10] = [
    "Desktop",
    "Documents",
    "Developer",
    "Projects",
    "Projeler",
    "devv",
    "dev",
    "src",
    "code",
    "repos",
];
const PROJECT_DEPTH: usize = 4;
const PROJECT_THRESHOLD: u64 = 30 * MB;

pub fn projects(env: &Env) -> Vec<Item> {
    let roots: Vec<PathBuf> = PROJECT_ROOTS
        .iter()
        .map(|r| env.home(r))
        .filter(|r| !env.is_protected(r) && size::is_dir(r) && !size::is_symlink(r))
        .collect();
    let found: Vec<(PathBuf, &str)> = roots
        .par_iter()
        .flat_map_iter(|root| {
            let mut found = Vec::new();
            collect(root, 0, &mut found);
            found
        })
        .collect();
    by_size(
        found
            .par_iter()
            .filter_map(|(folder, tool)| {
                let project = folder.parent()?;
                let mut item = dir_item(
                    format!("project-{}", folder.display()),
                    Category::Projects,
                    format!("{}/{}", name_of(project), name_of(folder)),
                    format!("{}. Recreated by {tool}.", abbreviate(project, &env.home)),
                    folder,
                    Safety::Review,
                    Action::RemovePaths(vec![folder.clone()]),
                    PROJECT_THRESHOLD,
                )?;
                // Dated by the project's own files: node_modules is as old as
                // the last install, which says nothing about the code beside it.
                item.modified = last_activity(project).or(item.modified);
                Some(item)
            })
            .collect(),
    )
}

fn collect(dir: &Path, depth: usize, found: &mut Vec<(PathBuf, &'static str)>) {
    if depth > PROJECT_DEPTH {
        return;
    }
    for child in size::subdirectories(dir) {
        let name = name_of(&child);
        if let Some((_, tool, manifest)) = TARGETS.iter().find(|(target, _, _)| *target == name)
            && manifest.is_none_or(|m| size::exists(&dir.join(m)))
        {
            found.push((child, tool));
            continue;
        }
        if !name.starts_with('.') && name != "Library" {
            collect(&child, depth + 1, found);
        }
    }
}

/// Newest file a person changed in a project: build folders and git's object
/// store are left out, git's index is counted. Bounded so a huge repository
/// costs no more than a small one.
pub fn last_activity(project: &Path) -> Option<SystemTime> {
    let mut newest = std::fs::metadata(project.join(".git/index"))
        .and_then(|m| m.modified())
        .ok();
    let mut queue = vec![project.to_path_buf()];
    let mut seen = 0;
    while let Some(dir) = queue.pop() {
        for child in size::children(&dir) {
            seen += 1;
            if seen > 20_000 {
                return newest;
            }
            let name = name_of(&child.path);
            if name == ".git" || TARGETS.iter().any(|(t, _, _)| *t == name) {
                continue;
            }
            match child.kind {
                size::Kind::Dir => queue.push(child.path),
                size::Kind::File => {
                    let modified = SystemTime::UNIX_EPOCH
                        + std::time::Duration::from_secs(child.modified.max(0) as u64);
                    newest = newest.max(Some(modified));
                }
                size::Kind::Other => {}
            }
        }
    }
    newest
}
