//! Real clicks and typing in a headless GPUI window, on fixture items.
//! Fixture mode never scans or deletes anything on disk.
use gpui_kit::test::TestWindowExt;
use gpui_kit::{AppContext, TestAppContext, WindowHandle, px, size};
use sysdata::ui::{GrantGuide, Mode, SysData};

fn open(cx: &mut TestAppContext) -> WindowHandle<SysData> {
    cx.update(gpui_kit::init);
    cx.open_window(size(px(460.), px(900.)), |window, cx| {
        SysData::new(Mode::Fixture, window, cx)
    })
}

#[gpui_kit::test]
fn groups_start_folded_and_open_on_click(cx: &mut TestAppContext) {
    let handle = open(cx);
    cx.update_window(handle.into(), |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(window.find("total").label(), Some("14.12 GB"));
        assert_eq!(
            window.find("summary").label(),
            Some("6.89 GB safe to free now · 205.94 GB free on disk · 15.99 GB purgeable")
        );
        assert!(
            window.try_find("row-pkg-npm").is_none(),
            "folded on the first scan"
        );
        window.click("group-packages", cx);
    })
    .expect("open packages");
    cx.update_window(handle.into(), |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(window.find("row-pkg-npm").label(), Some("npm cache"));
        assert_eq!(window.find("size-pkg-npm").label(), Some("33.6 MB"));
        // The Manual row offers instructions, never a checkbox or a delete.
        assert!(
            window
                .try_find("check-pkg-homebrew-/opt/homebrew")
                .is_none()
        );
        assert!(
            window
                .try_find("delete-pkg-homebrew-/opt/homebrew")
                .is_none()
        );
        assert!(window.find("info-pkg-homebrew-/opt/homebrew").visible());
    })
    .expect("packages open");
}

#[gpui_kit::test]
fn select_safe_ticks_regenerable_rows_and_offers_one_delete(cx: &mut TestAppContext) {
    let handle = open(cx);
    cx.update_window(handle.into(), |_, window, cx| {
        window.render_frame(cx);
        window.click("select-safe", cx);
    })
    .expect("select safe");
    cx.update_window(handle.into(), |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(window.find("check-pkg-npm").label(), Some("checked"));
        assert_eq!(
            window.find("check-xcode-DerivedData").label(),
            Some("checked")
        );
        assert_eq!(window.find("check-log-unified").label(), Some("checked"));
        assert!(
            window.try_find("row-project-demo/node_modules").is_none(),
            "a group without Safe rows stays folded"
        );
        assert!(
            window.find("row-tool-.codex").visible(),
            "Tools holds a Safe row, so it opens"
        );
        assert_eq!(window.find("select-safe").label(), Some("Deselect safe"));
        assert_eq!(
            window.find("delete-selected").label(),
            Some("Delete 5 selected · 6.89 GB")
        );
        window.click("delete-selected", cx);
    })
    .expect("ask to delete");
    cx.update_window(handle.into(), |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(window.find("confirmation").label(), Some("Delete 5 items?"));
        let body = window
            .find("confirmation-body")
            .label()
            .unwrap_or_default()
            .to_string();
        assert!(body.starts_with("Frees about 6.89 GB."), "{body}");
        assert!(body.contains("1 needs an administrator password"), "{body}");
        window.click("show-plan", cx);
    })
    .expect("show plan");
    cx.update_window(handle.into(), |_, window, cx| {
        window.render_frame(cx);
        let plan = window.find("plan").label().unwrap_or_default().to_string();
        assert!(plan.contains("As administrator: log erase --all"), "{plan}");
        assert!(
            plan.contains("Delete everything inside /tmp/sysdata-fixture/pkg-npm"),
            "{plan}"
        );
        window.click("confirm-delete", cx);
    })
    .expect("confirm");
    cx.update_window(handle.into(), |_, window, cx| {
        window.render_frame(cx);
        assert!(window.try_find("row-pkg-npm").is_none());
        assert!(window.try_find("confirmation").is_none());
        assert_eq!(
            window.find("reclaimed").label(),
            Some("Reclaimed this session: 6.89 GB")
        );
        assert_eq!(window.find("total").label(), Some("7.23 GB"));
    })
    .expect("deleted");
}

#[gpui_kit::test]
fn a_review_row_goes_to_the_trash_and_cancel_keeps_it(cx: &mut TestAppContext) {
    let handle = open(cx);
    cx.update_window(handle.into(), |_, window, cx| {
        window.render_frame(cx);
        window.click("group-tools", cx);
    })
    .expect("open tools");
    cx.update_window(handle.into(), |_, window, cx| {
        window.render_frame(cx);
        window.click("delete-tool-.codex", cx);
    })
    .expect("ask");
    cx.update_window(handle.into(), |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(
            window.find("confirmation").label(),
            Some("Delete Codex CLI data?")
        );
        assert_eq!(
            window.find("confirmation-body").label(),
            Some("Frees about 1.3 GB. It goes to the Trash first.")
        );
        window.click("cancel-delete", cx);
    })
    .expect("cancel");
    cx.update_window(handle.into(), |_, window, cx| {
        window.render_frame(cx);
        assert!(window.try_find("confirmation").is_none());
        assert!(window.find("row-tool-.codex").visible());
        window.click("delete-tool-.codex", cx);
    })
    .expect("ask again");
    cx.update_window(handle.into(), |_, window, cx| {
        window.render_frame(cx);
        window.click("confirm-delete", cx);
    })
    .expect("confirm");
    cx.update_window(handle.into(), |_, window, cx| {
        window.render_frame(cx);
        assert!(window.try_find("row-tool-.codex").is_none());
        assert_eq!(
            window.find("notice").label(),
            Some("Moved to the Trash. Empty the Trash to free the space.")
        );
        // The Trash frees nothing yet, so nothing is claimed as reclaimed.
        assert_eq!(
            window.find("reclaimed").label(),
            Some("Reclaimed this session: 0 bytes")
        );
    })
    .expect("trashed");
}

#[gpui_kit::test]
fn filter_narrows_rows_and_says_when_nothing_matches(cx: &mut TestAppContext) {
    let handle = open(cx);
    cx.update_window(handle.into(), |_, window, cx| {
        window.render_frame(cx);
        window.click("filter", cx);
        window.input("rust", cx);
    })
    .expect("type");
    cx.update_window(handle.into(), |_, window, cx| {
        window.render_frame(cx);
        window.click("group-tools", cx);
    })
    .expect("open tools");
    cx.update_window(handle.into(), |_, window, cx| {
        window.render_frame(cx);
        assert!(window.find("row-tool-.rustup/toolchains").visible());
        assert!(window.try_find("row-tool-.codex").is_none());
        assert!(window.try_find("group-packages").is_none());
        // Clicking the group took focus from the field.
        window.click("filter", cx);
        window.input("zzz", cx);
    })
    .expect("no match");
    cx.update_window(handle.into(), |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(window.find("empty").label(), Some("No item matches"));
    })
    .expect("empty state");
}

#[gpui_kit::test]
fn hiding_a_row_leaves_the_total_until_show_all(cx: &mut TestAppContext) {
    let handle = open(cx);
    cx.update_window(handle.into(), |_, window, cx| {
        window.render_frame(cx);
        window.click("group-projects", cx);
    })
    .expect("open projects");
    cx.update_window(handle.into(), |_, window, cx| {
        window.render_frame(cx);
        window.click("hide-project-demo/node_modules", cx);
    })
    .expect("hide");
    cx.update_window(handle.into(), |_, window, cx| {
        window.render_frame(cx);
        assert!(window.try_find("row-project-demo/node_modules").is_none());
        assert_eq!(window.find("total").label(), Some("13.51 GB"));
        assert_eq!(window.find("show-all").label(), Some("1 hidden · Show all"));
        window.click("show-all", cx);
    })
    .expect("show all");
    cx.update_window(handle.into(), |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(window.find("total").label(), Some("14.12 GB"));
        assert!(window.try_find("show-all").is_none());
    })
    .expect("restored");
}

#[gpui_kit::test]
fn a_manual_row_shows_its_instructions(cx: &mut TestAppContext) {
    let handle = open(cx);
    cx.update_window(handle.into(), |_, window, cx| {
        window.render_frame(cx);
        window.click("group-packages", cx);
    })
    .expect("open packages");
    cx.update_window(handle.into(), |_, window, cx| {
        window.render_frame(cx);
        window.click("info-pkg-homebrew-/opt/homebrew", cx);
    })
    .expect("open instructions");
    cx.update_window(handle.into(), |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(
            window
                .find("instructions-pkg-homebrew-/opt/homebrew")
                .label(),
            Some("brew leaves\nbrew autoremove")
        );
    })
    .expect("instructions");
}

#[gpui_kit::test]
fn the_grant_guide_offers_the_card_then_confirms(cx: &mut TestAppContext) {
    cx.update(gpui_kit::init);
    let waiting = cx.open_window(size(px(380.), px(112.)), |_, _| GrantGuide::new(false));
    cx.update_window(waiting.into(), |_, window, cx| {
        window.render_frame(cx);
        let card = window.find("grant-card");
        assert_eq!(card.label(), Some("SysData GPUI"));
        // The AppKit dragging source is laid over exactly these pixels.
        let bounds = card.bounds();
        assert_eq!((bounds.left(), bounds.top()), (px(14.), px(38.)));
        assert_eq!((bounds.size.width, bounds.size.height), (px(352.), px(34.)));
        assert!(window.try_find("grant-granted").is_none());
    })
    .expect("waiting guide");
    let granted = cx.open_window(size(px(380.), px(112.)), |_, _| GrantGuide::new(true));
    cx.update_window(granted.into(), |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(
            window.find("grant-granted").label(),
            Some("Full Disk Access granted")
        );
        assert!(window.try_find("grant-card").is_none());
    })
    .expect("granted guide");
}
