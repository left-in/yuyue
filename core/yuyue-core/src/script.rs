//! 剧本: who says each line of a book (听书开发方案 §3.2, step 3). The bubbles need only this;
//! the voices of 分角色朗读 come later and read the same script.
//!
//! Rules first, and only where they're sure: a line gets a name when the words around it say
//! it (“宝玉道”), or when the one who speaks is plain from the clauses before it (主语承前省略);
//! a crowd or someone unnamed (“众人笑道”“外面人说”) is kept as they're called. Anything else is
//! left without a name — a grey bubble — for the decision model to choose among those present,
//! later. A wrong name is worse than none, so a rule that isn't sure gives up.
//!
//! The cast is read from the whole book: the few characters that come before a speech verb
//! often enough are names.

use std::collections::HashMap;

use regex::Regex;

use crate::api::{YuyueCore, lock};
use crate::error::Result;
use serde::{Deserialize, Serialize};

/// Who says a line, and how the rules know.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct Line {
    /// The sentence the quote starts in, and the one it ends in.
    pub first: u32,
    pub last: u32,
    /// Where in the first sentence the quote's text starts and ends (characters, quotes left out).
    pub start: u32,
    pub end: u32,
    /// None: the rules aren't sure (a grey bubble).
    pub who: Option<String>,
    pub how: How,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum How {
    /// The speech words name them: 宝玉道.
    Named,
    /// No name before the speech words; the one doing things just before is the one speaking.
    Before,
    /// A crowd, two of them, or someone unnamed: 众人, 二人, 外面人.
    Group,
    /// The rules don't know.
    Unsure,
}

/// The words that say someone speaks, longest first so 笑道 wins over 道.
const VERBS: &[&str] = &[
    "咕噥說", "咕哝说", "囑咐他道", "嘱咐他道", "笑說道", "笑说道", "說道", "说道", "問道", "问道", "笑道", "笑說", "笑说", "歎道", "叹道", "嘆道",
    "念道", "答說", "答说", "央告", "安慰", "囑咐", "嘱咐", "讓", "让", "令", "回", "回道", "喝道", "罵道", "骂道", "哭道", "冷笑道", "忙道", "因道", "又道", "便道", "說", "说", "道", "問", "问", "央", "答", "命", "吩咐", "告訴", "告诉", "叫道", "喊道", "嚷道",
];

/// Groups and unnamed speakers, as they're written.
const GROUPS: &[&str] = &[
    "眾人", "众人", "二人", "兩人", "两人", "大家", "眾嬤嬤", "众嬷嬷", "婆娘們", "婆娘们", "地下婆娘們", "地下婆娘们", "丫鬟們", "丫鬟们", "外面人", "外头人", "有人", "一個", "一个",
    "老嬤嬤", "老嬷嬷", "眾丫鬟", "众丫鬟", "眾姊妹", "众姊妹", "姊妹們", "姊妹们", "姐妹們", "姐妹们", "小丫頭", "小丫头", "小丫鬟", "丫鬟", "丫頭", "丫头", "婆子", "媳婦", "媳妇",
    "小廝", "小厮", "嬤嬤", "嬷嬷", "家人", "眾丫頭", "众丫头",
];

/// Openers and closers of a quote.
const OPEN: &[char] = &['“', '"', '「', '『'];
const CLOSE: &[char] = &['”', '"', '」', '』'];

/// Words that come before a speech verb but aren't anyone: 一面, 因笑, 忙.
const NOT_NAMES: &[&str] = &[
    "一面", "因笑", "笑著", "笑着", "說著", "说着", "因問", "因问", "因又", "听了", "听说", "聽了", "又問", "又问", "便問", "便问", "忙問", "忙问", "因說", "因说", "只得", "方才", "回頭", "回头",
    "因命", "命人", "便命", "半日", "半晌", "口內", "口内", "先生", "心下想", "心里", "心里想", "心中", "暗想", "忽然", "悄悄的", "微微的", "連忙", "连忙", "喜的", "拍手", "搖頭", "摇头", "歎口气",
    "叹口气", "出來", "出来", "回來", "回来", "口里", "俗語", "俗语", "大了", "儿笑", "有的", "就有人", "向寶玉", "向宝玉", "一語", "一语", "未了", "听如此", "如此",
];

pub struct Cast {
    names: Vec<String>,
}

impl Cast {
    /// The names that come before a speech verb at least three times in the book's sentences.
    pub fn read(sections: &[Vec<String>]) -> Cast {
        let verbs = VERBS.join("|");
        let pat = Regex::new(&format!(r#"(?:^|[，。；：！？．、\s“”])([一-鿿]{{2,3}}?)(?:笑|冷笑|忙|便|因|又|也|方|只|才|乃|遂|先|含笑|点头|點頭)*(?:{verbs})[：:]?[“"「『]"#)).unwrap();
        let mut count: HashMap<String, u32> = HashMap::new();
        for s in sections.iter().flatten() {
            for c in pat.captures_iter(s) {
                *count.entry(c[1].to_string()).or_default() += 1;
            }
        }
        let lead = "便又因忙也方只才乃遂先冷笑含都一這这那";
        let mut names: Vec<String> = count
            .into_iter()
            .filter(|(n, k)| {
                *k >= 3
                    && !NOT_NAMES.contains(&n.as_str())
                    && !GROUPS.contains(&n.as_str())
                    && !n.chars().next().is_some_and(|c| lead.contains(c))
                    && !n.chars().last().is_some_and(|c| "都也又便了的著着說说道".contains(c))
                    && !is_doing(n)
            })
            .map(|(n, _)| n)
            .collect();
        // Longest first, so 林黛玉 is found before 黛玉.
        names.sort_by(|a, b| b.chars().count().cmp(&a.chars().count()).then(a.cmp(b)));
        Cast { names }
    }

    pub fn names(&self) -> &[String] {
        &self.names
    }

    /// The name `text` starts with, after the little words a clause opens with.
    fn subject(&self, clause: &str) -> Option<String> {
        let rest = strip_lead(clause);
        let pick = |s: &str| {
            GROUPS.iter().map(|g| g.to_string()).chain(self.names.iter().cloned()).filter(|n| s.starts_with(n.as_str())).max_by_key(|n| n.chars().count())
        };
        let hit = pick(rest)?;
        // 宝玉的奶母李嬷嬷: the one after 的 is who.
        let after = &rest[hit.len()..];
        if let Some(more) = after.strip_prefix("的")
            && let Some(i) = self.names.iter().filter_map(|n| more.find(n.as_str()).map(|i| (i, n))).min_by_key(|(i, _)| *i) {
                return Some(i.1.clone());
            }
        Some(hit)
    }
}

/// A doing word (起身, 回头, 点头, 笑着), not a name: it has a character names rarely do.
fn is_doing(w: &str) -> bool {
    w.chars().any(|c| "起身回頭头點点笑哭看听聽說说走來来去坐站問问答叫喊想見见拍搖摇歎叹忙".contains(c))
}

/// Words a clause opens with before its subject: 那, 这里, 一时, 可巧, 忽然, 只见, 于是.
fn strip_lead(clause: &str) -> &str {
    const LEAD: &[&str] = &[
        "這里", "这里", "那里", "一時", "一时", "可巧", "忽然", "當下", "当下", "彼時", "彼时", "此時", "此时", "只見", "只见", "于是", "於是", "誰知", "谁知", "那", "這", "这", "忽", "正",
        "偏", "又", "便", "也", "因", "一面", "先", "卻說", "却说", "且說", "且说", "就", "遂", "乃", "忙", "悄悄的", "又想起", "忽想起", "想起",
    ];
    let mut s = clause.trim_start();
    'again: loop {
        for l in LEAD {
            if let Some(r) = s.strip_prefix(l) {
                s = r;
                continue 'again;
            }
        }
        return s;
    }
}

/// The clauses of a stretch of text, split at Chinese punctuation.
fn clauses(text: &str) -> Vec<&str> {
    text.split(['，', '。', '；', '！', '？', '．', ',', '.', ';', '!', '?']).map(str::trim).filter(|c| !c.is_empty()).collect()
}

fn verb_at_end(clause: &str) -> Option<usize> {
    VERBS.iter().filter(|v| clause.ends_with(*v)).map(|v| clause.len() - v.len()).min()
}

/// The lines of a section: each quote, where it is, and who says it as far as the rules know.
pub fn lines(cast: &Cast, sentences: &[String]) -> Vec<Line> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < sentences.len() {
        let s = &sentences[i];
        let mut from = 0;
        while let Some(rel) = s[from..].find(OPEN) {
            let open = from + rel;
            let body = open + s[open..].chars().next().unwrap().len_utf8();
            // The quote may run on into the next sentences.
            let (last, close) = match s[body..].find(CLOSE) {
                Some(c) => (i, Some(body + c)),
                None => (sentences[i + 1..].iter().position(|t| t.contains(CLOSE)).map(|k| i + 1 + k).unwrap_or(i), None),
            };
            let before = &s[..open];
            let after = close.map(|c| &s[c + s[c..].chars().next().unwrap().len_utf8()..]).unwrap_or("");
            let (who, how) = if latin(s) { speaker_en(cast, before, after) } else { speaker(cast, sentences, i, before, out.last()) };
            let start = s[..body].chars().count() as u32;
            let end = close.map(|c| s[..c].chars().count() as u32).unwrap_or(s.chars().count() as u32);
            out.push(Line { first: i as u32, last: last as u32, start, end, who, how });
            match close {
                Some(c) => from = c + s[c..].chars().next().unwrap().len_utf8(),
                None => break,
            }
            if last != i {
                break;
            }
        }
        i = out.last().filter(|l| l.first as usize == i).map(|l| l.last as usize + 1).unwrap_or(i + 1).max(i + 1);
    }
    out
}

/// Words that make the name after them the one acted on, not the one acting: 向莺儿, 推宝玉.
const OBJECT_MARKS: &[&str] = &[
    "向", "問", "问", "對", "对", "和", "與", "与", "同", "給", "给", "讓", "让", "把", "見", "见", "推", "叫", "安慰", "拉", "攜", "携", "看", "瞧", "勸", "劝", "拍", "扶", "跟", "命", "令",
    "吩咐", "囑咐", "嘱咐", "告訴", "告诉",
];

/// Verbs that take whom they're said to after them: 问晴雯道, 吩咐小丫头子们, 遂问众人.
const TO_WHOM: &[&str] = &["問", "问", "吩咐", "囑咐", "嘱咐", "命", "令", "告訴", "告诉", "叫", "央告", "安慰", "回"];

/// Where the speech words end the clause, allowing whom it's said to after them; the part
/// before the verb.
fn head_of(clause: &str) -> Option<&str> {
    if let Some(v) = verb_at_end(clause) {
        let head = &clause[..v];
        // 问晴雯道: the 问 before the name is the verb; the head is before it.
        if let Some((i, _)) = TO_WHOM.iter().filter_map(|t| head.rfind(t).map(|i| (i, t))).max_by_key(|(i, _)| *i)
            && head[i..].chars().count() <= 8 {
                return Some(&head[..i]);
            }
        return Some(head);
    }
    // 遂问众人, 因含笑问他: a verb, then up to a few characters of whom.
    TO_WHOM.iter().filter_map(|t| clause.rfind(t).map(|i| (i, t))).filter(|(i, t)| clause[i + t.len()..].chars().count() <= 6).max_by_key(|(i, _)| *i).map(|(i, _)| &clause[..i])
}

/// Nothing in front of the speech words but adverbs and the like (又笑, 便忙起身, 乃回头向莺儿笑):
/// the speaker isn't written here, so the one doing things just before is the one. Anything
/// else — an unknown noun, 丫鬟进来 — and the rules don't guess.
fn is_bare(cast: &Cast, head: &str) -> bool {
    let mut rest = strip_lead(head).to_string();
    // Those acted on, and what marks them, come out first.
    for n in cast.names.iter().chain(GROUPS.iter().map(|_| &EMPTY)) {
        if n.is_empty() {
            continue;
        }
        for m in OBJECT_MARKS {
            rest = rest.replace(&format!("{m}{n}"), "");
        }
    }
    for w in ["他們", "他们", "他", "她", "我", "你"] {
        for m in OBJECT_MARKS {
            rest = rest.replace(&format!("{m}{w}"), "");
        }
    }
    const ADVERBS: &str = "又便因忙也方只才乃遂先都笑含冷再還还仍亦即就悄的連连起身回頭头點点著着了一面答回说說问問叫命令念看想听聽登時时急滿满面淚泪痕泣哄抬眼乜斜倦口內内跳起來来";
    rest.chars().all(|c| ADVERBS.contains(c))
}

static EMPTY: String = String::new();

/// A clause that brings someone new in, who may be the one who speaks next: 传医诊视, 叫人来,
/// 只见秋纹走进来.
fn brings_in(clause: &str) -> bool {
    ["傳", "传", "請", "请", "叫", "喚", "唤", "只見", "只见", "進來", "进来", "走來", "走来", "來了", "来了", "診", "诊"].iter().any(|w| clause.contains(w))
}

/// A name in `text` that's someone acted on (after 向, 推, 见…), not the one acting.
fn only_objects(cast: &Cast, text: &str) -> bool {
    names_in(cast, text).all(|n| {
        text.match_indices(n.as_str()).all(|(i, _)| OBJECT_MARKS.iter().any(|m| text[..i].ends_with(m)) || text[..i].ends_with("的") || i > 0 && cast.subject(text).is_some_and(|s| !same_person(&s, n)))
    })
}

/// A sentence in a Latin script: English and the like, where the speaker is told after the
/// quote as often as before it.
fn latin(s: &str) -> bool {
    let letters = s.chars().filter(|c| c.is_alphabetic()).count();
    letters > 0 && s.chars().filter(|c| c.is_ascii_alphabetic()).count() * 2 > letters
}

const SAID: &[&str] = &["said", "replied", "returned", "cried", "asked", "answered", "continued", "added", "observed", "exclaimed", "whispered", "repeated", "rejoined", "resumed"];

/// English: `“…,” said Mr. Bennet` / `“…,” she replied` / `Elizabeth said, “…”`. A pronoun
/// isn't a name; it's left for later (the decision model knows who “she” is).
fn speaker_en(cast: &Cast, before: &str, after: &str) -> (Option<String>, How) {
    let words: Vec<&str> = after.split(|c: char| c.is_whitespace() || c == ',' || c == ';' || c == ':' || c == '.').filter(|w| !w.is_empty()).take(6).collect();
    // said Mr. Bennet / Mr. Bennet said
    if let Some(i) = words.iter().position(|w| SAID.contains(&w.to_lowercase().as_str())) {
        if i == 0 {
            if let Some(n) = name_at(cast, &after[after.find(words[0]).unwrap() + words[0].len()..]) {
                return (Some(n), How::Named);
            }
        } else if let Some(n) = name_at(cast, after) {
            return (Some(n), How::Named);
        }
        return (None, How::Unsure);
    }
    // Elizabeth said, “…”
    let b = before.trim_end_matches([' ', ',', ':']);
    if let Some(w) = SAID.iter().find(|w| b.ends_with(*w)) {
        let head = b[..b.len() - w.len()].trim_end();
        if let Some(n) = cast.names.iter().filter(|n| head.ends_with(n.as_str())).max_by_key(|n| n.len()) {
            return (Some(n.clone()), How::Named);
        }
    }
    (None, How::Unsure)
}

/// The name at the start of `text` (after spaces and “the”), or a run of capitalised words —
/// Mr. Bennet, his lady → none.
fn name_at(cast: &Cast, text: &str) -> Option<String> {
    let t = text.trim_start_matches([' ', ',', '—']);
    if let Some(n) = cast.names.iter().filter(|n| t.starts_with(n.as_str())).max_by_key(|n| n.len()) {
        return Some(n.clone());
    }
    let mut out = Vec::new();
    for w in t.split(' ') {
        let w = w.trim_end_matches([',', ';', ':', '.', '!', '?']);
        if w.chars().next().is_some_and(char::is_uppercase) && !["She", "He", "I", "They", "It", "We", "You"].contains(&w) {
            out.push(w);
            if !["Mr", "Mrs", "Miss", "Sir", "Lady", "Dr", "Colonel", "Captain"].contains(&w) {
                break;
            }
        } else {
            break;
        }
    }
    (!out.is_empty()).then(|| out.join(" ").replace("Mr ", "Mr. ").replace("Mrs ", "Mrs. ").replace("Dr ", "Dr. "))
}

/// Who says a quote that follows `before` in sentence `at`; `prev` is who said the line before,
/// when the rules were sure.
fn speaker(cast: &Cast, sentences: &[String], at: usize, before: &str, prev: Option<&Line>) -> (Option<String>, How) {
    let before = before.trim_end_matches(['：', ':', ' ']);
    let cs = clauses(before);
    let Some(last) = cs.last() else { return (None, How::Unsure) };
    let Some(head) = head_of(last) else { return (None, How::Unsure) };
    // 宝玉笑道 / 众人道: the clause's subject.
    if let Some(n) = cast.subject(head) {
        let how = if GROUPS.contains(&n.as_str()) { How::Group } else { How::Named };
        // 一个 is never sure: 一个抱住腰，一个携着手.
        if n == "一個" || n == "一个" {
            return (None, How::Unsure);
        }
        return (Some(n), how);
    }
    // 忽听外面人说: the one heard is the one speaking.
    for h in ["听見", "听见", "聽見", "听", "聽"] {
        if let Some(i) = head.find(h)
            && let Some(n) = cast.subject(&head[i + h.len()..])
                && n != "一個" && n != "一个" {
                    let how = if GROUPS.contains(&n.as_str()) { How::Group } else { How::Named };
                    return (Some(n), how);
                }
    }
    // 茜雪道 at the start of a sentence: two or three characters and the verb, a name even when
    // the cast hasn't got it.
    if cs.len() == 1 && before.len() == last.len() {
        let n = head.chars().count();
        if (2..=3).contains(&n) && !is_doing(head) && head.chars().all(|c| ('\u{4e00}'..='\u{9fff}').contains(&c)) && !NOT_NAMES.contains(&head) && !head.starts_with(|c: char| "便又因忙也方只才乃遂先一這这那".contains(c)) {
            return (Some(head.to_string()), How::Named);
        }
    }
    // 说着又问: the one who just spoke goes on.
    if ["說著", "说着"].iter().any(|w| strip_lead(head).starts_with(w) || head.starts_with(w)) && cs.len() == 1
        && let Some(p) = prev.filter(|p| p.who.is_some() && p.how != How::Group && p.last as usize + 1 == at) {
            return (p.who.clone(), How::Before);
        }
    // A name inside the clause, not at its start, and not one acted on, or someone the rules
    // don't know (丫鬟进来笑道): too easy to get the wrong one.
    if !only_objects(cast, head) || !is_bare(cast, head) {
        return (None, How::Unsure);
    }
    // 主语承前省略: the nearest subject in the clauses before, in this sentence — as long as
    // nothing on the way brings someone else in (传医诊视，说道 is the doctor).
    for c in cs[..cs.len() - 1].iter().rev() {
        if let Some(n) = cast.subject(c) {
            return sure_before(n);
        }
        if !only_objects(cast, c) || brings_in(c) {
            return (None, How::Unsure);
        }
    }
    // …or the sentence before. When it holds a line of its own, only when that line was said by
    // the one the sentence is about: the same person goes on (念道…又笑道).
    if at > 0 {
        let p = &sentences[at - 1];
        let quoted = p.contains(OPEN);
        let text = if quoted { &p[..p.find(OPEN).unwrap()] } else { p.as_str() };
        for c in clauses(text).iter().rev() {
            if let Some(n) = cast.subject(c) {
                if quoted && !prev.is_some_and(|l| l.last as usize + 1 == at && l.who.as_deref().is_some_and(|w| same_person(w, &n))) {
                    return (None, How::Unsure);
                }
                return sure_before(n);
            }
            if !only_objects(cast, c) {
                return (None, How::Unsure);
            }
        }
    }
    (None, How::Unsure)
}

fn sure_before(n: String) -> (Option<String>, How) {
    if GROUPS.contains(&n.as_str()) {
        if n == "一個" || n == "一个" {
            return (None, How::Unsure);
        }
        return (Some(n), How::Group);
    }
    (Some(n), How::Before)
}

fn names_in<'a>(cast: &'a Cast, text: &'a str) -> impl Iterator<Item = &'a String> + 'a {
    cast.names.iter().filter(move |n| text.contains(n.as_str()))
}

/// The same person written two ways (宝玉, 贾宝玉): the shorter one when one ends the other.
pub fn same_person(a: &str, b: &str) -> bool {
    a == b || (a.chars().count() >= 2 && b.chars().count() >= 2 && (a.ends_with(b) || b.ends_with(a)))
}

/// A section's lines, for the bubbles and the voices.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct SectionScript {
    pub lines: Vec<Line>,
    /// Everyone the book names before a speech verb, longest name first.
    pub cast: Vec<String>,
}

#[uniffi::export]
impl YuyueCore {
    /// 剧本 for one section: each quote and who says it, as far as the rules are sure. The cast
    /// is read from the whole book once and kept while the core is open.
    pub fn section_script(&self, book_id: String, section: u32) -> Result<SectionScript> {
        let cast = self.cast(&book_id)?;
        let sentences = self.sentences(book_id, section)?;
        Ok(SectionScript { lines: lines(&cast, &sentences), cast: cast.names.clone() })
    }
}

impl YuyueCore {
    fn cast(&self, book_id: &str) -> Result<std::sync::Arc<Cast>> {
        if let Some(c) = lock(&self.casts).get(book_id) {
            return Ok(c.clone());
        }
        let n = self.manifest(book_id)?.sections.len() as u32;
        let all: Vec<Vec<String>> = (0..n).map(|i| self.sentences(book_id.to_string(), i).unwrap_or_default()).collect();
        let cast = std::sync::Arc::new(Cast::read(&all));
        lock(&self.casts).insert(book_id.to_string(), cast.clone());
        Ok(cast)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The rules against the answers for 红楼梦 第八回 (fixtures/speakers): a name given is the
    /// right one; how many are left grey is printed, to watch it come down.
    #[test]
    fn hongloumeng_eight() {
        let dir = std::env::temp_dir().join(format!("yuyue-script-{}", getrandom::u64().unwrap()));
        let core = YuyueCore::open(dir.to_string_lossy().into_owned(), "test".into(), "test".into()).unwrap();
        let book = core.import_book(format!("{}/../../fixtures/books/hongloumeng.epub", env!("CARGO_MANIFEST_DIR"))).unwrap();
        let detail = core.book(book.id.clone()).unwrap();
        let all: Vec<Vec<String>> = (0..detail.sections.len() as u32).map(|i| core.sentences(book.id.clone(), i).unwrap_or_default()).collect();
        let cast = Cast::read(&all);
        let answers = std::fs::read_to_string(format!("{}/../../fixtures/speakers/hongloumeng-08.jsonl", env!("CARGO_MANIFEST_DIR"))).unwrap();
        let mut rows = answers.lines().map(|l| serde_json::from_str::<serde_json::Value>(l).unwrap());
        let head = rows.next().unwrap();
        let section = head["section"].as_u64().unwrap() as usize;
        let got = lines(&cast, &all[section]);
        let (mut right, mut wrong, mut grey) = (0, Vec::new(), 0);
        for g in rows {
            if g["kind"] == "not_speech" {
                continue;
            }
            let s = g["s"].as_u64().unwrap() as u32;
            let q = g["q"].as_str().unwrap();
            let who = g["who"].as_str().unwrap();
            let line = got.iter().find(|l| l.first == s && all[section][s as usize].chars().skip(l.start as usize).collect::<String>().starts_with(q));
            match line.and_then(|l| l.who.clone()) {
                None => {
                    grey += 1;
                    if std::env::var("SCRIPT_GREY").is_ok() {
                        println!("灰 {s} [{}] {who}：{}", g["kind"], all[section][s as usize]);
                    }
                }
                Some(n) if same_person(&n, who) || who.split('、').any(|w| same_person(&n, w)) || (n == "二人" && who.contains('、')) => right += 1,
                Some(n) => wrong.push(format!("{s} {q}：{who}，认成 {n}")),
            }
        }
        std::fs::remove_dir_all(dir).ok();
        println!("第八回：认对 {right}，认错 {}，没把握 {grey}", wrong.len());
        assert!(wrong.is_empty(), "认错了：\n{}", wrong.join("\n"));
    }

    #[test]
    fn a_quote_and_its_speaker() {
        let cast = Cast { names: vec!["寶玉".into(), "黛玉".into()] };
        let s: Vec<String> = ["寶玉笑道：“在那里看見了？”", "黛玉听了，冷笑道：“我早知道。”", "說著走了．"].iter().map(|s| s.to_string()).collect();
        let got = lines(&cast, &s);
        assert_eq!(got.iter().map(|l| (l.first, l.who.as_deref(), l.how)).collect::<Vec<_>>(), [(0, Some("寶玉"), How::Named), (1, Some("黛玉"), How::Before)]);
        assert_eq!(s[0].chars().skip(got[0].start as usize).take((got[0].end - got[0].start) as usize).collect::<String>(), "在那里看見了？");
    }
}
