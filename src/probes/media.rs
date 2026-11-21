//! Virtual machine disks and the big caches media, chat and creative apps
//! keep outside ~/Library/Caches.
use super::{Env, MB, by_size, dir_item, extension_is, stem_of};
use crate::{
    item::{Action, Category, Item, Safety},
    size,
};
use rayon::prelude::*;

pub fn virtual_machines(env: &Env) -> Vec<Item> {
    let sources: [(&str, Option<&str>, &str); 7] = [
        ("Parallels", Some("pvm"), "Parallels"),
        ("Documents/Parallels", Some("pvm"), "Parallels"),
        (
            "Library/Containers/com.utmapp.UTM/Data/Documents",
            Some("utm"),
            "UTM",
        ),
        (
            "Virtual Machines.localized",
            Some("vmwarevm"),
            "VMware Fusion",
        ),
        (
            "Documents/Virtual Machines.localized",
            Some("vmwarevm"),
            "VMware Fusion",
        ),
        ("VirtualBox VMs", None, "VirtualBox"),
        (".tart/vms", None, "Tart"),
    ];
    let machines: Vec<_> = sources
        .iter()
        .map(|(dir, suffix, product)| (env.home(dir), suffix, product))
        .filter(|(dir, _, _)| !env.is_protected(dir))
        .flat_map(|(dir, suffix, product)| {
            size::subdirectories(&dir)
                .into_iter()
                .filter(move |m| suffix.is_none_or(|s| extension_is(m, s)))
                .map(move |m| (m, *product))
        })
        .collect();
    by_size(
        machines
            .par_iter()
            .filter_map(|(machine, product)| {
                dir_item(
                    format!("vm-{}", machine.display()),
                    Category::Vms,
                    format!("{product}: {}", stem_of(machine)),
                    "A whole virtual machine, with everything installed inside it.",
                    machine,
                    Safety::Review,
                    Action::RemovePaths(vec![machine.clone()]),
                    50 * MB,
                )
            })
            .collect(),
    )
}

pub fn app_caches(env: &Env) -> Vec<Item> {
    let entries: [(&str, &str, &str, &str, Safety); 15] = [
        (
            "slack",
            "Slack cache",
            "Library/Application Support/Slack/Cache",
            "Message and file previews. Slack rebuilds them as you use it.",
            Safety::Safe,
        ),
        (
            "slack-sw",
            "Slack service worker cache",
            "Library/Application Support/Slack/Service Worker/CacheStorage",
            "Web app assets, downloaded again at the next launch.",
            Safety::Safe,
        ),
        (
            "discord",
            "Discord cache",
            "Library/Application Support/discord/Cache",
            "Media previews. Discord rebuilds them as you use it.",
            Safety::Safe,
        ),
        (
            "teams",
            "Microsoft Teams cache",
            "Library/Containers/com.microsoft.teams2/Data/Library/Caches",
            "Teams rebuilds it as you use it.",
            Safety::Safe,
        ),
        (
            "zoom",
            "Zoom data",
            "Library/Application Support/zoom.us",
            "Update packages and logs. Zoom downloads what it needs again.",
            Safety::Review,
        ),
        (
            "spotify",
            "Spotify cache",
            "Library/Application Support/Spotify/PersistentCache",
            "Streamed audio. Downloaded playlists live elsewhere and stay.",
            Safety::Safe,
        ),
        (
            "safari",
            "Safari cache",
            "Library/Containers/com.apple.Safari/Data/Library/Caches",
            "Page cache. History and logins stay.",
            Safety::Safe,
        ),
        (
            "adobe-media",
            "Adobe media cache",
            "Library/Application Support/Adobe/Common/Media Cache Files",
            "Premiere and After Effects render caches, rebuilt when a project opens.",
            Safety::Safe,
        ),
        (
            "adobe-caches",
            "Adobe caches",
            "Library/Caches/Adobe",
            "Creative Cloud app caches.",
            Safety::Safe,
        ),
        (
            "adobe-cc",
            "Creative Cloud installers",
            "Library/Application Support/Adobe/Adobe Desktop Common",
            "Downloaded installers and update payloads.",
            Safety::Review,
        ),
        (
            "steam",
            "Steam games",
            "Library/Application Support/Steam/steamapps",
            "Installed games. Uninstall them in Steam so your saves stay in sync.",
            Safety::Review,
        ),
        (
            "epic",
            "Epic Games launcher data",
            "Library/Application Support/Epic",
            "Launcher caches and downloads.",
            Safety::Review,
        ),
        (
            "xcode-device-logs",
            "iOS device logs",
            "Library/Developer/Xcode/iOS Device Logs",
            "Crash logs copied from connected devices.",
            Safety::Safe,
        ),
        (
            "photos-cache",
            "Photos caches",
            "Library/Containers/com.apple.photolibraryd/Data/Library/Caches",
            "Thumbnails and derivatives. The library itself is untouched.",
            Safety::Safe,
        ),
        (
            "quicklook",
            "Quick Look thumbnails",
            "Library/Caches/com.apple.QuickLook.thumbnailcache",
            "Preview thumbnails, rebuilt on demand.",
            Safety::Safe,
        ),
    ];
    let mut items: Vec<Item> = entries
        .par_iter()
        .filter_map(|(id, name, path, detail, safety)| {
            let path = env.home(path);
            if env.is_protected(&path) {
                return None;
            }
            dir_item(
                format!("cache-{id}"),
                Category::Apps,
                *name,
                *detail,
                &path,
                *safety,
                Action::EmptyDirectories(vec![path.clone()]),
                20 * MB,
            )
        })
        .collect();

    // Final Cut keeps render files inside each library bundle.
    if env.full_disk_access {
        for root in [env.home("Movies"), env.home("Documents")] {
            for library in size::subdirectories(&root) {
                if !extension_is(&library, "fcpbundle") {
                    continue;
                }
                let renders: Vec<_> = size::subdirectories(&library)
                    .into_iter()
                    .map(|event| event.join("Render Files"))
                    .filter(|p| size::exists(p))
                    .collect();
                let bytes: u64 = renders.par_iter().map(|p| size::measure(p).bytes).sum();
                if renders.is_empty() || bytes < 20 * MB {
                    continue;
                }
                let mut item = Item::new(
                    format!("fcp-renders-{}", library.display()),
                    Category::Apps,
                    format!("Final Cut render files: {}", stem_of(&library)),
                    "Rebuilt when the project opens. Final Cut's File > Delete Generated Library Files does the same.",
                    Some(bytes),
                    Safety::Safe,
                    Action::EmptyDirectories(renders),
                );
                item.reveal = Some(library.clone());
                items.push(item);
            }
        }
    }
    by_size(items)
}
