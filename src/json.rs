//! `sysdata --json`: the whole inventory for scripts, largest first. Same
//! shape as the Swift app's `--json`, so the two can be compared line by line.
use crate::{
    item::Item,
    mac::{self, DiskSpace},
};
use serde_json::{Value, json};
use std::time::SystemTime;

pub fn inventory(items: &[Item], space: DiskSpace, now: SystemTime) -> Value {
    let mut sorted: Vec<&Item> = items.iter().collect();
    sorted.sort_by(|a, b| b.bytes().cmp(&a.bytes()).then_with(|| a.id.cmp(&b.id)));
    json!({
        "generatedAt": mac::iso8601(now),
        "freeBytes": space.free,
        "purgeableBytes": space.purgeable,
        "totalBytes": items.iter().map(Item::bytes).sum::<u64>(),
        "items": sorted.iter().map(|item| json!({
            "id": item.id,
            "category": item.category.key(),
            "name": item.name,
            "detail": item.detail,
            "sizeBytes": item.size,
            "safety": item.safety.key(),
            "manual": item.action.is_manual(),
            "path": item.reveal.as_ref().map(|p| p.display().to_string()),
            "lastModified": item.modified.map(mac::iso8601),
            "idleDays": item.idle_days(now),
        })).collect::<Vec<_>>(),
    })
}
