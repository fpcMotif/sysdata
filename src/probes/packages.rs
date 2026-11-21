//! Package-manager download caches. Each is refilled on demand, and the
//! tool's own clean command runs when it is installed, so its bookkeeping stays right.
use super::{Env, MB, by_size, dir_item};
use crate::{
    item::{Action, Category, Item, Safety},
    shell, size,
};
use rayon::prelude::*;
use std::path::{Path, PathBuf};

struct Cache {
    id: &'static str,
    name: &'static str,
    path: PathBuf,
    tool: Option<(&'static str, &'static [&'static str])>,
    detail: String,
    safety: Safety,
}

pub fn probe(env: &Env) -> Vec<Item> {
    let cache = |id, name, path: &str, tool, detail: &str| Cache {
        id,
        name,
        path: env.home(path),
        tool,
        detail: detail.into(),
        safety: Safety::Safe,
    };
    let mut caches = vec![
        cache(
            "brew",
            "Homebrew downloads",
            "Library/Caches/Homebrew",
            Some(("brew", &["cleanup", "--prune=all", "-s"][..])),
            "Downloaded bottles and source archives.",
        ),
        cache(
            "npm",
            "npm cache",
            ".npm/_cacache",
            Some(("npm", &["cache", "clean", "--force"][..])),
            "Package tarballs and their metadata.",
        ),
        cache(
            "yarn",
            "Yarn cache",
            "Library/Caches/Yarn",
            Some(("yarn", &["cache", "clean"][..])),
            "Package tarballs.",
        ),
        cache(
            "pip",
            "pip cache",
            "Library/Caches/pip",
            Some(("pip3", &["cache", "purge"][..])),
            "Wheels and the HTTP cache.",
        ),
        cache(
            "uv",
            "uv cache",
            ".cache/uv",
            Some(("uv", &["cache", "clean"][..])),
            "Python wheels, sources and interpreters.",
        ),
        cache(
            "pods",
            "CocoaPods cache",
            "Library/Caches/CocoaPods",
            Some(("pod", &["cache", "clean", "--all"][..])),
            "Pod specs and sources.",
        ),
        cache(
            "gradle",
            "Gradle caches",
            ".gradle/caches",
            None,
            "Dependency jars and the build cache. Downloaded again on the next build.",
        ),
        cache(
            "cargo",
            "Cargo registry",
            ".cargo/registry",
            None,
            "Crate sources and downloaded archives.",
        ),
        cache(
            "swiftpm",
            "SwiftPM cache",
            "Library/Caches/org.swift.swiftpm",
            None,
            "Package repository clones.",
        ),
        cache(
            "go",
            "Go build cache",
            "Library/Caches/go-build",
            None,
            "Compiled Go packages.",
        ),
        cache(
            "cypress",
            "Cypress binaries",
            "Library/Caches/Cypress",
            None,
            "Downloaded Cypress versions.",
        ),
        cache(
            "playwright",
            "Playwright browsers",
            "Library/Caches/ms-playwright",
            None,
            "Downloaded browser builds. `playwright install` fetches them again.",
        ),
    ];

    // Only pnpm knows where a custom store lives, and an uninstalled pnpm
    // leaves its store with nothing referencing it.
    if let Some(pnpm) = shell::which("pnpm") {
        if let Some(path) = shell::probe(&pnpm, &["store", "path"]) {
            caches.push(Cache {
                id: "pnpm",
                name: "pnpm store",
                path: PathBuf::from(path.trim()),
                tool: Some(("pnpm", &["store", "prune"])),
                detail:
                    "Packages no project references any more, in the content-addressable store."
                        .into(),
                safety: Safety::Safe,
            });
        }
    } else if let Some(store) = [
        "Library/pnpm/store",
        ".local/share/pnpm/store",
        ".pnpm-store",
    ]
    .iter()
    .map(|p| env.home(p))
    .find(|p| size::exists(p))
    {
        caches.push(Cache {
            id: "pnpm",
            name: "pnpm store",
            path: store,
            tool: None,
            detail: "pnpm is not on this Mac, so nothing appears to use this store. A version manager may still run pnpm from elsewhere.".into(),
            safety: Safety::Review,
        });
    }

    // uvx programs (MCP servers among them) hold uv's cache lock for hours.
    // Cleaning would wait on them and remove the environments they run from.
    let running_uv = if env.system { running_uv() } else { 0 };
    if running_uv > 0
        && let Some(uv) = caches.iter_mut().find(|c| c.id == "uv")
    {
        uv.safety = Safety::Manual;
        uv.detail = format!(
            "{running_uv} uv process{} running, such as tools started with uvx. They hold this cache; quit them first.",
            if running_uv == 1 { " is" } else { "es are" }
        );
    }

    let mut items: Vec<Item> = caches
        .par_iter()
        .filter_map(|cache| {
            let action = if cache.id == "uv" && running_uv > 0 {
                Action::Manual(
                    "# Quit the programs started with uvx first, then:\nuv cache clean".into(),
                )
            } else if let Some((tool, args)) = cache.tool
                && let Some(program) = shell::which(tool)
            {
                Action::Command {
                    program,
                    args: args.iter().map(|a| a.to_string()).collect(),
                }
            } else {
                Action::EmptyDirectories(vec![cache.path.clone()])
            };
            dir_item(
                format!("pkg-{}", cache.id),
                Category::Packages,
                cache.name,
                cache.detail.clone(),
                &cache.path,
                cache.safety,
                action,
                MB,
            )
        })
        .collect();

    if env.system {
        // The whole prefix: formulae also install into share/ and lib/, casks into Caskroom.
        for prefix in ["/opt/homebrew", "/usr/local"] {
            if size::exists(&Path::new(prefix).join("bin/brew")) {
                items.extend(dir_item(
                    format!("pkg-homebrew-{prefix}"),
                    Category::Packages,
                    "Homebrew installation",
                    format!("{prefix}: every formula and cask installed with brew. Remove what you no longer use."),
                    Path::new(prefix),
                    Safety::Manual,
                    Action::Manual("brew leaves            # formulae you asked for\nbrew list --cask\nbrew uninstall <formula>\nbrew uninstall --cask <name>\nbrew autoremove".into()),
                    100 * MB,
                ));
            }
        }
    }
    by_size(items)
}

fn running_uv() -> usize {
    shell::probe(Path::new("/usr/bin/pgrep"), &["-x", "uv"]).map_or(0, |out| {
        out.lines().filter(|l| !l.trim().is_empty()).count()
    })
}
