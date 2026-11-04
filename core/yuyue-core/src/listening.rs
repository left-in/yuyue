//! 听读书 that sync (听书开发方案 §4.3): where each sentence of an e-book is in a recording of it,
//! and which recording goes with which e-book, kept in the store so one device lays a book out
//! and the others use it — no model to download, nothing to run again.
//!
//! The recordings themselves don't go through the log: each device brings in its own copy, and
//! the 有声书's id (from its files' sizes and ends, `audio::audio_id`) says it's the same one. So
//! everything here is keyed by that id: `listen/<recording>`.
//!
//! Fields: `book` (the e-book), `intro`, `through`, `introSkipped`, `made` (ms), `took`
//! (seconds), `fits` (how each chapter came out) and one `s<section>` per chapter: its sentences
//! as `[sentence, start ms, end ms, heard ‰, moved by hand 0/1]`. A chapter to a register keeps
//! each write small and lets a 微调 on one chapter and a lay-out on another meet without loss.
//! Only what changed is written, so laying a book out again, file by file, doesn't fill the log.

use serde_json::{Value, json};

use crate::align::SectionFit;
use crate::api::{YuyueCore, lock};
use crate::error::Result;

/// A sentence's place in the recording, as kept and synced.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct ListenSentence {
    pub section: u32,
    pub sentence: u32,
    /// Seconds from the start of the whole recording; negative when it isn't there.
    pub start: f64,
    pub end: f64,
    pub heard: f32,
    /// Moved by hand (微调): laying the book out again leaves it where it is.
    pub adjusted: bool,
}

/// A recording laid against an e-book.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct Listening {
    /// The 有声书 (its shelf id) and the e-book it's laid against.
    pub recording: String,
    pub book: String,
    pub sentences: Vec<ListenSentence>,
    pub sections: Vec<SectionFit>,
    pub intro: f64,
    /// Up to where the recording has been laid out, in seconds; the whole of it once made.
    pub through: f64,
    pub intro_skipped: bool,
    /// When it was finished (ms since 1970), and how long that took; None while it's being made.
    pub made_ms: Option<i64>,
    pub took: Option<f64>,
}

fn entity(recording: &str) -> String {
    format!("listen/{recording}")
}

fn ms(s: f64) -> i64 {
    if s < 0.0 { -1 } else { (s * 1000.0).round() as i64 }
}

fn chapter(sentences: &[&ListenSentence]) -> Value {
    Value::Array(sentences.iter().map(|s| json!([s.sentence, ms(s.start), ms(s.end), (s.heard.clamp(0.0, 1.0) * 1000.0).round() as i64, s.adjusted as u8])).collect())
}

fn fits(sections: &[SectionFit]) -> Value {
    Value::Array(sections.iter().map(|f| json!([f.section, f.sentences, (f.heard.clamp(0.0, 1.0) * 1000.0).round() as i64, f.missing, f.unsure])).collect())
}

fn from_fields(recording: &str, f: &std::collections::BTreeMap<String, Value>) -> Option<Listening> {
    let book = f.get("book")?.as_str()?.to_string();
    let num = |k: &str| f.get(k).and_then(Value::as_f64);
    let mut sentences = Vec::new();
    for (k, v) in f {
        let Some(section) = k.strip_prefix('s').and_then(|n| n.parse::<u32>().ok()) else { continue };
        for row in v.as_array().into_iter().flatten() {
            let r = row.as_array()?;
            let n = |i: usize| r.get(i).and_then(Value::as_i64).unwrap_or(0);
            let secs = |x: i64| if x < 0 { -1.0 } else { x as f64 / 1000.0 };
            sentences.push(ListenSentence { section, sentence: n(0) as u32, start: secs(n(1)), end: secs(n(2)), heard: n(3) as f32 / 1000.0, adjusted: n(4) != 0 });
        }
    }
    sentences.sort_by_key(|s| (s.section, s.sentence));
    let sections = f
        .get("fits")
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|r| {
                    let r = r.as_array()?;
                    let n = |i: usize| r.get(i).and_then(Value::as_i64).unwrap_or(0);
                    Some(SectionFit { section: n(0) as u32, sentences: n(1) as u32, heard: n(2) as f32 / 1000.0, missing: n(3) as u32, unsure: n(4) as u32 })
                })
                .collect()
        })
        .unwrap_or_default();
    Some(Listening {
        recording: recording.to_string(),
        book,
        sentences,
        sections,
        intro: num("intro").unwrap_or(0.0),
        through: num("through").unwrap_or(0.0),
        intro_skipped: f.get("introSkipped").and_then(Value::as_bool).unwrap_or(false),
        made_ms: f.get("made").and_then(Value::as_i64),
        took: num("took"),
    })
}

/// What to write for `l`, leaving out what the store already holds.
fn writes(l: &Listening, have: &std::collections::BTreeMap<String, Value>) -> Vec<(String, Value)> {
    let mut want: Vec<(String, Value)> = vec![
        ("book".into(), json!(l.book)),
        ("intro".into(), json!((l.intro * 1000.0).round() / 1000.0)),
        ("through".into(), json!((l.through * 1000.0).round() / 1000.0)),
        ("introSkipped".into(), json!(l.intro_skipped)),
        ("made".into(), l.made_ms.map_or(Value::Null, |m| json!(m))),
        ("took".into(), l.took.map_or(Value::Null, |t| json!((t * 10.0).round() / 10.0))),
        ("fits".into(), fits(&l.sections)),
    ];
    let mut by_section: std::collections::BTreeMap<u32, Vec<&ListenSentence>> = std::collections::BTreeMap::new();
    for s in &l.sentences {
        by_section.entry(s.section).or_default().push(s);
    }
    for (section, list) in &by_section {
        want.push((format!("s{section}"), chapter(list)));
    }
    // Chapters no longer there (laid against another e-book) are emptied.
    for k in have.keys() {
        if k.strip_prefix('s').and_then(|n| n.parse::<u32>().ok()).is_some_and(|n| !by_section.contains_key(&n)) && !have[k].is_null() {
            want.push((k.clone(), Value::Null));
        }
    }
    want.retain(|(k, v)| have.get(k) != Some(v) && !(v.is_null() && !have.contains_key(k)));
    want
}

#[uniffi::export]
impl YuyueCore {
    /// Keeps where each sentence is in `listening.recording` (laid out, or 微调), so other
    /// devices get it. Writes only what changed.
    pub fn save_listening(&self, listening: Listening) -> Result<()> {
        let e = entity(&listening.recording);
        let mut store = lock(&self.store);
        let have = store.fields(&e)?;
        let w = writes(&listening, &have);
        if w.is_empty() {
            return Ok(());
        }
        let list: Vec<(&str, &str, Value)> = w.iter().map(|(k, v)| (e.as_str(), k.as_str(), v.clone())).collect();
        store.set_many(&list)
    }

    /// The recording's lay-out, when this device or another has made one.
    pub fn listening(&self, recording: String) -> Result<Option<Listening>> {
        let f = lock(&self.store).fields(&entity(&recording))?;
        Ok(from_fields(&recording, &f))
    }

    /// Every recording laid against an e-book, as (recording, e-book), without the sentences:
    /// for finding the ones another device made.
    pub fn listening_pairs(&self) -> Result<Vec<ListenPair>> {
        let all = lock(&self.store).entities("listen/")?;
        Ok(all
            .iter()
            .filter_map(|(e, f)| {
                let recording = e.strip_prefix("listen/")?.to_string();
                let book = f.get("book")?.as_str()?.to_string();
                Some(ListenPair { recording, book, made: f.get("made").is_some_and(|m| !m.is_null()) })
            })
            .collect())
    }

    /// The recording laid against nothing any more (removed, or laid against another e-book is
    /// saved instead), on every device.
    pub fn forget_listening(&self, recording: String) -> Result<()> {
        let e = entity(&recording);
        let mut store = lock(&self.store);
        let have = store.fields(&e)?;
        let list: Vec<(&str, &str, Value)> = have.iter().filter(|(_, v)| !v.is_null()).map(|(k, _)| (e.as_str(), k.as_str(), Value::Null)).collect();
        if list.is_empty() {
            return Ok(());
        }
        store.set_many(&list)
    }
}

/// A recording and the e-book it's laid against.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct ListenPair {
    pub recording: String,
    pub book: String,
    /// Finished, not still being laid out.
    pub made: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn core(name: &str) -> std::sync::Arc<YuyueCore> {
        let dir = std::env::temp_dir().join(format!("yuyue-listen-{name}-{}", getrandom::u64().unwrap()));
        YuyueCore::open(dir.to_string_lossy().into_owned(), name.into(), name.into()).unwrap()
    }

    fn sample() -> Listening {
        let s = |section, sentence, start: f64, end: f64| ListenSentence { section, sentence, start, end, heard: 0.9, adjusted: false };
        Listening {
            recording: "rec1".into(),
            book: "book1".into(),
            sentences: vec![s(1, 0, 3.2, 5.0), s(1, 1, 5.0, 9.125), s(1, 2, -1.0, -1.0), s(2, 0, 9.125, 12.0)],
            sections: vec![SectionFit { section: 1, sentences: 3, heard: 0.6, missing: 1, unsure: 0 }, SectionFit { section: 2, sentences: 1, heard: 0.9, missing: 0, unsure: 0 }],
            intro: 3.2,
            through: 12.0,
            intro_skipped: false,
            made_ms: Some(1_762_000_000_000),
            took: Some(41.5),
        }
    }

    #[test]
    fn made_on_one_device_used_on_another() {
        let a = core("a");
        let b = core("b");
        let l = sample();
        a.save_listening(l.clone()).unwrap();
        assert_eq!(a.listening("rec1".into()).unwrap(), Some(l.clone()));
        let batch = a.export_changes(b.sync_version().unwrap()).unwrap();
        b.import_changes(batch).unwrap();
        assert_eq!(b.listening("rec1".into()).unwrap(), Some(l.clone()));
        assert_eq!(b.listening_pairs().unwrap(), vec![ListenPair { recording: "rec1".into(), book: "book1".into(), made: true }]);

        // 微调 on b: one chapter changes, and only that chapter is written.
        let mut moved = l.clone();
        moved.sentences[3].start = 9.5;
        moved.sentences[3].adjusted = true;
        let before = b.sync_version().unwrap();
        b.save_listening(moved.clone()).unwrap();
        let back = b.export_changes(before).unwrap();
        assert_eq!(back.matches("\"field\"").count(), 1, "{back}");
        a.import_changes(b.export_changes(a.sync_version().unwrap()).unwrap()).unwrap();
        assert_eq!(a.listening("rec1".into()).unwrap(), Some(moved));

        // Saving the same again writes nothing.
        let v = a.sync_version().unwrap();
        a.save_listening(a.listening("rec1".into()).unwrap().unwrap()).unwrap();
        assert_eq!(a.sync_version().unwrap(), v);

        a.forget_listening("rec1".into()).unwrap();
        assert_eq!(a.listening("rec1".into()).unwrap(), None);
        assert!(a.listening_pairs().unwrap().is_empty());
    }
}
