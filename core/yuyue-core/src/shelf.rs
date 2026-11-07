//! Organising the shelf: reading status and collections.
//!
//! Registers: `book/<id>` · `finished` (marked read), `collection/<id>` · `name` / `icon` /
//! `order` / `usedAt` / `deleted`, and `member/<collection>/<book>` · `in`. Membership is one
//! register per pair, so adding a book on one device and another book on a second device
//! both survive a sync.

use std::collections::BTreeMap;

use serde_json::{Value, json};

use crate::api::{BookSummary, YuyueCore, lock, now_ms};
use crate::error::{CoreError, Result};
use crate::store::Store;

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum ReadingStatus {
    /// Not opened yet.
    Want,
    Reading,
    Finished,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BookCollection {
    pub id: String,
    pub name: String,
    /// The app's name for the icon; `None` lets the app pick one.
    pub icon: Option<String>,
    /// Books in it that are still on the shelf.
    pub count: u32,
    /// When a book was last put in it (ms), for "recently used" lists.
    pub used_at: i64,
}

/// A book reads as finished when marked so, or when the reader got to the very end.
const DONE_AT: f64 = 0.995;

pub(crate) fn status(fields: &BTreeMap<String, Value>, progress: f64) -> ReadingStatus {
    match fields.get("finished").and_then(Value::as_bool) {
        Some(true) => ReadingStatus::Finished,
        // Unmarked by hand: back to reading, wherever the progress is.
        Some(false) if progress > 0.0 => ReadingStatus::Reading,
        _ if progress >= DONE_AT => ReadingStatus::Finished,
        _ if progress > 0.0 || fields.contains_key("openedAt") => ReadingStatus::Reading,
        _ => ReadingStatus::Want,
    }
}

pub(crate) fn collections_of(store: &Store, book: &str) -> Result<Vec<String>> {
    let live = live_collections(store)?;
    let mut out = Vec::new();
    for (entity, f) in store.entities("member/")? {
        let Some((c, b)) = entity.strip_prefix("member/").and_then(|r| r.split_once('/')) else { continue };
        if b == book && f.get("in") == Some(&json!(true)) && live.contains_key(c) {
            out.push((live[c].clone(), c.to_string()));
        }
    }
    out.sort();
    Ok(out.into_iter().map(|(_, c)| c).collect())
}

/// Collection id → its sort key (order, then creation stamp) for collections not deleted.
fn live_collections(store: &Store) -> Result<BTreeMap<String, (i64, String)>> {
    Ok(store
        .entities("collection/")?
        .into_iter()
        .filter(|(_, f)| f.get("deleted") != Some(&json!(true)) && f.contains_key("name"))
        .filter_map(|(e, f)| {
            let id = e.strip_prefix("collection/")?.to_string();
            let order = f.get("order").and_then(Value::as_i64).unwrap_or(0);
            Some((id.clone(), (order, id)))
        })
        .collect())
}

fn new_id() -> String {
    format!("{:016x}", getrandom::u64().unwrap_or_else(|_| now_ms() as u64 ^ (std::process::id() as u64) << 40))
}

fn check_id(id: &str) -> Result<()> {
    if id.len() == 16 && id.bytes().all(|b| b.is_ascii_hexdigit()) {
        Ok(())
    } else {
        Err(CoreError::not_found("collection"))
    }
}

fn clean_name(name: &str) -> Result<String> {
    let name = name.split_whitespace().collect::<Vec<_>>().join(" ");
    if name.is_empty() {
        return Err(CoreError::Invalid { detail: crate::i18n::tr("合集要有名字", "A collection needs a name") });
    }
    Ok(name.chars().take(40).collect())
}

#[uniffi::export]
impl YuyueCore {
    /// The shelf, in the order the user arranged it (new ones last).
    pub fn collections(&self) -> Result<Vec<BookCollection>> {
        let store = lock(&self.store);
        let live = live_collections(&store)?;
        let books: BTreeMap<String, bool> = store
            .entities("book/")?
            .into_iter()
            .filter_map(|(e, f)| Some((e.strip_prefix("book/")?.to_string(), f.get("deleted") != Some(&json!(true)))))
            .collect();
        let mut counts: BTreeMap<&str, u32> = BTreeMap::new();
        for (entity, f) in store.entities("member/")? {
            let Some((c, b)) = entity.strip_prefix("member/").and_then(|r| r.split_once('/')) else { continue };
            if f.get("in") == Some(&json!(true))
                && books.get(b) == Some(&true)
                && let Some((key, _)) = live.get_key_value(c)
            {
                *counts.entry(key.as_str()).or_default() += 1;
            }
        }
        let mut out: Vec<((i64, String), BookCollection)> = Vec::new();
        for (id, key) in &live {
            let f = store.fields(&format!("collection/{id}"))?;
            out.push((
                key.clone(),
                BookCollection {
                    id: id.clone(),
                    name: f.get("name").and_then(Value::as_str).unwrap_or_default().to_string(),
                    icon: f.get("icon").and_then(Value::as_str).map(str::to_string),
                    count: counts.get(id.as_str()).copied().unwrap_or(0),
                    used_at: f.get("usedAt").and_then(Value::as_i64).unwrap_or(0),
                },
            ));
        }
        out.sort_by(|a, b| a.0.cmp(&b.0));
        Ok(out.into_iter().map(|(_, c)| c).collect())
    }

    /// Makes a collection, last on the shelf. With `book`, puts that book in it straight away.
    pub fn create_collection(&self, name: String, icon: Option<String>, book: Option<String>) -> Result<BookCollection> {
        let name = clean_name(&name)?;
        let id = new_id();
        {
            let mut store = lock(&self.store);
            let order = live_collections(&store)?.values().map(|k| k.0).max().map_or(0, |m| m + 1);
            let mut fields = vec![("name", json!(name)), ("order", json!(order)), ("usedAt", json!(now_ms()))];
            if let Some(icon) = &icon {
                fields.push(("icon", json!(icon)));
            }
            store.set_fields(&format!("collection/{id}"), &fields)?;
        }
        if let Some(book) = book {
            self.set_in_collection(id.clone(), book, true)?;
        }
        self.collections()?.into_iter().find(|c| c.id == id).ok_or_else(|| CoreError::not_found("collection"))
    }

    pub fn rename_collection(&self, id: String, name: String) -> Result<()> {
        check_id(&id)?;
        lock(&self.store).set(&format!("collection/{id}"), "name", json!(clean_name(&name)?))
    }

    pub fn set_collection_icon(&self, id: String, icon: Option<String>) -> Result<()> {
        check_id(&id)?;
        lock(&self.store).set(&format!("collection/{id}"), "icon", icon.map_or(Value::Null, |i| json!(i)))
    }

    /// Removes the collection; its books stay on the shelf.
    pub fn delete_collection(&self, id: String) -> Result<()> {
        check_id(&id)?;
        lock(&self.store).set(&format!("collection/{id}"), "deleted", json!(true))
    }

    /// Undoes `delete_collection`.
    pub fn restore_collection(&self, id: String) -> Result<()> {
        check_id(&id)?;
        lock(&self.store).set(&format!("collection/{id}"), "deleted", json!(false))
    }

    /// Puts the collections in this order (ids not listed keep their place after these).
    pub fn reorder_collections(&self, ids: Vec<String>) -> Result<()> {
        let mut store = lock(&self.store);
        for (i, id) in ids.iter().enumerate() {
            check_id(id)?;
            let entity = format!("collection/{id}");
            if store.get(&entity, "order")? != Some(json!(i)) {
                store.set(&entity, "order", json!(i))?;
            }
        }
        Ok(())
    }

    pub fn set_in_collection(&self, collection: String, book: String, inside: bool) -> Result<()> {
        check_id(&collection)?;
        self.book_dir(&book)?;
        let mut store = lock(&self.store);
        store.set(&format!("member/{collection}/{book}"), "in", json!(inside))?;
        if inside {
            store.set(&format!("collection/{collection}"), "usedAt", json!(now_ms()))?;
        }
        Ok(())
    }

    /// The books in a collection, most recently opened first.
    pub fn collection_books(&self, collection: String) -> Result<Vec<BookSummary>> {
        check_id(&collection)?;
        Ok(self.books()?.into_iter().filter(|b| b.collections.contains(&collection)).collect())
    }

    /// 编辑信息: the title and authors the shelf shows. Empty ones go back to the file's.
    pub fn edit_book_info(&self, book: String, title: String, authors: Vec<String>) -> Result<BookSummary> {
        self.book_dir(&book)?;
        let title = title.split_whitespace().collect::<Vec<_>>().join(" ");
        let authors: Vec<String> = authors
            .iter()
            .map(|a| a.split_whitespace().collect::<Vec<_>>().join(" "))
            .filter(|a| !a.is_empty())
            .collect();
        let entity = format!("book/{book}");
        lock(&self.store).set_fields(
            &entity,
            &[
                ("titleEdit", if title.is_empty() { Value::Null } else { json!(title) }),
                ("authorsEdit", if authors.is_empty() { Value::Null } else { json!(authors) }),
            ],
        )?;
        self.summary(&book)
    }

    /// 标为读完 / 标为没读完.
    pub fn set_finished(&self, book: String, finished: bool) -> Result<()> {
        self.book_dir(&book)?;
        // When it was finished, for 今年读完.
        let at = if finished { json!(now_ms()) } else { Value::Null };
        lock(&self.store).set_fields(&format!("book/{book}"), &[("finished", json!(finished)), ("finishedAt", at)])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> String {
        format!("{}/../../fixtures/books/{name}", env!("CARGO_MANIFEST_DIR"))
    }

    fn temp(name: &str) -> String {
        let dir = std::env::temp_dir().join(format!("yuyue-shelf-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir.to_string_lossy().into_owned()
    }

    #[test]
    fn collections_status_and_undo() {
        let dir = temp("one");
        let core = YuyueCore::open(dir.clone(), "Mac".into(), "macos".into()).unwrap();
        let a = core.import_book(fixture("pride-and-prejudice.epub")).unwrap();
        let b = core.import_book(fixture("beiying.txt")).unwrap();
        assert_eq!(a.status, ReadingStatus::Want);

        let night = core.create_collection("  睡前  ".into(), Some("moon".into()), Some(a.id.clone())).unwrap();
        assert_eq!((night.name.as_str(), night.count, night.icon.as_deref()), ("睡前", 1, Some("moon")));
        assert!(core.create_collection(" ".into(), None, None).is_err());
        let sf = core.create_collection("科幻".into(), None, None).unwrap();
        core.set_in_collection(sf.id.clone(), a.id.clone(), true).unwrap();
        core.set_in_collection(sf.id.clone(), b.id.clone(), true).unwrap();
        core.set_in_collection(sf.id.clone(), b.id.clone(), false).unwrap();
        let names: Vec<_> = core.collections().unwrap().into_iter().map(|c| (c.name, c.count)).collect();
        assert_eq!(names, [("睡前".to_string(), 1), ("科幻".to_string(), 1)]);
        core.reorder_collections(vec![sf.id.clone(), night.id.clone()]).unwrap();
        assert_eq!(core.collections().unwrap()[0].id, sf.id);
        let book = core.books().unwrap().into_iter().find(|x| x.id == a.id).unwrap();
        assert_eq!(book.collections, [sf.id.clone(), night.id.clone()]);
        assert_eq!(core.collection_books(night.id.clone()).unwrap().len(), 1);

        core.save_progress(b.id.clone(), crate::api::Position { section: 0, sentence: 0 }).unwrap();
        core.set_finished(a.id.clone(), true).unwrap();
        let st = |id: &str| core.books().unwrap().into_iter().find(|x| x.id == id).unwrap().status;
        assert_eq!((st(&a.id), st(&b.id)), (ReadingStatus::Finished, ReadingStatus::Reading));
        core.set_finished(a.id.clone(), false).unwrap();
        assert_eq!(st(&a.id), ReadingStatus::Want);

        // Deleting keeps the files until purged, so it can be undone; counts skip it meanwhile.
        core.delete_book(a.id.clone()).unwrap();
        assert_eq!(core.collections().unwrap()[1].count, 0);
        core.restore_book(a.id.clone()).unwrap();
        assert_eq!(core.collections().unwrap()[1].count, 1);
        core.delete_book(a.id.clone()).unwrap();
        assert_eq!(core.purge_deleted(60_000).unwrap(), 0, "too recent");
        assert_eq!(core.purge_deleted(0).unwrap(), 1);
        assert!(core.restore_book(a.id.clone()).is_err());

        let renamed = core.edit_book_info(b.id.clone(), " 背影  ".into(), vec!["朱自清".into(), " ".into()]).unwrap();
        assert_eq!((renamed.title.as_str(), renamed.authors.as_slice()), ("背影", ["朱自清".to_string()].as_slice()));
        let back = core.edit_book_info(b.id.clone(), "".into(), vec![]).unwrap();
        assert_eq!(back.title, b.title);

        core.delete_collection(night.id.clone()).unwrap();
        assert_eq!(core.collections().unwrap().len(), 1);
        core.restore_collection(night.id.clone()).unwrap();
        assert!(core.rename_collection("../x".into(), "y".into()).is_err());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn membership_merges_across_devices() {
        let (da, db) = (temp("a"), temp("b"));
        let a = YuyueCore::open(da.clone(), "iPhone".into(), "ios".into()).unwrap();
        let b = YuyueCore::open(db.clone(), "Mac".into(), "macos".into()).unwrap();
        let x = a.import_book(fixture("edge-cases.epub")).unwrap();
        let y = a.import_book(fixture("beiying.txt")).unwrap();
        b.import_book(fixture("edge-cases.epub")).unwrap();
        b.import_book(fixture("beiying.txt")).unwrap();
        let c = a.create_collection("通勤听".into(), None, None).unwrap();
        b.import_changes(a.export_changes(b.sync_version().unwrap()).unwrap()).unwrap();
        a.set_in_collection(c.id.clone(), x.id.clone(), true).unwrap();
        b.set_in_collection(c.id.clone(), y.id.clone(), true).unwrap();
        b.import_changes(a.export_changes(b.sync_version().unwrap()).unwrap()).unwrap();
        a.import_changes(b.export_changes(a.sync_version().unwrap()).unwrap()).unwrap();
        for core in [&a, &b] {
            assert_eq!(core.collections().unwrap()[0].count, 2);
        }
        std::fs::remove_dir_all(&da).unwrap();
        std::fs::remove_dir_all(&db).unwrap();
    }
}
