//! The System Data panel: one stateful view over `Model`. Scans, deletes and
//! folder breakdowns run on plain threads and stream results back.
use crate::{
    fixture, grant,
    item::{Category, Item, Safety, format_bytes},
    mac,
    model::{Model, Pending},
    probes::{self, Env, Progress},
    reclaim::{self, Event, goes_to_trash},
    shell, size, status_item,
};
use gpui_kit::{
    component::{
        Icon, Root, Sizable, Theme,
        input::{Input, InputEvent, InputState},
        tooltip::Tooltip,
    },
    prelude::*,
    *,
};
use std::{
    path::PathBuf,
    time::{Duration, Instant, SystemTime},
};

actions!(sysdata, [FocusFilter, Rescan, SelectSafe, Dismiss]);

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// The panel under the menu bar item.
    MenuBar,
    /// An ordinary window.
    Window,
    /// Fixed sample items; nothing is scanned or deleted.
    Fixture,
}

const MONO: &str = ".AppleSystemUIFontMonospaced";

#[derive(Clone, Copy)]
struct Palette {
    bg: u32,
    raised: u32,
    hover: u32,
    text: u32,
    muted: u32,
    faint: u32,
    border: u32,
    accent: u32,
    safe: u32,
    review: u32,
    danger: u32,
}

fn palette(window: &Window) -> Palette {
    let accent = mac::accent_color().unwrap_or(0x0a84ff);
    match window.appearance() {
        WindowAppearance::Dark | WindowAppearance::VibrantDark => Palette {
            bg: 0x1f1f21,
            raised: 0x2c2c2f,
            hover: 0x2a2a2d,
            text: 0xf2f2f5,
            muted: 0xa1a1a8,
            faint: 0x6c6c72,
            border: 0x38383c,
            accent,
            safe: 0x30d158,
            review: 0xff9f0a,
            danger: 0xff453a,
        },
        _ => Palette {
            bg: 0xf7f7f8,
            raised: 0xebebee,
            hover: 0xefeff2,
            text: 0x1d1d1f,
            muted: 0x6e6e73,
            faint: 0xa6a6ab,
            border: 0xe2e2e6,
            accent,
            safe: 0x248a3d,
            review: 0xc26a00,
            danger: 0xd70015,
        },
    }
}

/// A color with an alpha byte, for tints.
fn tint(color: u32, alpha: u8) -> Rgba {
    rgba(color << 8 | u32::from(alpha))
}

enum ScanMessage {
    Progress(Progress),
    Done(Vec<Item>, mac::DiskSpace),
}

pub struct SysData {
    model: Model,
    mode: Mode,
    filter: Entity<InputState>,
    focus: FocusHandle,
    show_plan: bool,
    copied: bool,
    scan: Option<Task<()>>,
    work: Vec<Task<()>>,
    grant: Option<GrantFlow>,
    _subscriptions: Vec<Subscription>,
}

/// The floating guide shown while the person drags the app into the list.
struct GrantFlow {
    window: WindowHandle<Root>,
    guide: Entity<GrantGuide>,
    /// The AppKit dragging source over the guide's app card.
    drag_source: usize,
}

const GUIDE_WIDTH: f64 = 380.;
const GUIDE_HEIGHT: f64 = 112.;
/// The app card in the guide, in its top-left coordinates. The render and
/// the AppKit dragging source both use it, so they cover the same pixels.
const GUIDE_CARD: mac::Rect = mac::Rect {
    origin: mac::Point { x: 14., y: 38. },
    size: mac::Point { x: 352., y: 34. },
};

impl SysData {
    pub fn new(mode: Mode, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let filter = cx.new(|cx| InputState::new(window, cx).placeholder("Filter"));
        let mut subscriptions = vec![cx.subscribe(&filter, |s, input, event, cx| {
            if matches!(event, InputEvent::Change) {
                let text = input.read(cx).value().to_string();
                s.model.set_filter(text);
                cx.notify();
            }
        })];
        if mode == Mode::MenuBar {
            // A menu closes when it loses focus; so does this panel.
            subscriptions.push(cx.observe_window_activation(window, |s, window, _| {
                if !window.is_window_active() && !status_item::pinned() {
                    s.show_plan = false;
                    status_item::hide();
                }
            }));
        }
        subscriptions.push(cx.observe_window_appearance(window, |_, window, cx| {
            apply_theme(palette(window), cx);
        }));
        cx.bind_keys([
            KeyBinding::new("cmd-f", FocusFilter, Some("SysData")),
            KeyBinding::new("cmd-r", Rescan, Some("SysData")),
            KeyBinding::new("cmd-shift-s", SelectSafe, Some("SysData")),
            KeyBinding::new("escape", Dismiss, Some("SysData")),
        ]);
        apply_theme(palette(window), cx);
        let focus = cx.focus_handle();
        focus.focus(window, cx);

        let mut model = if mode == Mode::Fixture {
            Model::load(None)
        } else {
            Model::load(Some(state_file()))
        };
        let mut view = Self {
            model: Model::default(),
            mode,
            filter,
            focus,
            show_plan: false,
            copied: false,
            scan: None,
            work: Vec::new(),
            grant: None,
            _subscriptions: subscriptions,
        };
        if mode == Mode::Fixture {
            model.full_disk_access = true;
            model.begin_scan(false);
            model.finish_scan(
                fixture::items(),
                mac::DiskSpace {
                    free: 205_940_000_000,
                    capacity: 494_380_000_000,
                    purgeable: 15_990_000_000,
                },
            );
            view.model = model;
        } else {
            view.model = model;
            view.rescan(false, cx);
        }
        if mode == Mode::MenuBar {
            // The menu bar number stays meaningful without opening the panel.
            view.work.push(cx.spawn(async move |view, cx| {
                loop {
                    cx.background_executor()
                        .timer(std::time::Duration::from_secs(24 * 60 * 60))
                        .await;
                    if view.update(cx, |s, cx| s.rescan(true, cx)).is_err() {
                        break;
                    }
                }
            }));
        }
        view
    }

    pub fn model(&self) -> &Model {
        &self.model
    }

    fn changed(&mut self, cx: &mut Context<Self>) {
        if self.mode == Mode::MenuBar {
            let bytes = self.model.measured_bytes();
            status_item::set_title(&if bytes >= 100_000_000 {
                format_bytes(bytes)
            } else {
                String::new()
            });
        }
        cx.notify();
    }

    pub fn rescan(&mut self, quiet: bool, cx: &mut Context<Self>) {
        if self.model.scanning || self.mode == Mode::Fixture {
            return;
        }
        let env = Env::current();
        self.model.full_disk_access = env.full_disk_access;
        // Free space is one cheap call; the header should not read zero while scanning.
        self.model.space = mac::disk_space();
        self.model.begin_scan(quiet);
        let (tx, rx) = async_channel::unbounded();
        std::thread::Builder::new()
            .name("sysdata-scan".into())
            .spawn(move || {
                let items = probes::scan(&env, &|progress| {
                    let _ = tx.send_blocking(ScanMessage::Progress(progress));
                });
                let _ = tx.send_blocking(ScanMessage::Done(items, mac::disk_space()));
            })
            .expect("scan thread");
        self.scan = Some(cx.spawn(async move |view, cx| {
            while let Ok(message) = rx.recv().await {
                let alive = view.update(cx, |s, cx| {
                    match message {
                        ScanMessage::Progress(progress) => s.model.accept_progress(progress, quiet),
                        ScanMessage::Done(items, space) => s.model.finish_scan(items, space),
                    }
                    s.changed(cx);
                });
                if alive.is_err() {
                    break;
                }
            }
        }));
        cx.notify();
    }

    /// Opens the Full Disk Access pane and floats a guide under it with a
    /// card to drag into the list; polls until the grant appears.
    fn begin_grant(&mut self, cx: &mut Context<Self>) {
        if self.mode == Mode::Fixture || self.model.full_disk_access {
            return;
        }
        grant::open_settings();
        if let Some(flow) = &self.grant
            && flow
                .window
                .update(cx, |_, w, _| w.activate_window())
                .is_ok()
        {
            return;
        }
        let mut guide = None;
        let options = WindowOptions {
            kind: WindowKind::PopUp,
            titlebar: None,
            window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                point(px(0.), px(0.)),
                size(px(GUIDE_WIDTH as f32), px(GUIDE_HEIGHT as f32)),
            ))),
            focus: false,
            show: true,
            is_movable: false,
            is_resizable: false,
            is_minimizable: false,
            ..Default::default()
        };
        let Ok(window) = cx.open_window(options, |w, cx| {
            let view = cx.new(|_| GrantGuide::new(false));
            guide = Some(view.clone());
            cx.new(|cx| Root::new(view, w, cx))
        }) else {
            return;
        };
        let Some(guide) = guide else {
            return;
        };
        let app = grant::app_path();
        let drag_source = window
            .update(cx, |_, w, _| {
                place_guide(w);
                grant::install_drag_source(w, GUIDE_CARD, &app) as usize
            })
            .unwrap_or(0);
        self.grant = Some(GrantFlow {
            window,
            guide,
            drag_source,
        });
        let home = shell::home();
        self.work.retain(|task| !task.is_ready());
        self.work.push(cx.spawn(async move |view, cx| {
            let started = Instant::now();
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(500))
                    .await;
                let home = home.clone();
                let granted = cx
                    .background_executor()
                    .spawn(async move { probes::has_full_disk_access(&home) })
                    .await;
                let waiting = view
                    .update(cx, |s, cx| s.poll_grant(granted, cx))
                    .unwrap_or(false);
                if !waiting || started.elapsed() > Duration::from_secs(600) {
                    break;
                }
            }
        }));
    }

    /// Returns whether to keep waiting: not while the grant is in, or once
    /// the person closed the guide.
    fn poll_grant(&mut self, granted: bool, cx: &mut Context<Self>) -> bool {
        let Some(flow) = self.grant.take() else {
            return false;
        };
        if !granted {
            let open = flow.window.update(cx, |_, w, _| place_guide(w)).is_ok();
            if open {
                self.grant = Some(flow);
            }
            return open;
        }
        // SAFETY: the view was installed in this window, which the update proves is open.
        let _ = flow.window.update(cx, |_, _, _| unsafe {
            grant::remove_drag_source(flow.drag_source as mac::id)
        });
        flow.guide.update(cx, |guide, cx| {
            guide.granted = true;
            cx.notify();
        });
        let window = flow.window;
        self.work.push(cx.spawn(async move |_, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(1500))
                .await;
            let _ = window.update(cx, |_, w, _| w.remove_window());
        }));
        self.model.full_disk_access = true;
        self.rescan(true, cx);
        false
    }

    fn ask_delete(&mut self, pending: Pending, cx: &mut Context<Self>) {
        self.model.pending = Some(pending);
        self.show_plan = false;
        self.copied = false;
        cx.notify();
    }

    fn cancel_delete(&mut self, cx: &mut Context<Self>) {
        self.model.pending = None;
        self.show_plan = false;
        cx.notify();
    }

    fn confirm_delete(&mut self, cx: &mut Context<Self>) {
        let batch = self.model.take_pending();
        self.show_plan = false;
        if batch.is_empty() {
            cx.notify();
            return;
        }
        if self.mode == Mode::Fixture {
            // Nothing on disk: report what a real run would.
            for item in batch {
                let trashed = goes_to_trash(&item, self.model.safe_to_trash);
                self.model.apply(Event::Done {
                    freed: if trashed { 0 } else { item.bytes() },
                    ids: vec![item.id],
                    trashed,
                });
            }
            self.changed(cx);
            return;
        }
        let options = reclaim::Options {
            home: shell::home(),
            safe_to_trash: self.model.safe_to_trash,
            allow_admin: true,
        };
        let (tx, rx) = async_channel::unbounded();
        std::thread::Builder::new()
            .name("sysdata-reclaim".into())
            .spawn(move || {
                reclaim::run_batch(&batch, &options, &mut |event| {
                    let _ = tx.send_blocking(event);
                });
            })
            .expect("reclaim thread");
        self.work.retain(|task| !task.is_ready());
        self.work.push(cx.spawn(async move |view, cx| {
            while let Ok(event) = rx.recv().await {
                if view
                    .update(cx, |s, cx| {
                        s.model.apply(event);
                        s.changed(cx);
                    })
                    .is_err()
                {
                    return;
                }
            }
            let space = cx
                .background_executor()
                .spawn(async { mac::disk_space() })
                .await;
            let _ = view.update(cx, |s, cx| {
                s.model.space = space;
                s.changed(cx);
            });
        }));
        cx.notify();
    }

    fn toggle_row(&mut self, item: &Item, cx: &mut Context<Self>) {
        let opened = self.model.toggle_expanded(&item.id);
        let needs_breakdown =
            opened && !item.action.is_manual() && !self.model.breakdowns.contains_key(&item.id);
        if let (true, Some(path)) = (needs_breakdown, item.reveal.clone()) {
            if self.mode == Mode::Fixture {
                self.model.breakdowns.insert(item.id.clone(), Vec::new());
            } else {
                let id = item.id.clone();
                self.work.retain(|task| !task.is_ready());
                self.work.push(cx.spawn(async move |view, cx| {
                    let children = cx
                        .background_executor()
                        .spawn(async move { size::largest_children(&path, 5) })
                        .await;
                    let _ = view.update(cx, |s, cx| {
                        s.model.breakdowns.insert(id, children);
                        cx.notify();
                    });
                }));
            }
        }
        cx.notify();
    }

    fn header(&self, p: Palette, cx: &mut Context<Self>) -> impl IntoElement {
        let m = &self.model;
        let total = if m.items.is_empty() && m.scanning {
            "Scanning".to_string()
        } else {
            format_bytes(m.measured_bytes())
        };
        let summary = if m.scanning && m.items.is_empty() {
            m.phase.clone()
        } else {
            format!(
                "{} safe to free now · {} free on disk · {} purgeable",
                format_bytes(m.safe_bytes()),
                format_bytes(m.space.free),
                format_bytes(m.space.purgeable)
            )
        };
        div()
            .flex()
            .flex_col()
            .gap(px(3.))
            .px(px(16.))
            // A window's transparent title bar keeps its traffic lights here.
            .pt(px(if self.mode == Mode::MenuBar { 14. } else { 34. }))
            .pb(px(10.))
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .child(
                        div()
                            .text_size(px(17.))
                            .font_weight(FontWeight::BOLD)
                            .child("System Data"),
                    )
                    .child(
                        observed(div().id("total"))
                            .aria_label(total.clone())
                            .text_size(px(17.))
                            .text_color(rgb(p.muted))
                            .font_weight(FontWeight::MEDIUM)
                            .child(total),
                    )
                    .child(div().flex_1())
                    .child(
                        button(
                            "select-safe",
                            if m.all_safe_selected() {
                                "Deselect safe"
                            } else {
                                "Select safe"
                            },
                            p,
                        )
                        .tooltip(|w, cx| {
                            Tooltip::new("Select every item that is regenerated automatically")
                                .build(w, cx)
                        })
                        .on_click(cx.listener(|s, _, _, cx| {
                            s.model.toggle_safe();
                            cx.notify();
                        })),
                    )
                    .child(
                        button("rescan", "Rescan", p)
                            .child(icon("refresh-cw", p.muted))
                            .when(m.scanning, |d| d.opacity(0.5))
                            .on_click(cx.listener(|s, _, _, cx| s.rescan(true, cx))),
                    ),
            )
            .child(
                observed(div().id("summary"))
                    .aria_label(summary.clone())
                    .text_size(px(12.))
                    .text_color(rgb(p.muted))
                    .child(summary),
            )
    }

    fn banners(&self, p: Palette, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let m = &self.model;
        let mut banners = Vec::new();
        if !m.full_disk_access && self.mode != Mode::Fixture && m.scanned {
            banners.push(
                card(p, p.review)
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap(px(8.))
                            .child(icon("triangle-alert", p.review))
                            .child(div().flex_1().font_weight(FontWeight::SEMIBOLD).child("Grant Full Disk Access once"))
                            .child(
                                button("grant-access", "Grant Access", p)
                                    .on_click(cx.listener(|s, _, _, cx| s.begin_grant(cx))),
                            ),
                    )
                    .child(
                        div()
                            .text_size(px(11.5))
                            .text_color(rgb(p.muted))
                            .child("Without it, containers, Mail and Safari data stay unmeasured, and macOS would ask about each one. System Settings opens; drag SysData GPUI into the list."),
                    )
                    .into_any_element(),
            );
        }
        if m.scanning && !m.items.is_empty() {
            banners.push(
                observed(div().id("phase"))
                    .aria_label(m.phase.clone())
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .px(px(16.))
                    .py(px(4.))
                    .text_size(px(11.5))
                    .text_color(rgb(p.muted))
                    .child(icon("loader", p.muted))
                    .child(m.phase.clone())
                    .into_any_element(),
            );
        }
        for (id, text, color) in [
            ("notice", m.notice.clone(), p.safe),
            ("error", m.error.clone(), p.review),
        ] {
            if let Some(text) = text {
                banners.push(
                    card(p, color)
                        .child(
                            observed(div().id(id))
                                .aria_label(text.clone())
                                .flex()
                                .items_start()
                                .gap(px(8.))
                                .child(div().flex_1().text_size(px(12.)).child(text))
                                .child(
                                    icon_button(format!("dismiss-{id}"), "close", "Dismiss", p)
                                        .on_click(cx.listener(move |s, _, _, cx| {
                                            if id == "notice" {
                                                s.model.notice = None;
                                            } else {
                                                s.model.error = None;
                                            }
                                            cx.notify();
                                        })),
                                ),
                        )
                        .into_any_element(),
                );
            }
        }
        banners
    }

    fn list(&self, p: Palette, cx: &mut Context<Self>) -> impl IntoElement {
        let groups = self.model.groups();
        let empty = if !groups.is_empty() {
            None
        } else if !self.model.filter.trim().is_empty() {
            Some("No item matches")
        } else if self.model.scanned {
            Some("Nothing to reclaim")
        } else {
            Some("Measuring known locations…")
        };
        let now = SystemTime::now();
        let mut rows: Vec<AnyElement> = Vec::new();
        for group in groups {
            let collapsed = self.model.collapsed.contains(&group.category);
            rows.push(
                self.group_header(group.category, group.total, collapsed, p, cx)
                    .into_any_element(),
            );
            if !collapsed {
                for item in group.items {
                    rows.push(self.row(item, now, p, cx).into_any_element());
                }
            }
        }
        observed(div().id("list"))
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .px(px(12.))
            .pb(px(8.))
            .when_some(empty, |d, text| {
                d.child(
                    observed(div().id("empty"))
                        .aria_label(text)
                        .size_full()
                        .flex()
                        .items_center()
                        .justify_center()
                        .text_color(rgb(p.muted))
                        .child(text),
                )
            })
            .children(rows)
    }

    fn group_header(
        &self,
        category: Category,
        total: u64,
        collapsed: bool,
        p: Palette,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let key = category.key();
        let selectable = self.model.category_selectable(category);
        let selected = self.model.category_selected(category);
        let partly = !selected
            && self
                .model
                .selected_items()
                .iter()
                .any(|i| i.category == category);
        observed(div().id(SharedString::from(format!("group-{key}"))))
            .aria_label(category.title())
            .role(Role::Button)
            .flex()
            .items_center()
            .gap(px(8.))
            .h(px(34.))
            .px(px(4.))
            .mt(px(2.))
            .rounded(px(6.))
            .cursor_pointer()
            .hover(|d| d.bg(rgb(p.hover)))
            .on_click(cx.listener(move |s, _, _, cx| {
                s.model.toggle_collapsed(category);
                cx.notify();
            }))
            .child(icon(
                if collapsed {
                    "chevron-right"
                } else {
                    "chevron-down"
                },
                p.muted,
            ))
            .child(
                checkbox(
                    format!("group-check-{key}"),
                    if selected {
                        Check::On
                    } else if partly {
                        Check::Mixed
                    } else {
                        Check::Off
                    },
                    selectable,
                    p,
                )
                .on_click(cx.listener(move |s, _, _, cx| {
                    cx.stop_propagation();
                    let on = !s.model.category_selected(category);
                    s.model.set_category_selected(category, on);
                    cx.notify();
                })),
            )
            .child(
                div()
                    .flex_1()
                    .font_weight(FontWeight::SEMIBOLD)
                    .child(category.title()),
            )
            .child(
                div()
                    .font_family(MONO)
                    .text_size(px(12.5))
                    .child(format_bytes(total)),
            )
    }

    fn row(
        &self,
        item: &Item,
        now: SystemTime,
        p: Palette,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let id = item.id.clone();
        let busy = self.model.busy.contains(&id);
        let selected = self.model.selected.contains(&id);
        let manual = item.action.is_manual();
        let expanded = self.model.expanded.contains(&id);
        let expandable = manual || item.reveal.is_some();
        let size = item.size.map_or("—".to_string(), format_bytes);
        let safety_color = match item.safety {
            Safety::Safe => p.safe,
            Safety::Review => p.review,
            Safety::Manual => p.muted,
        };
        let row_item = item.clone();
        observed(div().id(SharedString::from(format!("row-{id}"))))
            .aria_label(item.name.clone())
            .role(Role::Row)
            .flex()
            .flex_col()
            .gap(px(6.))
            .py(px(7.))
            .pl(px(26.))
            .pr(px(4.))
            .border_t_1()
            .border_color(rgb(p.border))
            .when(busy, |d| d.opacity(0.5))
            .child(
                div()
                    .flex()
                    .items_start()
                    .gap(px(9.))
                    .child(if manual {
                        div().w(px(15.)).flex_shrink_0().into_any_element()
                    } else {
                        let toggled = id.clone();
                        checkbox(
                            format!("check-{id}"),
                            if selected { Check::On } else { Check::Off },
                            !busy,
                            p,
                        )
                        .mt(px(1.))
                        .on_click(cx.listener(move |s, event: &ClickEvent, _, cx| {
                            let on = !s.model.selected.contains(&toggled);
                            s.model.set_selected(&toggled, on, event.modifiers().shift);
                            cx.notify();
                        }))
                        .into_any_element()
                    })
                    .child(
                        div()
                            .id(SharedString::from(format!("open-{id}")))
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .gap(px(2.))
                            .when(expandable, |d| d.cursor_pointer())
                            .on_click(cx.listener(move |s, _, _, cx| s.toggle_row(&row_item, cx)))
                            .child(
                                div()
                                    .flex()
                                    .items_center()
                                    .gap(px(6.))
                                    .child(
                                        div()
                                            .truncate()
                                            .text_size(px(13.5))
                                            .child(item.name.clone()),
                                    )
                                    .child(
                                        div()
                                            .flex_shrink_0()
                                            .px(px(6.))
                                            .rounded(px(8.))
                                            .text_size(px(10.5))
                                            .font_weight(FontWeight::MEDIUM)
                                            .bg(tint(safety_color, 0x26))
                                            .text_color(rgb(safety_color))
                                            .child(item.safety.label()),
                                    )
                                    .children(item.idle_label(now).map(|idle| {
                                        div()
                                            .flex_shrink_0()
                                            .text_size(px(10.5))
                                            .text_color(rgb(p.faint))
                                            .child(idle)
                                    })),
                            )
                            .child(
                                div()
                                    .text_size(px(11.5))
                                    .text_color(rgb(p.muted))
                                    .line_clamp(2)
                                    .child(item.detail.clone()),
                            ),
                    )
                    .child(
                        observed(div().id(SharedString::from(format!("size-{id}"))))
                            .aria_label(size.clone())
                            .flex_shrink_0()
                            .min_w(px(64.))
                            .text_right()
                            .font_family(MONO)
                            .text_size(px(12.5))
                            .when(item.size.is_none(), |d| d.text_color(rgb(p.muted)))
                            .child(size),
                    )
                    .child(self.row_actions(item, busy, expanded, expandable, p, cx)),
            )
            .when(expanded, |d| d.child(self.expansion(item, p, cx)))
    }

    #[allow(clippy::too_many_arguments)]
    fn row_actions(
        &self,
        item: &Item,
        busy: bool,
        expanded: bool,
        expandable: bool,
        p: Palette,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let id = item.id.clone();
        let name = item.name.clone();
        let toggle_item = item.clone();
        div()
            .flex()
            .items_center()
            .gap(px(2.))
            .flex_shrink_0()
            .when(expandable && !item.action.is_manual(), |d| {
                d.child(
                    icon_button(
                        format!("expand-{id}"),
                        if expanded {
                            "chevron-up"
                        } else {
                            "chevron-down"
                        },
                        if expanded {
                            "Hide breakdown"
                        } else {
                            "Show largest entries"
                        },
                        p,
                    )
                    .on_click(cx.listener(move |s, _, _, cx| s.toggle_row(&toggle_item, cx))),
                )
            })
            .when_some(item.reveal.clone(), |d, path| {
                d.child(
                    icon_button(
                        format!("reveal-{id}"),
                        "folder",
                        format!("Reveal {name} in Finder"),
                        p,
                    )
                    .on_click(move |_, _, _| mac::reveal(&path)),
                )
            })
            .child({
                let hidden = id.clone();
                icon_button(
                    format!("hide-{id}"),
                    "eye-off",
                    "Don't show this item again",
                    p,
                )
                .on_click(cx.listener(move |s, _, _, cx| {
                    s.model.hide(&hidden);
                    s.changed(cx);
                }))
            })
            .child(if busy {
                icon_button(format!("busy-{id}"), "loader", "Working…", p).into_any_element()
            } else if item.action.is_manual() {
                let manual = item.clone();
                icon_button(
                    format!("info-{id}"),
                    "info",
                    format!("How to remove {}", item.name),
                    p,
                )
                .on_click(cx.listener(move |s, _, _, cx| s.toggle_row(&manual, cx)))
                .into_any_element()
            } else {
                let doomed = id.clone();
                icon_button(
                    format!("delete-{id}"),
                    "trash",
                    format!("Delete {}", item.name),
                    p,
                )
                .on_click(
                    cx.listener(move |s, _, _, cx| s.ask_delete(Pending::One(doomed.clone()), cx)),
                )
                .into_any_element()
            })
    }

    fn expansion(&self, item: &Item, p: Palette, cx: &mut Context<Self>) -> AnyElement {
        let id = item.id.clone();
        if let Some(instructions) = item.action.manual_instructions() {
            let text = instructions.to_string();
            return div()
                .ml(px(24.))
                .flex()
                .flex_col()
                .gap(px(6.))
                .child(
                    observed(div().id(SharedString::from(format!("instructions-{id}"))))
                        .aria_label(text.clone())
                        .p(px(8.))
                        .rounded(px(6.))
                        .bg(rgb(p.raised))
                        .font_family(MONO)
                        .text_size(px(11.5))
                        .child(text.clone()),
                )
                .child(
                    button(format!("copy-{id}"), "Copy", p)
                        .w(px(64.))
                        .on_click(cx.listener(move |_, _, _, cx| {
                            cx.write_to_clipboard(ClipboardItem::new_string(text.clone()))
                        })),
                )
                .into_any_element();
        }
        let content: AnyElement = match self.model.breakdowns.get(&id) {
            None => div()
                .text_size(px(11.5))
                .text_color(rgb(p.muted))
                .child("Measuring the largest entries…")
                .into_any_element(),
            Some(children) if children.is_empty() => div()
                .text_size(px(11.5))
                .text_color(rgb(p.muted))
                .child("Empty folder")
                .into_any_element(),
            Some(children) => div()
                .flex()
                .flex_col()
                .gap(px(2.))
                .children(children.iter().map(|(path, bytes, dir)| {
                    div()
                        .flex()
                        .items_center()
                        .gap(px(6.))
                        .text_size(px(11.5))
                        .child(icon(if *dir { "folder" } else { "file" }, p.faint))
                        .child(
                            div().flex_1().truncate().child(
                                path.file_name()
                                    .map_or(String::new(), |n| n.to_string_lossy().into_owned()),
                            ),
                        )
                        .child(
                            div()
                                .font_family(MONO)
                                .text_color(rgb(p.muted))
                                .child(format_bytes(*bytes)),
                        )
                }))
                .into_any_element(),
        };
        div()
            .id(SharedString::from(format!("breakdown-{id}")))
            .ml(px(24.))
            .child(content)
            .into_any_element()
    }

    fn confirmation(&self, p: Palette, cx: &mut Context<Self>) -> impl IntoElement {
        let (title, body) = self.model.confirmation();
        let plan = self.model.pending_plan();
        let admin = self
            .model
            .pending_items()
            .iter()
            .any(|i| i.action.needs_admin());
        let count = self.model.pending_items().len();
        observed(div().id("confirmation"))
            .aria_label(title.clone())
            .flex()
            .flex_col()
            .gap(px(6.))
            .px(px(16.))
            .py(px(10.))
            .border_t_1()
            .border_color(rgb(p.border))
            .bg(tint(p.danger, 0x10))
            .child(div().font_weight(FontWeight::SEMIBOLD).child(title))
            .child(
                observed(div().id("confirmation-body"))
                    .aria_label(body.clone())
                    .text_size(px(12.))
                    .text_color(rgb(p.muted))
                    .child(body),
            )
            .when(!plan.is_empty(), |d| {
                let lines = plan.join("\n");
                d.child(
                    div()
                        .flex()
                        .items_center()
                        .gap(px(8.))
                        .child(
                            observed(div().id("show-plan"))
                                .role(Role::Button)
                                .aria_label("Show exactly what runs")
                                .flex()
                                .items_center()
                                .gap(px(4.))
                                .text_size(px(12.))
                                .text_color(rgb(p.accent))
                                .cursor_pointer()
                                .on_click(cx.listener(|s, _, _, cx| {
                                    s.show_plan = !s.show_plan;
                                    cx.notify();
                                }))
                                .child(icon(
                                    if self.show_plan {
                                        "chevron-down"
                                    } else {
                                        "chevron-right"
                                    },
                                    p.accent,
                                ))
                                .child(if admin {
                                    "Show the commands that run as administrator"
                                } else {
                                    "Show exactly what runs"
                                }),
                        )
                        .when(self.show_plan, |d| {
                            d.child(div().flex_1()).child(
                                button("copy-plan", if self.copied { "Copied" } else { "Copy" }, p)
                                    .on_click(cx.listener(move |s, _, _, cx| {
                                        cx.write_to_clipboard(ClipboardItem::new_string(
                                            lines.clone(),
                                        ));
                                        s.copied = true;
                                        cx.notify();
                                    })),
                            )
                        }),
                )
                .when(self.show_plan, |d| {
                    d.child(
                        observed(div().id("plan"))
                            .aria_label(plan.join("\n"))
                            .max_h(px(120.))
                            .overflow_y_scroll()
                            .p(px(6.))
                            .rounded(px(6.))
                            .bg(rgb(p.raised))
                            .font_family(MONO)
                            .text_size(px(11.))
                            .text_color(rgb(p.muted))
                            .children(plan.iter().map(|line| div().child(line.clone()))),
                    )
                })
            })
            .child(
                div()
                    .flex()
                    .justify_end()
                    .gap(px(8.))
                    .child(
                        button("cancel-delete", "Cancel", p)
                            .on_click(cx.listener(|s, _, _, cx| s.cancel_delete(cx))),
                    )
                    .child(
                        danger_button(
                            "confirm-delete",
                            if count == 1 {
                                "Delete".to_string()
                            } else {
                                format!("Delete {count} items")
                            },
                            p,
                        )
                        .on_click(cx.listener(|s, _, _, cx| s.confirm_delete(cx))),
                    ),
            )
    }

    fn footer(&self, p: Palette, cx: &mut Context<Self>) -> impl IntoElement {
        let m = &self.model;
        let selected = m.selected_items().len();
        let off_screen = m.selected_off_screen();
        let hidden = m.hidden_count();
        let reclaimed = format!("Reclaimed this session: {}", format_bytes(m.reclaimed));
        div()
            .flex()
            .flex_col()
            .gap(px(8.))
            .px(px(16.))
            .py(px(10.))
            .border_t_1()
            .border_color(rgb(p.border))
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .when(selected > 0, |d| {
                        d.child(
                            danger_button(
                                "delete-selected",
                                format!(
                                    "Delete {selected} selected · {}",
                                    format_bytes(m.selected_bytes())
                                ),
                                p,
                            )
                            .on_click(
                                cx.listener(|s, _, _, cx| s.ask_delete(Pending::Selection, cx)),
                            ),
                        )
                        .child(
                            button("clear-selection", "Clear", p).on_click(cx.listener(
                                |s, _, _, cx| {
                                    s.model.clear_selection();
                                    cx.notify();
                                },
                            )),
                        )
                    })
                    .when(selected == 0, |d| {
                        d.child(
                            observed(div().id("reclaimed"))
                                .aria_label(reclaimed.clone())
                                .text_size(px(12.))
                                .text_color(rgb(p.muted))
                                .child(reclaimed),
                        )
                    })
                    .child(div().flex_1())
                    .when(hidden > 0, |d| {
                        d.child(
                            observed(div().id("show-all"))
                                .role(Role::Button)
                                .aria_label(format!("{hidden} hidden · Show all"))
                                .text_size(px(12.))
                                .text_color(rgb(p.accent))
                                .cursor_pointer()
                                .on_click(cx.listener(|s, _, _, cx| {
                                    s.model.unhide_all();
                                    s.changed(cx);
                                }))
                                .child(format!("{hidden} hidden · Show all")),
                        )
                    })
                    .child(button("quit", "Quit", p).on_click(|_, _, cx| cx.quit())),
            )
            .when(off_screen > 0, |d| {
                d.child(
                    observed(div().id("off-screen"))
                        .aria_label(format!(
                            "{off_screen} selected rows are hidden by the filter or a folded group"
                        ))
                        .text_size(px(11.5))
                        .text_color(rgb(p.review))
                        .child(format!(
                            "{off_screen} selected row{} not on screen will be deleted too.",
                            if off_screen == 1 { " is" } else { "s are" }
                        )),
                )
            })
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .text_size(px(12.))
                    .text_color(rgb(p.muted))
                    .child(
                        switch("safe-to-trash", m.safe_to_trash, p).on_click(cx.listener(
                            |s, _, _, cx| {
                                let on = !s.model.safe_to_trash;
                                s.model.set_safe_to_trash(on);
                                cx.notify();
                            },
                        )),
                    )
                    .child("Move Safe items to the Trash too"),
            )
    }
}

impl Render for SysData {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let p = palette(window);
        let banners = self.banners(p, cx);
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(rgb(p.bg))
            .text_color(rgb(p.text))
            .font_family(".AppleSystemUIFont")
            .text_size(px(13.))
            .key_context("SysData")
            .track_focus(&self.focus)
            .on_action(cx.listener(|s, _: &FocusFilter, w, cx| {
                s.filter.update(cx, |input, cx| input.focus(w, cx));
            }))
            .on_action(cx.listener(|s, _: &Rescan, _, cx| s.rescan(true, cx)))
            .on_action(cx.listener(|s, _: &SelectSafe, _, cx| {
                s.model.toggle_safe();
                cx.notify();
            }))
            .on_action(cx.listener(|s, _: &Dismiss, w, cx| {
                if s.model.pending.is_some() {
                    s.cancel_delete(cx);
                } else if s.mode == Mode::MenuBar {
                    status_item::hide();
                }
                s.focus.focus(w, cx);
            }))
            .child(self.header(p, cx))
            .child(
                div().px(px(16.)).pb(px(10.)).child(
                    div()
                        .flex()
                        .items_center()
                        .h(px(30.))
                        .rounded(px(7.))
                        .bg(rgb(p.raised))
                        .child(
                            Input::new(&self.filter)
                                .id("filter")
                                .small()
                                .appearance(false)
                                .bordered(false)
                                .cleanable(true)
                                .prefix(icon("search", p.faint)),
                        ),
                ),
            )
            .child(div().h(px(1.)).bg(rgb(p.border)))
            .children(banners)
            .child(self.list(p, cx))
            .when(self.model.pending.is_some(), |d| {
                d.child(self.confirmation(p, cx))
            })
            .child(self.footer(p, cx))
    }
}

/// Keeps the guide on the Settings window's bottom edge as that window
/// appears, moves or closes.
fn place_guide(window: &Window) {
    let frame = grant::anchor(
        grant::settings_window(),
        grant::main_screen(),
        GUIDE_WIDTH,
        GUIDE_HEIGHT,
    );
    grant::place(window, frame);
}

/// The floating guide: drag the card into System Settings' list.
pub struct GrantGuide {
    granted: bool,
}

impl GrantGuide {
    pub fn new(granted: bool) -> Self {
        Self { granted }
    }
}

impl Render for GrantGuide {
    fn render(&mut self, window: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        let p = palette(window);
        let name = "SysData GPUI";
        let at = |d: Div, top: f64| d.absolute().top(px(top as f32)).left(px(14.));
        div()
            .size_full()
            .relative()
            .bg(rgb(p.bg))
            .text_color(rgb(p.text))
            .font_family(".AppleSystemUIFont")
            .text_size(px(12.5))
            .when(!self.granted, |d| {
                d.child(
                    at(div(), 11.)
                        .right(px(10.))
                        .h(px(20.))
                        .flex()
                        .items_center()
                        .gap(px(6.))
                        .child(icon("arrow-up", p.accent))
                        .child(
                            div()
                                .flex_1()
                                .font_weight(FontWeight::MEDIUM)
                                .child(format!("Drag {name} into the Full Disk Access list")),
                        )
                        .child(
                            icon_button("grant-dismiss", "close", "Close", p)
                                .on_click(|_, w, _| w.remove_window()),
                        ),
                )
                .child(
                    observed(div().id("grant-card"))
                        .aria_label(name)
                        .absolute()
                        .top(px(GUIDE_CARD.origin.y as f32))
                        .left(px(GUIDE_CARD.origin.x as f32))
                        .w(px(GUIDE_CARD.size.x as f32))
                        .h(px(GUIDE_CARD.size.y as f32))
                        .px(px(10.))
                        .flex()
                        .items_center()
                        .gap(px(8.))
                        .rounded(px(8.))
                        .bg(rgb(p.raised))
                        .child(
                            div()
                                .size(px(22.))
                                .rounded(px(5.))
                                .bg(rgb(p.accent))
                                .flex()
                                .items_center()
                                .justify_center()
                                .child(icon("hard-drive", 0xffffff)),
                        )
                        .child(div().flex_1().font_weight(FontWeight::MEDIUM).child(name))
                        .child(icon("menu", p.faint)),
                )
                .child(
                    at(div(), 82.)
                        .text_size(px(11.))
                        .text_color(rgb(p.faint))
                        .child(format!("Or click + in System Settings and choose {name}.")),
                )
            })
            .when(self.granted, |d| {
                d.flex()
                    .items_center()
                    .gap(px(12.))
                    .px(px(22.))
                    .child(icon("circle-check", p.safe).size(px(26.)))
                    .child(
                        observed(div().id("grant-granted"))
                            .aria_label("Full Disk Access granted")
                            .flex()
                            .flex_col()
                            .gap(px(2.))
                            .child(
                                div()
                                    .text_size(px(13.5))
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .child("Full Disk Access granted"),
                            )
                            .child(
                                div()
                                    .text_size(px(11.))
                                    .text_color(rgb(p.muted))
                                    .child("Rescanning everything now."),
                            ),
                    )
            })
    }
}

/// Where hidden rows and preferences persist.
fn state_file() -> PathBuf {
    shell::home().join("Library/Application Support/SysData GPUI/state.json")
}

fn observed(div: Stateful<Div>) -> gpui_kit::base::ObservedElement<Stateful<Div>> {
    div.test_support()
}

fn icon(name: &str, color: u32) -> Icon {
    Icon::default()
        .path(SharedString::from(format!("icons/{name}.svg")))
        .size(px(14.))
        .text_color(rgb(color))
}

fn button(
    id: impl Into<SharedString>,
    label: impl Into<SharedString>,
    p: Palette,
) -> gpui_kit::base::ObservedElement<Stateful<Div>> {
    pill(id, label, p.raised, p.text, p.border)
}

fn danger_button(
    id: impl Into<SharedString>,
    label: impl Into<SharedString>,
    p: Palette,
) -> gpui_kit::base::ObservedElement<Stateful<Div>> {
    pill(id, label, p.danger, 0xffffff, p.danger).font_weight(FontWeight::SEMIBOLD)
}

/// GPUI allows one hover style per element, so each variant sets its own.
fn pill(
    id: impl Into<SharedString>,
    label: impl Into<SharedString>,
    bg: u32,
    fg: u32,
    hover: u32,
) -> gpui_kit::base::ObservedElement<Stateful<Div>> {
    let label: SharedString = label.into();
    observed(div().id(id.into()))
        .role(Role::Button)
        .aria_label(label.clone())
        .flex()
        .items_center()
        .justify_center()
        .gap(px(6.))
        .h(px(26.))
        .px(px(10.))
        .rounded(px(7.))
        .bg(rgb(bg))
        .text_color(rgb(fg))
        .text_size(px(12.5))
        .font_weight(FontWeight::MEDIUM)
        .cursor_pointer()
        .hover(move |d| d.bg(rgb(hover)).opacity(0.92))
        .child(label)
}

fn icon_button(
    id: impl Into<SharedString>,
    name: &str,
    label: impl Into<SharedString>,
    p: Palette,
) -> gpui_kit::base::ObservedElement<Stateful<Div>> {
    let label: SharedString = label.into();
    let tip = label.clone();
    observed(div().id(id.into()))
        .role(Role::Button)
        .aria_label(label)
        .flex()
        .items_center()
        .justify_center()
        .size(px(24.))
        .rounded(px(6.))
        .cursor_pointer()
        .hover(|d| d.bg(rgb(p.hover)))
        .tooltip(move |w, cx| Tooltip::new(tip.clone()).build(w, cx))
        .child(icon(name, p.muted))
}

#[derive(Clone, Copy, PartialEq)]
enum Check {
    On,
    Off,
    Mixed,
}

fn checkbox(
    id: impl Into<SharedString>,
    state: Check,
    enabled: bool,
    p: Palette,
) -> gpui_kit::base::ObservedElement<Stateful<Div>> {
    let filled = state != Check::Off;
    observed(div().id(id.into()))
        .role(Role::CheckBox)
        .aria_label(match state {
            Check::On => "checked",
            Check::Off => "unchecked",
            Check::Mixed => "mixed",
        })
        .flex_shrink_0()
        .flex()
        .items_center()
        .justify_center()
        .size(px(15.))
        .rounded(px(4.))
        .border_1()
        .border_color(rgb(if filled { p.accent } else { p.faint }))
        .when(filled, |d| d.bg(rgb(p.accent)))
        .when(!enabled, |d| d.opacity(0.35))
        .when(enabled, |d| d.cursor_pointer())
        .when(state == Check::On, |d| {
            d.child(icon("check", 0xffffff).size(px(11.)))
        })
        .when(state == Check::Mixed, |d| {
            d.child(icon("minus", 0xffffff).size(px(11.)))
        })
}

fn switch(
    id: &'static str,
    on: bool,
    p: Palette,
) -> gpui_kit::base::ObservedElement<Stateful<Div>> {
    observed(div().id(id))
        .role(Role::Switch)
        .aria_label(if on { "on" } else { "off" })
        .flex()
        .items_center()
        .w(px(30.))
        .h(px(18.))
        .p(px(2.))
        .rounded(px(9.))
        .cursor_pointer()
        .bg(rgb(if on { p.accent } else { p.border }))
        .when(on, |d| d.justify_end())
        .child(div().size(px(14.)).rounded(px(7.)).bg(rgb(0xffffff)))
}

fn card(p: Palette, color: u32) -> Div {
    div()
        .mx(px(12.))
        .mt(px(8.))
        .p(px(10.))
        .flex()
        .flex_col()
        .gap(px(6.))
        .rounded(px(8.))
        .bg(tint(color, 0x16))
        .border_1()
        .border_color(tint(color, 0x40))
        .text_color(rgb(p.text))
}

/// The filter field draws itself from GPUI Kit's theme.
fn apply_theme(p: Palette, cx: &mut App) {
    let theme = Theme::global_mut(cx);
    theme.foreground = rgb(p.text).into();
    theme.muted_foreground = rgb(p.faint).into();
    theme.border = rgb(p.border).into();
    theme.caret = rgb(p.accent).into();
    theme.selection = tint(p.accent, 0x40).into();
    theme.popover = rgb(p.bg).into();
    theme.popover_foreground = rgb(p.text).into();
}
