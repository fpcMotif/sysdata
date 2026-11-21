//! Fixed sample items for `--fixture` and the interaction tests. The paths
//! do not exist, and fixture mode never touches the disk.
use crate::item::{Action, Category, Item, Safety};
use std::{
    path::PathBuf,
    time::{Duration, SystemTime},
};

const MB: u64 = 1_000_000;

fn at(path: &str) -> PathBuf {
    PathBuf::from("/tmp/sysdata-fixture").join(path)
}

#[allow(clippy::too_many_arguments)]
fn row(
    id: &str,
    category: Category,
    name: &str,
    detail: &str,
    bytes: u64,
    safety: Safety,
    action: Action,
    idle_days: u64,
) -> Item {
    let mut item = Item::new(id, category, name, detail, Some(bytes), safety, action);
    item.reveal = Some(at(id));
    item.modified = Some(SystemTime::now() - Duration::from_secs(idle_days * 86_400));
    item
}

pub fn items() -> Vec<Item> {
    let remove = |id: &str| Action::RemovePaths(vec![at(id)]);
    let empty = |id: &str| Action::EmptyDirectories(vec![at(id)]);
    vec![
        row(
            "pkg-npm",
            Category::Packages,
            "npm cache",
            "Package tarballs and their metadata.",
            33_600_000,
            Safety::Safe,
            empty("pkg-npm"),
            2,
        ),
        row(
            "pkg-cargo",
            Category::Packages,
            "Cargo registry",
            "Crate sources and downloaded archives.",
            1_526 * MB,
            Safety::Safe,
            empty("pkg-cargo"),
            1,
        ),
        row(
            "tool-hidden-.local",
            Category::Tools,
            "Hidden folder .local",
            "Not one this app recognises. Usually a tool's data or cache; check what made it before deleting.",
            1_600 * MB,
            Safety::Review,
            remove("tool-hidden-.local"),
            0,
        ),
        row(
            "tool-.codex",
            Category::Tools,
            "Codex CLI data",
            "Sessions and caches.",
            1_300 * MB,
            Safety::Review,
            remove("tool-.codex"),
            3,
        ),
        row(
            "tool-.rustup/toolchains",
            Category::Tools,
            "Rust toolchains",
            "`rustup toolchain install` brings one back.",
            622_100_000,
            Safety::Review,
            remove("tool-.rustup/toolchains"),
            40,
        ),
        row(
            "tool-cache-hyperframes",
            Category::Tools,
            "Cache: hyperframes",
            "An entry in ~/.cache. Tools rebuild their caches on demand.",
            202 * MB,
            Safety::Safe,
            remove("tool-cache-hyperframes"),
            90,
        ),
        row(
            "xcode-DerivedData",
            Category::Xcode,
            "DerivedData",
            "Build products and indexes. Xcode rebuilds them on the next build.",
            4_200 * MB,
            Safety::Safe,
            empty("xcode-DerivedData"),
            20,
        ),
        row(
            "log-unified",
            Category::Logs,
            "Unified log store",
            "The persisted system log. Cleared with `log erase --all`.",
            924_600_000,
            Safety::Safe,
            Action::Privileged("log erase --all".into()),
            0,
        ),
        row(
            "pkg-homebrew-/opt/homebrew",
            Category::Packages,
            "Homebrew installation",
            "/opt/homebrew: every formula and cask installed with brew.",
            3_100 * MB,
            Safety::Manual,
            Action::Manual("brew leaves\nbrew autoremove".into()),
            5,
        ),
        row(
            "project-demo/node_modules",
            Category::Projects,
            "demo/node_modules",
            "~/devv/demo. Recreated by npm install.",
            607 * MB,
            Safety::Review,
            remove("project-demo/node_modules"),
            120,
        ),
    ]
}
