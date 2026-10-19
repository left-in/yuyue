//! 数据快照: the library's state — progress and bookmarks, highlights, 生词, settings and
//! replace rules — and, if asked, the books' own files, in one `.yuyue` file to carry to another
//! device or keep as a backup.
//!
//! The file is a zip: `snapshot.json` (who made it, when, what's in it, and every register it
//! holds as the operation that set it, stamp and all), and `books/<id>/…` when the files came
//! along.
//!
//! Bringing one back writes what it holds as this device's own changes, so the next sync carries
//! them on like any other edit (and nothing about which operations another device has seen gets
//! muddled by a file holding only some of them). 合并 takes a value only where the snapshot's is
//! newer than this device's; 覆盖 takes all of them, and removes the highlights, bookmarks, words,
//! rules and collections the snapshot doesn't have. Books are never removed, either way.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs::File;
use std::io::{Read, Write};
use std::path::{Component, Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipArchive, ZipWriter};

use crate::api::{YuyueCore, lock, now_ms};
use crate::error::{CoreError, Result};
use crate::store::{Op, Version};

const FORMAT: &str = "yuyue-snapshot";
const HEADER: &str = "snapshot.json";
/// The header without the registers, for listing snapshots quickly.
const ABOUT: &str = "about.json";

/// What goes into a snapshot.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct SnapshotParts {
    /// 进度和书签: where each book is, bookmarks, time spent, 读完, collections.
    pub progress: bool,
    /// 笔记: highlights and the thoughts on them.
    pub notes: bool,
    pub words: bool,
    /// 设置和替换规则.
    pub settings: bool,
    /// 书文件: the books themselves.
    pub files: bool,
}

/// How much there is of each kind, in the library or in a snapshot.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct SnapshotCounts {
    /// Books on the shelf.
    pub books: u32,
    /// Books with a position saved.
    pub read: u32,
    pub notes: u32,
    pub words: u32,
    pub rules: u32,
    /// The books' files, in bytes.
    pub file_bytes: u64,
    /// Everything else, in bytes, before compression.
    pub data_bytes: u64,
}

/// A snapshot read back, before anything is done with it.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct SnapshotInfo {
    pub device_name: String,
    pub platform: String,
    /// Wall-clock milliseconds.
    pub made_at: i64,
    /// The file's size in bytes.
    pub bytes: u64,
    pub parts: SnapshotParts,
    pub counts: SnapshotCounts,
    /// This library now, after 合并, and after 覆盖.
    pub now: SnapshotCounts,
    pub merged: SnapshotCounts,
    pub replaced: SnapshotCounts,
}

/// Who made a snapshot and when, for a list of them.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct SnapshotAbout {
    pub device_name: String,
    pub platform: String,
    pub made_at: i64,
    #[serde(default)]
    pub bytes: u64,
    pub parts: SnapshotParts,
    pub counts: SnapshotCounts,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Header {
    format: String,
    version: u32,
    device: String,
    device_name: String,
    platform: String,
    made_at: i64,
    parts: SnapshotParts,
    counts: SnapshotCounts,
    ops: Vec<Op>,
}

/// Kinds of register, by the start of their entity's name, and the part each belongs to.
/// `book/` and `device/` always come along: the rest refers to them.
const KINDS: &[(&str, Part)] = &[
    ("book/", Part::Always),
    ("device/", Part::Always),
    ("progress/", Part::Progress),
    ("bookmark/", Part::Progress),
    ("time/", Part::Progress),
    ("days/", Part::Progress),
    ("collection/", Part::Progress),
    ("member/", Part::Progress),
    ("mark/", Part::Notes),
    ("word/", Part::Words),
    ("settings/", Part::Settings),
    ("rule/", Part::Settings),
];

#[derive(Clone, Copy, PartialEq, Eq)]
enum Part {
    Always,
    Progress,
    Notes,
    Words,
    Settings,
}

fn kind_of(entity: &str) -> Option<(&'static str, Part)> {
    KINDS.iter().find(|(prefix, _)| entity.starts_with(prefix)).copied()
}

fn included(part: Part, parts: &SnapshotParts) -> bool {
    match part {
        Part::Always => true,
        Part::Progress => parts.progress,
        Part::Notes => parts.notes,
        Part::Words => parts.words,
        Part::Settings => parts.settings,
    }
}

/// Things 覆盖 removes when the snapshot doesn't have them.
const REMOVABLE: &[&str] = &["bookmark/", "mark/", "word/", "rule/", "collection/", "member/"];

/// The registers as entity → field → value.
type State = BTreeMap<String, BTreeMap<String, Value>>;

fn state_of(ops: &[Op]) -> State {
    let mut state = State::new();
    for op in ops {
        state.entry(op.entity.clone()).or_default().insert(op.field.clone(), op.value.clone());
    }
    state
}

fn live(fields: &BTreeMap<String, Value>) -> bool {
    fields.get("deleted") != Some(&json!(true))
}

fn count(state: &State, prefix: &str) -> u32 {
    state.range(prefix.to_string()..).take_while(|(e, _)| e.starts_with(prefix)).filter(|(_, f)| live(f)).count() as u32
}

fn counts_of(state: &State) -> SnapshotCounts {
    let read: BTreeSet<&str> = state
        .range("progress/".to_string()..)
        .take_while(|(e, _)| e.starts_with("progress/"))
        .filter_map(|(e, _)| e.strip_prefix("progress/")?.split('/').next())
        .filter(|book| state.get(&format!("book/{book}")).is_some_and(live))
        .collect();
    SnapshotCounts {
        books: count(state, "book/"),
        read: read.len() as u32,
        notes: count(state, "mark/"),
        words: count(state, "word/"),
        rules: count(state, "rule/"),
        file_bytes: 0,
        data_bytes: 0,
    }
}

/// What bringing `snap` back writes on a library whose registers are `local`.
fn plan(local: &[Op], snap: &[Op], parts: &SnapshotParts, replace: bool) -> Vec<(String, String, Value)> {
    let here: HashMap<(&str, &str), (&Value, &str)> =
        local.iter().map(|op| ((op.entity.as_str(), op.field.as_str()), (&op.value, op.hlc.as_str()))).collect();
    let mut writes = Vec::new();
    for op in snap {
        let Some((prefix, part)) = kind_of(&op.entity) else { continue };
        // Device names are each device's own to say.
        if prefix == "device/" || !included(part, parts) {
            continue;
        }
        let take = match here.get(&(op.entity.as_str(), op.field.as_str())) {
            None => true,
            Some((value, _)) if **value == op.value => false,
            Some((_, hlc)) => (replace && part != Part::Always) || op.hlc.as_str() > *hlc,
        };
        if take {
            writes.push((op.entity.clone(), op.field.clone(), op.value.clone()));
        }
    }
    if replace {
        let theirs: BTreeSet<&str> = snap.iter().map(|op| op.entity.as_str()).collect();
        for (entity, fields) in state_of(local) {
            let Some((prefix, part)) = kind_of(&entity) else { continue };
            if !included(part, parts) || !REMOVABLE.contains(&prefix) || theirs.contains(entity.as_str()) {
                continue;
            }
            if prefix == "member/" {
                if fields.get("in") == Some(&json!(true)) {
                    writes.push((entity, "in".into(), json!(false)));
                }
            } else if live(&fields) {
                writes.push((entity, "deleted".into(), json!(true)));
            }
        }
    }
    writes
}

fn after(local: &[Op], writes: &[(String, String, Value)]) -> SnapshotCounts {
    let mut state = state_of(local);
    for (entity, field, value) in writes {
        state.entry(entity.clone()).or_default().insert(field.clone(), value.clone());
    }
    counts_of(&state)
}

fn dir_size(dir: &Path) -> u64 {
    let Ok(entries) = std::fs::read_dir(dir) else { return 0 };
    entries
        .flatten()
        .map(|e| match e.file_type() {
            Ok(t) if t.is_dir() => dir_size(&e.path()),
            Ok(_) => e.metadata().map(|m| m.len()).unwrap_or(0),
            Err(_) => 0,
        })
        .sum()
}

fn files_in(dir: &Path, out: &mut Vec<PathBuf>) -> Result<()> {
    for e in std::fs::read_dir(dir)? {
        let e = e?;
        if e.file_type()?.is_dir() {
            files_in(&e.path(), out)?;
        } else {
            out.push(e.path());
        }
    }
    Ok(())
}

/// `books/<id>/<path>` inside the zip, checked so it can't land outside that book's folder.
fn book_entry(name: &Path) -> Option<(String, PathBuf)> {
    let mut parts = name.components();
    if parts.next() != Some(Component::Normal("books".as_ref())) {
        return None;
    }
    let Some(Component::Normal(id)) = parts.next() else { return None };
    let id = id.to_str()?;
    if id.len() != 32 || !id.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let rest: PathBuf = parts.clone().collect();
    if rest.as_os_str().is_empty() || !parts.all(|c| matches!(c, Component::Normal(_))) {
        return None;
    }
    Some((id.to_string(), rest))
}

impl YuyueCore {
    fn snapshot_ops(&self, parts: &SnapshotParts) -> Result<Vec<Op>> {
        let ops = lock(&self.store).export(&Version::new())?.ops;
        Ok(ops.into_iter().filter(|op| kind_of(&op.entity).is_some_and(|(_, part)| included(part, parts))).collect())
    }

    fn live_books(&self) -> Result<Vec<String>> {
        Ok(lock(&self.store)
            .entities("book/")?
            .into_iter()
            .filter(|(_, f)| live(f))
            .filter_map(|(e, _)| e.strip_prefix("book/").map(str::to_string))
            .filter(|id| self.books_dir.join(id).join("book.json").is_file())
            .collect())
    }

    fn read_header(path: &str) -> Result<(Header, ZipArchive<File>)> {
        let mut zip = ZipArchive::new(File::open(path)?).map_err(|_| CoreError::Invalid { message: crate::i18n::tr("这不是语阅的快照", "This isn't a 语阅 snapshot") })?;
        let mut text = String::new();
        zip.by_name(HEADER)
            .map_err(|_| CoreError::Invalid { message: crate::i18n::tr("这不是语阅的快照", "This isn't a 语阅 snapshot") })?
            .read_to_string(&mut text)?;
        let header: Header = serde_json::from_str(&text)?;
        if header.format != FORMAT {
            return Err(CoreError::Invalid { message: crate::i18n::tr("这不是语阅的快照", "This isn't a 语阅 snapshot") });
        }
        if header.version > 1 {
            return Err(CoreError::Invalid { message: crate::i18n::tr("这个快照来自更新版本的语阅，先更新再导入", "This snapshot is from a newer 语阅. Update the app, then import it") });
        }
        Ok((header, zip))
    }
}

#[uniffi::export]
impl YuyueCore {
    /// How much of each kind the library holds, for choosing what goes into a snapshot.
    pub fn snapshot_counts(&self) -> Result<SnapshotCounts> {
        let all = SnapshotParts { progress: true, notes: true, words: true, settings: true, files: false };
        let ops = self.snapshot_ops(&all)?;
        let mut counts = counts_of(&state_of(&ops));
        counts.data_bytes = serde_json::to_vec(&ops)?.len() as u64;
        counts.file_bytes = self.live_books()?.iter().map(|id| dir_size(&self.books_dir.join(id))).sum();
        Ok(counts)
    }

    /// Writes a snapshot of `parts` to `path`. Returns its size in bytes.
    pub fn make_snapshot(&self, path: String, parts: SnapshotParts) -> Result<u64> {
        let ops = self.snapshot_ops(&parts)?;
        let mut counts = counts_of(&state_of(&ops));
        counts.data_bytes = serde_json::to_vec(&ops)?.len() as u64;
        let books = if parts.files { self.live_books()? } else { Vec::new() };
        counts.file_bytes = books.iter().map(|id| dir_size(&self.books_dir.join(id))).sum();
        let (device, device_name, platform) = {
            let store = lock(&self.store);
            let me = store.device().to_string();
            let text = |f: &str| store.get(&format!("device/{me}"), f).ok().flatten().and_then(|v| v.as_str().map(str::to_string));
            let (name, platform) = (text("name").unwrap_or_default(), text("platform").unwrap_or_default());
            (me, name, platform)
        };
        let header = Header { format: FORMAT.into(), version: 1, device, device_name, platform, made_at: now_ms(), parts, counts, ops };

        // Written beside the target and moved into place, so a half-written file is never taken for one.
        let target = PathBuf::from(&path);
        let partial = target.with_extension("yuyue-part");
        let result = (|| -> Result<()> {
            let mut zip = ZipWriter::new(File::create(&partial)?);
            zip.start_file(HEADER, SimpleFileOptions::default().compression_method(CompressionMethod::Deflated))?;
            zip.write_all(&serde_json::to_vec(&header)?)?;
            let about = SnapshotAbout {
                device_name: header.device_name.clone(),
                platform: header.platform.clone(),
                made_at: header.made_at,
                bytes: 0,
                parts: header.parts,
                counts: header.counts,
            };
            zip.start_file(ABOUT, SimpleFileOptions::default())?;
            zip.write_all(&serde_json::to_vec(&about)?)?;
            // Books are zips and pictures already: stored as they are.
            let stored = SimpleFileOptions::default().compression_method(CompressionMethod::Stored).large_file(true);
            for id in &books {
                let dir = self.books_dir.join(id);
                let mut files = Vec::new();
                files_in(&dir, &mut files)?;
                for file in files {
                    let Ok(rel) = file.strip_prefix(&dir) else { continue };
                    let name = Path::new("books").join(id).join(rel);
                    zip.start_file(name.to_string_lossy().replace('\\', "/"), stored)?;
                    std::io::copy(&mut File::open(&file)?, &mut zip)?;
                }
            }
            zip.finish()?.sync_all()?;
            Ok(())
        })();
        if let Err(e) = result {
            let _ = std::fs::remove_file(&partial);
            return Err(e);
        }
        std::fs::rename(&partial, &target)?;
        Ok(std::fs::metadata(&target)?.len())
    }

    /// Who made a snapshot, when, and what's in it, without reading it all.
    pub fn peek_snapshot(&self, path: String) -> Result<SnapshotAbout> {
        let bytes = std::fs::metadata(&path)?.len();
        let not_one = || CoreError::Invalid { message: crate::i18n::tr("这不是语阅的快照", "This isn't a 语阅 snapshot") };
        let mut zip = ZipArchive::new(File::open(&path)?).map_err(|_| not_one())?;
        let mut text = String::new();
        zip.by_name(ABOUT).map_err(|_| not_one())?.read_to_string(&mut text)?;
        let about: SnapshotAbout = serde_json::from_str(&text)?;
        Ok(SnapshotAbout { bytes, ..about })
    }

    /// What a snapshot holds, and what the library would hold after 合并 or 覆盖.
    pub fn read_snapshot(&self, path: String) -> Result<SnapshotInfo> {
        let bytes = std::fs::metadata(&path)?.len();
        let (header, _) = Self::read_header(&path)?;
        let local = lock(&self.store).export(&Version::new())?.ops;
        let merged = after(&local, &plan(&local, &header.ops, &header.parts, false));
        let replaced = after(&local, &plan(&local, &header.ops, &header.parts, true));
        Ok(SnapshotInfo {
            device_name: header.device_name,
            platform: header.platform,
            made_at: header.made_at,
            bytes,
            parts: header.parts,
            counts: header.counts,
            now: counts_of(&state_of(&local)),
            merged,
            replaced,
        })
    }

    /// Brings a snapshot back: 合并 (`replace` false) or 覆盖. Books whose files it carries and
    /// this device lacks are put in place. Returns how many values changed.
    pub fn restore_snapshot(&self, path: String, replace: bool) -> Result<u32> {
        let (header, mut zip) = Self::read_header(&path)?;
        if header.parts.files {
            // Each book unpacked to one side first, then moved in whole.
            let mut books: BTreeMap<String, Vec<(usize, PathBuf)>> = BTreeMap::new();
            for i in 0..zip.len() {
                let entry = zip.by_index(i)?;
                if entry.is_dir() {
                    continue;
                }
                let Some(name) = entry.enclosed_name() else { continue };
                if let Some((id, rel)) = book_entry(&name) {
                    books.entry(id).or_default().push((i, rel));
                }
            }
            for (id, files) in books {
                let dir = self.books_dir.join(&id);
                if dir.join("book.json").is_file() {
                    continue;
                }
                let incoming = self.books_dir.join(format!(".incoming-{id}"));
                let _ = std::fs::remove_dir_all(&incoming);
                for (i, rel) in files {
                    let out = incoming.join(rel);
                    if let Some(parent) = out.parent() {
                        std::fs::create_dir_all(parent)?;
                    }
                    std::io::copy(&mut zip.by_index(i)?, &mut File::create(&out)?)?;
                }
                if !incoming.join("book.json").is_file() {
                    let _ = std::fs::remove_dir_all(&incoming);
                    continue;
                }
                let _ = std::fs::remove_dir_all(&dir);
                std::fs::rename(&incoming, &dir)?;
            }
        }
        let local = lock(&self.store).export(&Version::new())?.ops;
        let writes = plan(&local, &header.ops, &header.parts, replace);
        let borrowed: Vec<(&str, &str, Value)> = writes.iter().map(|(e, f, v)| (e.as_str(), f.as_str(), v.clone())).collect();
        if !borrowed.is_empty() {
            lock(&self.store).set_many(&borrowed)?;
        }
        lock(&self.manifests).clear();
        Ok(writes.len() as u32)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::notes::{MarkStyle, TextPoint};
    use std::sync::Arc;

    const ALL: SnapshotParts = SnapshotParts { progress: true, notes: true, words: true, settings: true, files: false };

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("yuyue-snap-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn core(dir: &Path, name: &str) -> Arc<YuyueCore> {
        YuyueCore::open(dir.join(name).to_string_lossy().into_owned(), name.into(), "ios".into()).unwrap()
    }

    fn fixture(name: &str) -> String {
        format!("{}/../../fixtures/books/{name}", env!("CARGO_MANIFEST_DIR"))
    }

    fn mark(core: &YuyueCore, book: &str, sentence: u32, note: Option<&str>) -> String {
        let at = |o| TextPoint { sentence, offset: o };
        core.add_mark(book.into(), 1, at(0), at(4), "我与父亲".into(), MarkStyle::Yellow, note.map(str::to_string)).unwrap().id
    }

    #[test]
    fn a_snapshot_carries_notes_and_words_to_a_new_device() {
        let dir = temp("carry");
        let a = core(&dir, "a");
        let book = a.import_book(fixture("beiying.epub")).unwrap();
        mark(&a, &book.id, 0, Some("开头"));
        a.add_word("father".into(), None, Some("父亲".into()), book.id.clone(), 1, 0, "我与父亲".into()).unwrap();
        let file = dir.join("a.yuyue").to_string_lossy().into_owned();
        a.make_snapshot(file.clone(), ALL).unwrap();

        let b = core(&dir, "b");
        assert_eq!(b.peek_snapshot(file.clone()).unwrap().counts.notes, 1);
        let info = b.read_snapshot(file.clone()).unwrap();
        assert_eq!((info.device_name.as_str(), info.counts.books, info.counts.notes, info.counts.words), ("a", 1, 1, 1));
        assert_eq!((info.now.notes, info.merged.notes, info.merged.words), (0, 1, 1));
        b.restore_snapshot(file, false).unwrap();
        let books = b.books().unwrap();
        // The book is on the shelf, its files still on the other device.
        assert_eq!((books.len(), books[0].available), (1, false));
        assert_eq!(b.marks(book.id.clone()).unwrap()[0].note.as_deref(), Some("开头"));
        assert_eq!(b.words().unwrap().len(), 1);
    }

    #[test]
    fn files_come_along_when_asked() {
        let dir = temp("files");
        let a = core(&dir, "a");
        let book = a.import_book(fixture("beiying.epub")).unwrap();
        let file = dir.join("a.yuyue").to_string_lossy().into_owned();
        a.make_snapshot(file.clone(), SnapshotParts { files: true, ..ALL }).unwrap();
        assert!(a.read_snapshot(file.clone()).unwrap().counts.file_bytes > 0);

        let b = core(&dir, "b");
        b.restore_snapshot(file, false).unwrap();
        let books = b.books().unwrap();
        assert!(books[0].available);
        assert_eq!(b.sentences(book.id.clone(), 0).unwrap(), a.sentences(book.id, 0).unwrap());
    }

    #[test]
    fn merge_keeps_what_is_newer_here_and_replace_takes_the_snapshot() {
        let dir = temp("modes");
        let a = core(&dir, "a");
        let book = a.import_book(fixture("beiying.epub")).unwrap();
        let first = mark(&a, &book.id, 0, Some("旧的想法"));
        let file = dir.join("a.yuyue").to_string_lossy().into_owned();
        a.make_snapshot(file.clone(), ALL).unwrap();

        // Changed after the snapshot: a newer thought, and a highlight it doesn't have.
        a.set_mark_note(book.id.clone(), first.clone(), Some("新的想法".into())).unwrap();
        mark(&a, &book.id, 2, None);

        let info = a.read_snapshot(file.clone()).unwrap();
        assert_eq!((info.now.notes, info.merged.notes, info.replaced.notes), (2, 2, 1));
        a.restore_snapshot(file.clone(), false).unwrap();
        let marks = a.marks(book.id.clone()).unwrap();
        assert_eq!(marks.len(), 2);
        assert_eq!(marks.iter().find(|m| m.id == first).unwrap().note.as_deref(), Some("新的想法"));

        a.restore_snapshot(file, true).unwrap();
        let marks = a.marks(book.id.clone()).unwrap();
        assert_eq!((marks.len(), marks[0].note.as_deref()), (1, Some("旧的想法")));
        // The book stays, and its own register wasn't turned back.
        assert_eq!(a.books().unwrap().len(), 1);
    }

    #[test]
    fn only_the_parts_asked_for() {
        let dir = temp("parts");
        let a = core(&dir, "a");
        let book = a.import_book(fixture("beiying.epub")).unwrap();
        mark(&a, &book.id, 0, None);
        a.add_word("father".into(), None, None, book.id.clone(), 1, 0, "我与父亲".into()).unwrap();
        let file = dir.join("a.yuyue").to_string_lossy().into_owned();
        a.make_snapshot(file.clone(), SnapshotParts { notes: false, ..ALL }).unwrap();
        let b = core(&dir, "b");
        b.restore_snapshot(file, false).unwrap();
        assert!(b.marks(book.id.clone()).unwrap().is_empty());
        assert_eq!(b.words().unwrap().len(), 1);
    }

    #[test]
    fn not_a_snapshot_and_paths_outside_are_refused() {
        let dir = temp("bad");
        let a = core(&dir, "a");
        let plain = dir.join("plain.yuyue");
        std::fs::write(&plain, b"hello").unwrap();
        assert!(a.read_snapshot(plain.to_string_lossy().into_owned()).is_err());

        assert!(book_entry(Path::new("books/0123456789abcdef0123456789abcdef/book.json")).is_some());
        assert!(book_entry(Path::new("books/0123456789abcdef0123456789abcdef")).is_none());
        assert!(book_entry(Path::new("books/../escape/book.json")).is_none());
        assert!(book_entry(Path::new("books/notanid/book.json")).is_none());
        assert!(book_entry(Path::new("other/0123456789abcdef0123456789abcdef/x")).is_none());
    }
}
