//! 难词注释 (FEATURES §3.5): a short Chinese meaning written above the harder words of a book
//! in English. Which words are hard comes from ECDICT's exam lists (四级, 六级, 考研, 雅思,
//! GRE) and, for words no exam lists, how rarely they turn up; the list is trimmed from ECDICT
//! (MIT) by `scripts/ecdict-trim.py` into `data/hardwords.tsv`.

use std::collections::{HashMap, HashSet};
use std::sync::LazyLock;

use crate::api::YuyueCore;
use crate::error::Result;
use crate::words::{forms, latin_words};

/// One word to write a meaning above, as it is spelt in the text ("acknowledged").
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct Gloss {
    pub form: String,
    pub gloss: String,
}

struct Entry {
    level: u8,
    gloss: &'static str,
}

/// Every word and its inflected forms, to the word's level and meaning.
static LIST: LazyLock<HashMap<&'static str, Entry>> = LazyLock::new(|| {
    let mut map = HashMap::new();
    for line in include_str!("../data/hardwords.tsv").lines() {
        if line.starts_with('#') {
            continue;
        }
        let mut cols = line.split('\t');
        let (Some(word), Some(level), Some(gloss)) = (cols.next(), cols.next(), cols.next()) else { continue };
        let level = level.parse().unwrap_or(6);
        map.insert(word, Entry { level, gloss });
        for form in cols.next().unwrap_or("").split(',').filter(|f| !f.is_empty()) {
            map.entry(form).or_insert(Entry { level, gloss });
        }
    }
    map
});

#[uniffi::export]
impl YuyueCore {
    /// The harder words in one section, each spelling once: those at `level` (2 四级, 3 六级,
    /// 4 考研, 5 雅思, 6 GRE) or harder; or, with `vocab_only`, just the 生词本's words still
    /// being learned, with the meaning they were kept with when the list has none.
    pub fn glosses(&self, book_id: String, section: u32, level: u8, vocab_only: bool) -> Result<Vec<Gloss>> {
        let dir = self.book_dir(&book_id)?;
        let Ok(sentences) = crate::book::sentences(&dir, section) else { return Ok(Vec::new()) };
        let mut learning: HashMap<String, String> = HashMap::new();
        if vocab_only {
            for w in self.words()?.into_iter().filter(|w| !w.known) {
                let kept = w.meaning.as_deref().map(short).unwrap_or_default();
                for f in forms(&w.word) {
                    learning.insert(f, kept.clone());
                }
            }
        }
        let mut seen = HashSet::new();
        let mut out = Vec::new();
        for text in &sentences {
            for w in latin_words(text) {
                if !seen.insert(w.clone()) {
                    continue;
                }
                let listed = LIST.get(w.as_str());
                let gloss = if vocab_only {
                    learning.get(&w).map(|kept| listed.map(|e| e.gloss.to_string()).unwrap_or_else(|| kept.clone()))
                } else {
                    listed.filter(|e| e.level >= level).map(|e| e.gloss.to_string())
                };
                if let Some(gloss) = gloss.filter(|g| !g.is_empty()) {
                    out.push(Gloss { form: w, gloss });
                }
            }
        }
        Ok(out)
    }
}

/// "n. 财富，大笔的钱；运气" → "财富".
fn short(meaning: &str) -> String {
    let rest = meaning.trim_start_matches(|c: char| c.is_ascii_alphabetic() || c == '.' || c == ' ');
    rest.split(['，', '；', ',', ';', '、']).next().unwrap_or("").trim().chars().take(6).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn glosses_the_harder_words() {
        assert_eq!(LIST.get("ascertained").map(|e| (e.level, e.gloss)), Some((3, "确定")));
        assert_eq!(short("n. 财富，大笔的钱；运气"), "财富");

        let dir = std::env::temp_dir().join(format!("yuyue-hard-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let core = YuyueCore::open(dir.to_string_lossy().into_owned(), "Mac".into(), "macos".into()).unwrap();
        let b = core
            .import_book(format!("{}/../../fixtures/books/pride-and-prejudice.epub", env!("CARGO_MANIFEST_DIR")))
            .unwrap();
        let sections = core.book(b.id.clone()).unwrap().sections.len() as u32;
        let all = |level, only| -> Vec<Gloss> {
            (0..sections).flat_map(|s| core.glosses(b.id.clone(), s, level, only).unwrap()).collect()
        };
        let six = all(3, false);
        assert!(six.iter().any(|g| g.form == "universally"), "{six:?}");
        // A higher level marks fewer words; nothing in the 生词本 yet, nothing to mark there.
        assert!(all(6, false).len() < six.len());
        assert!(all(2, false).len() > six.len());
        assert!(all(3, true).is_empty());
        assert!(all(2, false).iter().any(|g| g.form == "neighbourhood"));
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
