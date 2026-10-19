//! 同步冲突: a thought on a highlight changed on two devices before either saw the other's.
//! Sync keeps the newer, as everywhere; the store keeps both (`Store::conflicts`) until the
//! person chooses — this one, that one, or both — and the choice is written as a new change, so
//! every device ends up with it.

use serde_json::{Value, json};

use crate::api::{YuyueCore, lock};
use crate::error::{CoreError, Result};

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct ConflictSide {
    pub device_name: String,
    pub platform: String,
    pub this_device: bool,
    /// When it was written, wall-clock ms.
    pub at: i64,
    pub note: Option<String>,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct NoteConflict {
    pub book: String,
    pub book_title: String,
    pub mark: String,
    pub section: u32,
    /// The words highlighted.
    pub text: String,
    /// The older first; the newer is what the highlight shows now.
    pub older: ConflictSide,
    pub newer: ConflictSide,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum ConflictChoice {
    Older,
    Newer,
    /// 两份都留: the two together, the older first; just the longer when it already holds the other.
    Both,
}

fn note_of(v: &Value) -> Option<String> {
    v.as_str().map(str::trim).filter(|s| !s.is_empty()).map(str::to_string)
}

/// `{ms:013x}.{counter:04x}.{device}`.
fn split_stamp(hlc: &str) -> (i64, &str) {
    let mut parts = hlc.splitn(3, '.');
    let ms = parts.next().and_then(|p| i64::from_str_radix(p, 16).ok()).unwrap_or(0);
    (ms, parts.nth(1).unwrap_or(""))
}

#[uniffi::export]
impl YuyueCore {
    /// Thoughts that differ between two devices, waiting for a choice. Ones on highlights since
    /// deleted are left out.
    pub fn note_conflicts(&self) -> Result<Vec<NoteConflict>> {
        let store = lock(&self.store);
        let me = store.device().to_string();
        let mut out = Vec::new();
        for c in store.conflicts()? {
            let Some(rest) = c.entity.strip_prefix("mark/") else { continue };
            let Some((book, mark)) = rest.split_once('/') else { continue };
            let fields = store.fields(&c.entity)?;
            if fields.get("deleted") == Some(&json!(true)) || store.fields(&format!("book/{book}"))?.get("deleted") == Some(&json!(true)) {
                continue;
            }
            let side = |(value, hlc): &(Value, String)| -> Result<ConflictSide> {
                let (at, device) = split_stamp(hlc);
                let info = store.fields(&format!("device/{device}"))?;
                let text = |k: &str| info.get(k).and_then(Value::as_str).unwrap_or("").to_string();
                Ok(ConflictSide { device_name: text("name"), platform: text("platform"), this_device: device == me, at, note: note_of(value) })
            };
            let title = store.get(&format!("book/{book}"), "title")?.and_then(|v| v.as_str().map(str::to_string)).unwrap_or_default();
            out.push(NoteConflict {
                book: book.to_string(),
                book_title: title,
                mark: mark.to_string(),
                section: fields.get("section").and_then(Value::as_u64).unwrap_or(0) as u32,
                text: fields.get("text").and_then(Value::as_str).unwrap_or("").to_string(),
                older: side(&c.older)?,
                newer: side(&c.newer)?,
            });
        }
        Ok(out)
    }

    /// Settles one: the chosen thought becomes the highlight's, on every device.
    pub fn resolve_note_conflict(&self, book: String, mark: String, choice: ConflictChoice) -> Result<()> {
        let entity = format!("mark/{book}/{mark}");
        let mut store = lock(&self.store);
        let Some(c) = store.conflicts()?.into_iter().find(|c| c.entity == entity && c.field == "note") else {
            return Err(CoreError::not_found("conflict"));
        };
        let (older, newer) = (note_of(&c.older.0), note_of(&c.newer.0));
        let note = match choice {
            ConflictChoice::Older => older,
            ConflictChoice::Newer => newer,
            ConflictChoice::Both => match (older, newer) {
                (Some(a), Some(b)) if b.contains(&a) => Some(b),
                (Some(a), Some(b)) if a.contains(&b) => Some(a),
                (Some(a), Some(b)) => Some(format!("{a}\n\n{b}")),
                (a, b) => a.or(b),
            },
        };
        store.set(&entity, "note", note.map_or(Value::Null, |n| json!(n)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::notes::{MarkStyle, TextPoint};
    use crate::store::Store;

    fn two_devices() -> (Store, Store) {
        let a = Store::in_memory("aaaa", Box::new(|| 1_000)).unwrap();
        let b = Store::in_memory("bbbb", Box::new(|| 2_000)).unwrap();
        (a, b)
    }

    fn sync(from: &Store, to: &mut Store) {
        let batch = from.export(&to.version().unwrap()).unwrap();
        to.import(&batch).unwrap();
    }

    #[test]
    fn edits_made_apart_are_kept_both_until_chosen() {
        let (mut a, mut b) = two_devices();
        let m = "mark/0123456789abcdef0123456789abcdef/m1";
        a.set(m, "note", json!("这一段每次读都会停下来。")).unwrap();
        sync(&a, &mut b);
        // Both change it before hearing from the other.
        a.set(m, "note", json!("这一段每次读都会停下来。他探身下去的样子")).unwrap();
        b.set(m, "note", json!("不想读了")).unwrap();
        sync(&a, &mut b);
        let c = b.conflicts().unwrap();
        assert_eq!(c.len(), 1);
        assert_eq!(c[0].newer.0, json!("不想读了"));
        // The other side heard of b's after its own: b's came later and settled nothing new there.
        sync(&b, &mut a);
        assert!(a.conflicts().unwrap().is_empty());
        // Choosing on b writes it anew, and a's next sync from b takes it.
        b.set(m, "note", json!("这一段每次读都会停下来。他探身下去的样子")).unwrap();
        assert!(b.conflicts().unwrap().is_empty());
        sync(&b, &mut a);
        assert_eq!(a.get(m, "note").unwrap(), Some(json!("这一段每次读都会停下来。他探身下去的样子")));
    }

    #[test]
    fn a_later_edit_that_saw_it_is_no_clash() {
        let (mut a, mut b) = two_devices();
        let m = "mark/0123456789abcdef0123456789abcdef/m1";
        a.set(m, "note", json!("一")).unwrap();
        sync(&a, &mut b);
        b.set(m, "note", json!("二")).unwrap();
        sync(&b, &mut a);
        assert!(a.conflicts().unwrap().is_empty());
    }

    #[test]
    fn both_keeps_the_longer_when_it_holds_the_other() {
        let dir = std::env::temp_dir().join(format!("yuyue-conflict-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let open = |name: &str| YuyueCore::open(dir.join(name).to_string_lossy().into_owned(), name.into(), "ios".into()).unwrap();
        let (a, b) = (open("a"), open("b"));
        let book = a.import_book(format!("{}/../../fixtures/books/beiying.epub", env!("CARGO_MANIFEST_DIR"))).unwrap();
        b.import_book(format!("{}/../../fixtures/books/beiying.epub", env!("CARGO_MANIFEST_DIR"))).unwrap();
        let at = |o| TextPoint { sentence: 0, offset: o };
        let mark = a.add_mark(book.id.clone(), 1, at(0), at(4), "我与父亲".into(), MarkStyle::Yellow, Some("一".into())).unwrap();
        let pass = |from: &YuyueCore, to: &YuyueCore| {
            let batch = lock(&from.store).export(&lock(&to.store).version().unwrap()).unwrap();
            lock(&to.store).import(&batch).unwrap();
        };
        pass(&a, &b);
        a.set_mark_note(book.id.clone(), mark.id.clone(), Some("一二".into())).unwrap();
        // In the same millisecond the two would be ordered by device, either way round.
        std::thread::sleep(std::time::Duration::from_millis(2));
        b.set_mark_note(book.id.clone(), mark.id.clone(), Some("三".into())).unwrap();
        pass(&a, &b);
        let found = b.note_conflicts().unwrap();
        assert_eq!(found.len(), 1);
        assert_eq!((found[0].older.note.as_deref(), found[0].newer.note.as_deref()), (Some("一二"), Some("三")));
        assert_eq!((found[0].older.device_name.as_str(), found[0].newer.this_device), ("a", true));
        b.resolve_note_conflict(book.id.clone(), mark.id.clone(), ConflictChoice::Both).unwrap();
        assert_eq!(b.marks(book.id.clone()).unwrap()[0].note.as_deref(), Some("一二\n\n三"));
        assert!(b.note_conflicts().unwrap().is_empty());
    }
}
