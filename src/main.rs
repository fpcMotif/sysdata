use gpui_kit::{
    component::{Root, TitleBar},
    *,
};
use std::{path::Path, time::SystemTime};
use sysdata::{
    json, mac, probes, size, status_item,
    ui::{Mode, SysData},
};

actions!(sysdata_app, [Quit]);

const HELP: &str = "System Data — see what is inside macOS System Data and clear it item by item

  (no flags)      live in the menu bar
  --open          live in the menu bar and show the panel at launch
  --pin           like --open, and keep the panel open when focus leaves
  --window        open as a normal window
  --fixture       the window with fixed sample items; nothing is scanned or deleted
  --json          scan once and print the inventory as JSON
  --measure PATH  print the allocated bytes under each PATH
  --list PATH     print the entries of one directory

SYSDATA_TRACE=1 prints probe timings; SYSDATA_THREADS=N sets the walker threads.";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let flag = |name: &str| args.iter().any(|a| a == name);
    if flag("--help") {
        println!("{HELP}");
        return;
    }
    if let Some(at) = args.iter().position(|a| a == "--measure") {
        size::prepare();
        for path in &args[at + 1..] {
            println!("{}\t{path}", size::measure(Path::new(path)).bytes);
        }
        return;
    }
    if let Some(dir) = args
        .iter()
        .position(|a| a == "--list")
        .and_then(|at| args.get(at + 1))
    {
        for child in size::children(Path::new(dir)) {
            let kind = match child.kind {
                size::Kind::File => "file",
                size::Kind::Dir => "dir",
                size::Kind::Other => "other",
            };
            println!("{kind}\t{}", child.path.display());
        }
        return;
    }
    if flag("--json") {
        let items = probes::scan(&probes::Env::current(), &|_| {});
        let value = json::inventory(&items, mac::disk_space(), SystemTime::now());
        println!(
            "{}",
            serde_json::to_string_pretty(&value).expect("plain JSON")
        );
        return;
    }
    let open_now = flag("--open") || flag("--pin");
    status_item::set_pinned(flag("--pin"));
    let mode = if flag("--fixture") {
        Mode::Fixture
    } else if flag("--window") {
        Mode::Window
    } else {
        Mode::MenuBar
    };
    gpui_kit::application()
        .with_assets(sysdata::assets::AppAssets)
        .run(move |cx| {
            gpui_kit::init(cx);
            cx.bind_keys([KeyBinding::new("cmd-q", Quit, None)]);
            cx.on_action(|_: &Quit, cx: &mut App| cx.quit());
            let opened = if mode == Mode::MenuBar {
                open_menu_bar(open_now, cx)
            } else {
                open_window(mode, cx)
            };
            if let Err(error) = opened {
                eprintln!("Cannot open System Data: {error}");
                cx.quit();
            }
        });
}

fn open_window(mode: Mode, cx: &mut App) -> Result<()> {
    cx.on_window_closed(|cx, _| {
        if cx.windows().is_empty() {
            cx.quit();
        }
    })
    .detach();
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::centered(size(px(460.), px(680.)), cx)),
        window_min_size: Some(size(px(400.), px(420.))),
        ..TitleBar::window_options()
    };
    cx.open_window(options, move |window, cx| {
        window.set_window_title(if mode == Mode::Fixture {
            "System Data — Fixture"
        } else {
            "System Data"
        });
        window.activate_window();
        let view = cx.new(|cx| SysData::new(mode, window, cx));
        cx.new(|cx| Root::new(view, window, cx))
    })?;
    cx.activate(true);
    Ok(())
}

/// One panel, opened hidden, shown under the menu bar item on each click.
fn open_menu_bar(show_now: bool, cx: &mut App) -> Result<()> {
    status_item::become_accessory();
    let (clicks, clicked) = async_channel::unbounded::<()>();
    status_item::install(move || {
        let _ = clicks.try_send(());
    });
    status_item::set_title("");
    let options = WindowOptions {
        kind: WindowKind::PopUp,
        titlebar: None,
        window_bounds: Some(WindowBounds::Windowed(Bounds::new(
            point(px(0.), px(0.)),
            size(px(460.), px(640.)),
        ))),
        show: false,
        focus: false,
        is_movable: false,
        is_resizable: false,
        is_minimizable: false,
        ..Default::default()
    };
    let handle = cx.open_window(options, |window, cx| {
        let view = cx.new(|cx| SysData::new(Mode::MenuBar, window, cx));
        cx.new(|cx| Root::new(view, window, cx))
    })?;
    handle.update(cx, |_, window, _| status_item::adopt(window))?;
    cx.spawn(async move |cx| {
        if show_now {
            // The menu bar places a new item on a later pass; show under it then.
            cx.background_executor()
                .timer(std::time::Duration::from_millis(300))
                .await;
            let _ = handle.update(cx, |_, window, _| {
                status_item::show();
                window.refresh();
            });
        }
        while clicked.recv().await.is_ok() {
            let _ = handle.update(cx, |_, window, _| {
                status_item::toggle();
                window.refresh();
            });
        }
    })
    .detach();
    Ok(())
}
