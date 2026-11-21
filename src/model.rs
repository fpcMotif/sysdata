//! What the window shows and what the person has chosen, without any UI.
//! Every selection rule is written against what is actually on screen: a
//! delete must never reach a row the person cannot see without saying so.
use crate::{
    item::{Category, Item, Safety, format_bytes},
    mac::DiskSpace,
    probes::Progress,
    reclaim::{Event, goes_to_trash},
};
use serde_json::json;
use std::{
    collections::{HashMap, HashSet},
    path::PathBuf,
};

/// The delete waiting for confirmation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Pending {
    One(String),
    Selection,
}

pub struct Group<'a> {
    pub category: Category,
    pub items: Vec<&'a Item>,
    pub total: u64,
}

#[derive(Default)]
pub struct Model {
    pub items: Vec<Item>,
    pub scanning: bool,
    pub scanned: bool,
    pub phase: String,
    pub space: DiskSpace,
    pub reclaimed: u64,
    pub busy: HashSet<String>,
    pub hidden: HashSet<String>,
    pub selected: HashSet<String>,
    pub filter: String,
    pub collapsed: HashSet<Category>,
    pub expanded: HashSet<String>,
    /// Largest direct children, measured when a row is expanded.
    pub breakdowns: HashMap<String, Vec<(PathBuf, u64, bool)>>,
    pub full_disk_access: bool,
    pub pending: Option<Pending>,
    pub notice: Option<String>,
    pub error: Option<String>,
    /// Send Safe items to the Trash as well. Off: Safe items regenerate, and
    /// the Trash frees nothing until it is emptied.
    pub safe_to_trash: bool,
    anchor: Option<String>,
    deleted_during_scan: HashSet<String>,
    batch_failures: Vec<String>,
    batch_trashed: bool,
    state_file: Option<PathBuf>,
}

impl Model {
    /// A model that keeps hidden rows and the Trash preference in `state_file`.
    pub fn load(state_file: Option<PathBuf>) -> Self {
        let mut model = Model {
            state_file,
            ..Default::default()
        };
        let saved = model
            .state_file
            .as_ref()
            .and_then(|p| std::fs::read(p).ok())
            .and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok());
        if let Some(saved) = saved {
            model.hidden = saved["hidden"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|v| v.as_str().map(String::from))
                .collect();
            model.safe_to_trash = saved["safeToTrash"].as_bool().unwrap_or(false);
        }
        model
    }

    fn save(&self) {
        let Some(path) = &self.state_file else {
            return;
        };
        let mut hidden: Vec<&String> = self.hidden.iter().collect();
        hidden.sort();
        let state = json!({ "hidden": hidden, "safeToTrash": self.safe_to_trash });
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let _ = std::fs::write(path, state.to_string());
    }

    pub fn item(&self, id: &str) -> Option<&Item> {
        self.items.iter().find(|i| i.id == id)
    }

    pub fn visible(&self) -> impl Iterator<Item = &Item> {
        self.items.iter().filter(|i| !self.hidden.contains(&i.id))
    }

    pub fn listed(&self) -> impl Iterator<Item = &Item> {
        self.visible().filter(|i| i.matches(&self.filter))
    }

    fn on_screen(&self) -> impl Iterator<Item = &Item> {
        self.listed()
            .filter(|i| !self.collapsed.contains(&i.category))
    }

    /// The System Data this scan found: the headline and the menu bar number.
    pub fn measured_bytes(&self) -> u64 {
        self.visible().map(Item::bytes).sum()
    }

    pub fn safe_bytes(&self) -> u64 {
        self.visible()
            .filter(|i| i.safety == Safety::Safe && !i.action.is_manual())
            .map(Item::bytes)
            .sum()
    }

    pub fn hidden_count(&self) -> usize {
        self.items
            .iter()
            .filter(|i| self.hidden.contains(&i.id))
            .count()
    }

    pub fn selected_items(&self) -> Vec<&Item> {
        self.visible()
            .filter(|i| self.selected.contains(&i.id))
            .collect()
    }

    pub fn selected_bytes(&self) -> u64 {
        self.selected_items().into_iter().map(Item::bytes).sum()
    }

    /// Selected rows a filter or a folded group is hiding. They are still in the batch.
    pub fn selected_off_screen(&self) -> usize {
        let on_screen: HashSet<&str> = self.on_screen().map(|i| i.id.as_str()).collect();
        self.selected_items()
            .iter()
            .filter(|i| !on_screen.contains(i.id.as_str()))
            .count()
    }

    /// Groups in display order: fixed while results stream in, so headers do
    /// not jump under the pointer; largest first once the scan is done.
    pub fn groups(&self) -> Vec<Group<'_>> {
        let mut groups: Vec<Group<'_>> = Category::ALL
            .iter()
            .filter_map(|&category| {
                let mut items: Vec<&Item> =
                    self.listed().filter(|i| i.category == category).collect();
                if items.is_empty() {
                    return None;
                }
                items.sort_by(|a, b| b.bytes().cmp(&a.bytes()).then_with(|| a.name.cmp(&b.name)));
                let total = items.iter().map(|i| i.bytes()).sum();
                Some(Group {
                    category,
                    items,
                    total,
                })
            })
            .collect();
        if !self.scanning {
            groups.sort_by_key(|g| std::cmp::Reverse(g.total));
        }
        groups
    }

    /// Rows in the order the list draws them, for shift-click ranges.
    fn selectable_on_screen(&self) -> Vec<String> {
        self.groups()
            .into_iter()
            .filter(|g| !self.collapsed.contains(&g.category))
            .flat_map(|g| g.items)
            .filter(|i| !i.action.is_manual())
            .map(|i| i.id.clone())
            .collect()
    }

    /// Ticks or unticks one row; with `extend`, everything from the last
    /// clicked row to this one.
    pub fn set_selected(&mut self, id: &str, selected: bool, extend: bool) {
        if self.item(id).is_none_or(|i| i.action.is_manual()) {
            return;
        }
        if extend && let Some(anchor) = self.anchor.clone() {
            let order = self.selectable_on_screen();
            if let (Some(a), Some(b)) = (
                order.iter().position(|x| *x == anchor),
                order.iter().position(|x| x == id),
            ) {
                for id in &order[a.min(b)..=a.max(b)] {
                    if selected {
                        self.selected.insert(id.clone());
                    } else {
                        self.selected.remove(id);
                    }
                }
                return;
            }
        }
        if selected {
            self.selected.insert(id.to_string());
        } else {
            self.selected.remove(id);
        }
        self.anchor = Some(id.to_string());
    }

    fn selectable_in(&self, category: Category) -> Vec<String> {
        self.listed()
            .filter(|i| i.category == category && !i.action.is_manual())
            .map(|i| i.id.clone())
            .collect()
    }

    pub fn category_selectable(&self, category: Category) -> bool {
        !self.selectable_in(category).is_empty()
    }

    pub fn category_selected(&self, category: Category) -> bool {
        let ids = self.selectable_in(category);
        !ids.is_empty() && ids.iter().all(|id| self.selected.contains(id))
    }

    pub fn set_category_selected(&mut self, category: Category, selected: bool) {
        for id in self.selectable_in(category) {
            if selected {
                self.selected.insert(id);
            } else {
                self.selected.remove(&id);
            }
        }
        self.anchor = None;
    }

    /// Listed Safe rows, excluding the Trash: emptying it is permanent and it
    /// holds what Review deletions just put there.
    fn listed_safe(&self) -> Vec<(String, Category)> {
        self.listed()
            .filter(|i| {
                i.safety == Safety::Safe && !i.action.is_manual() && i.category != Category::Trash
            })
            .map(|i| (i.id.clone(), i.category))
            .collect()
    }

    pub fn all_safe_selected(&self) -> bool {
        let safe = self.listed_safe();
        !safe.is_empty() && safe.iter().all(|(id, _)| self.selected.contains(id))
    }

    /// Ticks every listed Safe row and opens the groups holding them; a
    /// second press unticks them. Rows the filter hides are left as they are.
    pub fn toggle_safe(&mut self) {
        let safe = self.listed_safe();
        if safe.is_empty() {
            return;
        }
        if self.all_safe_selected() {
            for (id, _) in &safe {
                self.selected.remove(id);
            }
        } else {
            for (id, category) in safe {
                self.selected.insert(id);
                self.collapsed.remove(&category);
            }
        }
        self.anchor = None;
    }

    pub fn clear_selection(&mut self) {
        self.selected.clear();
        self.anchor = None;
    }

    pub fn set_filter(&mut self, filter: String) {
        if filter != self.filter {
            self.filter = filter;
            self.anchor = None;
        }
    }

    pub fn toggle_collapsed(&mut self, category: Category) {
        if !self.collapsed.remove(&category) {
            self.collapsed.insert(category);
        }
        self.anchor = None;
    }

    pub fn toggle_expanded(&mut self, id: &str) -> bool {
        if self.expanded.remove(id) {
            false
        } else {
            self.expanded.insert(id.to_string());
            true
        }
    }

    pub fn hide(&mut self, id: &str) {
        self.hidden.insert(id.to_string());
        self.selected.remove(id);
        if self.anchor.as_deref() == Some(id) {
            self.anchor = None;
        }
        self.save();
    }

    pub fn unhide_all(&mut self) {
        self.hidden.clear();
        self.save();
    }

    pub fn set_safe_to_trash(&mut self, on: bool) {
        self.safe_to_trash = on;
        self.save();
    }

    // Scanning

    /// Starts a scan. A quiet rescan keeps the current list, selection and
    /// filter until the new results replace them.
    pub fn begin_scan(&mut self, quiet: bool) {
        let keep = quiet && self.scanned;
        self.scanning = true;
        self.phase = "Measuring known locations…".into();
        self.deleted_during_scan.clear();
        if !self.scanned {
            self.collapsed = Category::ALL.into_iter().collect();
        }
        if !keep {
            self.items.clear();
            self.selected.clear();
            self.filter.clear();
            self.error = None;
            self.anchor = None;
            self.breakdowns.clear();
        }
    }

    pub fn accept_progress(&mut self, progress: Progress, quiet: bool) {
        match progress {
            Progress::Batch {
                items,
                finished,
                total,
            } => {
                if !(quiet && self.scanned) {
                    self.items.extend(
                        items
                            .into_iter()
                            .filter(|i| !self.deleted_during_scan.contains(&i.id)),
                    );
                }
                self.phase = format!("Measuring… {finished} of {total} places");
            }
            Progress::CatchAll => self.phase = "Looking for anything else over 500 MB…".into(),
        }
    }

    pub fn finish_scan(&mut self, items: Vec<Item>, space: DiskSpace) {
        self.items = items
            .into_iter()
            .filter(|i| !self.deleted_during_scan.contains(&i.id))
            .collect();
        let present: HashSet<&str> = self.items.iter().map(|i| i.id.as_str()).collect();
        self.selected.retain(|id| present.contains(id.as_str()));
        self.expanded.retain(|id| present.contains(id.as_str()));
        self.breakdowns
            .retain(|id, _| present.contains(id.as_str()));
        if self
            .anchor
            .as_ref()
            .is_some_and(|a| !self.selected.contains(a))
        {
            self.anchor = None;
        }
        self.space = space;
        self.scanning = false;
        self.scanned = true;
        self.phase.clear();
    }

    // Deleting

    pub fn pending_items(&self) -> Vec<&Item> {
        match &self.pending {
            Some(Pending::One(id)) => self.item(id).into_iter().collect(),
            Some(Pending::Selection) => self.selected_items(),
            None => Vec::new(),
        }
    }

    /// Every operation the pending delete will run, one per line.
    pub fn pending_plan(&self) -> Vec<String> {
        self.pending_items()
            .iter()
            .flat_map(|i| i.action.plan())
            .collect()
    }

    pub fn confirmation(&self) -> (String, String) {
        let items = self.pending_items();
        let bytes: u64 = items.iter().map(|i| i.bytes()).sum();
        let title = match (&self.pending, items.as_slice()) {
            (Some(Pending::One(_)), [item]) => format!("Delete {}?", item.name),
            _ => format!("Delete {} items?", items.len()),
        };
        let mut body = if bytes > 0 {
            format!("Frees about {}. ", format_bytes(bytes))
        } else {
            String::new()
        };
        let trashed: Vec<&str> = items
            .iter()
            .filter(|i| goes_to_trash(i, self.safe_to_trash))
            .map(|i| i.name.as_str())
            .collect();
        match (items.len(), trashed.len()) {
            (count, 0) => {
                if items.iter().all(|i| i.safety == Safety::Safe) {
                    body.push_str(if count == 1 {
                        "It is regenerated automatically when needed."
                    } else {
                        "All of it is regenerated automatically when needed."
                    });
                }
            }
            (1, 1) => body.push_str("It goes to the Trash first."),
            (_, n) => body.push_str(&format!(
                "{n} go to the Trash first: {}.",
                trashed.join(", ")
            )),
        }
        let admin = items.iter().filter(|i| i.action.needs_admin()).count();
        if admin > 0 {
            body.push_str(&format!(
                " {admin} need{} an administrator password, asked once.",
                if admin == 1 { "s" } else { "" }
            ));
        }
        (title, body.trim().to_string())
    }

    /// The batch to run, with busy rows marked. Clears the pending delete.
    pub fn take_pending(&mut self) -> Vec<Item> {
        let batch: Vec<Item> = self
            .pending_items()
            .into_iter()
            .filter(|i| !i.action.is_manual() && !self.busy.contains(&i.id))
            .cloned()
            .collect();
        if self.pending == Some(Pending::Selection) {
            self.clear_selection();
        }
        self.pending = None;
        self.notice = None;
        self.error = None;
        self.batch_failures.clear();
        self.batch_trashed = false;
        batch
    }

    pub fn apply(&mut self, event: Event) {
        match event {
            Event::Busy(ids) => self.busy.extend(ids),
            Event::Done {
                ids,
                trashed,
                freed,
            } => {
                let gone: HashSet<&String> = ids.iter().collect();
                self.items.retain(|i| !gone.contains(&i.id));
                for id in &ids {
                    self.busy.remove(id);
                    self.selected.remove(id);
                    self.expanded.remove(id);
                    if self.scanning {
                        self.deleted_during_scan.insert(id.clone());
                    }
                }
                self.reclaimed += freed;
                if trashed {
                    self.batch_trashed = true;
                    self.notice =
                        Some("Moved to the Trash. Empty the Trash to free the space.".into());
                }
            }
            Event::Failed { ids, message } => {
                for id in &ids {
                    self.busy.remove(id);
                }
                self.batch_failures.push(message);
                self.error = Some(self.batch_failures.join("\n"));
            }
            Event::Stopped { deleted, remaining } => {
                for id in &remaining {
                    self.busy.remove(id);
                }
                self.selected = remaining.into_iter().collect();
                self.error = None;
                self.notice = Some(if deleted == 0 {
                    "Cancelled. Nothing was deleted.".into()
                } else {
                    format!("Cancelled. {deleted} already deleted, the rest left alone.")
                });
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::item::Action;

    fn item(id: &str, category: Category, safety: Safety, bytes: u64) -> Item {
        let action = if safety == Safety::Manual {
            Action::Manual("by hand".into())
        } else {
            Action::RemovePaths(vec![format!("/tmp/sysdata-model/{id}").into()])
        };
        Item::new(
            id,
            category,
            id,
            format!("{id} detail"),
            Some(bytes),
            safety,
            action,
        )
    }

    fn model() -> Model {
        let mut model = Model::default();
        model.begin_scan(false);
        model.finish_scan(
            vec![
                item("npm", Category::Packages, Safety::Safe, 30),
                item("yarn", Category::Packages, Safety::Safe, 20),
                item("claude", Category::Tools, Safety::Review, 500),
                item("brew-install", Category::Packages, Safety::Manual, 900),
                item("trash", Category::Trash, Safety::Safe, 5),
                item("logs", Category::Logs, Safety::Safe, 7),
            ],
            DiskSpace::default(),
        );
        model
    }

    #[test]
    fn first_scan_folds_every_group_and_select_safe_opens_theirs() {
        let mut m = model();
        assert_eq!(m.collapsed.len(), Category::ALL.len());
        m.toggle_safe();
        let mut selected: Vec<&str> = m.selected.iter().map(String::as_str).collect();
        selected.sort();
        assert_eq!(
            selected,
            ["logs", "npm", "yarn"],
            "never the Trash or a Manual row"
        );
        assert!(!m.collapsed.contains(&Category::Packages));
        assert!(m.collapsed.contains(&Category::Tools));
        m.toggle_safe();
        assert!(m.selected.is_empty(), "a second press unticks");
    }

    #[test]
    fn groups_sort_by_total_once_the_scan_is_done() {
        let m = model();
        let order: Vec<Category> = m.groups().iter().map(|g| g.category).collect();
        assert_eq!(order[0], Category::Packages);
        assert_eq!(order[1], Category::Tools);
        assert_eq!(m.measured_bytes(), 1462);
    }

    #[test]
    fn a_filter_keeps_the_selection_but_reports_what_it_hides() {
        let mut m = model();
        m.collapsed.clear();
        m.set_selected("npm", true, false);
        m.set_filter("claude".into());
        assert_eq!(m.selected_off_screen(), 1);
        assert_eq!(m.selected_items().len(), 1);
    }

    #[test]
    fn shift_click_selects_the_drawn_range() {
        let mut m = model();
        m.collapsed.clear();
        m.set_selected("npm", true, false);
        m.set_selected("logs", true, true);
        // Packages (npm, yarn; the Manual row is skipped), Tools (claude), Logs.
        for id in ["npm", "yarn", "claude", "logs"] {
            assert!(m.selected.contains(id), "{id}");
        }
        assert!(!m.selected.contains("brew-install"));
    }

    #[test]
    fn manual_rows_cannot_be_selected_and_hidden_rows_leave_the_totals() {
        let mut m = model();
        m.set_selected("brew-install", true, false);
        assert!(m.selected.is_empty());
        m.hide("claude");
        assert_eq!(m.measured_bytes(), 962);
        assert_eq!(m.hidden_count(), 1);
        m.unhide_all();
        assert_eq!(m.measured_bytes(), 1462);
    }

    #[test]
    fn confirmation_names_what_goes_to_the_trash() {
        let mut m = model();
        m.pending = Some(Pending::One("claude".into()));
        assert_eq!(
            m.confirmation(),
            (
                "Delete claude?".into(),
                "Frees about 500 bytes. It goes to the Trash first.".into()
            )
        );
        m.set_selected("npm", true, false);
        m.set_selected("claude", true, false);
        m.pending = Some(Pending::Selection);
        let (title, body) = m.confirmation();
        assert_eq!(title, "Delete 2 items?");
        assert!(body.ends_with("1 go to the Trash first: claude."), "{body}");
    }

    #[test]
    fn deletions_update_the_list_and_a_cancel_restores_the_selection() {
        let mut m = model();
        m.set_selected("npm", true, false);
        m.set_selected("yarn", true, false);
        m.pending = Some(Pending::Selection);
        let batch = m.take_pending();
        assert_eq!(batch.len(), 2);
        assert!(m.selected.is_empty());
        m.apply(Event::Busy(vec!["npm".into()]));
        m.apply(Event::Done {
            ids: vec!["npm".into()],
            trashed: false,
            freed: 30,
        });
        m.apply(Event::Stopped {
            deleted: 1,
            remaining: vec!["yarn".into()],
        });
        assert!(m.item("npm").is_none());
        assert_eq!(m.reclaimed, 30);
        assert!(m.selected.contains("yarn"));
        assert_eq!(
            m.notice.as_deref(),
            Some("Cancelled. 1 already deleted, the rest left alone.")
        );
    }

    #[test]
    fn hidden_rows_and_the_trash_preference_persist() {
        let file = std::env::temp_dir().join(format!("sysdata-state-{}.json", std::process::id()));
        let mut m = Model::load(Some(file.clone()));
        m.hide("x");
        m.set_safe_to_trash(true);
        let again = Model::load(Some(file.clone()));
        assert!(again.hidden.contains("x"));
        assert!(again.safe_to_trash);
        let _ = std::fs::remove_file(file);
    }
}
