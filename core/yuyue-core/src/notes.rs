//! Highlights, thoughts, bookmarks, in-book search and the time spent in each chapter
//! (FEATURES §2).
//!
//! Registers: `mark/<book>/<id>` · `section` / `start` / `end` / `text` / `style` / `note` /
//! `at` / `review` / `reviewedAt` / `deleted`, `bookmark/<book>/<id>` · `section` / `sentence` / `text` / `at` /
//! `deleted`, and `time/<book>/<device>` · `s<section>` = `{read, listen}` in seconds. Only
//! one device writes each time register, so adding up stays right after a sync.
//!
//! A highlight's ends are a sentence and a character offset into that sentence's text as the
//! page shows it; the reader works them out and draws them.

use std::collections::BTreeMap;

use serde_json::{Value, json};

use crate::api::{YuyueCore, lock, now_ms};
use crate::error::{CoreError, Result};

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum MarkStyle {
    Yellow,
    Blue,
    Pink,
    /// A red wavy line.
    Wave,
    Underline,
    Dotted,
}

impl MarkStyle {
    fn name(self) -> &'static str {
        match self {
            MarkStyle::Yellow => "yellow",
            MarkStyle::Blue => "blue",
            MarkStyle::Pink => "pink",
            MarkStyle::Wave => "wave",
            MarkStyle::Underline => "underline",
            MarkStyle::Dotted => "dotted",
        }
    }

    fn from_name(s: &str) -> MarkStyle {
        match s {
            "blue" => MarkStyle::Blue,
            "pink" => MarkStyle::Pink,
            "wave" => MarkStyle::Wave,
            "underline" => MarkStyle::Underline,
            "dotted" => MarkStyle::Dotted,
            _ => MarkStyle::Yellow,
        }
    }
}

/// A place inside a section: a sentence and a character offset into it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, uniffi::Record)]
pub struct TextPoint {
    pub sentence: u32,
    pub offset: u32,
}

/// 划线, with the thought written on it if any (想法).
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct Mark {
    pub id: String,
    pub section: u32,
    pub start: TextPoint,
    pub end: TextPoint,
    /// The words marked, as they were.
    pub text: String,
    pub style: MarkStyle,
    pub note: Option<String>,
    pub at: i64,
    /// 双击耳机: marked while listening, shown with a small headphone.
    pub heard: bool,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct Bookmark {
    pub id: String,
    pub section: u32,
    pub sentence: u32,
    /// The start of the sentence it was put on.
    pub text: String,
    pub at: i64,
}

/// One place a search found.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct SearchHit {
    pub section: u32,
    pub sentence: u32,
    /// Which match within the sentence (0 for the first).
    pub nth: u32,
    /// The words before, starting with "……" when the sentence goes on further back.
    pub before: String,
    pub matched: String,
    /// The words after, ending with "……" when the sentence goes on.
    pub after: String,
}

/// A highlight up for 今天回顾, with the book it is in.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct ReviewItem {
    pub book: String,
    pub mark: Mark,
}

/// 今天回顾: what is left to look at today, and how many were looked at already.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct ReviewDeck {
    pub items: Vec<ReviewItem>,
    pub done_today: u32,
}

/// A highlight kept in 回顾 comes back after this long.
const REVIEW_AGAIN_MS: i64 = 7 * 24 * 3600 * 1000;

/// Time spent on one book on one day (the app's local "2026-10-16"), added up over every device:
/// what 我的 · 阅读统计 counts.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct DayTime {
    pub day: String,
    pub book: String,
    pub read_seconds: u32,
    pub listen_seconds: u32,
}

/// Time spent in one section, added up over every device.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Record)]
pub struct SectionTime {
    pub section: u32,
    pub read_seconds: u32,
    pub listen_seconds: u32,
}

fn new_id() -> String {
    format!("{:016x}", getrandom::u64().unwrap_or_else(|_| now_ms() as u64 ^ (std::process::id() as u64) << 40))
}

fn check_id(id: &str) -> Result<()> {
    if id.len() == 16 && id.bytes().all(|b| b.is_ascii_hexdigit()) { Ok(()) } else { Err(CoreError::not_found("note")) }
}

fn point(v: Option<&Value>) -> Option<TextPoint> {
    let v = v?;
    Some(TextPoint { sentence: v.get("s")?.as_u64()? as u32, offset: v.get("o")?.as_u64()? as u32 })
}

fn live(f: &BTreeMap<String, Value>) -> bool {
    f.get("deleted") != Some(&json!(true))
}

fn int(f: &BTreeMap<String, Value>, key: &str) -> i64 {
    f.get(key).and_then(Value::as_i64).unwrap_or(0)
}

fn mark_from(id: &str, f: &BTreeMap<String, Value>) -> Option<Mark> {
    Some(Mark {
        id: id.to_string(),
        section: f.get("section")?.as_u64()? as u32,
        start: point(f.get("start"))?,
        end: point(f.get("end"))?,
        text: f.get("text").and_then(Value::as_str).unwrap_or_default().to_string(),
        style: MarkStyle::from_name(f.get("style").and_then(Value::as_str).unwrap_or_default()),
        note: f.get("note").and_then(Value::as_str).map(str::to_string),
        at: int(f, "at"),
        heard: f.get("heard").and_then(Value::as_bool).unwrap_or(false),
    })
}

fn clean_note(note: Option<String>) -> Option<String> {
    note.map(|n| n.trim().to_string()).filter(|n| !n.is_empty())
}

/// How far a search hit's context reaches on each side, in characters.
const CONTEXT: usize = 14;
/// A search stops after this many hits.
const MAX_HITS: usize = 500;

#[uniffi::export]
impl YuyueCore {

    /// The book's highlights in reading order.
    pub fn marks(&self, book: String) -> Result<Vec<Mark>> {
        self.book_dir(&book)?;
        let prefix = format!("mark/{book}/");
        let mut out: Vec<Mark> = lock(&self.store)
            .entities(&prefix)?
            .into_iter()
            .filter(|(_, f)| live(f))
            .filter_map(|(e, f)| mark_from(e.strip_prefix(&prefix)?, &f))
            .collect();
        out.sort_by_key(|a| (a.section, a.start, a.at));
        Ok(out)
    }

    /// Marks `text` from `start` to `end` of a section.
    pub fn add_mark(
        &self,
        book: String,
        section: u32,
        start: TextPoint,
        end: TextPoint,
        text: String,
        style: MarkStyle,
        note: Option<String>,
    ) -> Result<Mark> {
        self.insert_mark(book, section, start, end, text, style, note, false)
    }

    /// 双击耳机: marks the sentence just heard, unless a mark already covers it.
    pub fn mark_heard(&self, book: String, section: u32, start: TextPoint, end: TextPoint, text: String, style: MarkStyle) -> Result<Mark> {
        if let Some(mark) = self.marks(book.clone())?.into_iter().find(|m| m.section == section && m.start <= start && m.end >= end) {
            return Ok(mark);
        }
        self.insert_mark(book, section, start, end, text, style, None, true)
    }

    pub fn set_mark_style(&self, book: String, id: String, style: MarkStyle) -> Result<()> {
        self.book_dir(&book)?;
        check_id(&id)?;
        lock(&self.store).set(&format!("mark/{book}/{id}"), "style", json!(style.name()))
    }

    /// 想法: the thought on a highlight; empty takes it off and leaves the highlight.
    pub fn set_mark_note(&self, book: String, id: String, note: Option<String>) -> Result<()> {
        self.book_dir(&book)?;
        check_id(&id)?;
        let note = clean_note(note);
        lock(&self.store).set(&format!("mark/{book}/{id}"), "note", note.map_or(Value::Null, |n| json!(n)))
    }

    pub fn delete_mark(&self, book: String, id: String) -> Result<()> {
        self.set_deleted("mark", &book, &id, true)
    }

    pub fn restore_mark(&self, book: String, id: String) -> Result<()> {
        self.set_deleted("mark", &book, &id, false)
    }

    /// 今天回顾: up to `count` highlights for today, never-seen ones first (oldest first), then
    /// kept ones not seen for a week. `day_start` is the local midnight in ms; whatever was
    /// looked at since then counts toward today's `count`. With `book`, only that book.
    pub fn review_today(&self, book: Option<String>, day_start: i64, count: u32) -> Result<ReviewDeck> {
        let store = lock(&self.store);
        let gone: Vec<String> = store
            .entities("book/")?
            .into_iter()
            .filter(|(_, f)| !live(f))
            .filter_map(|(e, _)| e.strip_prefix("book/").map(str::to_string))
            .collect();
        let prefix = match &book {
            Some(b) => format!("mark/{b}/"),
            None => "mark/".to_string(),
        };
        let now = now_ms();
        let mut done_today = 0u32;
        let mut due: Vec<(i64, ReviewItem)> = Vec::new();
        for (e, f) in store.entities(&prefix)? {
            if !live(&f) {
                continue;
            }
            let Some((b, id)) = e.strip_prefix("mark/").and_then(|r| r.split_once('/')) else { continue };
            if gone.iter().any(|g| g == b) {
                continue;
            }
            let reviewed = int(&f, "reviewedAt");
            if f.contains_key("reviewedAt") && reviewed >= day_start {
                done_today += 1;
                continue;
            }
            let wait = match f.get("review").and_then(Value::as_str) {
                Some("drop") => continue,
                Some(_) if now - reviewed < REVIEW_AGAIN_MS => continue,
                Some(_) => reviewed,
                None => 0,
            };
            let Some(mark) = mark_from(id, &f) else { continue };
            due.push((wait, ReviewItem { book: b.to_string(), mark }));
        }
        due.sort_by_key(|(wait, item)| (*wait, item.mark.at));
        let left = count.saturating_sub(done_today) as usize;
        Ok(ReviewDeck { items: due.into_iter().take(left).map(|(_, i)| i).collect(), done_today })
    }

    /// 留下 (`keep`) or 不要了 in 回顾. 不要了 only stops it coming back; the highlight stays.
    pub fn set_mark_review(&self, book: String, id: String, keep: bool) -> Result<()> {
        self.book_dir(&book)?;
        check_id(&id)?;
        lock(&self.store).set_fields(
            &format!("mark/{book}/{id}"),
            &[("review", json!(if keep { "keep" } else { "drop" })), ("reviewedAt", json!(now_ms()))],
        )
    }

    /// The book's bookmarks in reading order.
    pub fn bookmarks(&self, book: String) -> Result<Vec<Bookmark>> {
        self.book_dir(&book)?;
        let prefix = format!("bookmark/{book}/");
        let mut out: Vec<Bookmark> = lock(&self.store)
            .entities(&prefix)?
            .into_iter()
            .filter(|(_, f)| live(f))
            .filter_map(|(e, f)| {
                Some(Bookmark {
                    id: e.strip_prefix(&prefix)?.to_string(),
                    section: f.get("section")?.as_u64()? as u32,
                    sentence: f.get("sentence")?.as_u64()? as u32,
                    text: f.get("text").and_then(Value::as_str).unwrap_or_default().to_string(),
                    at: int(&f, "at"),
                })
            })
            .collect();
        out.sort_by_key(|a| (a.section, a.sentence, a.at));
        Ok(out)
    }

    /// Puts a bookmark on a sentence, with the sentence's opening words to show for it.
    pub fn add_bookmark(&self, book: String, section: u32, sentence: u32) -> Result<Bookmark> {
        let dir = self.book_dir(&book)?;
        // An audiobook has no sentences: the app shows its bookmarks by the time.
        let text: String = crate::book::sentences(&dir, section)
            .ok()
            .and_then(|all| all.get(sentence as usize).map(|s| s.trim().chars().take(60).collect()))
            .unwrap_or_default();
        let id = new_id();
        let at = now_ms();
        lock(&self.store).set_fields(
            &format!("bookmark/{book}/{id}"),
            &[("section", json!(section)), ("sentence", json!(sentence)), ("text", json!(text)), ("at", json!(at))],
        )?;
        Ok(Bookmark { id, section, sentence, text, at })
    }

    pub fn delete_bookmark(&self, book: String, id: String) -> Result<()> {
        self.set_deleted("bookmark", &book, &id, true)
    }

    pub fn restore_bookmark(&self, book: String, id: String) -> Result<()> {
        self.set_deleted("bookmark", &book, &id, false)
    }

    /// 书内搜索: every place `query` turns up, in reading order, ignoring case.
    pub fn search_book(&self, book: String, query: String) -> Result<Vec<SearchHit>> {
        let dir = self.book_dir(&book)?;
        let query: Vec<char> = query.trim().to_lowercase().chars().collect();
        if query.is_empty() {
            return Ok(Vec::new());
        }
        let rules = self.rules_for(&book, false)?;
        let detail = self.book(book)?;
        let mut out = Vec::new();
        for (i, section) in detail.sections.iter().enumerate() {
            if section.sentences == 0 {
                continue;
            }
            let Ok(mut sentences) = crate::book::sentences(&dir, i as u32) else { continue };
            if !rules.is_empty() {
                sentences = sentences.iter().map(|s| rules.apply(s)).collect();
            }
            for (s, text) in sentences.iter().enumerate() {
                let chars: Vec<char> = text.chars().collect();
                let lower: Vec<char> = chars.iter().map(|c| c.to_lowercase().next().unwrap_or(*c)).collect();
                let mut nth = 0;
                let mut k = 0;
                while k + query.len() <= lower.len() {
                    if lower[k..k + query.len()] == query[..] {
                        let from = k.saturating_sub(CONTEXT);
                        let to = (k + query.len() + CONTEXT).min(chars.len());
                        out.push(SearchHit {
                            section: i as u32,
                            sentence: s as u32,
                            nth,
                            before: format!(
                                "{}{}",
                                if from > 0 { "……" } else { "" },
                                chars[from..k].iter().collect::<String>().trim_start()
                            ),
                            matched: chars[k..k + query.len()].iter().collect(),
                            after: format!(
                                "{}{}",
                                chars[k + query.len()..to].iter().collect::<String>().trim_end(),
                                if to < chars.len() { "……" } else { "" }
                            ),
                        });
                        if out.len() >= MAX_HITS {
                            return Ok(out);
                        }
                        nth += 1;
                        k += query.len();
                    } else {
                        k += 1;
                    }
                }
            }
        }
        Ok(out)
    }

    /// Adds time spent in a section on this device: reading with the eyes, or listening. `day` is
    /// the app's local date, "2026-10-16", for 阅读统计.
    pub fn add_time(&self, book: String, section: u32, read_seconds: u32, listen_seconds: u32, day: String) -> Result<()> {
        self.book_dir(&book)?;
        if read_seconds == 0 && listen_seconds == 0 {
            return Ok(());
        }
        if !is_day(&day) {
            return Err(CoreError::Invalid { detail: format!("not a day: {day}") });
        }
        let mut store = lock(&self.store);
        let device = store.device().to_string();
        let add = |store: &crate::store::Store, entity: &str, field: &str| -> Result<Value> {
            let old = store.get(entity, field)?;
            let get = |k: &str| old.as_ref().and_then(|v| v.get(k)).and_then(Value::as_u64).unwrap_or(0);
            Ok(json!({ "read": get("read") + read_seconds as u64, "listen": get("listen") + listen_seconds as u64 }))
        };
        let entity = format!("time/{book}/{device}");
        let field = format!("s{section}");
        let value = add(&store, &entity, &field)?;
        store.set(&entity, &field, value)?;
        let entity = format!("days/{day}/{device}");
        let value = add(&store, &entity, &book)?;
        store.set(&entity, &book, value)
    }

    /// Time spent on each book on each day from `from` to `to` ("2026-10-01", both included),
    /// over every device; days with nothing are left out.
    pub fn day_times(&self, from: String, to: String) -> Result<Vec<DayTime>> {
        let mut sums: BTreeMap<(String, String), (u64, u64)> = BTreeMap::new();
        for (entity, fields) in lock(&self.store).entities("days/")? {
            let Some(day) = entity.strip_prefix("days/").and_then(|r| r.split('/').next()) else { continue };
            if day < from.as_str() || day > to.as_str() {
                continue;
            }
            for (book, v) in fields {
                let e = sums.entry((day.to_string(), book)).or_default();
                e.0 += v.get("read").and_then(Value::as_u64).unwrap_or(0);
                e.1 += v.get("listen").and_then(Value::as_u64).unwrap_or(0);
            }
        }
        let clamp = |n: u64| n.min(u32::MAX as u64) as u32;
        Ok(sums
            .into_iter()
            .map(|((day, book), (r, l))| DayTime { day, book, read_seconds: clamp(r), listen_seconds: clamp(l) })
            .collect())
    }

    /// Time spent in each section, over every device; sections never opened are left out.
    pub fn section_times(&self, book: String) -> Result<Vec<SectionTime>> {
        self.book_dir(&book)?;
        let mut sums: BTreeMap<u32, (u64, u64)> = BTreeMap::new();
        for (_, fields) in lock(&self.store).entities(&format!("time/{book}/"))? {
            for (k, v) in fields {
                let Some(section) = k.strip_prefix('s').and_then(|n| n.parse::<u32>().ok()) else { continue };
                let e = sums.entry(section).or_default();
                e.0 += v.get("read").and_then(Value::as_u64).unwrap_or(0);
                e.1 += v.get("listen").and_then(Value::as_u64).unwrap_or(0);
            }
        }
        Ok(sums
            .into_iter()
            .map(|(section, (r, l))| SectionTime { section, read_seconds: r.min(u32::MAX as u64) as u32, listen_seconds: l.min(u32::MAX as u64) as u32 })
            .collect())
    }
}

/// "2026-10-16".
fn is_day(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() == 10 && b[4] == b'-' && b[7] == b'-' && b.iter().enumerate().all(|(i, c)| i == 4 || i == 7 || c.is_ascii_digit())
}

impl YuyueCore {
    #[allow(clippy::too_many_arguments)]
    fn insert_mark(
        &self,
        book: String,
        section: u32,
        start: TextPoint,
        end: TextPoint,
        text: String,
        style: MarkStyle,
        note: Option<String>,
        heard: bool,
    ) -> Result<Mark> {
        self.book_dir(&book)?;
        let (start, end) = if end < start { (end, start) } else { (start, end) };
        if start == end || text.trim().is_empty() {
            return Err(CoreError::Invalid { detail: crate::i18n::tr("没有选中文字", "Nothing is selected") });
        }
        let id = new_id();
        let note = clean_note(note);
        let at = now_ms();
        let mut fields = vec![
            ("section", json!(section)),
            ("start", json!({ "s": start.sentence, "o": start.offset })),
            ("end", json!({ "s": end.sentence, "o": end.offset })),
            ("text", json!(text)),
            ("style", json!(style.name())),
            ("note", note.as_ref().map_or(Value::Null, |n| json!(n))),
            ("at", json!(at)),
        ];
        if heard {
            fields.push(("heard", json!(true)));
        }
        lock(&self.store).set_fields(&format!("mark/{book}/{id}"), &fields)?;
        Ok(Mark { id, section, start, end, text, style, note, at, heard })
    }

    fn set_deleted(&self, kind: &str, book: &str, id: &str, deleted: bool) -> Result<()> {
        self.book_dir(book)?;
        check_id(id)?;
        lock(&self.store).set(&format!("{kind}/{book}/{id}"), "deleted", json!(deleted))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> String {
        format!("{}/../../fixtures/books/{name}", env!("CARGO_MANIFEST_DIR"))
    }

    fn temp(name: &str) -> String {
        let dir = std::env::temp_dir().join(format!("yuyue-notes-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir.to_string_lossy().into_owned()
    }

    #[test]
    fn marks_bookmarks_search_and_time() {
        let dir = temp("one");
        let core = YuyueCore::open(dir.clone(), "Mac".into(), "macos".into()).unwrap();
        let b = core.import_book(fixture("beiying.txt")).unwrap();
        let p = |s, o| TextPoint { sentence: s, offset: o };

        let late = core.add_mark(b.id.clone(), 0, p(5, 0), p(5, 4), "我买几个".into(), MarkStyle::Yellow, None).unwrap();
        let early = core.add_mark(b.id.clone(), 0, p(2, 6), p(1, 3), "父亲".into(), MarkStyle::Wave, Some("  ".into())).unwrap();
        assert_eq!((early.start, early.end, early.note.as_deref()), (p(1, 3), p(2, 6), None));
        assert!(core.add_mark(b.id.clone(), 0, p(1, 1), p(1, 1), "".into(), MarkStyle::Blue, None).is_err());
        core.set_mark_note(b.id.clone(), late.id.clone(), Some(" 难忘 ".into())).unwrap();
        core.set_mark_style(b.id.clone(), late.id.clone(), MarkStyle::Pink).unwrap();
        let marks = core.marks(b.id.clone()).unwrap();
        assert_eq!(marks.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(), [early.id.as_str(), late.id.as_str()]);
        assert_eq!((marks[1].style, marks[1].note.as_deref()), (MarkStyle::Pink, Some("难忘")));
        // 双击耳机: a sentence already marked stays as it is; another is marked as heard.
        assert_eq!(core.mark_heard(b.id.clone(), 0, p(5, 0), p(5, 4), "我买几个".into(), MarkStyle::Yellow).unwrap().id, late.id);
        let heard = core.mark_heard(b.id.clone(), 0, p(7, 0), p(7, 5), "看见他的背影".into(), MarkStyle::Yellow).unwrap();
        assert!(heard.heard && !marks[0].heard);
        assert!(core.marks(b.id.clone()).unwrap().iter().any(|m| m.id == heard.id && m.heard));
        core.delete_mark(b.id.clone(), heard.id).unwrap();
        core.delete_mark(b.id.clone(), early.id.clone()).unwrap();
        assert_eq!(core.marks(b.id.clone()).unwrap().len(), 1);
        core.restore_mark(b.id.clone(), early.id.clone()).unwrap();
        assert_eq!(core.marks(b.id.clone()).unwrap().len(), 2);

        let deck = core.review_today(None, 0, 5).unwrap();
        assert_eq!((deck.items.len(), deck.done_today), (2, 0));
        core.set_mark_review(b.id.clone(), deck.items[0].mark.id.clone(), false).unwrap();
        let deck = core.review_today(Some(b.id.clone()), 0, 5).unwrap();
        assert_eq!((deck.items.len(), deck.done_today), (1, 1));
        core.set_mark_review(b.id.clone(), deck.items[0].mark.id.clone(), true).unwrap();
        // Tomorrow: the dropped one stays away, the kept one waits a week.
        assert!(core.review_today(None, now_ms() + 1, 5).unwrap().items.is_empty());
        assert_eq!(core.marks(b.id.clone()).unwrap().len(), 2);

        let mark = core.add_bookmark(b.id.clone(), 0, 0).unwrap();
        assert!(!mark.text.is_empty());
        assert_eq!(core.bookmarks(b.id.clone()).unwrap().len(), 1);
        core.delete_bookmark(b.id.clone(), mark.id).unwrap();
        assert!(core.bookmarks(b.id.clone()).unwrap().is_empty());

        let hits = core.search_book(b.id.clone(), "父亲".into()).unwrap();
        assert!(hits.len() > 3);
        assert!(hits.iter().all(|h| h.matched == "父亲"));
        assert!(core.search_book(b.id.clone(), " ".into()).unwrap().is_empty());

        core.add_time(b.id.clone(), 0, 60, 0, "2026-10-15".into()).unwrap();
        core.add_time(b.id.clone(), 0, 30, 90, "2026-10-16".into()).unwrap();
        assert_eq!(core.section_times(b.id.clone()).unwrap(), [SectionTime { section: 0, read_seconds: 90, listen_seconds: 90 }]);
        assert!(core.add_time(b.id.clone(), 0, 1, 0, "16 Oct".into()).is_err());
        let days = core.day_times("2026-10-16".into(), "2026-10-31".into()).unwrap();
        assert_eq!(days, [DayTime { day: "2026-10-16".into(), book: b.id.clone(), read_seconds: 30, listen_seconds: 90 }]);
        assert_eq!(core.day_times("2026-10-01".into(), "2026-10-31".into()).unwrap().len(), 2);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
