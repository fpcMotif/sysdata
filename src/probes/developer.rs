//! Time Machine snapshots, simulators, simulator runtimes and Xcode.
use super::{Env, MB, dir_item, name_of};
use crate::{
    item::{Action, Category, Item, Safety},
    mac, shell, size,
};
use serde_json::Value;
use std::{
    collections::HashSet,
    path::{Path, PathBuf},
};

const XCRUN: &str = "/usr/bin/xcrun";

/// The selected developer directory, or `None` when there is none. Asked
/// before any `xcrun` call, because `xcrun` without tools opens an install dialog.
pub(super) fn active_developer_dir() -> Option<String> {
    static ACTIVE: std::sync::Mutex<Option<(std::time::Instant, Option<String>)>> =
        std::sync::Mutex::new(None);
    // Three probes ask during one scan; a rescan a minute later asks again.
    let mut cached = ACTIVE.lock().expect("developer dir");
    if let Some((at, answer)) = cached.as_ref()
        && at.elapsed().as_secs() < 30
    {
        return answer.clone();
    }
    let answer = shell::probe(Path::new("/usr/bin/xcode-select"), &["-p"])
        .map(|out| out.trim().to_string())
        .filter(|path| !path.is_empty() && size::exists(Path::new(path)));
    *cached = Some((std::time::Instant::now(), answer.clone()));
    answer
}

fn simctl_json(args: &[&str]) -> Option<Value> {
    let mut full = vec!["simctl"];
    full.extend_from_slice(args);
    serde_json::from_str(&shell::probe(Path::new(XCRUN), &full)?).ok()
}

/// APFS keeps hourly Time Machine snapshots on the boot volume. Finder counts
/// their blocks as System Data, and APFS does not report their size.
pub fn snapshots(env: &Env) -> Vec<Item> {
    if !env.system {
        return Vec::new();
    }
    let Some(listing) = shell::probe(Path::new("/usr/bin/tmutil"), &["listlocalsnapshots", "/"])
    else {
        return Vec::new();
    };
    let count = listing
        .lines()
        .filter(|line| line.contains("com.apple.TimeMachine"))
        .count();
    if count == 0 {
        return Vec::new();
    }
    vec![Item::new(
        "snapshots",
        Category::Snapshots,
        format!(
            "{count} local snapshot{}",
            if count == 1 { "" } else { "s" }
        ),
        "APFS snapshots Time Machine keeps between backups. APFS does not report their size; the next backup makes a new one.",
        None,
        Safety::Safe,
        Action::Privileged(
            "tmutil deletelocalsnapshots / ; tmutil thinlocalsnapshots / 9999999999999 4".into(),
        ),
    )]
}

pub fn simulators(env: &Env) -> Vec<Item> {
    let root = env.home("Library/Developer/CoreSimulator");
    if !env.system || !size::exists(&root) || active_developer_dir().is_none() {
        return Vec::new();
    }
    let mut items = Vec::new();
    let mut caches: Vec<PathBuf> = Vec::new();
    let mut cache_bytes = 0;
    let mut devices_counted = 0;

    let listing = simctl_json(&["list", "devices", "-j"]);
    let by_runtime = listing
        .as_ref()
        .and_then(|json| json["devices"].as_object());
    for (runtime, devices) in by_runtime.into_iter().flatten() {
        let runtime = runtime.replace("com.apple.CoreSimulator.SimRuntime.", "");
        for device in devices.as_array().into_iter().flatten() {
            let (Some(name), Some(udid), Some(data)) = (
                device["name"].as_str(),
                device["udid"].as_str(),
                device["dataPath"].as_str(),
            ) else {
                continue;
            };
            let data = PathBuf::from(data);
            let data_size = device["dataPathSize"].as_u64();
            if !device["isAvailable"].as_bool().unwrap_or(false) {
                let mut item = Item::new(
                    format!("sim-unavailable-{udid}"),
                    Category::Simulators,
                    format!("Unavailable: {name}"),
                    format!(
                        "Its runtime ({runtime}) is no longer installed, so this device cannot boot again."
                    ),
                    data_size,
                    Safety::Safe,
                    Action::Command {
                        program: XCRUN.into(),
                        args: vec!["simctl".into(), "delete".into(), udid.into()],
                    },
                );
                item.reveal = Some(data);
                items.push(item);
                continue;
            }
            devices_counted += 1;
            let device_caches: Vec<PathBuf> = [data.join("Library/Caches"), data.join("tmp")]
                .into_iter()
                .filter(|p| size::exists(p))
                .collect();
            let device_cache_bytes: u64 =
                device_caches.iter().map(|p| size::measure(p).bytes).sum();
            cache_bytes += device_cache_bytes;
            caches.extend(device_caches);
            // Its caches are their own row; the erase row counts the rest.
            let erase_bytes = data_size.map(|b| b.saturating_sub(device_cache_bytes));
            if erase_bytes.is_some_and(|b| b < 100 * MB) {
                continue;
            }
            let mut item = Item::new(
                format!("sim-erase-{udid}"),
                Category::Simulators,
                format!("Erase {name}"),
                format!(
                    "Resets this {runtime} simulator to factory state. Installed apps and their data are lost."
                ),
                erase_bytes,
                Safety::Review,
                Action::EraseSimulator(udid.into()),
            );
            item.reveal = Some(data);
            items.push(item);
        }
    }

    let dyld = root.join("Caches/dyld");
    if size::exists(&dyld) {
        cache_bytes += size::measure(&dyld).bytes;
        caches.push(dyld);
    }
    if !caches.is_empty() && cache_bytes > 0 {
        let mut item = Item::new(
            "sim-caches",
            Category::Simulators,
            format!("Device caches ({devices_counted} devices)"),
            "Each simulator's Caches and tmp, plus the shared dyld cache. Rebuilt at the next boot.",
            Some(cache_bytes),
            Safety::Safe,
            Action::Steps(vec![
                Action::ShutdownSimulators,
                Action::EmptyDirectories(caches),
            ]),
        );
        item.reveal = Some(root.join("Devices"));
        items.insert(0, item);
    }

    // macOS refuses to unlink anything here, root included. It goes when its runtime goes.
    items.extend(dir_item(
        "sim-system-dyld",
        Category::Simulators,
        "System dyld cache",
        "One shared cache per installed runtime, built by CoreSimulator and protected by macOS.",
        Path::new("/Library/Developer/CoreSimulator/Caches/dyld"),
        Safety::Manual,
        Action::Manual(
            "Delete the runtime it belongs to (Simulator runtimes), or:\nxcrun simctl runtime delete <UUID>\nThe cache is rebuilt when the runtime is installed again.".into(),
        ),
        50 * MB,
    ));
    items
}

pub fn runtimes(env: &Env) -> Vec<Item> {
    if !env.system || active_developer_dir().is_none() {
        return Vec::new();
    }
    let Some(listing) = simctl_json(&["runtime", "list", "-j"]) else {
        return Vec::new();
    };
    // Which runtime each SDK builds against, and which runtimes still carry a
    // device. Missing either answer means "unused" is never claimed.
    let chosen: Option<HashSet<String>> =
        simctl_json(&["runtime", "match", "list", "-j"]).map(|m| {
            m.as_object()
                .into_iter()
                .flatten()
                .filter_map(|(_, v)| v["chosenRuntimeBuild"].as_str().map(String::from))
                .collect()
        });
    let devices = simctl_json(&["list", "devices", "-j"]);
    let devices = devices.as_ref().and_then(|d| d["devices"].as_object());

    let mut items: Vec<Item> = listing
        .as_object()
        .into_iter()
        .flatten()
        .filter_map(|(identifier, runtime)| {
            if !runtime["deletable"].as_bool().unwrap_or(false) {
                return None;
            }
            let version = runtime["version"].as_str()?;
            let build = runtime["build"].as_str()?;
            let platform = platform_name(runtime["platformIdentifier"].as_str().unwrap_or(""));
            let last_used = runtime["lastUsedAt"].as_str();
            let unused = match (&chosen, devices, runtime["runtimeIdentifier"].as_str()) {
                (Some(chosen), Some(devices), Some(id)) if !chosen.contains(build) => {
                    devices.get(id).and_then(Value::as_array).is_none_or(Vec::is_empty)
                }
                _ => false,
            };
            let used = last_used
                .map(|t| format!("Last used {}. ", &t[..t.len().min(10)]))
                .unwrap_or_default();
            let mut item = Item::new(
                format!("runtime-{identifier}"),
                Category::Runtimes,
                if unused {
                    format!("{platform} {version} ({build}) · unused")
                } else {
                    format!("{platform} {version} ({build})")
                },
                if unused {
                    format!("{used}No installed Xcode builds against it and no simulator uses it. Xcode > Settings > Components can download it again.")
                } else {
                    format!("{used}Simulators on this runtime stop working. Xcode > Settings > Components can download it again.")
                },
                runtime["sizeBytes"].as_u64(),
                Safety::Review,
                Action::Command {
                    program: XCRUN.into(),
                    args: vec![
                        "simctl".into(),
                        "runtime".into(),
                        "delete".into(),
                        identifier.clone(),
                    ],
                },
            );
            item.reveal = runtime["path"].as_str().map(PathBuf::from);
            item.modified = last_used.and_then(mac::parse_iso8601);
            Some(item)
        })
        .collect();
    items.sort_by_key(|i| std::cmp::Reverse(i.bytes()));
    items
}

fn platform_name(identifier: &str) -> String {
    match identifier {
        "com.apple.platform.iphonesimulator" => "iOS".into(),
        "com.apple.platform.watchsimulator" => "watchOS".into(),
        "com.apple.platform.appletvsimulator" => "tvOS".into(),
        "com.apple.platform.xrsimulator" => "visionOS".into(),
        other => other.rsplit('.').next().unwrap_or(other).into(),
    }
}

pub fn xcode(env: &Env) -> Vec<Item> {
    let root = env.home("Library/Developer/Xcode");
    let entries: [(&str, &str, &str, Safety); 7] = [
        (
            "DerivedData",
            "DerivedData",
            "Build products and indexes. Xcode rebuilds them on the next build.",
            Safety::Safe,
        ),
        (
            "iOS DeviceSupport",
            "iOS DeviceSupport",
            "Symbols copied from iPhones and iPads. Copied again on the next connection.",
            Safety::Safe,
        ),
        (
            "watchOS DeviceSupport",
            "watchOS DeviceSupport",
            "Symbols copied from Apple Watches.",
            Safety::Safe,
        ),
        (
            "tvOS DeviceSupport",
            "tvOS DeviceSupport",
            "Symbols copied from Apple TVs.",
            Safety::Safe,
        ),
        (
            "visionOS DeviceSupport",
            "visionOS DeviceSupport",
            "Symbols copied from Vision Pro.",
            Safety::Safe,
        ),
        (
            "Preview simulators",
            "UserData/Previews/Simulator Devices",
            "Devices SwiftUI previews start. Created again on demand.",
            Safety::Safe,
        ),
        (
            "Archives",
            "Archives",
            "Release archives with dSYMs. Keep any build whose crashes you still symbolicate.",
            Safety::Review,
        ),
    ];
    let mut items: Vec<Item> = entries
        .iter()
        .filter_map(|(name, relative, detail, safety)| {
            let path = root.join(relative);
            dir_item(
                format!("xcode-{relative}"),
                Category::Xcode,
                *name,
                *detail,
                &path,
                *safety,
                Action::EmptyDirectories(vec![path.clone()]),
                1,
            )
        })
        .collect();
    let caches = env.home("Library/Caches/com.apple.dt.Xcode");
    items.extend(dir_item(
        "xcode-caches",
        Category::Xcode,
        "Xcode caches",
        "Documentation and download caches.",
        &caches,
        Safety::Safe,
        Action::EmptyDirectories(vec![caches.clone()]),
        MB,
    ));

    // Without an answer there is no telling which Xcode is in use, and
    // offering the active one is the mistake to avoid.
    if !env.system {
        return items;
    }
    let Some(active) = active_developer_dir() else {
        return items;
    };
    for app in size::subdirectories(Path::new("/Applications")) {
        let name = name_of(&app);
        if name.starts_with("Xcode")
            && name.ends_with(".app")
            && !active.starts_with(&*app.to_string_lossy())
        {
            items.extend(dir_item(
                format!("xcode-app-{name}"),
                Category::Xcode,
                format!("Inactive {name}"),
                format!("Not the selected developer directory ({active})."),
                &app,
                Safety::Review,
                Action::RemovePaths(vec![app.clone()]),
                1,
            ));
        }
    }
    items
}
