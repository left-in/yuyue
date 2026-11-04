//! What the apps call (through UniFFI): one `YuyueCore` per app, opened on its data folder.
//!
//! ```text
//! <data>/library.db   the operation log (store.rs)
//! <data>/books/<id>/  one folder per book (book.rs)
//! ```
//!
//! Entities in the log:
//! - `book/<id>`: `title`, `authors`, `language`, `format`, `addedAt`, `openedAt`, `deleted`,
//!   `deletedAt`, `finished`; collections are in `shelf`
//! - `progress/<book>/<device>`: `position` = `{section, sentence, fraction, at}`
//! - `settings/reader`: one field per setting, so changes made on two devices merge
//! - `device/<id>`: `name`, `platform`

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use percent_encoding::percent_decode_str;
use serde_json::{Value, json};

use crate::book::{self, Format, Manifest};
use crate::document::{self, Font, LayoutMode, PageSettings, Paging, Paper};
use crate::epub::Kind;
use crate::error::{CoreError, Result};
use crate::shelf::ReadingStatus;
use crate::store::{Batch, Store, Version};

/// A device sharing the library (`devices`), and the book it read last.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct DeviceInfo {
    pub id: String,
    pub name: String,
    pub platform: String,
    pub this_device: bool,
    /// The book it read last, how far through, and when (wall-clock ms).
    pub last_book: Option<String>,
    pub last_fraction: Option<f64>,
    pub last_at: Option<i64>,
}

/// What 同步这些 can leave out. Books, collections and devices always go.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum SyncPart {
    /// 进度和书签, with the time spent reading.
    Reading,
    /// 笔记和生词.
    Notes,
    /// 设置和替换规则.
    Settings,
}

impl SyncPart {
    fn prefixes(self) -> &'static [&'static str] {
        match self {
            SyncPart::Reading => &["progress/", "bookmark/", "time/", "days/", "listen/"],
            SyncPart::Notes => &["mark/", "word/"],
            SyncPart::Settings => &["settings/", "rule/"],
        }
    }
}

fn without(batch: &mut Batch, parts: &[SyncPart]) {
    batch.ops.retain(|op| !parts.iter().any(|p| p.prefixes().iter().any(|x| op.entity.starts_with(x))));
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum BookFormat {
    Epub,
    Txt,
    Pdf,
    /// A Kindle book (MOBI, AZW3), read like an EPUB.
    Mobi,
    /// 有声书 on its own: listened to, not read (`audiobook`).
    Audio,
    /// 播客: an episode written for one of the reader's shows.
    Podcast,
}

/// What the app read from a PDF with the system's viewer.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct PdfInfo {
    pub pages: u32,
    /// The document's own title and author, when it has sensible ones.
    pub title: Option<String>,
    pub authors: Vec<String>,
    /// Characters of text over all pages, for 还剩多久; 0 for a scan.
    pub characters: u64,
    /// The first page, as a JPEG.
    pub cover: Option<Vec<u8>>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum SectionKind {
    Text,
    Image,
    /// Licence pages: shown, never spoken.
    Boilerplate,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BookSummary {
    pub id: String,
    pub title: String,
    pub authors: Vec<String>,
    pub language: String,
    pub format: BookFormat,
    /// Absolute path of the cover image, if the book has one.
    pub cover_path: Option<String>,
    pub added_at: i64,
    pub opened_at: Option<i64>,
    /// When it was marked 读完, if it was.
    pub finished_at: Option<i64>,
    /// 0–1, from the most recent position on any device.
    pub progress: f64,
    /// 想读 / 在读 / 读完, kept by the app (FEATURES §1).
    pub status: ReadingStatus,
    /// Ids of the collections the book is in.
    pub collections: Vec<String>,
    pub read_minutes: u32,
    pub listen_minutes: u32,
    /// The book's files are on this device (the library syncs; files don't, yet).
    pub available: bool,
    /// A PDF's current page, 1-based (0 before opening).
    pub page: u32,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct SectionSummary {
    pub title: Option<String>,
    pub kind: SectionKind,
    pub linear: bool,
    pub continued: bool,
    /// The section's language (the book's unless the section says otherwise).
    pub lang: String,
    pub sentences: u32,
    pub units: u32,
    /// A PDF's pages; its positions count pages instead of sentences.
    pub pages: u32,
    /// An audiobook chapter's length in milliseconds; its positions count milliseconds.
    #[uniffi(default = 0)]
    pub ms: u32,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct TocItem {
    pub title: String,
    pub depth: u16,
    pub section: u32,
    pub anchor: Option<String>,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BookDetail {
    pub summary: BookSummary,
    /// The section reading starts at, past covers and licence pages.
    pub start: u32,
    pub sections: Vec<SectionSummary>,
    pub toc: Vec<TocItem>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Record)]
pub struct Position {
    pub section: u32,
    pub sentence: u32,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct Progress {
    pub position: Position,
    /// 0–1 through the main text.
    pub fraction: f64,
    pub device: String,
    pub device_name: Option<String>,
    pub this_device: bool,
    /// Wall-clock milliseconds when it was saved.
    pub at: i64,
}

/// The reading settings that follow the reader from device to device.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct ReaderSettings {
    pub paper: Paper,
    pub mode: LayoutMode,
    pub font: Option<Font>,
    pub font_size: f64,
    pub line_height: Option<f64>,
    pub paragraph_spacing: Option<f64>,
    pub justify: Option<bool>,
    pub indent: Option<bool>,
    pub compress: bool,
    /// 我的纸 the page is on, over `paper` (which is then the preset it reads like, so an app
    /// that doesn't know the paper still shows something close).
    #[uniffi(default = None)]
    pub custom_paper: Option<String>,
}

impl Default for ReaderSettings {
    fn default() -> Self {
        let p = PageSettings::default();
        ReaderSettings {
            paper: p.paper,
            mode: p.mode,
            font: p.font,
            font_size: p.font_size,
            line_height: p.line_height,
            paragraph_spacing: p.paragraph_spacing,
            justify: p.justify,
            indent: p.indent,
            compress: p.compress,
            custom_paper: None,
        }
    }
}

/// What each device decides about the page itself.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct PageGeometry {
    pub paging: Paging,
    pub margin: f64,
    pub top: f64,
    pub bottom: f64,
    pub columns: u8,
    pub reduced_motion: bool,
}

/// The answer to a request the WebView makes for a book URL.
#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum Served {
    Html { body: String },
    File { path: String, mime: String },
    NotFound,
}

#[derive(uniffi::Object)]
pub struct YuyueCore {
    pub(crate) books_dir: PathBuf,
    pub(crate) store: Mutex<Store>,
    pub(crate) manifests: Mutex<HashMap<String, Arc<Manifest>>>,
    /// Each book's 剧本 cast, read once from the whole book.
    pub(crate) casts: Mutex<HashMap<String, Arc<crate::script::Cast>>>,
}

pub(crate) fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

pub(crate) fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

#[uniffi::export]
impl YuyueCore {
    /// Opens (or creates) the library in `data_dir` and records this device's name.
    #[uniffi::constructor]
    pub fn open(data_dir: String, device_name: String, platform: String) -> Result<Arc<YuyueCore>> {
        let dir = PathBuf::from(data_dir);
        let books_dir = dir.join("books");
        std::fs::create_dir_all(&books_dir)?;
        let mut store = Store::open(&dir.join("library.db"))?;
        let entity = format!("device/{}", store.device());
        let current = store.fields(&entity)?;
        let mut changed = Vec::new();
        if current.get("name") != Some(&json!(device_name)) {
            changed.push(("name", json!(device_name)));
        }
        if current.get("platform") != Some(&json!(platform)) {
            changed.push(("platform", json!(platform)));
        }
        if !changed.is_empty() {
            store.set_fields(&entity, &changed)?;
        }
        Ok(Arc::new(YuyueCore { books_dir, store: Mutex::new(store), manifests: Mutex::new(HashMap::new()), casts: Mutex::new(HashMap::new()) }))
    }

    pub fn device_id(&self) -> String {
        lock(&self.store).device().to_string()
    }

    /// Imports an EPUB or TXT file. Importing the same file again returns the same book.
    pub fn import_book(&self, path: String) -> Result<BookSummary> {
        let p = Path::new(&path);
        // 播客's episodes travel as their script (`<id>.book.podcast`): rebuilt, not read as text.
        let manifest = if p.extension().is_some_and(|e| e.eq_ignore_ascii_case("podcast")) {
            self.import_episode(&std::fs::read(p)?)?
        } else {
            book::import(&self.books_dir, p)?
        };
        let id = manifest.id.clone();
        self.record_import(&manifest)?;
        lock(&self.manifests).insert(id.clone(), Arc::new(manifest));
        self.summary(&id)
    }

    /// The file a book was imported from, as kept here. 同步 · 书文件 puts it in the shared
    /// folder; importing it on another device gives the same book, since ids are the file's hash.
    pub fn original_file(&self, book_id: String) -> Result<String> {
        let manifest = self.manifest(&book_id)?;
        let path = self.book_dir(&book_id)?.join(format!("original.{}", manifest.format.extension()));
        if !path.is_file() {
            return Err(CoreError::not_found("original file"));
        }
        Ok(path.to_string_lossy().into_owned())
    }

    /// 换封面: an image the user picked (JPEG or PNG) becomes the book's cover on this device.
    /// It gets a new name each time, so whatever caches the old one by path lets it go.
    pub fn set_cover(&self, book_id: String, image: Vec<u8>) -> Result<BookSummary> {
        let dir = self.book_dir(&book_id)?;
        let mut m = (*self.manifest(&book_id)?).clone();
        let ext = if image.starts_with(&[0x89, b'P', b'N', b'G']) { "png" } else { "jpg" };
        let name = format!("cover-own-{}.{ext}", now_ms());
        std::fs::write(dir.join(&name), &image)?;
        if let Some(old) = m.cover.as_deref().filter(|c| c.starts_with("cover-own-")) {
            let _ = std::fs::remove_file(dir.join(old));
        }
        m.cover = Some(name);
        let tmp = dir.join(format!("book.json.{}", std::process::id()));
        std::fs::write(&tmp, serde_json::to_string_pretty(&m)?)?;
        std::fs::rename(&tmp, dir.join("book.json"))?;
        lock(&self.manifests).insert(book_id.clone(), Arc::new(m));
        self.summary(&book_id)
    }

    /// A PDF's page count, title and cover, read by the app after importing it. Only the first
    /// time counts: a PDF already described keeps what it has.
    pub fn set_pdf_info(&self, book_id: String, info: PdfInfo) -> Result<BookSummary> {
        let dir = self.book_dir(&book_id)?;
        let mut m = (*self.manifest(&book_id)?).clone();
        if m.format != Format::Pdf {
            return Err(CoreError::bad_book("not a PDF"));
        }
        if m.units > 0 || info.pages == 0 {
            return self.summary(&book_id);
        }
        let clean = |s: &str| s.split_whitespace().collect::<Vec<_>>().join(" ");
        if let Some(title) = info.title.as_deref().map(clean).filter(|t| !t.is_empty()) {
            m.title = title;
        }
        m.authors = info.authors.iter().map(|a| clean(a)).filter(|a| !a.is_empty()).collect();
        if let Some(jpeg) = &info.cover {
            std::fs::write(dir.join("cover.jpg"), jpeg)?;
            m.cover = Some("cover.jpg".into());
        }
        m.sections = vec![book::pdf_section(info.pages)];
        m.units = info.pages;
        // Text read at 400 characters a minute; a scan, or a page with little on it, a minute a page.
        m.read_minutes = ((info.characters / 400) as u32).max(info.pages).max(1);
        let tmp = dir.join(format!("book.json.{}", std::process::id()));
        std::fs::write(&tmp, serde_json::to_string_pretty(&m)?)?;
        std::fs::rename(&tmp, dir.join("book.json"))?;
        {
            let mut store = lock(&self.store);
            store.set_fields(&format!("book/{book_id}"), &[("title", json!(m.title)), ("authors", json!(m.authors))])?;
        }
        lock(&self.manifests).insert(book_id.clone(), Arc::new(m));
        self.summary(&book_id)
    }

    /// The library, most recently opened first.
    pub fn books(&self) -> Result<Vec<BookSummary>> {
        let ids: Vec<String> = {
            let store = lock(&self.store);
            store
                .entities("book/")?
                .into_iter()
                .filter(|(_, f)| f.get("deleted") != Some(&json!(true)))
                .filter_map(|(entity, _)| entity.strip_prefix("book/").map(str::to_string))
                .collect()
        };
        let mut books = ids.iter().map(|id| self.summary(id)).collect::<Result<Vec<_>>>()?;
        books.sort_by_key(|b| std::cmp::Reverse(b.opened_at.unwrap_or(0).max(b.added_at)));
        Ok(books)
    }

    pub fn book(&self, id: String) -> Result<BookDetail> {
        let m = self.manifest(&id)?;
        // Chapter titles in the book's chosen script (简繁转换), as its pages are.
        let rules = self.rules_for(&id, false)?;
        Ok(BookDetail {
            summary: self.summary(&id)?,
            start: m.start,
            sections: m
                .sections
                .iter()
                .enumerate()
                .map(|(i, s)| SectionSummary {
                    title: s.title.as_deref().map(|t| rules.convert(t)),
                    kind: section_kind(s.kind),
                    linear: s.linear,
                    continued: s.continued,
                    lang: m.section_lang(i as u32).to_string(),
                    sentences: s.sentences,
                    units: s.units,
                    pages: s.pages,
                    ms: s.ms,
                })
                .collect(),
            toc: m
                .toc
                .iter()
                .map(|e| TocItem { title: rules.convert(&e.title), depth: e.depth, section: e.section, anchor: e.anchor.clone() })
                .collect(),
        })
    }

    /// Removes a book from the library on every device. Its files stay on this one until
    /// `purge_deleted`, so the delete can be undone (`restore_book`).
    pub fn delete_book(&self, id: String) -> Result<()> {
        self.book_dir(&id)?;
        lock(&self.store).set_fields(&format!("book/{id}"), &[("deleted", json!(true)), ("deletedAt", json!(now_ms()))])?;
        Ok(())
    }

    /// Undoes `delete_book`, while the files are still here.
    pub fn restore_book(&self, id: String) -> Result<BookSummary> {
        if !self.book_dir(&id)?.exists() {
            return Err(CoreError::not_found("book"));
        }
        lock(&self.store).set(&format!("book/{id}"), "deleted", json!(false))?;
        self.summary(&id)
    }

    /// Removes the files of books deleted at least `older_than_ms` ago (on any device).
    /// Returns how many books' files went.
    pub fn purge_deleted(&self, older_than_ms: i64) -> Result<u32> {
        let cutoff = now_ms() - older_than_ms;
        let deleted: Vec<String> = lock(&self.store)
            .entities("book/")?
            .into_iter()
            .filter(|(_, f)| f.get("deleted") == Some(&json!(true)))
            .filter(|(_, f)| f.get("deletedAt").and_then(Value::as_i64).unwrap_or(0) <= cutoff)
            .filter_map(|(e, _)| e.strip_prefix("book/").map(str::to_string))
            .collect();
        let mut n = 0;
        for id in deleted {
            lock(&self.manifests).remove(&id);
            let dir = self.book_dir(&id)?;
            if dir.exists() {
                std::fs::remove_dir_all(dir)?;
                n += 1;
            }
        }
        Ok(n)
    }

    /// Answers the WebView's request for `/book/<id>/s/<n>.html` (the section document) or
    /// `/book/<id>/r/<path>` (a resource). `path` is the URL path as requested, still
    /// percent-encoded. `/app/…` is the reader bundle, which the app serves itself.
    pub fn serve(&self, path: String, geometry: PageGeometry) -> Served {
        self.try_serve(&path, &geometry).unwrap_or(Served::NotFound)
    }

    /// The section document, for callers that don't go through a URL.
    pub fn section_document(&self, book_id: String, section: u32, geometry: PageGeometry) -> Result<String> {
        let m = self.manifest(&book_id)?;
        if section as usize >= m.sections.len() {
            return Err(CoreError::not_found("section"));
        }
        let content = self.rules_for(&book_id, false)?.apply_html(&book::section_html(&self.book_dir(&book_id)?, section)?);
        let html = document::section_document(&m, section, &content, &self.page_settings(&book_id, &geometry)?);
        let faces = self.font_faces();
        Ok(if faces.is_empty() { html } else { html.replacen("</head>", &format!("<style>{faces}</style>\n</head>"), 1) })
    }

    /// Where downloaded fonts are kept (霞鹜文楷); the page loads them from `/fonts/<file>`.
    pub fn fonts_dir(&self) -> String {
        self.fonts_path().to_string_lossy().into_owned()
    }

    /// The text of each sentence in a section, indexed like `data-s`, as the page shows it:
    /// after the replace rules, not the 只改朗读 ones.
    pub fn sentences(&self, book_id: String, section: u32) -> Result<Vec<String>> {
        let rules = self.rules_for(&book_id, false)?;
        let out = book::sentences(&self.book_dir(&book_id)?, section)?;
        Ok(if rules.is_empty() { out } else { out.iter().map(|s| rules.apply(s)).collect() })
    }

    /// The section after `section` in reading order. For speech, pictures and licence pages
    /// are skipped as well.
    pub fn next_section(&self, book_id: String, section: u32, speech: bool) -> Result<Option<u32>> {
        let m = self.manifest(&book_id)?;
        Ok((section as usize + 1..m.sections.len()).find(|&i| in_order(&m, i, speech)).map(|i| i as u32))
    }

    pub fn previous_section(&self, book_id: String, section: u32, speech: bool) -> Result<Option<u32>> {
        let m = self.manifest(&book_id)?;
        Ok((0..(section as usize).min(m.sections.len())).rev().find(|&i| in_order(&m, i, speech)).map(|i| i as u32))
    }

    pub fn save_progress(&self, book_id: String, position: Position) -> Result<()> {
        let m = self.manifest(&book_id)?;
        let fraction = fraction(&m, position);
        let now = now_ms();
        let mut store = lock(&self.store);
        let entity = format!("progress/{book_id}/{}", store.device());
        let value = json!({ "section": position.section, "sentence": position.sentence, "fraction": fraction, "at": now });
        store.set(&entity, "position", value)?;
        store.set(&format!("book/{book_id}"), "openedAt", json!(now))?;
        Ok(())
    }

    /// Where this device left off.
    pub fn progress(&self, book_id: String) -> Result<Option<Progress>> {
        let device = self.device_id();
        Ok(self.all_progress(&book_id)?.into_iter().find(|p| p.device == device))
    }

    /// The most recent position on any device, to offer "continue where you left off on iPad".
    pub fn latest_progress(&self, book_id: String) -> Result<Option<Progress>> {
        Ok(self.all_progress(&book_id)?.into_iter().next())
    }

    pub fn reader_settings(&self) -> Result<ReaderSettings> {
        self.settings_at("settings/reader")
    }

    /// Saves the settings that changed.
    pub fn set_reader_settings(&self, settings: ReaderSettings) -> Result<()> {
        self.set_settings_at("settings/reader", settings)
    }

    /// A book's own settings (只用于这本书), when it has them.
    pub fn book_reader_settings(&self, book_id: String) -> Result<Option<ReaderSettings>> {
        self.book_dir(&book_id)?;
        let entity = format!("settings/book/{book_id}");
        if lock(&self.store).get(&entity, "own")? != Some(json!(true)) {
            return Ok(None);
        }
        self.settings_at(&entity).map(Some)
    }

    /// Gives a book settings of its own, or (None) lets it follow the shared ones again.
    pub fn set_book_reader_settings(&self, book_id: String, settings: Option<ReaderSettings>) -> Result<()> {
        self.book_dir(&book_id)?;
        let entity = format!("settings/book/{book_id}");
        lock(&self.store).set(&entity, "own", json!(settings.is_some()))?;
        match settings {
            Some(s) => self.set_settings_at(&entity, s),
            None => Ok(()),
        }
    }
}

impl YuyueCore {
    fn settings_at(&self, entity: &str) -> Result<ReaderSettings> {
        let fields = lock(&self.store).fields(entity)?;
        let d = ReaderSettings::default();
        let get = |k: &str| fields.get(k).cloned().unwrap_or(Value::Null);
        let opt_f64 = |k: &str, default: Option<f64>| match fields.get(k) {
            Some(v) => v.as_f64(),
            None => default,
        };
        let opt_bool = |k: &str, default: Option<bool>| match fields.get(k) {
            Some(v) => v.as_bool(),
            None => default,
        };
        Ok(ReaderSettings {
            paper: serde_json::from_value(get("paper")).unwrap_or(d.paper),
            mode: serde_json::from_value(get("mode")).unwrap_or(d.mode),
            font: match fields.get("font") {
                Some(v) => serde_json::from_value(v.clone()).unwrap_or(None),
                None => d.font,
            },
            font_size: get("fontSize").as_f64().unwrap_or(d.font_size),
            line_height: opt_f64("lineHeight", d.line_height),
            paragraph_spacing: opt_f64("paragraphSpacing", d.paragraph_spacing),
            justify: opt_bool("justify", d.justify),
            indent: opt_bool("indent", d.indent),
            compress: get("compress").as_bool().unwrap_or(d.compress),
            custom_paper: get("customPaper").as_str().map(str::to_string),
        })
    }

    fn set_settings_at(&self, entity: &str, mut settings: ReaderSettings) -> Result<()> {
        let current = self.settings_at(entity)?;
        // On 我的纸, `paper` is the preset it reads like.
        if let Some(id) = &settings.custom_paper {
            match crate::paper::find_paper(&lock(&self.store), id)? {
                Some(p) => settings.paper = crate::paper::paper_colors(p).preset,
                None => settings.custom_paper = None,
            }
        }
        let mut fields: Vec<(&str, Value)> = Vec::new();
        let mut put = |name, changed: bool, value: Value| {
            if changed {
                fields.push((name, value));
            }
        };
        let s = &settings;
        put("paper", s.paper != current.paper, json!(s.paper));
        put("mode", s.mode != current.mode, json!(s.mode));
        put("font", s.font != current.font, json!(s.font));
        put("fontSize", s.font_size != current.font_size, json!(s.font_size));
        put("lineHeight", s.line_height != current.line_height, json!(s.line_height));
        put("paragraphSpacing", s.paragraph_spacing != current.paragraph_spacing, json!(s.paragraph_spacing));
        put("justify", s.justify != current.justify, json!(s.justify));
        put("indent", s.indent != current.indent, json!(s.indent));
        put("compress", s.compress != current.compress, json!(s.compress));
        put("customPaper", s.custom_paper != current.custom_paper, json!(s.custom_paper));
        if !fields.is_empty() {
            lock(&self.store).set_fields(entity, &fields)?;
        }
        Ok(())
    }
}

#[uniffi::export]
impl YuyueCore {

    /// This library's sync version, to send to another device (JSON).
    pub fn sync_version(&self) -> Result<String> {
        Ok(serde_json::to_string(&lock(&self.store).version()?)?)
    }

    /// The changes a device at `version` (from its `sync_version`) hasn't seen (JSON).
    pub fn export_changes(&self, version: String) -> Result<String> {
        let since: Version = serde_json::from_str(&version)?;
        Ok(serde_json::to_string(&lock(&self.store).export(&since)?)?)
    }

    /// `export_changes` with `left_out` not sent.
    pub fn export_changes_except(&self, version: String, left_out: Vec<SyncPart>) -> Result<String> {
        let since: Version = serde_json::from_str(&version)?;
        let mut batch = lock(&self.store).export(&since)?;
        without(&mut batch, &left_out);
        Ok(serde_json::to_string(&batch)?)
    }

    /// `import_changes` with `left_out` not taken. A device's file always holds all it has, so
    /// turning a part back on means reading the files again from the start.
    pub fn import_changes_except(&self, batch: String, left_out: Vec<SyncPart>) -> Result<u32> {
        let mut batch: Batch = serde_json::from_str(&batch)?;
        without(&mut batch, &left_out);
        self.import_batch(batch)
    }

    /// Applies another device's changes. Returns how many values changed.
    pub fn import_changes(&self, batch: String) -> Result<u32> {
        self.import_batch(serde_json::from_str(&batch)?)
    }
}

impl YuyueCore {
    fn import_batch(&self, batch: Batch) -> Result<u32> {
        let changed = lock(&self.store).import(&batch)? as u32;
        if changed > 0 {
            // A TXT may be read another way now; its manifest is checked again when next needed.
            lock(&self.manifests).clear();
            lock(&self.casts).clear();
        }
        Ok(changed)
    }
}

#[uniffi::export]
impl YuyueCore {
    /// The devices sharing this library, this one first, then the most recently used.
    pub fn devices(&self) -> Result<Vec<DeviceInfo>> {
        let store = lock(&self.store);
        let me = store.device().to_string();
        let text = |f: &std::collections::BTreeMap<String, Value>, k: &str| f.get(k).and_then(Value::as_str).unwrap_or("").to_string();
        let mut out: Vec<DeviceInfo> = store
            .entities("device/")?
            .into_iter()
            .filter_map(|(e, f)| {
                let id = e.strip_prefix("device/")?.to_string();
                Some(DeviceInfo {
                    this_device: id == me,
                    name: text(&f, "name"),
                    platform: text(&f, "platform"),
                    id,
                    last_book: None,
                    last_fraction: None,
                    last_at: None,
                })
            })
            .collect();
        for (entity, fields) in store.entities("progress/")? {
            let Some((book, device)) = entity.strip_prefix("progress/").and_then(|r| r.split_once('/')) else { continue };
            let Some(p) = fields.get("position") else { continue };
            let at = p["at"].as_i64().unwrap_or(0);
            if let Some(d) = out.iter_mut().find(|d| d.id == device)
                && d.last_at.is_none_or(|t| at > t) {
                    d.last_book = Some(book.to_string());
                    d.last_fraction = p["fraction"].as_f64();
                    d.last_at = Some(at);
                }
        }
        out.sort_by(|a, b| b.this_device.cmp(&a.this_device).then(b.last_at.cmp(&a.last_at)));
        Ok(out)
    }
}

impl YuyueCore {
    pub(crate) fn book_dir(&self, id: &str) -> Result<PathBuf> {
        // Ids are hex hashes; anything else could point outside the books folder.
        if id.len() != 32 || !id.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(CoreError::not_found("book"));
        }
        Ok(self.books_dir.join(id))
    }

    pub(crate) fn manifest(&self, id: &str) -> Result<Arc<Manifest>> {
        if let Some(m) = lock(&self.manifests).get(id) {
            return Ok(m.clone());
        }
        let dir = self.book_dir(id)?;
        let mut m = book::load(&dir)?;
        // A recording has nothing the importer made, so nothing to make again.
        if m.version != book::FORMAT_VERSION && !matches!(m.format, Format::Audio | Format::Podcast) {
            m = book::reimport(&self.books_dir, id, None)?;
        }
        // Another device chose another encoding or chapter rule; a bad choice leaves the book as it is.
        if let Ok(Some(rebuilt)) = self.follow_txt_choice(id, &m) {
            m = rebuilt;
        }
        let m = Arc::new(m);
        lock(&self.manifests).insert(id.to_string(), m.clone());
        Ok(m)
    }

    pub(crate) fn summary(&self, id: &str) -> Result<BookSummary> {
        let fields = lock(&self.store).fields(&format!("book/{id}"))?;
        let manifest = self.manifest(id).ok();
        let text = |k: &str| fields.get(k).and_then(Value::as_str).map(str::to_string);
        let latest = self.all_progress(id)?.into_iter().next();
        let progress = latest.as_ref().map(|p| p.fraction).unwrap_or(0.0);
        let page = latest
            .as_ref()
            .filter(|p| manifest.as_ref().and_then(|m| m.sections.get(p.position.section as usize)).is_some_and(|s| s.pages > 0))
            .map(|p| p.position.sentence + 1)
            .unwrap_or(0);
        let format = match (&manifest, fields.get("format").and_then(Value::as_str)) {
            (Some(m), _) => m.format.into(),
            (None, Some("txt")) => BookFormat::Txt,
            (None, Some("pdf")) => BookFormat::Pdf,
            (None, Some("mobi")) => BookFormat::Mobi,
            (None, Some("audio")) => BookFormat::Audio,
            (None, Some("podcast")) => BookFormat::Podcast,
            (None, _) => BookFormat::Epub,
        };
        Ok(BookSummary {
            id: id.to_string(),
            // What the user typed in 编辑信息 wins over what the file says.
            title: text("titleEdit")
                .or_else(|| manifest.as_ref().map(|m| m.title.clone()))
                .or_else(|| text("title"))
                .unwrap_or_default(),
            authors: ["authorsEdit", "authors"]
                .iter()
                .filter(|k| **k == "authorsEdit" || manifest.is_none())
                .find_map(|k| fields.get(*k).and_then(|v| serde_json::from_value(v.clone()).ok()))
                .or_else(|| manifest.as_ref().map(|m| m.authors.clone()))
                .unwrap_or_default(),
            language: manifest.as_ref().map(|m| m.language.clone()).or_else(|| text("language")).unwrap_or_default(),
            format,
            cover_path: manifest
                .as_ref()
                .and_then(|m| m.cover.as_ref())
                .and_then(|c| self.book_dir(id).ok().map(|d| d.join(c).to_string_lossy().into_owned())),
            added_at: fields.get("addedAt").and_then(Value::as_i64).unwrap_or(0),
            opened_at: fields.get("openedAt").and_then(Value::as_i64),
            finished_at: fields.get("finishedAt").and_then(Value::as_i64),
            progress,
            status: crate::shelf::status(&fields, progress),
            collections: crate::shelf::collections_of(&lock(&self.store), id)?,
            read_minutes: manifest.as_ref().map(|m| m.read_minutes).unwrap_or(0),
            listen_minutes: manifest.as_ref().map(|m| m.listen_minutes).unwrap_or(0),
            available: manifest.is_some(),
            page,
        })
    }

    /// Every device's position in a book, most recent first.
    fn all_progress(&self, book_id: &str) -> Result<Vec<Progress>> {
        let store = lock(&self.store);
        let me = store.device().to_string();
        let prefix = format!("progress/{book_id}/");
        let mut out = Vec::new();
        for (entity, fields) in store.entities(&prefix)? {
            let Some(device) = entity.strip_prefix(&prefix) else { continue };
            let Some(p) = fields.get("position") else { continue };
            let stamp = store.stamp_of(&entity, "position")?.unwrap_or_default();
            let device_name = store.get(&format!("device/{device}"), "name")?.and_then(|v| v.as_str().map(str::to_string));
            out.push((
                stamp,
                Progress {
                    position: Position {
                        section: p["section"].as_u64().unwrap_or(0) as u32,
                        sentence: p["sentence"].as_u64().unwrap_or(0) as u32,
                    },
                    fraction: p["fraction"].as_f64().unwrap_or(0.0),
                    device: device.to_string(),
                    device_name,
                    this_device: device == me,
                    at: p["at"].as_i64().unwrap_or(0),
                },
            ));
        }
        // Clock stamps order changes even when the devices' wall clocks disagree.
        out.sort_by(|a, b| b.0.cmp(&a.0));
        Ok(out.into_iter().map(|(_, p)| p).collect())
    }

    fn page_settings(&self, book_id: &str, g: &PageGeometry) -> Result<PageSettings> {
        // The book's own settings when it has them (只用于这本书).
        let r = match self.book_reader_settings(book_id.to_string())? {
            Some(own) => own,
            None => self.reader_settings()?,
        };
        let custom = match &r.custom_paper {
            Some(id) => crate::paper::find_paper(&lock(&self.store), id)?,
            None => None,
        };
        let colors = custom.clone().map(crate::paper::paper_colors);
        Ok(PageSettings {
            paper: colors.as_ref().map_or(r.paper, |c| c.preset),
            paper_style: colors.as_ref().map(crate::paper::page_style),
            texture: custom.and_then(|p| p.texture.css()),
            mode: r.mode,
            paging: g.paging,
            justify: r.justify,
            indent: r.indent,
            compress: r.compress,
            reduced_motion: g.reduced_motion,
            font_size: r.font_size,
            line_height: r.line_height,
            paragraph_spacing: r.paragraph_spacing,
            font: r.font,
            margin: g.margin,
            top: g.top,
            bottom: g.bottom,
            columns: g.columns,
        })
    }

    fn fonts_path(&self) -> PathBuf {
        self.books_dir.parent().map(|p| p.join("fonts")).unwrap_or_else(|| self.books_dir.join("../fonts"))
    }

    /// `@font-face` for each downloaded font: 霞鹜文楷 as its regular and its heavier weight.
    fn font_faces(&self) -> String {
        let dir = self.fonts_path();
        let mut css = String::new();
        for (file, weight) in [("LXGWWenKaiLite-Regular.ttf", "100 450"), ("LXGWWenKaiLite-Medium.ttf", "451 900")] {
            if dir.join(file).is_file() {
                css.push_str(&format!(r#"@font-face{{font-family:"LXGW WenKai";src:url("/fonts/{file}");font-weight:{weight};font-display:swap}}"#));
            }
        }
        css
    }

    fn try_serve(&self, path: &str, geometry: &PageGeometry) -> Result<Served> {
        let path = path.split(['?', '#']).next().unwrap_or("");
        if let Some(name) = path.strip_prefix("/fonts/") {
            // A bare file name in the fonts folder, nothing else.
            if name.is_empty() || name.contains(['/', '\\']) || name.starts_with('.') {
                return Ok(Served::NotFound);
            }
            let file = self.fonts_path().join(name);
            return Ok(if file.is_file() { Served::File { path: file.to_string_lossy().into_owned(), mime: "font/ttf".into() } } else { Served::NotFound });
        }
        let Some(rest) = path.strip_prefix("/book/") else { return Ok(Served::NotFound) };
        let Some((id, rest)) = rest.split_once('/') else { return Ok(Served::NotFound) };
        if let Some(name) = rest.strip_prefix("s/") {
            let Some(n) = name.strip_suffix(".html").and_then(|n| n.parse::<u32>().ok()) else {
                return Ok(Served::NotFound);
            };
            let body = self.section_document(id.to_string(), n, geometry.clone())?;
            return Ok(Served::Html { body });
        }
        if let Some(resource) = rest.strip_prefix("r/") {
            let decoded = percent_decode_str(resource).decode_utf8_lossy();
            let Some(file) = book::resource_path(&self.book_dir(id)?, &decoded) else { return Ok(Served::NotFound) };
            let mime = mime_type(&decoded).to_string();
            return Ok(Served::File { path: file.to_string_lossy().into_owned(), mime });
        }
        Ok(Served::NotFound)
    }
}

fn section_kind(kind: Kind) -> SectionKind {
    match kind {
        Kind::Text => SectionKind::Text,
        Kind::Image => SectionKind::Image,
        Kind::Boilerplate => SectionKind::Boilerplate,
    }
}

fn in_order(m: &Manifest, i: usize, speech: bool) -> bool {
    let s = &m.sections[i];
    s.linear && (!speech || (s.kind == Kind::Text && s.sentences > 0))
}

/// How far through the main text a position is: the text sections before it, plus the share
/// of its own sentences already read.
pub(crate) fn fraction(m: &Manifest, p: Position) -> f64 {
    if m.units == 0 {
        return 0.0;
    }
    // A PDF's pages count as its text, an audiobook's milliseconds likewise.
    let counts = |s: &book::SectionInfo| s.linear && (s.kind == Kind::Text || s.pages > 0 || s.ms > 0);
    let before: u32 = m.sections.iter().take(p.section as usize).filter(|s| counts(s)).map(|s| s.units).sum();
    let within = m
        .sections
        .get(p.section as usize)
        .filter(|s| counts(s))
        .map(|s| {
            let steps = if s.ms > 0 { s.ms } else if s.pages > 0 { s.pages } else { s.sentences };
            if steps == 0 { 0.0 } else { s.units as f64 * (p.sentence.min(steps) as f64 / steps as f64) }
        })
        .unwrap_or(0.0);
    ((before as f64 + within) / m.units as f64).clamp(0.0, 1.0)
}

fn mime_type(path: &str) -> &'static str {
    let ext = path.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
    match ext.as_str() {
        "css" => "text/css",
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "svg" => "image/svg+xml",
        "avif" => "image/avif",
        "bmp" => "image/bmp",
        "ttf" => "font/ttf",
        "otf" => "font/otf",
        "woff" => "font/woff",
        "woff2" => "font/woff2",
        "mp3" => "audio/mpeg",
        "m4a" | "mp4" => "audio/mp4",
        _ => "application/octet-stream",
    }
}

impl From<Format> for BookFormat {
    fn from(f: Format) -> Self {
        match f {
            Format::Epub => BookFormat::Epub,
            Format::Txt => BookFormat::Txt,
            Format::Pdf => BookFormat::Pdf,
            Format::Mobi => BookFormat::Mobi,
            Format::Audio => BookFormat::Audio,
            Format::Podcast => BookFormat::Podcast,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> String {
        format!("{}/../../fixtures/books/{name}", env!("CARGO_MANIFEST_DIR"))
    }

    fn geometry() -> PageGeometry {
        PageGeometry { paging: Paging::Native, margin: 20.0, top: 50.0, bottom: 80.0, columns: 1, reduced_motion: false }
    }

    fn temp(name: &str) -> String {
        let dir = std::env::temp_dir().join(format!("yuyue-api-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir.to_string_lossy().into_owned()
    }

    #[test]
    fn imports_a_pdf() {
        let dir = temp("pdf");
        let core = YuyueCore::open(dir.clone(), "测试 Mac".into(), "macos".into()).unwrap();
        let file = std::env::temp_dir().join(format!("yuyue-api-pdf-{}.pdf", std::process::id()));
        std::fs::write(&file, b"%PDF-1.7\n% not parsed by the core\n%%EOF\n").unwrap();
        let pdf = core.import_book(file.to_string_lossy().into_owned()).unwrap();
        assert_eq!((pdf.format, pdf.read_minutes, pdf.cover_path.is_none()), (BookFormat::Pdf, 0, true));

        let info = PdfInfo { pages: 40, title: Some(" 一份  说明书 ".into()), authors: vec!["某人".into()], characters: 40_000, cover: Some(vec![0xff, 0xd8, 0xff]) };
        let pdf = core.set_pdf_info(pdf.id.clone(), info.clone()).unwrap();
        assert_eq!((pdf.title.as_str(), pdf.authors.clone(), pdf.read_minutes), ("一份 说明书", vec!["某人".to_string()], 100));
        assert!(pdf.cover_path.as_deref().is_some_and(|p| Path::new(p).is_file()));
        // Described once; another reading changes nothing.
        let again = core.set_pdf_info(pdf.id.clone(), PdfInfo { pages: 2, title: None, ..info }).unwrap();
        assert_eq!(again.title, "一份 说明书");

        core.save_progress(pdf.id.clone(), Position { section: 0, sentence: 9 }).unwrap();
        let pdf = core.summary(&pdf.id).unwrap();
        assert_eq!((pdf.page, (pdf.progress * 100.0).round()), (10, 23.0));
        // A fresh start reads the manifest from disk.
        drop(core);
        let core = YuyueCore::open(dir.clone(), "测试 Mac".into(), "macos".into()).unwrap();
        assert_eq!(core.book(pdf.id.clone()).unwrap().sections[0].pages, 40);
        let _ = std::fs::remove_file(&file);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_picked_cover_replaces_the_books_own_and_outlives_a_rebuild() {
        let dir = temp("cover");
        let core = YuyueCore::open(dir.clone(), "测试 iPhone".into(), "ios".into()).unwrap();
        let book = core.import_book(fixture("pride-and-prejudice.epub")).unwrap();
        let first = core.set_cover(book.id.clone(), vec![0x89, b'P', b'N', b'G', 1, 2]).unwrap();
        let path = first.cover_path.clone().unwrap();
        assert!(path.ends_with(".png") && Path::new(&path).is_file());
        std::thread::sleep(std::time::Duration::from_millis(2));
        let second = core.set_cover(book.id.clone(), vec![0xff, 0xd8, 0xff]).unwrap();
        let path2 = second.cover_path.clone().unwrap();
        assert!(path2.ends_with(".jpg") && path2 != path && !Path::new(&path).exists());
        let rebuilt = book::reimport(&core.books_dir, &book.id, None).unwrap();
        assert_eq!(rebuilt.cover.as_deref(), Path::new(&path2).file_name().and_then(|n| n.to_str()));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn library_reading_and_progress() {
        let dir = temp("library");
        let core = YuyueCore::open(dir.clone(), "测试 iPhone".into(), "ios".into()).unwrap();
        let book = core.import_book(fixture("pride-and-prejudice.epub")).unwrap();
        let txt = core.import_book(fixture("beiying.txt")).unwrap();
        assert_eq!(core.import_book(fixture("beiying.txt")).unwrap().id, txt.id);
        assert!(book.cover_path.as_deref().is_some_and(|p| Path::new(p).is_file()));
        assert!(book.available && book.progress == 0.0);
        let books = core.books().unwrap();
        assert_eq!(books.len(), 2);

        let detail = core.book(book.id.clone()).unwrap();
        assert_eq!(detail.sections[detail.start as usize].kind, SectionKind::Text);
        let ch1 = detail.toc.iter().find(|e| e.title == "Chapter I").unwrap().section;

        // Documents and resources through the URL scheme.
        let Served::Html { body } = core.serve(format!("/book/{}/s/{ch1}.html", book.id), geometry()) else { panic!() };
        assert!(body.contains(r#"data-yy-paging="native""#) && body.contains("--yy-margin:20px"));
        assert!(body.contains(r#"<div class="yy-meta">读"#), "chapter openings carry the reading time");
        let css = body.split("<link rel=\"stylesheet\" href=\"../r/").nth(1).unwrap().split('"').next().unwrap();
        let served = core.serve(format!("/book/{}/r/{css}", book.id), geometry());
        assert!(matches!(&served, Served::File { mime, path } if mime == "text/css" && Path::new(path).is_file()), "{served:?}");
        let Served::Html { body: cover } = core.serve(format!("/book/{}/s/0.html?v=2", book.id), geometry()) else { panic!() };
        assert!(cover.contains(r#"data-kind="image""#));
        let img = cover.split("src=\"../r/").nth(1).unwrap().split('"').next().unwrap();
        let served = core.serve(format!("/book/{}/r/{img}", book.id), geometry());
        assert!(matches!(&served, Served::File { mime, path } if mime == "image/jpeg" && Path::new(path).is_file()), "{served:?}");
        assert_eq!(core.serve(format!("/book/{}/r/../book.json", book.id), geometry()), Served::NotFound);
        assert_eq!(core.serve("/book/../../etc/s/1.html".into(), geometry()), Served::NotFound);
        assert_eq!(core.serve(format!("/book/{}/s/999.html", book.id), geometry()), Served::NotFound);

        // Speech skips the cover and the licence; paging doesn't.
        assert_eq!(core.next_section(book.id.clone(), 0, false).unwrap(), Some(1));
        assert_eq!(core.next_section(book.id.clone(), 0, true).unwrap(), Some(detail.start));
        let last = detail.sections.len() as u32 - 1;
        assert_eq!(core.next_section(book.id.clone(), last - 1, true).unwrap(), None);
        assert_eq!(core.previous_section(book.id.clone(), detail.start, true).unwrap(), None);

        let sentences = core.sentences(book.id.clone(), ch1).unwrap();
        assert!(sentences[0].starts_with("Chapter I"));
        core.save_progress(book.id.clone(), Position { section: ch1, sentence: 3 }).unwrap();
        let p = core.progress(book.id.clone()).unwrap().unwrap();
        assert!(p.this_device && p.position.sentence == 3 && p.fraction > 0.0 && p.fraction < 0.05, "{p:?}");
        assert_eq!(p.device_name.as_deref(), Some("测试 iPhone"));
        assert_eq!(core.books().unwrap()[0].id, book.id, "the book just read comes first");

        // Settings persist field by field and reach the next document.
        let mut s = core.reader_settings().unwrap();
        assert_eq!(s, ReaderSettings::default());
        s.paper = Paper::Kami;
        s.font_size = 20.0;
        s.font = Some(Font::Serif);
        core.set_reader_settings(s.clone()).unwrap();
        drop(core);
        let core = YuyueCore::open(dir.clone(), "测试 iPhone".into(), "ios".into()).unwrap();
        assert_eq!(core.reader_settings().unwrap(), s);
        let body = core.section_document(book.id.clone(), ch1, geometry()).unwrap();
        assert!(body.contains(r#"data-yy-paper="kami""#) && body.contains("--yy-fs:20px") && body.contains("--yy-font:var(--yy-serif)"));

        // A book with settings of its own keeps them; the rest follow the shared ones.
        assert_eq!(core.book_reader_settings(book.id.clone()).unwrap(), None);
        let mut own = s.clone();
        own.font_size = 26.0;
        core.set_book_reader_settings(book.id.clone(), Some(own.clone())).unwrap();
        assert_eq!(core.book_reader_settings(book.id.clone()).unwrap(), Some(own));
        assert!(core.section_document(book.id.clone(), ch1, geometry()).unwrap().contains("--yy-fs:26px"));
        assert_eq!(core.reader_settings().unwrap(), s);
        core.set_book_reader_settings(book.id.clone(), None).unwrap();
        assert!(core.section_document(book.id.clone(), ch1, geometry()).unwrap().contains("--yy-fs:20px"));

        core.delete_book(txt.id.clone()).unwrap();
        assert_eq!(core.books().unwrap().len(), 1);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn two_devices_share_progress_and_settings() {
        let (da, db) = (temp("dev-a"), temp("dev-b"));
        let a = YuyueCore::open(da.clone(), "iPhone".into(), "ios".into()).unwrap();
        let b = YuyueCore::open(db.clone(), "Mac".into(), "macos".into()).unwrap();
        let book = a.import_book(fixture("edge-cases.epub")).unwrap();
        b.import_book(fixture("edge-cases.epub")).unwrap();
        a.save_progress(book.id.clone(), Position { section: 1, sentence: 2 }).unwrap();
        let mut s = a.reader_settings().unwrap();
        s.paper = Paper::Dark;
        a.set_reader_settings(s).unwrap();
        let mut s = b.reader_settings().unwrap();
        s.font_size = 22.0;
        b.set_reader_settings(s).unwrap();

        let exchange = |from: &YuyueCore, to: &YuyueCore| {
            let changes = from.export_changes(to.sync_version().unwrap()).unwrap();
            to.import_changes(changes).unwrap()
        };
        assert!(exchange(&a, &b) > 0);
        exchange(&b, &a);
        // Different settings changed on each device: both survive.
        for core in [&a, &b] {
            let s = core.reader_settings().unwrap();
            assert_eq!((s.paper, s.font_size), (Paper::Dark, 22.0));
        }
        let latest = b.latest_progress(book.id.clone()).unwrap().unwrap();
        assert_eq!((latest.position.section, latest.device_name.as_deref(), latest.this_device), (1, Some("iPhone"), false));
        assert!(b.progress(book.id.clone()).unwrap().is_none());
        assert_eq!(exchange(&a, &b), 0);
        let devices = b.devices().unwrap();
        assert_eq!(devices.iter().map(|d| (d.name.as_str(), d.this_device)).collect::<Vec<_>>(), [("Mac", true), ("iPhone", false)]);
        assert_eq!(devices[1].last_book.as_deref(), Some(book.id.as_str()));
        // Everything from nothing: what a device puts in the shared folder.
        let everything = a.export_changes("{}".into()).unwrap();
        assert_eq!(b.import_changes(everything).unwrap(), 0);
        std::fs::remove_dir_all(&da).unwrap();
        std::fs::remove_dir_all(&db).unwrap();
    }

    #[test]
    fn sync_parts_left_out_come_back_when_turned_on() {
        let (da, db) = (temp("part-a"), temp("part-b"));
        let a = YuyueCore::open(da.clone(), "iPhone".into(), "ios".into()).unwrap();
        let b = YuyueCore::open(db.clone(), "Mac".into(), "macos".into()).unwrap();
        let book = a.import_book(fixture("edge-cases.epub")).unwrap();
        b.import_book(fixture("edge-cases.epub")).unwrap();
        a.save_progress(book.id.clone(), Position { section: 1, sentence: 2 }).unwrap();
        let mut s = a.reader_settings().unwrap();
        s.paper = Paper::Dark;
        a.set_reader_settings(s).unwrap();

        // Not sent: a's file has the progress but not the settings.
        let sent = a.export_changes_except("{}".into(), vec![SyncPart::Settings]).unwrap();
        assert!(sent.contains("progress/") && !sent.contains("\"settings/"));
        // Not taken: b reads a's whole file but leaves the settings out…
        let everything = a.export_changes("{}".into()).unwrap();
        assert!(b.import_changes_except(everything.clone(), vec![SyncPart::Settings]).unwrap() > 0);
        assert_ne!(b.reader_settings().unwrap().paper, Paper::Dark);
        assert!(b.latest_progress(book.id.clone()).unwrap().is_some());
        // A book's kept file, imported elsewhere, is the same book.
        let file = a.original_file(book.id.clone()).unwrap();
        assert_eq!(b.import_book(file).unwrap().id, book.id);
        // …and when they're on again, reading the same file from the start brings them.
        assert!(b.import_changes(everything).unwrap() > 0);
        assert_eq!(b.reader_settings().unwrap().paper, Paper::Dark);
        std::fs::remove_dir_all(&da).unwrap();
        std::fs::remove_dir_all(&db).unwrap();
    }
}
