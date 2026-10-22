//! 替换规则 (FEATURES §3): find and replace on a book's words, for one book or for every book,
//! plain or as a regular expression, on the page and in the voice or in the voice only.
//!
//! Registers: `rule/<id>` · `book` (a book id, `""` for every book) / `find` / `replace` /
//! `regex` / `speech` (只改朗读) / `on` / `order` / `deleted`.
//!
//! Rules work inside one sentence at a time and never add or remove one, so sentence numbers
//! (progress, highlights, bookmarks) stay put whatever the rules say. The book's own rules run
//! after the ones for every book, each list from the top down.

use std::collections::BTreeMap;

use regex::{NoExpand, Regex};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::api::{YuyueCore, lock, now_ms};
use crate::error::{CoreError, Result};

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct ReplaceRule {
    /// Empty for a rule not saved yet.
    pub id: String,
    /// The book it is for; `None` for every book.
    pub book: Option<String>,
    pub find: String,
    /// Empty deletes what was found.
    pub replace: String,
    pub regex: bool,
    /// 只改朗读: the page keeps the words, the voice reads the replacement.
    pub speech_only: bool,
    pub enabled: bool,
    /// Lower runs first.
    pub order: f64,
}

/// One of 常用规则, for people who don't write regular expressions.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct CommonRule {
    pub title: String,
    pub detail: String,
    pub rule: ReplaceRule,
}

/// What a rule would do to a book, while it is being written.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct RulePreview {
    /// Places it matches, up to `PREVIEW_MAX`.
    pub count: u32,
    /// More than `PREVIEW_MAX`.
    pub more: bool,
    /// Why it can't run (a regular expression that doesn't parse).
    pub error: Option<String>,
    /// The first place: before it reads `lead` + `matched` + `tail`, after `lead` +
    /// `replaced` + `tail`.
    pub first: Option<RuleSample>,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct RuleSample {
    pub section: u32,
    pub sentence: u32,
    /// Starts with "……" when the sentence goes on further back.
    pub lead: String,
    pub matched: String,
    pub replaced: String,
    /// Ends with "……" when the sentence goes on.
    pub tail: String,
}

const PREVIEW_MAX: u32 = 999;
/// Characters of context on each side of a sample.
const CONTEXT: usize = 24;

/// Rules ready to run, then the book's 简繁 conversion when it has one.
pub(crate) struct Rules(Vec<(Regex, String, bool)>, Option<Script>);

impl Rules {
    pub(crate) fn is_empty(&self) -> bool {
        self.0.is_empty() && self.1.is_none()
    }

    pub(crate) fn apply(&self, text: &str) -> String {
        let mut out = text.to_string();
        for (re, with, regex) in &self.0 {
            out = if *regex { re.replace_all(&out, with.as_str()) } else { re.replace_all(&out, NoExpand(with)) }.into_owned();
        }
        match self.1 {
            Some(script) => script.convert(&out),
            None => out,
        }
    }

    /// Runs the rules on a section document's sentence spans, leaving the markup alone: what a
    /// sentence's text loses is taken out of its text nodes, what it gains goes where the
    /// match began. A sentence split by inline markup (`<em>`) is matched as one.
    pub(crate) fn apply_html(&self, html: &str) -> String {
        if self.is_empty() {
            return html.to_string();
        }
        let tokens = tokenize(html);
        // Each sentence's text pieces: (token, plain text).
        let mut by_sentence: BTreeMap<u32, Vec<(usize, String)>> = BTreeMap::new();
        let mut stack: Vec<Option<u32>> = Vec::new();
        for (i, t) in tokens.iter().enumerate() {
            match t {
                Token::Tag(raw) if raw.starts_with("</span") => {
                    stack.pop();
                }
                Token::Tag(raw) if raw.starts_with("<span") && !raw.ends_with("/>") => stack.push(sentence_of(raw)),
                Token::Tag(_) => {}
                Token::Text(raw) => {
                    if let Some(s) = stack.iter().rev().find_map(|s| *s) {
                        by_sentence.entry(s).or_default().push((i, unescape(raw)));
                    }
                }
            }
        }
        let mut replaced: BTreeMap<usize, String> = BTreeMap::new();
        for pieces in by_sentence.values() {
            let plain: String = pieces.iter().map(|(_, t)| t.as_str()).collect();
            let after = self.apply(&plain);
            if after == plain {
                continue;
            }
            for (i, text) in redistribute(pieces, &plain, &after) {
                replaced.insert(i, text);
            }
        }
        let mut out = String::with_capacity(html.len());
        for (i, t) in tokens.iter().enumerate() {
            match (t, replaced.get(&i)) {
                (_, Some(text)) => crate::dom::escape_text(text, &mut out),
                // Outside the sentences (headings, captions): only the 简繁 conversion.
                (Token::Text(raw), None) if self.1.is_some() => crate::dom::escape_text(&self.convert(&unescape(raw)), &mut out),
                (Token::Tag(raw) | Token::Text(raw), None) => out.push_str(raw),
            }
        }
        out
    }

    /// The book's 简繁 conversion alone, for titles.
    pub(crate) fn convert(&self, text: &str) -> String {
        match self.1 {
            Some(script) => script.convert(text),
            None => text.to_string(),
        }
    }
}

/// Spreads a sentence's new text over its old pieces: the common start and end stay in the
/// pieces they were in, the changed middle goes to the piece where the change starts.
fn redistribute(pieces: &[(usize, String)], before: &str, after: &str) -> Vec<(usize, String)> {
    let b: Vec<char> = before.chars().collect();
    let a: Vec<char> = after.chars().collect();
    let mut head = 0;
    while head < b.len() && head < a.len() && b[head] == a[head] {
        head += 1;
    }
    let mut tail = 0;
    while tail < b.len() - head && tail < a.len() - head && b[b.len() - 1 - tail] == a[a.len() - 1 - tail] {
        tail += 1;
    }
    let (cut_from, cut_to) = (head, b.len() - tail);
    let middle: String = a[head..a.len() - tail].iter().collect();
    let mut out = Vec::with_capacity(pieces.len());
    let mut pos = 0;
    let mut placed = false;
    for (n, (i, text)) in pieces.iter().enumerate() {
        let chars: Vec<char> = text.chars().collect();
        let (start, end) = (pos, pos + chars.len());
        pos = end;
        let mut s = String::new();
        for (k, c) in chars.iter().enumerate() {
            let at = start + k;
            if at == cut_from && !placed {
                s.push_str(&middle);
                placed = true;
            }
            if at < cut_from || at >= cut_to {
                s.push(*c);
            }
        }
        // An insertion at the very end of a piece, or of the whole sentence.
        if !placed && (cut_from == end && (cut_from < cut_to || n == pieces.len() - 1)) {
            s.push_str(&middle);
            placed = true;
        }
        if s != *text {
            out.push((*i, s));
        }
    }
    out
}

enum Token<'a> {
    Tag(&'a str),
    Text(&'a str),
}

fn tokenize(html: &str) -> Vec<Token<'_>> {
    let mut out = Vec::new();
    let mut rest = html;
    while !rest.is_empty() {
        if rest.starts_with('<') {
            let end = rest.find('>').map_or(rest.len(), |e| e + 1);
            out.push(Token::Tag(&rest[..end]));
            rest = &rest[end..];
        } else {
            let end = rest.find('<').unwrap_or(rest.len());
            out.push(Token::Text(&rest[..end]));
            rest = &rest[end..];
        }
    }
    out
}

/// The sentence a `<span class="s" data-s="N">` opens.
fn sentence_of(tag: &str) -> Option<u32> {
    if !tag.contains(r#"class="s""#) {
        return None;
    }
    let at = tag.find(r#"data-s=""#)? + 8;
    tag[at..].split('"').next()?.parse().ok()
}

fn unescape(raw: &str) -> String {
    if !raw.contains('&') {
        return raw.to_string();
    }
    let mut out = String::with_capacity(raw.len());
    let mut rest = raw;
    while let Some(i) = rest.find('&') {
        out.push_str(&rest[..i]);
        rest = &rest[i..];
        let Some(end) = rest.find(';').filter(|&e| e <= 10) else {
            out.push('&');
            rest = &rest[1..];
            continue;
        };
        let name = &rest[1..end];
        let c = match name {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            "nbsp" => Some('\u{a0}'),
            _ => name
                .strip_prefix("#x")
                .or_else(|| name.strip_prefix("#X"))
                .and_then(|h| u32::from_str_radix(h, 16).ok())
                .or_else(|| name.strip_prefix('#').and_then(|d| d.parse().ok()))
                .and_then(char::from_u32),
        };
        match c {
            Some(c) => {
                out.push(c);
                rest = &rest[end + 1..];
            }
            None => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

fn compile(rule: &ReplaceRule) -> std::result::Result<Regex, String> {
    let pattern = if rule.regex { rule.find.clone() } else { regex::escape(&rule.find) };
    Regex::new(&pattern).map_err(|e| match e {
        regex::Error::Syntax(_) => crate::i18n::tr("正则表达式写得不对", "The regular expression isn't valid"),
        regex::Error::CompiledTooBig(_) => crate::i18n::tr("正则表达式太复杂了", "The regular expression is too complex"),
        _ => crate::i18n::tr("正则表达式用不了", "The regular expression can't be used"),
    })
}

fn rule_from(id: &str, f: &BTreeMap<String, Value>) -> Option<ReplaceRule> {
    let book = f.get("book").and_then(Value::as_str).unwrap_or_default();
    Some(ReplaceRule {
        id: id.to_string(),
        book: (!book.is_empty()).then(|| book.to_string()),
        find: f.get("find")?.as_str()?.to_string(),
        replace: f.get("replace").and_then(Value::as_str).unwrap_or_default().to_string(),
        regex: f.get("regex").and_then(Value::as_bool).unwrap_or(false),
        speech_only: f.get("speech").and_then(Value::as_bool).unwrap_or(false),
        enabled: f.get("on").and_then(Value::as_bool).unwrap_or(true),
        order: f.get("order").and_then(Value::as_f64).unwrap_or(0.0),
    })
}

fn new_id() -> String {
    format!("{:016x}", getrandom::u64().unwrap_or_else(|_| now_ms() as u64 ^ (std::process::id() as u64) << 40))
}

fn check_id(id: &str) -> Result<()> {
    if id.len() == 16 && id.bytes().all(|b| b.is_ascii_hexdigit()) { Ok(()) } else { Err(CoreError::not_found("rule")) }
}

fn template(find: &str, replace: &str, regex: bool) -> ReplaceRule {
    ReplaceRule {
        id: String::new(),
        book: None,
        find: find.to_string(),
        replace: replace.to_string(),
        regex,
        speech_only: false,
        enabled: true,
        order: 0.0,
    }
}

#[uniffi::export]
impl YuyueCore {
    /// A book's own rules (`Some`), or the ones for every book (`None`), in the order they run.
    pub fn replace_rules(&self, book: Option<String>) -> Result<Vec<ReplaceRule>> {
        if let Some(b) = &book {
            self.book_dir(b)?;
        }
        Ok(self.all_rules()?.into_iter().filter(|r| r.book == book).collect())
    }

    /// Saves a rule, new (empty id, put at the bottom) or changed. A regular expression has to
    /// parse.
    pub fn save_replace_rule(&self, rule: ReplaceRule) -> Result<ReplaceRule> {
        if rule.find.is_empty() {
            return Err(CoreError::Invalid { detail: crate::i18n::tr("要查找的字是空的", "Type what to find") });
        }
        compile(&rule).map_err(|detail| CoreError::Invalid { detail })?;
        if let Some(b) = &rule.book {
            self.book_dir(b)?;
        }
        let mut rule = rule;
        if rule.id.is_empty() {
            rule.id = new_id();
            let last = self.all_rules()?.iter().filter(|r| r.book == rule.book).map(|r| r.order).fold(0.0, f64::max);
            rule.order = last + 1.0;
        } else {
            check_id(&rule.id)?;
        }
        lock(&self.store).set_fields(
            &format!("rule/{}", rule.id),
            &[
                ("book", json!(rule.book.clone().unwrap_or_default())),
                ("find", json!(rule.find)),
                ("replace", json!(rule.replace)),
                ("regex", json!(rule.regex)),
                ("speech", json!(rule.speech_only)),
                ("on", json!(rule.enabled)),
                ("order", json!(rule.order)),
                ("deleted", json!(false)),
            ],
        )?;
        Ok(rule)
    }

    pub fn set_replace_rule_enabled(&self, id: String, enabled: bool) -> Result<()> {
        check_id(&id)?;
        lock(&self.store).set(&format!("rule/{id}"), "on", json!(enabled))
    }

    /// Moves a rule to run at `order` (the app picks a number between its new neighbours).
    pub fn move_replace_rule(&self, id: String, order: f64) -> Result<()> {
        check_id(&id)?;
        lock(&self.store).set(&format!("rule/{id}"), "order", json!(order))
    }

    pub fn delete_replace_rule(&self, id: String) -> Result<()> {
        check_id(&id)?;
        lock(&self.store).set(&format!("rule/{id}"), "deleted", json!(true))
    }

    pub fn restore_replace_rule(&self, id: String) -> Result<()> {
        check_id(&id)?;
        lock(&self.store).set(&format!("rule/{id}"), "deleted", json!(false))
    }

    /// 实时预览: how many places in the book the rule matches, and the first one before and
    /// after. Runs on the words as imported, without the other rules.
    pub fn preview_replace_rule(&self, book: String, rule: ReplaceRule) -> Result<RulePreview> {
        let dir = self.book_dir(&book)?;
        let mut preview = RulePreview { count: 0, more: false, error: None, first: None };
        if rule.find.is_empty() {
            return Ok(preview);
        }
        let re = match compile(&rule) {
            Ok(re) => re,
            Err(e) => {
                preview.error = Some(e);
                return Ok(preview);
            }
        };
        let detail = self.book(book)?;
        for (i, section) in detail.sections.iter().enumerate() {
            if section.sentences == 0 {
                continue;
            }
            let Ok(sentences) = crate::book::sentences(&dir, i as u32) else { continue };
            for (s, text) in sentences.iter().enumerate() {
                for m in re.find_iter(text) {
                    if m.is_empty() && rule.replace.is_empty() {
                        continue;
                    }
                    if preview.count == PREVIEW_MAX {
                        preview.more = true;
                        return Ok(preview);
                    }
                    preview.count += 1;
                    if preview.first.is_none() {
                        let lead: Vec<char> = text[..m.start()].chars().collect();
                        let tail: Vec<char> = text[m.end()..].chars().collect();
                        let replaced = if rule.regex {
                            let caps = re.captures_at(text, m.start()).expect("matched here");
                            let mut out = String::new();
                            caps.expand(&rule.replace, &mut out);
                            out
                        } else {
                            rule.replace.clone()
                        };
                        let from = lead.len().saturating_sub(CONTEXT);
                        let to = tail.len().min(CONTEXT);
                        preview.first = Some(RuleSample {
                            section: i as u32,
                            sentence: s as u32,
                            lead: format!("{}{}", if from > 0 { "……" } else { "" }, lead[from..].iter().collect::<String>()),
                            matched: m.as_str().to_string(),
                            replaced,
                            tail: format!("{}{}", tail[..to].iter().collect::<String>(), if to < tail.len() { "……" } else { "" }),
                        });
                    }
                }
            }
        }
        Ok(preview)
    }

    /// 从常用规则里挑: the usual clean-ups for books from the web.
    pub fn common_replace_rules(&self) -> Vec<CommonRule> {
        let item = |title: (&str, &str), detail: (&str, &str), rule: ReplaceRule| CommonRule { title: crate::i18n::tr(title.0, title.1), detail: crate::i18n::tr(detail.0, detail.1), rule };
        vec![
            item(
                ("网址水印", "Web addresses"),
                ("删掉夹在正文里的网址", "Remove web addresses left in the text"),
                template(r"(?i)(https?://)?(www\.|m\.|wap\.)[a-z0-9\-.]+\.[a-z]{2,6}(/\S*)?", "", true),
            ),
            item(("站点广告", "Site ads"), ("删掉【……最新章节……】一类的括号广告", "Remove bracketed site ads like 【…最新章节…】"), template(r"[【\[(（][^】\])）]*(最新章节|首发|无弹窗|手机阅读|请记住|本书网址)[^】\])）]*[】\])）]", "", true)),
            item(("“本章完”", "“End of chapter”"), ("删掉章节末尾的（本章完）", "Remove （本章完） at the end of chapters"), template(r"[（(]本章完[)）]", "", true)),
            item(("作者的话", "Author's notes"), ("删掉以 PS： 开头的作者附言", "Remove author's notes starting with PS:"), template(r"^\s*[Pp][Ss][:：].*$", "", true)),
            item(("求票求收藏", "Vote begging"), ("删掉求月票、求推荐、求收藏的句子", "Remove lines asking for votes, recommendations or follows"), template(r"^.*求(月票|推荐票?|收藏|订阅|打赏).*$", "", true)),
            item(("多余的空格", "Extra spaces"), ("几个空格并成一个", "Turn runs of spaces into one"), template(r"[ \u{3000}]{2,}", " ", true)),
        ]
    }

    /// The text of each sentence as the voice should read it: every rule on, the 只改朗读
    /// ones too. Same count as `sentences`.
    pub fn spoken_sentences(&self, book_id: String, section: u32) -> Result<Vec<String>> {
        let rules = self.rules_for(&book_id, true)?;
        let out = crate::book::sentences(&self.book_dir(&book_id)?, section)?;
        Ok(if rules.is_empty() { out } else { out.iter().map(|s| rules.apply(s)).collect() })
    }
}

impl YuyueCore {
    fn all_rules(&self) -> Result<Vec<ReplaceRule>> {
        let prefix = "rule/";
        let mut out: Vec<ReplaceRule> = lock(&self.store)
            .entities(prefix)?
            .into_iter()
            .filter(|(_, f)| f.get("deleted") != Some(&json!(true)))
            .filter_map(|(e, f)| rule_from(e.strip_prefix(prefix)?, &f))
            .collect();
        out.sort_by(|a, b| a.order.total_cmp(&b.order).then_with(|| a.id.cmp(&b.id)));
        Ok(out)
    }

    /// What runs on a book: the rules for every book, then its own; the 只改朗读 ones only for
    /// the voice. A rule that no longer compiles is skipped.
    pub(crate) fn rules_for(&self, book: &str, speech: bool) -> Result<Rules> {
        let all = self.all_rules()?;
        let ordered = all.iter().filter(|r| r.book.is_none()).chain(all.iter().filter(|r| r.book.as_deref() == Some(book)));
        Ok(Rules(
            ordered
                .filter(|r| r.enabled && (speech || !r.speech_only))
                .filter_map(|r| Some((compile(r).ok()?, r.replace.clone(), r.regex)))
                .collect(),
            self.script_of(book)?,
        ))
    }

    fn script_of(&self, book: &str) -> Result<Option<Script>> {
        let value = lock(&self.store).get(&format!("book/{book}"), "script")?;
        Ok(value.and_then(|v| serde_json::from_value(v).ok()))
    }
}

/// A Chinese book shown in the other script (单本书简繁转换): the file stays as it is; what is
/// shown, read aloud and searched for in it is converted.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "lowercase")]
pub enum Script {
    /// 简体
    Simplified,
    /// 繁體
    Traditional,
}

impl Script {
    fn convert(self, text: &str) -> String {
        let to = match self {
            Script::Simplified => zhconv::Variant::ZhHans,
            Script::Traditional => zhconv::Variant::ZhHant,
        };
        zhconv::zhconv(text, to)
    }
}

#[uniffi::export]
impl YuyueCore {
    /// The script a book is shown in, when it isn't shown as it is.
    pub fn book_script(&self, book_id: String) -> Result<Option<Script>> {
        self.book_dir(&book_id)?;
        self.script_of(&book_id)
    }

    /// Shows a book in 简体 or 繁體, or (None) as it is. Synced with the book.
    pub fn set_book_script(&self, book_id: String, script: Option<Script>) -> Result<()> {
        self.book_dir(&book_id)?;
        let value = script.map(|s| json!(s)).unwrap_or(Value::Null);
        lock(&self.store).set(&format!("book/{book_id}"), "script", value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rules(list: &[(&str, &str, bool)]) -> Rules {
        Rules(
            list.iter()
                .map(|(f, r, re)| (compile(&template(f, r, *re)).unwrap(), r.to_string(), *re))
                .collect(),
            None,
        )
    }

    #[test]
    fn converts_a_book_to_the_other_script() {
        let to_trad = Rules(Vec::new(), Some(Script::Traditional));
        assert_eq!(to_trad.apply("红楼梦里的头发"), "紅樓夢裏的頭髮");
        let to_simp = Rules(Vec::new(), Some(Script::Simplified));
        assert_eq!(to_simp.apply("紅樓夢"), "红楼梦");
        // Headings outside the sentences go along; the markup stays.
        let html = r#"<h2>第一回 甄士隱夢幻識通靈</h2><p><span class="s" data-s="0">此開卷第一回也。</span></p>"#;
        assert_eq!(
            to_simp.apply_html(html),
            r#"<h2>第一回 甄士隐梦幻识通灵</h2><p><span class="s" data-s="0">此开卷第一回也。</span></p>"#
        );
    }

    #[test]
    fn replaces_inside_sentences_keeping_markup() {
        let html = r#"<p><span class="s" data-s="0">她把伞靠在门边，【最新章节请到 xx 网】回头看了一眼。</span><span class="s" data-s="1">单老板笑了<span class="pz-r">，</span>说&amp;好。</span></p>"#;
        let r = rules(&[("【.*?最新章节.*?】", "", true), ("单老板", "善老板", false)]);
        assert_eq!(
            r.apply_html(html),
            r#"<p><span class="s" data-s="0">她把伞靠在门边，回头看了一眼。</span><span class="s" data-s="1">善老板笑了<span class="pz-r">，</span>说&amp;好。</span></p>"#
        );
    }

    #[test]
    fn matches_across_inline_markup() {
        let html = r#"<p><span class="s" data-s="3">我想（本</span><em><span class="s" data-s="3">章完）</span></em><span class="s" data-s="3">好</span></p>"#;
        let out = rules(&[("（本章完）", "", false)]).apply_html(html);
        assert_eq!(out, r#"<p><span class="s" data-s="3">我想</span><em><span class="s" data-s="3"></span></em><span class="s" data-s="3">好</span></p>"#);
        // Text outside sentences is left alone.
        let meta = r#"<div class="yy-meta">（本章完）</div>"#;
        assert_eq!(rules(&[("（本章完）", "", false)]).apply_html(meta), meta);
    }

    #[test]
    fn plain_rules_are_literal_and_regex_ones_expand() {
        assert_eq!(rules(&[("a.c", "$1", false)]).apply("abc a.c"), "abc $1");
        assert_eq!(rules(&[(r"(\d+)元", "${1}块", true)]).apply("花了30元"), "花了30块");
    }

    #[test]
    fn rules_for_a_book_and_for_every_book() {
        let dir = std::env::temp_dir().join(format!("yuyue-rules-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let core = YuyueCore::open(dir.to_string_lossy().into_owned(), "Mac".into(), "macos".into()).unwrap();
        let b = core
            .import_book(format!("{}/../../fixtures/books/beiying.txt", env!("CARGO_MANIFEST_DIR")))
            .unwrap();
        let before = core.sentences(b.id.clone(), 0).unwrap();
        let geometry = crate::api::PageGeometry { paging: crate::document::Paging::Native, margin: 20.0, top: 50.0, bottom: 80.0, columns: 1, reduced_motion: false };
        assert!(core.section_document(b.id.clone(), 0, geometry.clone()).unwrap().contains("父亲"));

        let mut mine = template("父亲", "爸爸", false);
        mine.book = Some(b.id.clone());
        let mine = core.save_replace_rule(mine).unwrap();
        let mut spoken = template("背影", "bèi yǐng", false);
        spoken.speech_only = true;
        core.save_replace_rule(spoken).unwrap();
        assert!(core.save_replace_rule(template("(", "", true)).is_err());

        assert_eq!(core.replace_rules(Some(b.id.clone())).unwrap(), vec![mine.clone()]);
        assert_eq!(core.replace_rules(None).unwrap().len(), 1);
        let shown = core.sentences(b.id.clone(), 0).unwrap();
        assert_eq!(shown.len(), before.len());
        assert!(shown.iter().all(|s| !s.contains("父亲")) && shown.iter().any(|s| s.contains("背影")));
        let heard = core.spoken_sentences(b.id.clone(), 0).unwrap();
        assert!(heard.iter().all(|s| !s.contains("背影")));
        assert!(!core.section_document(b.id.clone(), 0, geometry.clone()).unwrap().contains("父亲"));
        assert!(core.search_book(b.id.clone(), "父亲".into()).unwrap().is_empty());

        let preview = core.preview_replace_rule(b.id.clone(), template("父亲", "爸爸", false)).unwrap();
        assert!(preview.count > 5 && preview.error.is_none());
        let first = preview.first.unwrap();
        assert_eq!((first.matched.as_str(), first.replaced.as_str()), ("父亲", "爸爸"));
        assert!(core.preview_replace_rule(b.id.clone(), template("[", "", true)).unwrap().error.is_some());

        core.set_replace_rule_enabled(mine.id.clone(), false).unwrap();
        assert_eq!(core.sentences(b.id.clone(), 0).unwrap(), before);
        core.delete_replace_rule(mine.id.clone()).unwrap();
        assert!(core.replace_rules(Some(b.id.clone())).unwrap().is_empty());
        assert!(!core.common_replace_rules().is_empty());
        for c in core.common_replace_rules() {
            assert!(compile(&c.rule).is_ok(), "{}", c.title);
        }
    }

    #[test]
    fn redistributes_insertions_at_the_end() {
        let pieces = vec![(0, "ab".to_string()), (2, "c".to_string())];
        assert_eq!(redistribute(&pieces, "abc", "abcd"), vec![(2, "cd".to_string())]);
        assert_eq!(redistribute(&pieces, "abc", "xbc"), vec![(0, "xb".to_string())]);
    }
}
