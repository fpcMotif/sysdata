//! Developer tool folders hidden in the home folder, and the safety net: any
//! large folder no other probe explained.
use super::{Env, MB, abbreviate, by_size, dir_item, name_of};
use crate::{
    item::{Action, Category, Item, Safety},
    mac, shell, size,
};
use rayon::prelude::*;
use std::{
    collections::{HashMap, HashSet},
    path::{Path, PathBuf},
};

type Known = (
    &'static str,
    &'static str,
    &'static str,
    Safety,
    Option<(&'static str, &'static [&'static str])>,
);

const KNOWN: [Known; 40] = [
    (
        ".ollama/models",
        "Ollama models",
        "Downloaded model weights. `ollama pull` fetches them again.",
        Safety::Review,
        None,
    ),
    (
        ".cache/huggingface",
        "Hugging Face cache",
        "Downloaded models and datasets.",
        Safety::Review,
        None,
    ),
    (
        ".cache/torch",
        "PyTorch cache",
        "Downloaded model weights.",
        Safety::Review,
        None,
    ),
    (
        ".lmstudio",
        "LM Studio models",
        "Downloaded model weights.",
        Safety::Review,
        None,
    ),
    (
        ".nvm/versions",
        "nvm Node versions",
        "Every Node.js installed with nvm. `nvm install` brings one back.",
        Safety::Review,
        None,
    ),
    (
        ".rustup/toolchains",
        "Rust toolchains",
        "`rustup toolchain install` brings one back.",
        Safety::Review,
        None,
    ),
    (
        ".pyenv/versions",
        "pyenv Python versions",
        "`pyenv install` brings one back.",
        Safety::Review,
        None,
    ),
    (
        ".rbenv/versions",
        "rbenv Ruby versions",
        "`rbenv install` brings one back.",
        Safety::Review,
        None,
    ),
    (
        ".sdkman/candidates",
        "SDKMAN toolchains",
        "`sdk install` brings one back.",
        Safety::Review,
        None,
    ),
    (
        ".local/share/mise/installs",
        "mise tool versions",
        "Every tool version mise installed. `mise install` fetches them again.",
        Safety::Review,
        None,
    ),
    (
        ".local/share/uv/python",
        "uv Python versions",
        "Interpreters uv downloaded. `uv python install` fetches them again.",
        Safety::Review,
        None,
    ),
    (
        ".local/share/uv/tools",
        "uv tools",
        "Tools installed with `uv tool install`.",
        Safety::Review,
        None,
    ),
    (
        "miniconda3",
        "Miniconda",
        "Conda environments and packages.",
        Safety::Review,
        None,
    ),
    (
        "anaconda3",
        "Anaconda",
        "Conda environments and packages.",
        Safety::Review,
        None,
    ),
    (
        ".conda/pkgs",
        "Conda package cache",
        "Downloaded packages.",
        Safety::Safe,
        Some(("conda", &["clean", "--all", "-y"])),
    ),
    (
        ".m2/repository",
        "Maven repository",
        "Downloaded jars, fetched again on the next build.",
        Safety::Safe,
        None,
    ),
    (
        ".ivy2",
        "Ivy cache",
        "Downloaded jars for sbt.",
        Safety::Safe,
        None,
    ),
    (
        ".cocoapods/repos",
        "CocoaPods specs repos",
        "`pod setup` rebuilds them.",
        Safety::Safe,
        None,
    ),
    (
        ".gradle/wrapper/dists",
        "Gradle distributions",
        "Downloaded Gradle versions.",
        Safety::Safe,
        None,
    ),
    (
        ".android/cache",
        "Android SDK download cache",
        "Downloaded again on demand.",
        Safety::Safe,
        None,
    ),
    (
        "go/pkg/mod",
        "Go module cache",
        "Downloaded modules.",
        Safety::Safe,
        Some(("go", &["clean", "-modcache"])),
    ),
    (
        ".cargo/git",
        "Cargo git checkouts",
        "Git dependencies Cargo checked out, fetched again on the next build.",
        Safety::Safe,
        None,
    ),
    (
        ".bun/install/cache",
        "Bun cache",
        "Package tarballs.",
        Safety::Safe,
        None,
    ),
    (
        ".npm/_npx",
        "npx cache",
        "Packages npx fetched to run once. npx fetches them again.",
        Safety::Safe,
        None,
    ),
    (".deno", "Deno cache", "Cached modules.", Safety::Safe, None),
    (
        ".moon",
        "moon toolchain",
        "Tools moonrepo downloaded. moon installs them again on demand.",
        Safety::Review,
        None,
    ),
    (
        ".vscode/extensions",
        "VS Code extensions",
        "Installed extensions. The marketplace reinstalls them.",
        Safety::Review,
        None,
    ),
    (
        ".cursor/extensions",
        "Cursor extensions",
        "Installed extensions.",
        Safety::Review,
        None,
    ),
    (
        ".antigravity-ide/extensions",
        "Antigravity extensions",
        "Installed extensions. The marketplace reinstalls them.",
        Safety::Review,
        None,
    ),
    (
        ".docker",
        "Docker CLI data",
        "Contexts and build history, not images.",
        Safety::Review,
        None,
    ),
    (
        ".orbstack",
        "OrbStack data",
        "Virtual machines and containers.",
        Safety::Review,
        None,
    ),
    (
        ".lima",
        "Lima virtual machines",
        "Virtual machine disks.",
        Safety::Review,
        None,
    ),
    (
        ".colima",
        "Colima virtual machine",
        "A virtual machine disk.",
        Safety::Review,
        None,
    ),
    (
        ".claude",
        "Claude Code data",
        "Session transcripts, memory, plugins and caches. Deleting it loses history.",
        Safety::Review,
        None,
    ),
    (
        ".codex",
        "Codex CLI data",
        "Sessions and caches.",
        Safety::Review,
        None,
    ),
    (
        ".grok",
        "Grok CLI data",
        "Sessions, settings and caches. Deleting it loses history.",
        Safety::Review,
        None,
    ),
    (
        ".copilot",
        "GitHub Copilot CLI data",
        "Sessions, settings and caches. Deleting it signs you out.",
        Safety::Review,
        None,
    ),
    (
        ".kilo",
        "Kilo Code data",
        "Sessions, settings and caches. Deleting it loses history.",
        Safety::Review,
        None,
    ),
    (
        ".gemini",
        "Gemini CLI data",
        "Settings and IDE support files.",
        Safety::Review,
        None,
    ),
    (
        ".factory",
        "Factory CLI data",
        "Sessions, settings and caches. Deleting it loses history.",
        Safety::Review,
        None,
    ),
];

/// Top-level dot-folders another probe already reports.
const COVERED_TOP: [&str; 6] = [".npm", ".cargo", ".Trash", ".android", ".gradle", ".cache"];
const HIDDEN_THRESHOLD: u64 = 100 * MB;

pub fn developer_tools(env: &Env) -> Vec<Item> {
    let mut claimed_top: HashSet<String> = COVERED_TOP.iter().map(|s| s.to_string()).collect();
    let mut claimed_cache: HashSet<String> =
        ["uv", "huggingface", "torch"].map(String::from).into();
    for (path, ..) in KNOWN {
        let mut parts = path.split('/');
        let top = parts.next().unwrap_or(path);
        claimed_top.insert(top.to_string());
        if top == ".cache"
            && let Some(sub) = parts.next()
        {
            claimed_cache.insert(sub.to_string());
        }
    }

    let mut items: Vec<Item> = KNOWN
        .par_iter()
        .filter_map(|(path, name, detail, safety, tool)| {
            let path = env.home(path);
            let action = match tool.and_then(|(tool, args)| Some((shell::which(tool)?, args))) {
                Some((program, args)) => Action::Command {
                    program,
                    args: args.iter().map(|a| a.to_string()).collect(),
                },
                None => Action::RemovePaths(vec![path.clone()]),
            };
            dir_item(
                format!(
                    "tool-{}",
                    path.strip_prefix(&env.home).unwrap_or(&path).display()
                ),
                Category::Tools,
                *name,
                *detail,
                &path,
                *safety,
                action,
                10 * MB,
            )
        })
        .collect();

    let hidden: Vec<PathBuf> = size::subdirectories(&env.home)
        .into_iter()
        .filter(|p| {
            let name = name_of(p);
            name.starts_with('.') && !claimed_top.contains(&name)
        })
        .collect();
    items.extend(hidden.par_iter().filter_map(|folder| {
        let name = name_of(folder);
        dir_item(
            format!("tool-hidden-{name}"),
            Category::Tools,
            format!("Hidden folder {name}"),
            "Not one this app recognises. Usually a tool's data or cache; check what made it before deleting.",
            folder,
            Safety::Review,
            Action::RemovePaths(vec![folder.clone()]),
            HIDDEN_THRESHOLD,
        )
    }).collect::<Vec<_>>());

    let caches: Vec<PathBuf> = size::subdirectories(&env.home(".cache"))
        .into_iter()
        .filter(|p| !claimed_cache.contains(&name_of(p)))
        .collect();
    items.extend(
        caches
            .par_iter()
            .filter_map(|folder| {
                let name = name_of(folder);
                dir_item(
                    format!("tool-cache-{name}"),
                    Category::Tools,
                    format!("Cache: {name}"),
                    "An entry in ~/.cache. Tools rebuild their caches on demand.",
                    folder,
                    Safety::Safe,
                    Action::RemovePaths(vec![folder.clone()]),
                    HIDDEN_THRESHOLD,
                )
            })
            .collect::<Vec<_>>(),
    );
    by_size(items)
}

const LARGE_THRESHOLD: u64 = 500 * MB;
const LARGE_DEPTH: usize = 4;

/// Walks the places Finder folds into System Data and reports every folder
/// over 500 MB that no other item accounts for. `known` holds totals the
/// probes already measured, so those trees are not walked twice.
pub fn large_folders(env: &Env, claimed: &[PathBuf], known: &HashMap<PathBuf, u64>) -> Vec<Item> {
    let mut roots = vec![env.home.clone()];
    if env.system {
        roots.extend(
            [
                "/Library",
                "/private/var",
                "/opt",
                "/usr/local",
                "/Users/Shared",
            ]
            .map(PathBuf::from),
        );
    }
    // Other categories in Storage settings, or the person's own work, which
    // no delete regenerates. Their build folders still get their own rows,
    // and the walk counts any git repository as nothing for the same reason.
    let mut excluded: Vec<PathBuf> = [
        "Pictures",
        "Music",
        "Movies",
        "Desktop",
        "Documents",
        "Downloads",
        "Library/Messages",
        "Library/Mail",
        "Library/Containers/com.apple.mail",
        "Library/Mobile Documents",
        "Applications",
        "Library/CloudStorage",
    ]
    .iter()
    .chain(super::user_data::PROJECT_ROOTS_OUTSIDE_DOCUMENTS.iter())
    .map(|p| env.home(p))
    .collect();
    if !env.full_disk_access {
        excluded.extend(["Library/Containers", "Library/Group Containers"].map(|p| env.home(p)));
    }
    // Every user's live temp and cache folders; the temp probe prunes your own safely.
    excluded.push(PathBuf::from("/private/var/folders"));
    let skip: HashSet<PathBuf> = claimed.iter().chain(&excluded).cloned().collect();
    let apps = InstalledApps::current(env);
    let context = Visit {
        claimed,
        excluded: &excluded,
        apps: &apps,
        home: &env.home,
    };
    let items: Vec<Item> = roots
        .par_iter()
        .filter(|root| size::exists(root) && size::on_boot_volume(root))
        .flat_map_iter(|root| {
            let sizes = size::directory_sizes(root, LARGE_DEPTH, &skip, known);
            let mut items = Vec::new();
            for child in size::subdirectories(root) {
                context.visit(&child, 1, &sizes, &mut items);
            }
            items
        })
        .collect();
    by_size(items)
}

struct Visit<'a> {
    claimed: &'a [PathBuf],
    excluded: &'a [PathBuf],
    apps: &'a InstalledApps,
    home: &'a Path,
}

impl Visit<'_> {
    fn visit(
        &self,
        dir: &Path,
        depth: usize,
        sizes: &HashMap<PathBuf, u64>,
        items: &mut Vec<Item>,
    ) {
        if self
            .excluded
            .iter()
            .chain(self.claimed)
            .any(|p| dir.starts_with(p))
        {
            return;
        }
        let Some(&bytes) = sizes.get(dir) else {
            return;
        };
        if bytes < LARGE_THRESHOLD {
            return;
        }
        let name = name_of(dir);
        let holds_claimed = self.claimed.iter().any(|p| p.starts_with(dir) && p != dir);
        // A folder the reclaimer would refuse, such as ~/Library/Caches, is
        // never one row: what is inside it is the answer.
        if holds_claimed
            || name == "Library"
            || name == "Application Support"
            || crate::reclaim::protected(dir, self.home)
        {
            if depth < LARGE_DEPTH {
                for child in size::subdirectories(dir) {
                    self.visit(&child, depth + 1, sizes, items);
                }
            }
            return;
        }
        let owner = describe_owner(dir, self.apps);
        // Outside your home and /Users/Shared, an unexplained folder belongs to
        // macOS or an installer. It is shown, never offered for deletion.
        let yours = dir.starts_with(self.home) || dir.starts_with("/Users/Shared");
        let (detail, safety, action) = if yours {
            (
                match owner {
                    Some(owner) => format!("{owner} Open it in Finder and decide."),
                    None => "Not one this app recognises. Open it in Finder and decide.".into(),
                },
                Safety::Review,
                Action::RemovePaths(vec![dir.to_path_buf()]),
            )
        } else {
            (
                owner.unwrap_or_else(|| "System data this app does not recognise.".into()),
                Safety::Manual,
                Action::Manual("macOS or an installer manages this folder. Remove the software that owns it, or leave it to macOS.".into()),
            )
        };
        let mut item = Item::new(
            format!("other-{}", dir.display()),
            Category::Other,
            abbreviate(dir, self.home),
            detail,
            Some(bytes),
            safety,
            action,
        );
        item.reveal = Some(dir.to_path_buf());
        item.modified = size::shallow_modified(dir);
        items.push(item);
    }
}

/// Installed apps by bundle identifier and by name, to say who made a folder
/// and, more usefully, when that app is gone.
pub struct InstalledApps {
    by_identifier: HashMap<String, String>,
    names: Vec<String>,
}

impl InstalledApps {
    pub fn current(env: &Env) -> Self {
        let mut locations = vec![env.home("Applications")];
        if env.system {
            locations.extend(
                [
                    "/Applications",
                    "/Applications/Utilities",
                    "/System/Applications",
                    "/System/Applications/Utilities",
                ]
                .map(PathBuf::from),
            );
        }
        let apps: Vec<PathBuf> = locations
            .iter()
            .flat_map(|l| size::subdirectories(l))
            .filter(|p| super::extension_is(p, "app"))
            .collect();
        let found: Vec<(String, Option<String>)> = apps
            .par_iter()
            .map(|app| {
                let name = super::stem_of(app);
                let id = mac::plist_string(&app.join("Contents/Info.plist"), "CFBundleIdentifier");
                (name, id)
            })
            .collect();
        let mut by_identifier = HashMap::new();
        let mut names = Vec::new();
        for (name, id) in found {
            if let Some(id) = id {
                by_identifier.insert(id.to_lowercase(), name.clone());
            }
            names.push(name);
        }
        Self {
            by_identifier,
            names,
        }
    }

    #[cfg(test)]
    pub fn from(apps: &[(&str, &str)]) -> Self {
        Self {
            by_identifier: apps
                .iter()
                .map(|(id, n)| (id.to_lowercase(), n.to_string()))
                .collect(),
            names: apps.iter().map(|(_, n)| n.to_string()).collect(),
        }
    }
}

/// A sentence naming who made `dir`, or `None` when its path does not say.
pub fn describe_owner(dir: &Path, apps: &InstalledApps) -> Option<String> {
    let parts: Vec<String> = dir
        .components()
        .map(|c| c.as_os_str().to_string_lossy().into_owned())
        .collect();
    let library = parts.iter().rposition(|p| p == "Library")?;
    if parts.get(library + 1).is_some_and(|p| p == "Metadata") {
        return Some("Spotlight's index of this Mac's files. macOS maintains it; excluding folders in System Settings > Spotlight shrinks it.".into());
    }
    let (parent, owner) = (parts.get(library + 1)?, parts.get(library + 2)?);
    if ![
        "Application Support",
        "Containers",
        "Group Containers",
        "Caches",
        "Logs",
        "HTTPStorages",
        "WebKit",
        "Saved Application State",
    ]
    .contains(&parent.as_str())
    {
        return None;
    }
    if looks_like_bundle_id(owner) {
        let id = strip_team_prefix(owner).to_lowercase();
        return Some(match apps.by_identifier.get(&id) {
            Some(name) => format!("Belongs to {name}."),
            None => format!("Left by {owner}, which is no longer installed on this Mac."),
        });
    }
    apps.names
        .iter()
        .find(|n| *n == owner)
        .or_else(|| {
            apps.names
                .iter()
                .find(|n| n.starts_with(&format!("{owner} ")))
        })
        .map(|name| format!("Belongs to {name}."))
}

fn looks_like_bundle_id(name: &str) -> bool {
    name.split('.').count() >= 3 && !name.contains(' ')
}

/// Group containers carry a team prefix (`UBF8T346G9.Office`) or `group.`.
fn strip_team_prefix(name: &str) -> &str {
    let first = name.split('.').next().unwrap_or("");
    if (first.len() == 10
        && first
            .chars()
            .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit()))
        || first == "group"
    {
        &name[first.len() + 1..]
    } else {
        name
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn owners_come_from_the_path() {
        let apps = InstalledApps::from(&[
            ("com.tinyspeck.slackmacgap", "Slack"),
            ("com.microsoft.Word", "Microsoft Word"),
        ]);
        let describe = |p: &str| describe_owner(Path::new(p), &apps);
        assert_eq!(
            describe("/Users/a/Library/Caches/com.tinyspeck.slackmacgap").as_deref(),
            Some("Belongs to Slack.")
        );
        assert_eq!(
            describe("/Users/a/Library/Containers/com.gone.app").as_deref(),
            Some("Left by com.gone.app, which is no longer installed on this Mac.")
        );
        assert_eq!(
            describe("/Users/a/Library/Group Containers/UBF8T346G9.com.microsoft.Word").as_deref(),
            Some("Belongs to Microsoft Word.")
        );
        assert_eq!(
            describe("/Users/a/Library/Application Support/Slack").as_deref(),
            Some("Belongs to Slack.")
        );
        assert_eq!(
            describe("/Users/a/Library/Application Support/Unknown"),
            None
        );
        assert_eq!(describe("/Users/a/devv"), None);
    }
}
