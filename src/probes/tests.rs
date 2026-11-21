//! Probes against a throwaway home folder. System locations are off.
use super::*;
use std::{fs, time::SystemTime};

struct Home(PathBuf);

impl Home {
    fn new() -> Self {
        // Parallel tests can read the same clock tick; the counter keeps homes apart.
        static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let root = std::env::temp_dir().join(format!(
            "sysdata-home-{}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed),
            SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&root).unwrap();
        Home(root)
    }

    fn file(&self, relative: &str, bytes: usize) -> &Self {
        let path = self.0.join(relative);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, vec![1u8; bytes]).unwrap();
        self
    }

    fn env(&self, full_disk_access: bool) -> Env {
        Env {
            home: self.0.clone(),
            full_disk_access,
            system: false,
        }
    }
}

impl Drop for Home {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn ids(items: &[Item]) -> Vec<&str> {
    let mut ids: Vec<&str> = items.iter().map(|i| i.id.as_str()).collect();
    ids.sort();
    ids
}

const BIG: usize = (MB as usize) + 1;

#[test]
fn package_caches_need_a_megabyte() {
    let home = Home::new();
    home.file(".npm/_cacache/a", BIG)
        .file("Library/Caches/pip/b", 10);
    let items = packages::probe(&home.env(true));
    assert_eq!(ids(&items), ["pkg-npm"]);
    assert_eq!(items[0].category, Category::Packages);
    assert_eq!(items[0].safety, Safety::Safe);
}

#[test]
fn unknown_hidden_folders_are_review_and_known_ones_are_named() {
    let home = Home::new();
    home.file(".mystery/blob", 101 * MB as usize)
        .file(".claude/projects/x", 11 * MB as usize)
        .file(".cache/thing/y", 101 * MB as usize)
        .file(".local/share/mise/installs/node/z", 11 * MB as usize);
    let items = catch_all::developer_tools(&home.env(true));
    assert_eq!(
        ids(&items),
        [
            "tool-.claude",
            "tool-.local/share/mise/installs",
            "tool-cache-thing",
            "tool-hidden-.mystery"
        ]
    );
    let mystery = items
        .iter()
        .find(|i| i.id == "tool-hidden-.mystery")
        .unwrap();
    assert_eq!(mystery.safety, Safety::Review);
    let cache = items.iter().find(|i| i.id == "tool-cache-thing").unwrap();
    assert_eq!(cache.safety, Safety::Safe);
}

#[test]
fn project_build_folders_need_their_manifest() {
    let home = Home::new();
    home.file("devv/app/node_modules/pkg/index.js", 31 * MB as usize)
        .file("devv/app/src/main.ts", 10)
        .file("devv/tool/target/debug/bin", 31 * MB as usize)
        .file("devv/tool/Cargo.toml", 10)
        .file("devv/notes/target/keep.txt", 31 * MB as usize);
    let items = user_data::projects(&home.env(true));
    let names: Vec<&str> = items.iter().map(|i| i.name.as_str()).collect();
    assert!(names.contains(&"app/node_modules"));
    assert!(names.contains(&"tool/target"));
    assert!(
        !names.contains(&"notes/target"),
        "a target folder without Cargo.toml is not a build folder"
    );
}

#[test]
fn protected_folders_are_skipped_without_full_disk_access() {
    let home = Home::new();
    home.file("Documents/site/node_modules/x", 31 * MB as usize);
    assert!(user_data::projects(&home.env(false)).is_empty());
    assert_eq!(user_data::projects(&home.env(true)).len(), 1);
}

#[test]
fn the_catch_all_skips_claimed_excluded_and_repositories() {
    let home = Home::new();
    home.file("Library/Big/blob", 501 * MB as usize)
        .file("Documents/huge", 501 * MB as usize)
        .file("devv/project/data", 501 * MB as usize)
        .file("stuff/repo/.git/HEAD", 10)
        .file("stuff/repo/blob", 501 * MB as usize)
        .file("claimed/blob", 501 * MB as usize);
    let env = home.env(true);
    let items = catch_all::large_folders(&env, &[home.0.join("claimed")], &Default::default());
    assert_eq!(
        ids(&items),
        [format!("other-{}", home.0.join("Library/Big").display()).as_str()]
    );
    assert_eq!(items[0].name, "~/Library/Big");
}

#[test]
fn a_protected_folder_is_never_one_row() {
    let home = Home::new();
    for n in 0..6 {
        home.file(&format!("Library/Caches/app{n}/blob"), 90 * MB as usize);
    }
    home.file("Library/Caches/big/blob", 501 * MB as usize);
    let items = catch_all::large_folders(&home.env(true), &[], &Default::default());
    assert_eq!(
        ids(&items),
        [format!("other-{}", home.0.join("Library/Caches/big").display()).as_str()],
        "~/Library/Caches itself is 1 GB but must not be offered"
    );
}

#[test]
fn a_full_scan_streams_every_probe() {
    let home = Home::new();
    home.file("Library/Logs/app.log", 4096);
    let batches = std::sync::Mutex::new(0);
    let items = scan(&home.env(true), &|progress| {
        if let Progress::Batch { total, .. } = progress {
            assert_eq!(total, PROBES.len());
            *batches.lock().unwrap() += 1;
        }
    });
    assert_eq!(*batches.lock().unwrap(), PROBES.len());
    assert_eq!(ids(&items), ["log-user"]);
}
