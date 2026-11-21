//! Real deletions on throwaway folders. The Trash is redirected to a
//! temporary directory, so nothing reaches the person's real Trash.
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};
use sysdata::{
    item::{Action, Category, Item, Safety},
    reclaim::{self, Event, Failure, Options},
};

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("sysdata-reclaim-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn write(path: &Path, bytes: usize) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, vec![0u8; bytes]).unwrap();
}

fn options(home: &Path) -> Options {
    Options {
        home: home.to_path_buf(),
        safe_to_trash: false,
        allow_admin: false,
    }
}

#[test]
fn remove_empty_and_trash_do_exactly_what_they_say() {
    let root = scratch("modes");
    let trash = root.join("fake-trash");
    fs::create_dir_all(&trash).unwrap();
    // SAFETY: this test binary's only other test never reads the variable.
    unsafe { std::env::set_var("SYSDATA_TRASH_DIR", &trash) };
    let home = root.join("home");
    write(&home.join("cache/a/one.bin"), 5_000);
    write(&home.join("cache/two.bin"), 5_000);
    write(&home.join("gone/three.bin"), 5_000);
    write(&home.join("review/four.bin"), 5_000);

    let emptied = reclaim::perform(
        &Action::EmptyDirectories(vec![home.join("cache")]),
        false,
        &options(&home),
    );
    assert_eq!(emptied, Ok(false));
    assert!(home.join("cache").is_dir(), "the folder itself stays");
    assert_eq!(fs::read_dir(home.join("cache")).unwrap().count(), 0);

    let removed = reclaim::perform(
        &Action::RemovePaths(vec![home.join("gone")]),
        false,
        &options(&home),
    );
    assert_eq!(removed, Ok(false));
    assert!(!home.join("gone").exists());

    let trashed = reclaim::perform(
        &Action::RemovePaths(vec![home.join("review")]),
        true,
        &options(&home),
    );
    assert_eq!(trashed, Ok(true));
    assert!(!home.join("review").exists());
    let in_trash: Vec<_> = fs::read_dir(&trash)
        .unwrap()
        .map(|e| e.unwrap().file_name())
        .collect();
    assert_eq!(in_trash.len(), 1, "moved, not deleted");
    assert!(in_trash[0].to_string_lossy().starts_with("review."));
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn the_guard_refuses_before_anything_moves() {
    let root = scratch("guard");
    let home = root.join("home");
    write(&home.join("Documents/keep.txt"), 10);
    write(&home.join("Library/Caches/app/cache.bin"), 10);
    // A batch naming a protected folder touches none of its paths.
    let action = Action::RemovePaths(vec![
        home.join("Library/Caches/app"),
        home.join("Documents"),
    ]);
    let result = reclaim::perform(&action, false, &options(&home));
    assert!(matches!(result, Err(Failure::Refused(_))), "{result:?}");
    assert!(home.join("Library/Caches/app/cache.bin").exists());
    assert!(home.join("Documents/keep.txt").exists());

    // A symlinked ancestor cannot smuggle a target into a protected folder.
    std::os::unix::fs::symlink(home.join("Library"), home.join("sneaky")).unwrap();
    let via_link = reclaim::perform(
        &Action::RemovePaths(vec![home.join("sneaky/Caches")]),
        false,
        &options(&home),
    );
    assert!(matches!(via_link, Err(Failure::Refused(_))), "{via_link:?}");
    assert!(home.join("Library/Caches/app/cache.bin").exists());

    // Emptying through a symlink would reach elsewhere.
    let empty_link = reclaim::perform(
        &Action::EmptyDirectories(vec![home.join("sneaky")]),
        false,
        &options(&home),
    );
    assert!(
        matches!(empty_link, Err(Failure::Refused(_))),
        "{empty_link:?}"
    );
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn prune_removes_only_old_files_and_the_folders_it_emptied() {
    let root = scratch("prune");
    write(&root.join("old/deep/a.log"), 10);
    write(&root.join("mixed/b.log"), 10);
    write(&root.join("mixed/fresh.log"), 10);
    fs::create_dir_all(root.join("already-empty")).unwrap();
    for file in ["old/deep/a.log", "mixed/b.log"] {
        let status = Command::new("/usr/bin/touch")
            .args(["-t", "202001010000"])
            .arg(root.join(file))
            .status()
            .unwrap();
        assert!(status.success());
    }
    reclaim::prune(&root, 3);
    assert!(
        !root.join("old").exists(),
        "emptied by this pass, parents too"
    );
    assert!(!root.join("mixed/b.log").exists());
    assert!(root.join("mixed/fresh.log").exists());
    assert!(
        root.join("already-empty").exists(),
        "a folder this pass did not empty stays"
    );
    assert!(root.exists(), "the pruned folder itself stays");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn a_batch_reports_each_item_and_needs_no_password_for_user_files() {
    let root = scratch("batch");
    let home = root.join("home");
    write(&home.join("c1/x.bin"), 4096);
    write(&home.join("c2/y.bin"), 4096);
    let item = |id: &str, path: PathBuf| {
        Item::new(
            id,
            Category::Packages,
            id,
            "",
            Some(4096),
            Safety::Safe,
            Action::RemovePaths(vec![path]),
        )
    };
    let mut events = Vec::new();
    reclaim::run_batch(
        &[item("c1", home.join("c1")), item("c2", home.join("c2"))],
        &options(&home),
        &mut |e| events.push(e),
    );
    let done: Vec<&Event> = events
        .iter()
        .filter(|e| matches!(e, Event::Done { .. }))
        .collect();
    assert_eq!(done.len(), 2, "{events:?}");
    assert!(!home.join("c1").exists() && !home.join("c2").exists());
    fs::remove_dir_all(root).unwrap();
}
