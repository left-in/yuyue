//! 生词本: words looked up in books in other languages and kept to learn.
//!
//! Registers: `word/<key>` · `word` / `phonetic` / `meaning` / `book` / `section` /
//! `sentence` / `context` / `at` / `known` / `deleted`, where `<key>` is the word in lower
//! case. A word is one entry however many books it turns up in; the book and sentence are
//! where it was first kept. 掌握了 (`known`) keeps the entry but stops marking it in books.

use std::collections::{BTreeMap, HashMap};

use serde_json::{Value, json};

use crate::api::{YuyueCore, lock, now_ms};
use crate::error::{CoreError, Result};

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct VocabWord {
    /// As it was kept, e.g. "fortune".
    pub word: String,
    /// "/ˈfɔːtʃuːn/", when the dictionary gave one.
    pub phonetic: Option<String>,
    /// The short meaning, e.g. "n. 财富，大笔的钱；运气".
    pub meaning: Option<String>,
    pub book: String,
    pub section: u32,
    pub sentence: u32,
    /// The sentence it was met in.
    pub context: String,
    pub at: i64,
    /// 掌握了.
    pub known: bool,
}

/// Where a word turns up in the library.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct WordCount {
    pub word: String,
    pub books: u32,
    pub times: u32,
}

#[uniffi::export]
impl YuyueCore {
    /// The 生词本, the most recently kept first; 掌握了 ones too.
    pub fn words(&self) -> Result<Vec<VocabWord>> {
        let mut out: Vec<VocabWord> = lock(&self.store)
            .entities("word/")?
            .into_iter()
            .filter(|(_, f)| f.get("deleted") != Some(&json!(true)))
            .filter_map(|(_, f)| word_from(&f))
            .collect();
        out.sort_by_key(|w| std::cmp::Reverse(w.at));
        Ok(out)
    }

    /// Keeps a word, met in `context` at `section`/`sentence` of `book`. Keeping it again
    /// brings it back if it was removed or 掌握了, and leaves where it was first met.
    #[allow(clippy::too_many_arguments)]
    pub fn add_word(
        &self,
        word: String,
        phonetic: Option<String>,
        meaning: Option<String>,
        book: String,
        section: u32,
        sentence: u32,
        context: String,
    ) -> Result<VocabWord> {
        self.book_dir(&book)?;
        let word = word.trim().to_string();
        let key = key_of(&word)?;
        let entity = format!("word/{key}");
        let mut store = lock(&self.store);
        let old = store.fields(&entity)?;
        let fresh = old.is_empty() || old.get("deleted") == Some(&json!(true));
        let clean = |v: Option<String>| v.map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).map_or(Value::Null, |s| json!(s));
        if fresh {
            store.set_fields(
                &entity,
                &[
                    ("word", json!(word)),
                    ("phonetic", clean(phonetic)),
                    ("meaning", clean(meaning)),
                    ("book", json!(book)),
                    ("section", json!(section)),
                    ("sentence", json!(sentence)),
                    ("context", json!(context.trim())),
                    ("at", json!(now_ms())),
                    ("known", json!(false)),
                    ("deleted", json!(false)),
                ],
            )?;
        } else {
            store.set(&entity, "known", json!(false))?;
        }
        let f = store.fields(&entity)?;
        word_from(&f).ok_or_else(|| CoreError::not_found("word"))
    }

    /// 掌握了: kept in the list, no longer marked in books.
    pub fn set_word_known(&self, word: String, known: bool) -> Result<()> {
        let key = key_of(&word)?;
        lock(&self.store).set(&format!("word/{key}"), "known", json!(known))
    }

    pub fn delete_word(&self, word: String) -> Result<()> {
        let key = key_of(&word)?;
        lock(&self.store).set(&format!("word/{key}"), "deleted", json!(true))
    }

    pub fn restore_word(&self, word: String) -> Result<()> {
        let key = key_of(&word)?;
        lock(&self.store).set(&format!("word/{key}"), "deleted", json!(false))
    }

    /// How often each of `words` turns up across the books on this device, counting the
    /// usual inflections ("fortunes", "fixed").
    pub fn word_counts(&self, words: Vec<String>) -> Result<Vec<WordCount>> {
        let mut form_of: HashMap<String, usize> = HashMap::new();
        for (i, w) in words.iter().enumerate() {
            for f in forms(&w.to_lowercase()) {
                form_of.entry(f).or_insert(i);
            }
        }
        let mut counts = vec![(0u32, 0u32); words.len()];
        for book in self.books()? {
            if !book.available {
                continue;
            }
            let here = self.count_in(&book.id, &form_of, words.len())?;
            for (i, n) in here.into_iter().enumerate() {
                if n > 0 {
                    counts[i].0 += 1;
                    counts[i].1 += n;
                }
            }
        }
        Ok(words.into_iter().zip(counts).map(|(word, (books, times))| WordCount { word, books, times }).collect())
    }

    /// How often `word` turns up in one book: 本书出现 12 次.
    pub fn book_word_count(&self, book: String, word: String) -> Result<u32> {
        let form_of: HashMap<String, usize> = forms(&word.to_lowercase()).into_iter().map(|f| (f, 0)).collect();
        Ok(self.count_in(&book, &form_of, 1)?[0])
    }
}

impl YuyueCore {
    fn count_in(&self, book: &str, form_of: &HashMap<String, usize>, n: usize) -> Result<Vec<u32>> {
        let dir = self.book_dir(book)?;
        let detail = self.book(book.to_string())?;
        let mut out = vec![0u32; n];
        for (i, section) in detail.sections.iter().enumerate() {
            if section.sentences == 0 {
                continue;
            }
            let Ok(sentences) = crate::book::sentences(&dir, i as u32) else { continue };
            for text in &sentences {
                for w in latin_words(text) {
                    if let Some(&k) = form_of.get(&w) {
                        out[k] += 1;
                    }
                }
            }
        }
        Ok(out)
    }
}

fn key_of(word: &str) -> Result<String> {
    let key = word.trim().to_lowercase();
    if key.is_empty() || key.chars().count() > 64 || key.contains('/') || key.split_whitespace().count() > 4 {
        return Err(CoreError::Invalid { detail: crate::i18n::tr("这不像一个词", "That doesn't look like a word") });
    }
    Ok(key)
}

fn word_from(f: &BTreeMap<String, Value>) -> Option<VocabWord> {
    let s = |k: &str| f.get(k).and_then(Value::as_str).map(str::to_string);
    Some(VocabWord {
        word: s("word")?,
        phonetic: s("phonetic"),
        meaning: s("meaning"),
        book: s("book").unwrap_or_default(),
        section: f.get("section").and_then(Value::as_u64).unwrap_or(0) as u32,
        sentence: f.get("sentence").and_then(Value::as_u64).unwrap_or(0) as u32,
        context: s("context").unwrap_or_default(),
        at: f.get("at").and_then(Value::as_i64).unwrap_or(0),
        known: f.get("known") == Some(&json!(true)),
    })
}

/// The words of a sentence in letters other than CJK, lower-cased; an apostrophe or hyphen
/// between letters stays inside the word.
pub(crate) fn latin_words(text: &str) -> Vec<String> {
    let chars: Vec<char> = text.chars().collect();
    let letter = |c: char| c.is_alphabetic() && !is_cjk(c);
    let mut out = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        if !letter(chars[i]) {
            i += 1;
            continue;
        }
        let start = i;
        while i < chars.len()
            && (letter(chars[i]) || (matches!(chars[i], '\'' | '’' | '-') && i + 1 < chars.len() && letter(chars[i + 1]) && i > start))
        {
            i += 1;
        }
        out.push(chars[start..i].iter().collect::<String>().to_lowercase().replace('’', "'"));
    }
    out
}

fn is_cjk(c: char) -> bool {
    matches!(c as u32, 0x3040..=0x30FF | 0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xF900..=0xFAFF | 0xAC00..=0xD7AF | 0x20000..=0x2FA1F)
}

/// A word and its usual English inflections: fortune → fortunes, fortuned…; fix → fixes,
/// fixed, fixing; carry → carries, carried; love → loving.
pub(crate) fn forms(word: &str) -> Vec<String> {
    let w = word.trim().to_lowercase();
    let mut out = vec![w.clone()];
    if w.chars().count() < 3 || !w.chars().all(|c| c.is_ascii_alphabetic()) {
        return out;
    }
    let push = |out: &mut Vec<String>, s: String| {
        if !out.contains(&s) {
            out.push(s);
        }
    };
    push(&mut out, format!("{w}s"));
    push(&mut out, format!("{w}es"));
    push(&mut out, format!("{w}ed"));
    push(&mut out, format!("{w}ing"));
    push(&mut out, format!("{w}'s"));
    if let Some(stem) = w.strip_suffix('e') {
        push(&mut out, format!("{w}d"));
        push(&mut out, format!("{stem}ing"));
    }
    if let Some(stem) = w.strip_suffix('y') {
        push(&mut out, format!("{stem}ies"));
        push(&mut out, format!("{stem}ied"));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn words_keep_count_and_forget() {
        let dir = std::env::temp_dir().join(format!("yuyue-words-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let core = YuyueCore::open(dir.to_string_lossy().into_owned(), "Mac".into(), "macos".into()).unwrap();
        let b = core
            .import_book(format!("{}/../../fixtures/books/pride-and-prejudice.epub", env!("CARGO_MANIFEST_DIR")))
            .unwrap();

        let w = core
            .add_word("Fortune".into(), Some("/ˈfɔːtʃuːn/".into()), Some("n. 财富".into()), b.id.clone(), 1, 0, " a good fortune ".into())
            .unwrap();
        assert_eq!((w.word.as_str(), w.context.as_str(), w.known), ("Fortune", "a good fortune", false));
        assert!(core.add_word("a/b".into(), None, None, b.id.clone(), 0, 0, "".into()).is_err());
        core.add_word("neighbourhood".into(), None, Some("  ".into()), b.id.clone(), 1, 1, "".into()).unwrap();
        let list = core.words().unwrap();
        assert_eq!(list.len(), 2);
        assert_eq!(list.iter().find(|w| w.word == "neighbourhood").unwrap().meaning, None);

        core.set_word_known("fortune".into(), true).unwrap();
        assert!(core.words().unwrap().iter().any(|w| w.word == "Fortune" && w.known));
        // Kept again: back to learning, first meeting left as it was.
        let again = core.add_word("fortune".into(), None, None, b.id.clone(), 9, 9, "other".into()).unwrap();
        assert_eq!((again.known, again.section, again.phonetic.as_deref()), (false, 1, Some("/ˈfɔːtʃuːn/")));

        let counts = core.word_counts(vec!["fortune".into(), "zzzz".into()]).unwrap();
        assert_eq!(counts[0].books, 1);
        assert!(counts[0].times >= core.book_word_count(b.id.clone(), "fortune".into()).unwrap());
        assert!(counts[0].times > 5);
        assert_eq!((counts[1].books, counts[1].times), (0, 0));

        core.delete_word("FORTUNE".into()).unwrap();
        assert_eq!(core.words().unwrap().len(), 1);
        core.restore_word("fortune".into()).unwrap();
        assert_eq!(core.words().unwrap().len(), 2);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn splitting_and_forms() {
        assert_eq!(latin_words("“Don’t you know—it's well-known?” 他说 naïve"), ["don't", "you", "know", "it's", "well-known", "naïve"]);
        assert!(forms("carry").contains(&"carried".to_string()));
        assert!(forms("love").contains(&"loving".to_string()));
        assert_eq!(forms("a"), ["a"]);
    }
}
