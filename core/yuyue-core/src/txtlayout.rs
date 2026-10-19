//! 编码和目录 (FEATURES §1): reading a TXT in another encoding, or cutting it into chapters by
//! another rule. The page tries a choice on the original file without touching the book; applying
//! it re-imports the book.
//!
//! Registers: `book/<id>` · `txtEncoding` / `txtRule`, so every device reads the file the same
//! way. Each device's folder records how it was built (`layout.json`); a device that finds the
//! two disagree builds the book again.
//!
//! Sentence numbers change when the chapters do, so highlights, bookmarks and progress are
//! carried over: each place goes to the same point through the text, then to the nearest
//! sentence with the same words.

use serde_json::{Value, json};

use crate::api::{BookSummary, Position, YuyueCore, fraction, lock};
use crate::book::{self, Format, Manifest, TxtOptions};
use crate::error::{CoreError, Result};
use crate::txt;

/// An encoding and a chapter rule; `None` for the importer's own guess.
#[derive(Clone, Debug, Default, PartialEq, uniffi::Record)]
pub struct TxtChoice {
    pub encoding: Option<String>,
    pub rule: Option<String>,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct TxtChapter {
    pub title: String,
    /// Characters, the chapter's parts put together.
    pub chars: u32,
    /// The section it starts, once the book is read this way.
    pub section: u32,
}

/// What the file looks like read with one choice.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct TxtLayout {
    /// Bytes in the original file.
    pub size: u64,
    /// The encoding the importer guesses, for "自动 · GBK".
    pub detected: String,
    /// The encoding this was read in.
    pub encoding: String,
    /// The rule the importer uses when none is written.
    pub default_rule: String,
    /// The start of the first chapter, to see at once whether it reads: its title and first
    /// paragraphs.
    pub preview_title: Option<String>,
    pub preview: Vec<String>,
    /// Bytes that aren't text in this encoding.
    pub unreadable: u32,
    pub chapters: Vec<TxtChapter>,
    /// The chapter in `chapters` far longer than the others: a heading the rule missed.
    pub long: Option<u32>,
    /// Why the result may be wrong.
    pub doubt: Option<String>,
    /// The rule doesn't compile; nothing else is filled in.
    pub error: Option<String>,
}

const PREVIEW_PARAGRAPHS: usize = 3;
const PREVIEW_WIDTH: usize = 120;
/// How far from the place through the text the same words are looked for, in sentences.
const SEARCH_SPAN: usize = 300;

#[uniffi::export]
impl YuyueCore {
    /// How a TXT is read now.
    pub fn txt_choice(&self, book_id: String) -> Result<TxtChoice> {
        let dir = self.txt_dir(&book_id)?;
        let o = book::txt_options(&dir);
        Ok(TxtChoice { encoding: o.encoding, rule: o.rule })
    }

    /// What a choice would make of the file, without changing the book.
    pub fn txt_layout(&self, book_id: String, choice: TxtChoice) -> Result<TxtLayout> {
        let dir = self.txt_dir(&book_id)?;
        let bytes = std::fs::read(dir.join("original.txt"))?;
        let detected = txt::encoding_name(txt::decode_as(&bytes, None).encoding);
        let encoding = encoding(&choice)?;
        let mut layout = TxtLayout {
            size: bytes.len() as u64,
            detected,
            encoding: String::new(),
            default_rule: txt::DEFAULT_RULE.into(),
            preview_title: None,
            preview: Vec::new(),
            unreadable: 0,
            chapters: Vec::new(),
            long: None,
            doubt: None,
            error: None,
        };
        let headings = match txt::Headings::rule(choice.rule.as_deref()) {
            Ok(h) => h,
            Err(_) => {
                layout.error = Some(crate::i18n::tr("目录规则写得不对", "The chapter rule isn't valid"));
                return Ok(layout);
            }
        };
        let a = txt::analyze(&bytes, encoding, &headings);
        layout.encoding = txt::encoding_name(a.decoded.encoding);
        if let Some(first) = a.book.chapters.iter().find(|c| !c.paragraphs.is_empty()) {
            layout.preview_title = first.title.clone();
            layout.preview = first.paragraphs.iter().take(PREVIEW_PARAGRAPHS).map(|p| shortened(p)).collect();
        }
        layout.unreadable = a.decoded.errors as u32;
        layout.chapters = a
            .outline
            .iter()
            .map(|(t, n, s)| TxtChapter { title: t.clone().unwrap_or_else(|| crate::i18n::tr("开头", "Beginning")), chars: *n as u32, section: *s as u32 })
            .collect();
        layout.long = a.long.map(|i| i as u32);
        layout.doubt = a.doubt;
        Ok(layout)
    }

    /// Why the way a TXT was read may be wrong, for a hint on its page; none when it looks fine.
    pub fn txt_doubt(&self, book_id: String) -> Result<Option<String>> {
        let dir = self.txt_dir(&book_id)?;
        Ok(book::txt_options(&dir).doubt)
    }

    /// Reads the TXT with a choice from now on, on every device. Highlights, bookmarks and
    /// progress are carried over to the new chapters.
    pub fn set_txt_choice(&self, book_id: String, choice: TxtChoice) -> Result<BookSummary> {
        let dir = self.txt_dir(&book_id)?;
        let choice = normalized(choice);
        encoding(&choice)?;
        txt::Headings::rule(choice.rule.as_deref()).map_err(|_| CoreError::Invalid { message: crate::i18n::tr("目录规则写得不对", "The chapter rule isn't valid") })?;
        let old = book::txt_options(&dir);
        if old.encoding == choice.encoding && old.rule == choice.rule {
            return self.summary(&book_id);
        }
        self.rebuild(&book_id, &choice, true)?;
        lock(&self.store).set_fields(
            &format!("book/{book_id}"),
            &[("txtEncoding", json!(choice.encoding)), ("txtRule", json!(choice.rule))],
        )?;
        self.summary(&book_id)
    }
}

impl YuyueCore {
    fn txt_dir(&self, book_id: &str) -> Result<std::path::PathBuf> {
        let dir = self.book_dir(book_id)?;
        if self.manifest(book_id)?.format != Format::Txt {
            return Err(CoreError::bad_book("not a text file"));
        }
        Ok(dir)
    }

    /// A TXT built here another way than the library says, after a sync: built again.
    pub(crate) fn follow_txt_choice(&self, book_id: &str, m: &Manifest) -> Result<Option<Manifest>> {
        if m.format != Format::Txt {
            return Ok(None);
        }
        let fields = lock(&self.store).fields(&format!("book/{book_id}"))?;
        let text = |k: &str| fields.get(k).and_then(Value::as_str).map(str::to_string);
        let wanted = TxtChoice { encoding: text("txtEncoding"), rule: text("txtRule") };
        let built = book::txt_options(&self.book_dir(book_id)?);
        if built.encoding == wanted.encoding && built.rule == wanted.rule {
            return Ok(None);
        }
        // The device that chose moved the shared notes; only this device's progress is left.
        self.rebuild(book_id, &wanted, false).map(Some)
    }

    fn rebuild(&self, book_id: &str, choice: &TxtChoice, move_notes: bool) -> Result<Manifest> {
        let dir = self.book_dir(book_id)?;
        let old = self.manifest_on_disk(book_id)?;
        let before = Flat::read(&dir, &old)?;
        let options = TxtOptions { encoding: choice.encoding.clone(), rule: choice.rule.clone(), doubt: None };
        let new = book::reimport(&self.books_dir, book_id, Some(&options))?;
        let after = Flat::read(&dir, &new)?;
        self.carry_over(book_id, &old, &new, &before, &after, move_notes)?;
        lock(&self.manifests).insert(book_id.to_string(), std::sync::Arc::new(new.clone()));
        Ok(new)
    }

    fn manifest_on_disk(&self, book_id: &str) -> Result<Manifest> {
        if let Some(m) = lock(&self.manifests).get(book_id) {
            return Ok((**m).clone());
        }
        book::load(&self.book_dir(book_id)?)
    }

    fn carry_over(&self, book: &str, old: &Manifest, new: &Manifest, before: &Flat, after: &Flat, move_notes: bool) -> Result<()> {
        let map = |section: u64, sentence: u64| before.map(after, section as u32, sentence as u32);
        let mut store = lock(&self.store);
        // What was read off the old text (title, language) follows it, unless the reader changed it.
        let entity = format!("book/{book}");
        let fields = store.fields(&entity)?;
        let mut changed = Vec::new();
        if fields.get("title") == Some(&json!(old.title)) && old.title != new.title {
            changed.push(("title", json!(new.title)));
        }
        if fields.get("authors") == Some(&json!(old.authors)) && old.authors != new.authors {
            changed.push(("authors", json!(new.authors)));
        }
        if fields.get("language") == Some(&json!(old.language)) && old.language != new.language {
            changed.push(("language", json!(new.language)));
        }
        if !changed.is_empty() {
            store.set_fields(&entity, &changed)?;
        }

        let progress = format!("progress/{book}/{}", store.device());
        if let Some(p) = store.get(&progress, "position")? {
            let (section, sentence) = map(p["section"].as_u64().unwrap_or(0), p["sentence"].as_u64().unwrap_or(0));
            let mut p = p.clone();
            p["section"] = json!(section);
            p["sentence"] = json!(sentence);
            p["fraction"] = json!(fraction(new, Position { section, sentence }));
            store.set(&progress, "position", p)?;
        }
        if !move_notes {
            return Ok(());
        }
        for (entity, f) in store.entities(&format!("mark/{book}/"))? {
            if f.get("deleted") == Some(&json!(true)) {
                continue;
            }
            let section = f.get("section").and_then(Value::as_u64).unwrap_or(0);
            let point = |k: &str| f.get(k).map(|v| (v["s"].as_u64().unwrap_or(0), v["o"].as_u64().unwrap_or(0))).unwrap_or((0, 0));
            let ((s0, o0), (s1, o1)) = (point("start"), point("end"));
            let (to, start) = map(section, s0);
            let (end_section, end) = map(section, s1);
            // A highlight lives in one section; one cut in two by a new heading keeps its start.
            let (end, o1) = if end_section == to && end >= start { (end, o1) } else { (start, o0 + 1) };
            store.set_fields(
                &entity,
                &[("section", json!(to)), ("start", json!({ "s": start, "o": o0 })), ("end", json!({ "s": end, "o": o1 }))],
            )?;
        }
        for (entity, f) in store.entities(&format!("bookmark/{book}/"))? {
            if f.get("deleted") == Some(&json!(true)) {
                continue;
            }
            let (section, sentence) = map(
                f.get("section").and_then(Value::as_u64).unwrap_or(0),
                f.get("sentence").and_then(Value::as_u64).unwrap_or(0),
            );
            store.set_fields(&entity, &[("section", json!(section)), ("sentence", json!(sentence))])?;
        }
        Ok(())
    }
}

/// Encodings by their usual names; the one the importer guesses is no choice at all.
fn normalized(choice: TxtChoice) -> TxtChoice {
    let rule = choice.rule.map(|r| r.trim().to_string()).filter(|r| !r.is_empty() && r != txt::DEFAULT_RULE);
    let encoding = choice.encoding.map(|e| e.trim().to_string()).filter(|e| !e.is_empty());
    TxtChoice { encoding, rule }
}

fn encoding(choice: &TxtChoice) -> Result<Option<&'static encoding_rs::Encoding>> {
    match &choice.encoding {
        Some(name) => txt::encoding_for(name).map(Some).ok_or_else(|| CoreError::Invalid { message: format!("{}{name}", crate::i18n::tr("不认识的编码：", "Unknown encoding: ")) }),
        None => Ok(None),
    }
}

fn shortened(p: &str) -> String {
    if p.chars().count() > PREVIEW_WIDTH { format!("{}…", p.chars().take(PREVIEW_WIDTH).collect::<String>()) } else { p.to_string() }
}

/// A book's sentences in one row, with where each section starts and how far through the
/// text each sentence is.
struct Flat {
    /// Index of each section's first sentence.
    starts: Vec<usize>,
    /// Characters before each sentence.
    offsets: Vec<usize>,
    texts: Vec<String>,
    total: usize,
}

impl Flat {
    fn read(dir: &std::path::Path, m: &Manifest) -> Result<Flat> {
        let mut flat = Flat { starts: Vec::new(), offsets: Vec::new(), texts: Vec::new(), total: 0 };
        for n in 0..m.sections.len() as u32 {
            flat.starts.push(flat.texts.len());
            for s in book::sentences(dir, n).unwrap_or_default() {
                flat.offsets.push(flat.total);
                flat.total += s.chars().count();
                flat.texts.push(s);
            }
        }
        Ok(flat)
    }

    fn index(&self, section: u32, sentence: u32) -> Option<usize> {
        let start = *self.starts.get(section as usize)?;
        let end = self.starts.get(section as usize + 1).copied().unwrap_or(self.texts.len());
        (start < end).then(|| (start + sentence as usize).min(end - 1))
    }

    fn place(&self, i: usize) -> (u32, u32) {
        let section = self.starts.partition_point(|&s| s <= i).saturating_sub(1);
        (section as u32, (i - self.starts[section]) as u32)
    }

    /// The same place in `other`: as far through the text, then the nearest sentence there with
    /// the same words.
    fn map(&self, other: &Flat, section: u32, sentence: u32) -> (u32, u32) {
        if other.texts.is_empty() {
            return (0, 0);
        }
        let Some(i) = self.index(section, sentence) else { return (0, 0) };
        let through = if self.total == 0 { 0.0 } else { self.offsets[i] as f64 / self.total as f64 };
        let target = (through * other.total as f64) as usize;
        let guess = other.offsets.partition_point(|&o| o <= target).saturating_sub(1);
        let words = &self.texts[i];
        let found = (words.chars().count() >= 2)
            .then(|| {
                (0..=SEARCH_SPAN).find_map(|d| {
                    [guess.checked_sub(d), Some(guess + d)].into_iter().flatten().find(|&j| other.texts.get(j) == Some(words))
                })
            })
            .flatten();
        other.place(found.unwrap_or(guess))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn flat(sections: &[&[&str]]) -> Flat {
        let mut f = Flat { starts: Vec::new(), offsets: Vec::new(), texts: Vec::new(), total: 0 };
        for s in sections {
            f.starts.push(f.texts.len());
            for t in *s {
                f.offsets.push(f.total);
                f.total += t.chars().count();
                f.texts.push(t.to_string());
            }
        }
        f
    }

    #[test]
    fn places_follow_the_words_into_new_chapters() {
        let old = flat(&[&["第一章", "甲甲甲。", "乙乙乙。", "第二章", "丙丙丙。", "丁丁丁。"]]);
        let new = flat(&[&["第一章", "甲甲甲。", "乙乙乙。"], &["第二章", "丙丙丙。", "丁丁丁。"]]);
        assert_eq!(old.map(&new, 0, 5), (1, 2));
        assert_eq!(old.map(&new, 0, 1), (0, 1));
        assert_eq!(new.map(&old, 1, 1), (0, 4));
        // Out of range stays inside the book.
        assert_eq!(old.map(&new, 9, 0), (0, 0));
    }

    #[test]
    fn previews_and_rechapters_a_txt() {
        let dir = std::env::temp_dir().join(format!("yuyue-txtlayout-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let mut text = String::from("测试之书\n\n");
        for i in 1..=6 {
            text.push_str(&format!("第{i}章 开始\n"));
            text.push_str(&format!("　　这是第{i}章的正文，一句话。另一句话。\n\n"));
            text.push_str(&format!("卷{i}·小节\n"));
            text.push_str("　　小节里的话。\n\n");
        }
        let file = dir.join("书.txt");
        std::fs::write(&file, &text).unwrap();
        let core = YuyueCore::open(dir.join("lib").to_string_lossy().into_owned(), "Mac".into(), "macos".into()).unwrap();
        let b = core.import_book(file.to_string_lossy().into_owned()).unwrap();

        let auto = core.txt_layout(b.id.clone(), TxtChoice::default()).unwrap();
        assert_eq!(auto.detected, "UTF-8");
        assert_eq!(auto.chapters.len(), 6, "{:?}", auto.chapters);
        assert_eq!(auto.preview_title.as_deref(), Some("第1章 开始"));
        assert_eq!(auto.preview[0], "这是第1章的正文，一句话。另一句话。");
        let bad = core.txt_layout(b.id.clone(), TxtChoice { encoding: None, rule: Some("(".into()) }).unwrap();
        assert!(bad.error.is_some());
        let big5 = core.txt_layout(b.id.clone(), TxtChoice { encoding: Some("Big5".into()), rule: None }).unwrap();
        assert!(big5.unreadable > 0 && big5.encoding == "Big5");

        // A bookmark on the last chapter's words, and progress there.
        let section = core.book(b.id.clone()).unwrap().sections.len() as u32 - 1;
        let words = core.sentences(b.id.clone(), section).unwrap();
        let at = words.iter().position(|s| s.contains("另一句话")).unwrap() as u32;
        core.add_bookmark(b.id.clone(), section, at).unwrap();
        core.save_progress(b.id.clone(), Position { section, sentence: at }).unwrap();

        let rule = Some("^(第.+章|卷.+)".to_string());
        let layout = core.txt_layout(b.id.clone(), TxtChoice { encoding: None, rule: rule.clone() }).unwrap();
        assert_eq!(layout.chapters.len(), 12);
        assert_eq!(layout.chapters[11].section, 11);
        core.set_txt_choice(b.id.clone(), TxtChoice { encoding: None, rule: rule.clone() }).unwrap();
        assert_eq!(core.txt_choice(b.id.clone()).unwrap().rule, rule);
        let detail = core.book(b.id.clone()).unwrap();
        assert_eq!(detail.sections.len(), 12);

        let mark = &core.bookmarks(b.id.clone()).unwrap()[0];
        assert_eq!(core.sentences(b.id.clone(), mark.section).unwrap()[mark.sentence as usize], words[at as usize]);
        let p = core.progress(b.id.clone()).unwrap().unwrap();
        assert_eq!((p.position.section, p.position.sentence), (mark.section, mark.sentence));

        // Back to the importer's own way.
        core.set_txt_choice(b.id.clone(), TxtChoice { encoding: None, rule: Some(txt::DEFAULT_RULE.into()) }).unwrap();
        assert_eq!(core.txt_choice(b.id.clone()).unwrap(), TxtChoice::default());
        assert_eq!(core.book(b.id.clone()).unwrap().sections.len(), 6);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
