# SysData GPUI

A macOS menu bar app that shows what fills "System Data" in Storage settings and clears it item by item.
It is a Rust + [GPUI](https://gpui-kit.com/) port of [System Data Unpacked](https://github.com/Jarvis322/macos-sysdata) by Yigit Can Polat.
This branch replaces the Swift app with Rust; the scan, the categories and the safety tiers follow the original.

> **License.** The original is proprietary ([LICENSE](LICENSE)). It permits reading the source and building it for your own use.
> It forbids ports or forks intended for distribution. Keep this port private, or get the author's written permission before publishing it.

## Why System Data is opaque

Storage settings asks `SpaceAttribution` for per-app sizes and `CacheDelete` for purgeable space.
Whatever it cannot attribute becomes `SACategoryIdentifierSystemData`: a remainder, not a folder.
So no Finder location holds "System Data", and the settings pane cannot show what is inside.
This app measures the locations that usually make up the remainder: caches, simulators, logs, build output, VM disks, snapshots.

## Run

Apple's command-line developer tools and Mise are required.

```sh
cd ~/devv/sysdata
mise trust && mise install
mise run bundle            # builds dist/SysData GPUI.app
open "dist/SysData GPUI.app"
```

| Command | Purpose |
| --- | --- |
| `mise run run` | Menu bar app from a release build |
| `mise run window` | The same view in a normal window |
| `mise run fixture` | The window with fixed sample items; nothing is scanned or deleted |
| `mise run json` | One scan printed as JSON, the same shape as the Swift app's `--json` |
| `mise run test` | Walker, probe, reclaim, model and GPUI interaction tests |
| `mise run check` | rustfmt and Clippy with warnings denied |

Binary flags: `--open` shows the panel at launch, `--pin` also keeps it open when focus leaves (for screenshots and automation), `--measure PATH…` prints allocated bytes, `--list DIR` prints one directory.
`SYSDATA_TRACE=1` prints each probe's time; `SYSDATA_THREADS=N` overrides the walker's thread count.

Grant Full Disk Access to `SysData GPUI` once. Without it, protected folders (containers, Mail, Safari, Documents) are skipped rather than prompting one dialog per folder.
**Grant Access** in the banner opens Privacy & Security > Full Disk Access and floats a guide on the Settings window's bottom edge.
Drag the app card from the guide into the list. The app checks every half second, shows "Full Disk Access granted", closes the guide and rescans.
The card is a native AppKit dragging source: GPUI's own drag and drop cannot hand a file to another app.

## What you see

The panel lists 18 groups, largest first. Each row has a size, a badge and actions.

| Badge | Meaning | Delete |
| --- | --- | --- |
| Safe | The owning tool or macOS rebuilds it | Deleted, or moved to the Trash when "Move Safe items to the Trash too" is on |
| Review | Something real is lost: a device, a login, a download | Always moved to the Trash |
| Manual | This app never deletes it | The row shows how instead |

**Select safe** ticks every Safe row except the Trash itself. Before anything runs, the confirmation shows the size it frees, what goes to the Trash, whether an administrator password is needed, and every operation as an exact command. Scripts that need root share one password prompt.

## Safety model

Every path passes a guard before anything moves:

1. It must be absolute and free of `.` and `..`.
2. It must not be a protected folder, such as your home, `~/Library`, `~/Documents`, `~/.ssh`, `/Library` or `/Applications`. Children of those may go.
3. Its real path, after resolving symlinked ancestors, is checked again, so a link cannot smuggle a target into a protected folder.
4. It must not be a mounted volume.
5. It must not contain this app's own executable.

A batch is screened completely before its first path is touched.

Differences from the original, all toward precision:

- A Review item that cannot go to the Trash is reported and left in place. The original deleted it permanently instead.
- The catch-all never offers a folder the guard would refuse, such as `~/Library/Caches` as one row, and never offers a git repository as one blob.
- Large folders outside your home (and outside `/Users/Shared`) are listed as Manual. `/private/var/folders` is excluded; the temp probe prunes your own files there safely.
- Code folders (`~/devv`, `~/src`, `~/Developer` and similar) are searched for build output: `node_modules`, `target` beside `Cargo.toml`, `.venv` beside `pyproject.toml`, and others. The folders themselves are never offered.
- Scans set the I/O policy that stops iCloud and File Provider placeholders from downloading.
- `xcrun` runs only when a developer directory is selected, so a Mac without Xcode never sees an install dialog.

## How the scan is fast

Measured on an M4 Pro (8 performance and 4 efficiency cores) with a warm cache. The Swift numbers are the installed System Data Unpacked 0.3.11.

| Full scan (`--json`) | Mean ± σ, 3 runs | User CPU | System CPU |
| --- | --- | --- | --- |
| Swift 0.3.11 | 22.80 s ± 0.20 s | 6.93 s | 10.98 s |
| This port | 4.71 s ± 0.20 s | 0.56 s | 18.61 s |

The port is 4.84 ± 0.21 times faster. The two do not scan identical sets: this port also walks code folders for build output, and 0.3.11 predates several upstream probes.

The walker reads each directory with `getattrlistbulk`, which returns names, types, devices, modification times and allocated sizes for many entries per call.
It opens each subdirectory with `openat` on its parent's descriptor, so the kernel never re-resolves a full path.
Subdirectories fan out over a rayon pool sized to the performance cores. Past that, kernel contention can dominate: `~/Library` took 6.51 s at 12 threads against 1.21 s at 8, although `~/devv` was fastest at 12 (1.52 s).
Probes that wait on `simctl`, `docker` or `tmutil` run on their own threads, so they never hold a walker thread.
Totals the probes measured are reused by the catch-all, so no tree is walked twice.

The time is almost all kernel work: a full scan spends 0.56 s in user code and 18.6 s of CPU in the kernel across threads.
That is why the language matters less than the system calls; see the comparison below.

Mean wall time of one tree, `hyperfine -N -w 1 -r 5`:

| Tool | Language | Method | `~/Library/Caches` 12.7 GB | `~/Library` 53.6 GB | `~/devv` 26.6 GB |
| --- | --- | --- | --- | --- | --- |
| This walker, 8 threads | Rust | `getattrlistbulk` + `openat` | 127 ms | **1.21 s** | 2.60 s ± 1.62 s |
| This walker, 4 threads | Rust | same | **81 ms** | 2.05 s ± 2.08 s | 1.66 s ± 1.10 s |
| diskus | Rust | `readdir` + `lstat` | 83 ms | 6.82 s | 2.12 s |
| dust | Rust | `readdir` + `lstat` | 105 ms | 6.12 s | 2.18 s |
| gdu | Go | `readdir` + `lstat`, goroutines | 97 ms | 6.13 s | 2.30 s |
| Plain Go walker | Go | `readdir` + `lstat`, goroutines | 97 ms | 6.76 s | 3.46 s |
| Mole (`mo analyze`) | Go | `os.ReadDir` + `Info()`, `du` for known caches | 265 ms | 9.78 s | 3.44 s |
| `du -sk` | C | `fts`, one thread | 261 ms | 5.95 s | 4.96 s |

ncdu (Zig) could not be built here: it links `ncursesw` and `zstd`, which the macOS SDK lacks.
The large ± values at 4 and 8 threads on `~/devv` and at 4 threads on `~/Library` each come from one slow run among five.
The Go walker with this walker's rules reports the same bytes, so the gap is the system calls, not the counting.
Every `readdir` + `lstat` tool lands within about 2× of the others whatever its language. The walker that reads a directory in one call wins by 3–8× on large trees.
A Go or Zig rewrite would match this only by calling `getattrlistbulk` too.

Byte totals differ by method: gdu and Mole count a hard-linked file once, and Mole also caps each file at its logical size. This walker counts regular files' allocated blocks, each link separately, like Finder and the original app.

## Source

| File | Role |
| --- | --- |
| `src/size.rs` | The parallel `getattrlistbulk` walker |
| `src/probes/` | The 18 probes and the catch-all |
| `src/reclaim.rs` | The guard, deletes, Trash moves, prune, commands and the administrator batch |
| `src/model.rs` | Selection, filter, folding and delete bookkeeping, without UI |
| `src/ui.rs` | The GPUI panel |
| `src/status_item.rs` | The menu bar item and panel placement, through AppKit |
| `src/grant.rs` | The Full Disk Access pane, the Settings window locator, guide placement and the AppKit drag source |
| `src/mac.rs` | Disk space, Trash, Finder, plist and accent color calls |
