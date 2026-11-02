//! Plain-text books: encoding detection, paragraph reconstruction and chapter detection.
//!
//! The structure detection is also used for EPUBs that are really text files in XHTML clothes
//! (many public-domain Chinese books: one huge `<p>` per few hundred lines, hard-wrapped, with
//! "　　" starting each paragraph and no table of contents).

use std::sync::LazyLock;

use encoding_rs::Encoding;
use regex::Regex;

use crate::dom::{Element, Node};
use crate::text::{guess_language, is_cjk, is_wide};

pub struct TextBook {
    pub title: Option<String>,
    pub author: Option<String>,
    pub language: &'static str,
    pub chapters: Vec<Chapter>,
}

#[derive(Debug, Default, PartialEq)]
pub struct Chapter {
    pub title: Option<String>,
    pub paragraphs: Vec<String>,
    /// A later part of a chapter that was too long for one section.
    pub continued: bool,
}

/// Chapters longer than this are cut into parts at paragraph boundaries, so a WebView never has
/// to lay out a whole novel at once.
const MAX_SECTION_CHARS: usize = 60_000;
const PART_CHARS: usize = 30_000;

/// The paragraph text used for a scene break ("* * *", "————").
pub const SCENE_BREAK: &str = "* * *";

/// Decodes a text file: BOM, then UTF-8, then a statistical guess (GBK/Big5/Shift_JIS…).
pub fn decode(bytes: &[u8]) -> String {
    decode_as(bytes, None).text
}

pub struct Decoded {
    pub text: String,
    pub encoding: &'static Encoding,
    /// Bytes that weren't text in that encoding, each now a U+FFFD.
    pub errors: usize,
}

/// Decodes in the given encoding, or the one `decode` would pick.
pub fn decode_as(bytes: &[u8], forced: Option<&'static Encoding>) -> Decoded {
    let (text, encoding) = match forced {
        Some(enc) => (enc.decode_with_bom_removal(bytes).0.into_owned(), enc),
        None => {
            if let Some((enc, bom_len)) = Encoding::for_bom(bytes) {
                (enc.decode_without_bom_handling(&bytes[bom_len..]).0.into_owned(), enc)
            } else if let Ok(s) = std::str::from_utf8(bytes) {
                (s.to_string(), encoding_rs::UTF_8)
            } else {
                let mut detector = chardetng::EncodingDetector::new(chardetng::Iso2022JpDetection::Deny);
                detector.feed(bytes, true);
                let enc = detector.guess(None, chardetng::Utf8Detection::Allow);
                (enc.decode(bytes).0.into_owned(), enc)
            }
        }
    };
    let errors = text.chars().filter(|&c| c == '\u{FFFD}').count();
    Decoded { text, encoding, errors }
}

/// "GBK", "UTF-8", "GB18030", "Big5"…
pub fn encoding_name(enc: &'static Encoding) -> String {
    if enc == encoding_rs::GB18030 { "GB18030".into() } else { enc.name().to_string() }
}

pub fn encoding_for(name: &str) -> Option<&'static Encoding> {
    Encoding::for_label(name.trim().as_bytes())
}

/// The chapter rule shown when none was written: what the importer looks for in Chinese books.
/// It also knows 序章, 楔子, "Chapter 3" and the like, which a written rule replaces.
pub const DEFAULT_RULE: &str = "^第[0-9零一二三四五六七八九十百千万两]+[章回节卷部篇集]";

/// What starts a chapter: the importer's own idea, or a rule the reader wrote.
#[derive(Default)]
pub struct Headings(Option<Regex>);

impl Headings {
    /// A rule the reader wrote; the default one, or none, means the importer's own.
    pub fn rule(rule: Option<&str>) -> Result<Headings, regex::Error> {
        match rule.map(str::trim).filter(|r| !r.is_empty() && *r != DEFAULT_RULE) {
            Some(r) => Ok(Headings(Some(Regex::new(r)?))),
            None => Ok(Headings(None)),
        }
    }

    fn is(&self, line: &str) -> bool {
        match &self.0 {
            Some(r) => line.chars().count() <= 60 && r.is_match(line),
            None => is_heading(line),
        }
    }

    fn is_bare(&self, line: &str) -> bool {
        self.0.is_none() && is_bare_heading(line)
    }
}

const CJK_NUMBER: &str = r"[\s　]*[0-9０-９零〇一二三四五六七八九十百千万两]+[\s　]*";
const LATIN_NUMBER: &str = r"(?i:[0-9]+|[ivxlcdm]+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|last)";

static CJK_HEADING: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(&format!(r"^第{CJK_NUMBER}[章回节節卷部篇集幕]([\s　：:．.、]|$)")).unwrap()
});
static CJK_BARE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(&format!(r"^第{CJK_NUMBER}[章回节節卷部篇集幕]$")).unwrap());
static NAMED_HEADING: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^(序章|序言|序|楔子|引子|引言|前言|后记|後記|尾声|尾聲|终章|終章|番外|附录|附錄|跋)([\s　：:].*)?$").unwrap()
});
/// "CHAPTER XII.", "Chapter 3: The Party", "BOOK ONE — THE RIVER", "Prologue". A sentence that
/// merely starts with "Chapter one of…" doesn't match: anything after the number must follow a
/// separator or start with a capital.
static LATIN_HEADING: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(&format!(
        r"^(?:(?i:chapter|book|part|volume|act|canto)\s+{LATIN_NUMBER}(?:[\s-]{LATIN_NUMBER})*|(?i:prologue|epilogue|preface|introduction|afterword|foreword|appendix))\.?(?:\s*[:.\-—–]\s*\S.*|\s+\p{{Lu}}.*)?$"
    ))
    .unwrap()
});
static LATIN_BARE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(&format!(r"^(?i:chapter|book|part|volume)\s+{LATIN_NUMBER}(?:[\s-]{LATIN_NUMBER})*\.?$")).unwrap()
});

pub fn is_heading(line: &str) -> bool {
    let n = line.chars().count();
    if n == 0 || n > 60 {
        return false;
    }
    if CJK_HEADING.is_match(line) || NAMED_HEADING.is_match(line) {
        // "第三章说的是……。" is a sentence, not a heading.
        return n <= 50 && !line.contains(['。', '！', '？']);
    }
    LATIN_HEADING.is_match(line)
}

/// A heading with only its number ("第一章", "CHAPTER I."), whose name may be on the next line.
fn is_bare_heading(line: &str) -> bool {
    CJK_BARE.is_match(line) || LATIN_BARE.is_match(line)
}

static COUPLET_HEADING: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(&format!(r"^(第{CJK_NUMBER}回)[\s　]+(\p{{Han}}{{5,9}})[\s　]+(\p{{Han}}{{5,9}})[\s　]+(\S.*)$")).unwrap()
});

static COUPLET: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^(\p{Han}{5,9})[\s　]+(\p{Han}{5,9})$").unwrap());

/// "賈雨村夤緣复舊職　林黛玉拋父進京都": the name of a chapter in a classical novel, which may
/// be followed directly by the chapter's text.
fn is_couplet(line: &str) -> bool {
    COUPLET.captures(line).is_some_and(|c| c[1].chars().count() == c[2].chars().count())
}

/// Splits text that ran on into a heading line off the heading. Chapter titles of classical
/// novels are couplets of two equal halves ("第三十一回　撕扇子作千金一笑　因麒麟伏白首雙星"), so
/// anything after the second half is the chapter's first words.
fn split_heading(line: &str) -> (String, Option<String>) {
    if let Some(c) = COUPLET_HEADING.captures(line)
        && c[2].chars().count() == c[3].chars().count() {
            return (format!("{} {} {}", collapse_inner(&c[1]), &c[2], &c[3]), Some(c[4].to_string()));
        }
    (collapse_inner(line), None)
}

fn is_decoration(line: &str) -> bool {
    line.chars().count() >= 3
        && line.chars().all(|c| matches!(c, '─' | '—' | '-' | '=' | '*' | '~' | '_' | '·' | '－' | '＝' | '＊' | '※' | ' ' | '　'))
}

/// `Some(true)` for "*** START OF THE PROJECT GUTENBERG EBOOK …", `Some(false)` for its "END".
fn is_gutenberg_marker(line: &str) -> Option<bool> {
    let upper = line.trim_start_matches(['*', ' ']).to_ascii_uppercase();
    if !upper.contains("PROJECT GUTENBERG") {
        return None;
    }
    if upper.starts_with("START OF") {
        Some(true)
    } else if upper.starts_with("END OF") {
        Some(false)
    } else {
        None
    }
}

fn trim(line: &str) -> &str {
    line.trim_matches(|c: char| c.is_whitespace() || c == '\u{FEFF}')
}

fn indent(line: &str) -> usize {
    line.chars().take_while(|c| c.is_whitespace()).map(|c| if c == '\u{3000}' { 2 } else { 1 }).sum()
}

fn width(s: &str) -> usize {
    s.chars().map(|c| if is_wide(c) { 2 } else { 1 }).sum()
}

/// How the lines of a file are laid out.
struct Layout {
    /// The width hard-wrapped lines were wrapped at, if the file is hard-wrapped at all. Files
    /// with one paragraph per line have wildly varying line widths and no such width.
    wrap: Option<usize>,
    /// The indent of continuation lines; paragraphs start indented further.
    base_indent: usize,
}

impl Layout {
    fn of(lines: &[&str]) -> Layout {
        let body: Vec<&str> = lines.iter().copied().filter(|l| !trim(l).is_empty()).collect();
        if body.len() < 20 {
            return Layout { wrap: None, base_indent: 0 };
        }
        let mut widths: Vec<usize> = body.iter().map(|l| width(l.trim_end())).collect();
        widths.sort_unstable();
        let w = widths[widths.len() * 9 / 10];
        let full = widths.iter().filter(|&&x| x * 100 >= w * 85).count();
        let mut indents: Vec<usize> = body.iter().map(|l| indent(l)).collect();
        indents.sort_unstable();
        // When (nearly) every line starts with the same indent, every line starts a paragraph.
        let mut common = (0, 0);
        for run in indents.chunk_by(|a, b| a == b) {
            if run.len() > common.1 {
                common = (run[0], run.len());
            }
        }
        let every_line_indented = common.0 > 0 && common.1 * 10 >= body.len() * 8;
        // Hard wrapping happens at 60–80 columns; most lines then sit near the maximum.
        let wrapped = w <= 200 && full * 100 >= body.len() * 35 && !every_line_indented;
        Layout { wrap: wrapped.then_some(w), base_indent: indents[indents.len() / 20] }
    }

    fn is_full(&self, raw: &str) -> bool {
        self.wrap.is_some_and(|w| width(raw.trim_end()) * 10 >= w * 8)
    }
}

/// A text file read one way: in an encoding, with a chapter rule.
pub struct Analysis {
    pub decoded: Decoded,
    pub book: TextBook,
    /// Each chapter's title, length in characters with its parts put back together, and the
    /// section it starts.
    pub outline: Vec<(Option<String>, usize, usize)>,
    /// The chapter in `outline` that is far longer than the rest: a heading the rule missed.
    pub long: Option<usize>,
    /// Why the result may be wrong, to point the reader at 编码和目录.
    pub doubt: Option<String>,
}

pub fn analyze(bytes: &[u8], encoding: Option<&'static Encoding>, headings: &Headings) -> Analysis {
    let decoded = decode_as(bytes, encoding);
    let book = structure_with(&decoded.text, headings);
    let mut outline: Vec<(Option<String>, usize, usize)> = Vec::new();
    for (i, ch) in book.chapters.iter().enumerate() {
        let n = ch.paragraphs.iter().map(|p| p.chars().count()).sum::<usize>();
        match outline.last_mut() {
            Some(last) if ch.continued => last.1 += n,
            _ => outline.push((ch.title.clone(), n, i)),
        }
    }
    let long = long_chapter(&outline);
    let chars = decoded.text.chars().count();
    let titled = outline.iter().filter(|(t, _, _)| t.is_some()).count();
    let doubt = if decoded.errors >= 20 || decoded.errors * 1000 > chars {
        Some(crate::i18n::tr("有些字没认出来，可能是编码不对", "Some characters weren't recognized; the encoding may be wrong"))
    } else if chars >= 50_000 && titled <= 1 {
        Some(crate::i18n::tr("没认出章节，目录可能不对", "No chapters were found; the contents may be wrong"))
    } else {
        long.map(|_| crate::i18n::tr("有一章长得不正常，可能漏了章节", "One chapter is unusually long; some chapters may be missing"))
    };
    Analysis { decoded, book, outline, long, doubt }
}

/// A chapter two and a half times as long as the usual one, and long in itself.
fn long_chapter(outline: &[(Option<String>, usize, usize)]) -> Option<usize> {
    if outline.len() < 5 {
        return None;
    }
    let mut sizes: Vec<usize> = outline.iter().map(|(_, n, _)| *n).collect();
    sizes.sort_unstable();
    let median = sizes[sizes.len() / 2];
    let (i, &(_, n, _)) = outline.iter().enumerate().max_by_key(|(_, (_, n, _))| *n)?;
    (n >= 8_000 && n * 2 >= median * 5).then_some(i)
}

/// Finds the title, author, paragraphs and chapters of a text file.
pub fn structure(text: &str) -> TextBook {
    structure_with(text, &Headings::default())
}

pub fn structure_with(text: &str, headings: &Headings) -> TextBook {
    let text = text.replace("\r\n", "\n").replace('\r', "\n");
    let lines: Vec<&str> = text.split('\n').collect();
    let (title, author, start) = front_matter(&lines, headings);
    let mut chapters = chapters_from(&lines, start, headings);
    if chapters.len() == 1 && chapters[0].title.is_none() {
        chapters[0].title = title.clone();
    }
    TextBook { title, author, language: guess_language(&text), chapters }
}

/// Paragraphs and chapters only, for text whose title is known from elsewhere.
pub fn chapters(text: &str) -> Vec<Chapter> {
    let text = text.replace("\r\n", "\n").replace('\r', "\n");
    let lines: Vec<&str> = text.split('\n').collect();
    chapters_from(&lines, 0, &Headings::default())
}

fn chapters_from(lines: &[&str], start: usize, headings: &Headings) -> Vec<Chapter> {
    let layout = Layout::of(lines);

    let mut chapters = vec![Chapter::default()];
    let mut para: Option<String> = None;
    let mut prev_full = false;
    // The chapter just started with a bare "第一章"; its name may follow on its own line.
    let mut bare_heading = false;

    fn end_para(para: &mut Option<String>, chapters: &mut [Chapter]) {
        if let Some(p) = para.take() {
            chapters.last_mut().unwrap().paragraphs.push(p);
        }
    }

    for (i, raw) in lines.iter().enumerate().skip(start) {
        let line = trim(raw);
        if line.is_empty() {
            end_para(&mut para, &mut chapters);
            prev_full = false;
            continue;
        }
        if headings.is(line) {
            end_para(&mut para, &mut chapters);
            let (title, rest) = split_heading(line);
            chapters.push(Chapter { title: Some(title), ..Default::default() });
            // Text that ran on into the heading line continues on the next line.
            prev_full = rest.is_some();
            para = rest;
            bare_heading = headings.is_bare(line);
            continue;
        }
        if let Some(starting) = is_gutenberg_marker(line) {
            // Project Gutenberg's licence header and footer become sections of their own.
            end_para(&mut para, &mut chapters);
            if !starting {
                chapters.push(Chapter::default());
            }
            chapters.last_mut().unwrap().paragraphs.push(line.to_string());
            if starting {
                chapters.push(Chapter::default());
            }
            prev_full = false;
            bare_heading = false;
            continue;
        }
        if is_decoration(line) {
            end_para(&mut para, &mut chapters);
            let current = chapters.last_mut().unwrap();
            if current.paragraphs.last().is_some_and(|p| p != SCENE_BREAK) {
                current.paragraphs.push(SCENE_BREAK.into());
            }
            prev_full = false;
            continue;
        }
        if bare_heading {
            bare_heading = false;
            // The name stands alone: the text starts after a blank or a new indented paragraph.
            let stands_alone = lines.get(i + 1).is_none_or(|next| {
                let t = trim(next);
                t.is_empty() || is_decoration(t) || headings.is(t) || indent(next) > layout.base_indent
            });
            let ends_sentence = line.ends_with(['。', '！', '？', '，', '；', '：', '.', '!', '?', ',', ';', ':']);
            if para.is_none() && (stands_alone || is_couplet(line)) && width(line) <= 60 && !ends_sentence {
                if let Some(t) = &mut chapters.last_mut().unwrap().title {
                    t.push(' ');
                    t.push_str(&collapse_inner(line));
                }
                continue;
            }
        }
        let continues = para.is_some() && prev_full && indent(raw) <= layout.base_indent;
        if continues {
            let p = para.as_mut().unwrap();
            let last = p.chars().last().unwrap_or(' ');
            let first = line.chars().next().unwrap_or(' ');
            if !(is_wide(last) || is_wide(first)) {
                p.push(' ');
            }
            p.push_str(line);
        } else {
            end_para(&mut para, &mut chapters);
            para = Some(line.to_string());
        }
        prev_full = layout.is_full(raw);
    }
    end_para(&mut para, &mut chapters);

    chapters.retain(|c| c.title.is_some() || !c.paragraphs.is_empty());
    // A heading repeated after a separator line: keep the one with the text.
    let mut i = 0;
    while i + 1 < chapters.len() {
        if chapters[i].paragraphs.is_empty() && chapters[i].title == chapters[i + 1].title {
            chapters.remove(i);
        } else {
            i += 1;
        }
    }
    for c in &mut chapters {
        if c.paragraphs.last().is_some_and(|p| p == SCENE_BREAK) {
            c.paragraphs.pop();
        }
    }
    drop_contents_lists(&mut chapters);
    chapters.into_iter().flat_map(split_long).collect()
}

const TITLE_LABELS: &[&str] = &["书名", "書名", "Title"];
const AUTHOR_LABELS: &[&str] = &["作者", "著者", "Author"];

/// "作者：曹雪芹" → "曹雪芹".
fn labelled<'a>(line: &'a str, labels: &[&str]) -> Option<&'a str> {
    let rest = labels.iter().find_map(|l| line.strip_prefix(l))?;
    let value = trim(rest.trim_start().strip_prefix([':', '：'])?);
    (!value.is_empty()).then_some(value)
}

/// Title and author: labelled lines near the top ("书名：…", Gutenberg's "Title: …"), or a short
/// first line followed by a short name. Returns the index of the first line after them.
fn front_matter(lines: &[&str], headings: &Headings) -> (Option<String>, Option<String>, usize) {
    let mut title = None;
    let mut author = None;
    for line in lines.iter().take(100).map(|l| trim(l)) {
        if title.is_none() {
            title = labelled(line, TITLE_LABELS).map(|v| v.trim_matches(['《', '》']).to_string());
        }
        if author.is_none() {
            author = labelled(line, AUTHOR_LABELS).map(str::to_string);
        }
    }
    let mut start = 0;
    let mut seen = 0;
    for (i, raw) in lines.iter().enumerate() {
        let line = trim(raw);
        if line.is_empty() {
            continue;
        }
        seen += 1;
        let consumed = if labelled(line, TITLE_LABELS).is_some() || labelled(line, AUTHOR_LABELS).is_some() {
            true
        } else if seen == 1
            && title.is_none()
            && !headings.is(line)
            && line.chars().count() <= 30
            && !line.ends_with(['。', '！', '？', '，', '.', '!', '?', ','])
        {
            title = Some(line.trim_matches(['《', '》']).to_string());
            true
        } else if seen == 2 && start > 0 && author.is_none() && !headings.is(line) {
            let name = line.strip_prefix("by ").or_else(|| line.strip_prefix("By ")).unwrap_or(line);
            let is_name = looks_like_name(name) || (name.len() < line.len() && name.len() <= 40);
            if is_name {
                author = Some(name.to_string());
            }
            is_name
        } else {
            false
        };
        if !consumed {
            break;
        }
        start = i + 1;
        if seen >= 6 {
            break;
        }
    }
    (title, author, start)
}

fn looks_like_name(s: &str) -> bool {
    let n = s.chars().count();
    (2..=6).contains(&n) && s.chars().all(|c| is_cjk(c) || c == '·')
}

fn collapse_inner(s: &str) -> String {
    let mut out = String::new();
    let mut space = false;
    for c in s.chars() {
        if c.is_whitespace() {
            space = !out.is_empty();
        } else {
            if space {
                out.push(' ');
                space = false;
            }
            out.push(c);
        }
    }
    out
}

/// Web-novel TXTs often start with their own table of contents: many headings in a row with
/// nothing between them. Those aren't chapters.
fn drop_contents_lists(chapters: &mut Vec<Chapter>) {
    let mut i = 0;
    while i < chapters.len() {
        let mut j = i;
        while j < chapters.len() && chapters[j].paragraphs.is_empty() && chapters[j].title.is_some() {
            j += 1;
        }
        if j - i >= 3 {
            chapters.drain(i..j);
        } else {
            i = j.max(i + 1);
        }
    }
}

fn split_long(ch: Chapter) -> Vec<Chapter> {
    let total: usize = ch.paragraphs.iter().map(|p| p.chars().count()).sum();
    if total <= MAX_SECTION_CHARS {
        return vec![ch];
    }
    let mut parts = vec![Chapter { title: ch.title.clone(), ..Default::default() }];
    let mut size = 0;
    for p in ch.paragraphs {
        let n = p.chars().count();
        if size + n > PART_CHARS && size > 0 {
            parts.push(Chapter { title: ch.title.clone(), continued: true, ..Default::default() });
            size = 0;
        }
        size += n;
        parts.last_mut().unwrap().paragraphs.push(p);
    }
    parts
}

/// The body for one chapter: `<h2 class="yy-title">` and one `<p>` per paragraph.
pub fn chapter_body(ch: &Chapter) -> Element {
    let mut body = Element::new("body");
    if let Some(t) = ch.title.as_ref().filter(|_| !ch.continued) {
        body.children.push(Node::Element(Element::new("h2").with_attr("class", "yy-title").with_text(t.clone())));
    }
    for p in &ch.paragraphs {
        let mut el = Element::new("p");
        if p == SCENE_BREAK {
            el.set_attr("class", "yy-break");
        }
        body.children.push(Node::Element(el.with_text(p.clone())));
    }
    body
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_gbk_and_utf8() {
        let gbk = std::fs::read(concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures/books/beiying-gbk.txt")).unwrap();
        let utf8 = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures/books/beiying.txt")).unwrap();
        let text = decode(&gbk);
        assert!(text.starts_with("背影"));
        assert!(text.contains("我与父亲不相见已二年馀了"));
        let a = structure(&text);
        let b = structure(&utf8);
        assert_eq!(a.title.as_deref(), Some("背影"));
        assert_eq!(b.title.as_deref(), Some("背影"));
        assert_eq!(b.author.as_deref(), Some("朱自清"));
        assert_eq!(a.chapters, b.chapters);
        assert_eq!(b.chapters.len(), 1);
        assert_eq!(b.chapters[0].title.as_deref(), Some("背影"));
        assert_eq!(b.chapters[0].paragraphs.len(), 6);
        assert_eq!(a.language, "zh");
    }

    #[test]
    fn decodes_utf16_with_bom() {
        let mut bytes = vec![0xFF, 0xFE];
        for u in "第一章 开始\n正文。".encode_utf16() {
            bytes.extend_from_slice(&u.to_le_bytes());
        }
        assert_eq!(decode(&bytes), "第一章 开始\n正文。");
    }

    #[test]
    fn headings() {
        assert!(is_heading("第一回\u{3000}甄士隱夢幻識通靈\u{3000}賈雨村風塵怀閨秀"));
        assert!(is_heading("第十四回　　林如海捐館揚州城　賈寶玉路謁北靜王"));
        assert!(is_heading("第 3 章 风起"));
        assert!(is_heading("楔子"));
        assert!(is_heading("CHAPTER XII."));
        assert!(is_heading("Chapter 1"));
        assert!(is_heading("Chapter 3: The Party"));
        assert!(is_heading("BOOK TWENTY-ONE"));
        assert!(is_heading("Chapter XII.—The Return"));
        assert!(is_heading("Prologue"));
        assert!(!is_heading("第三章说的是一件旧事。"));
        assert!(!is_heading("Chapters are long, he said."));
        assert!(!is_heading("Chapter one of my life began in a small town."));
        assert!(!is_heading("Part of the problem was the weather."));
        assert!(!is_heading("Book of the Dead"));
    }

    #[test]
    fn hard_wrapped_chinese_with_chapters() {
        let line = "　　".to_string() + &"字".repeat(30);
        let cont = "字".repeat(33);
        let mut text = String::from("第一回　甄士隱夢幻識通靈\n————————————\n");
        for _ in 0..12 {
            text += &format!("{line}\n{cont}\n{cont}\n短的一行．\n");
        }
        text += "第二回　賈夫人仙逝揚州城\n";
        for _ in 0..12 {
            text += &format!("{line}\n{cont}\n短的．\n");
        }
        let book = structure(&text);
        assert_eq!(book.chapters.len(), 2);
        assert_eq!(book.chapters[0].title.as_deref(), Some("第一回 甄士隱夢幻識通靈"));
        assert_eq!(book.chapters[0].paragraphs.len(), 12);
        assert_eq!(book.chapters[0].paragraphs[0].chars().count(), 30 + 33 + 33 + 5);
        assert_eq!(book.chapters[1].paragraphs.len(), 12);
    }

    #[test]
    fn one_paragraph_per_line() {
        let mut text = String::from("第一章 风起\n");
        for i in 0..40 {
            text += &format!("　　{}。\n", "字".repeat(20 + (i * 7) % 60));
        }
        let book = structure(&text);
        assert_eq!(book.chapters.len(), 1);
        assert_eq!(book.chapters[0].paragraphs.len(), 40);
    }

    #[test]
    fn english_blank_line_paragraphs() {
        let mut text = String::new();
        for i in 0..10 {
            text += &format!("CHAPTER {}\n\n", i + 1);
            for _ in 0..3 {
                text += "It is a truth universally acknowledged, that a single man in\npossession of a good fortune, must be in want of a wife.\n\n";
            }
        }
        let book = structure(&text);
        assert_eq!(book.language, "en");
        assert_eq!(book.chapters.len(), 10);
        assert_eq!(book.chapters[0].paragraphs.len(), 3);
        assert!(book.chapters[0].paragraphs[0].contains("single man in possession"));
    }

    #[test]
    fn gutenberg_header_and_chapter_names() {
        let text = "The Project Gutenberg eBook of Alice's Adventures in Wonderland\n\n\
            Title: Alice's Adventures in Wonderland\n\nAuthor: Lewis Carroll\n\n\
            *** START OF THE PROJECT GUTENBERG EBOOK ALICE'S ADVENTURES IN WONDERLAND ***\n\n\
            CHAPTER I.\n\nDown the Rabbit-Hole\n\n\
            Alice was beginning to get very tired of sitting by her sister on the\nbank.\n\n\
            CHAPTER II.\nThe Pool of Tears\n\n“Curiouser and curiouser!” cried Alice.\n\n\
            *** END OF THE PROJECT GUTENBERG EBOOK ALICE'S ADVENTURES IN WONDERLAND ***\n\nLicence text.\n";
        let book = structure(text);
        assert_eq!(book.title.as_deref(), Some("Alice's Adventures in Wonderland"));
        assert_eq!(book.author.as_deref(), Some("Lewis Carroll"));
        let titles: Vec<_> = book.chapters.iter().map(|c| c.title.as_deref()).collect();
        assert_eq!(
            titles,
            vec![None, Some("CHAPTER I. Down the Rabbit-Hole"), Some("CHAPTER II. The Pool of Tears"), None]
        );
        assert!(book.chapters[0].paragraphs.last().unwrap().starts_with("*** START"));
        assert!(book.chapters[3].paragraphs[0].starts_with("*** END"));
    }

    #[test]
    fn labelled_front_matter() {
        let text = "书名：《三体》\n作者：刘慈欣\n\n第一章 科学边界\n正文。\n";
        let book = structure(text);
        assert_eq!(book.title.as_deref(), Some("三体"));
        assert_eq!(book.author.as_deref(), Some("刘慈欣"));
        assert_eq!(book.chapters.len(), 1);
        assert_eq!(book.chapters[0].title.as_deref(), Some("第一章 科学边界"));
        // A bare heading's name on the next line joins it, but the first sentence doesn't.
        let book = structure("红楼梦\n第一回\n\n甄士隐梦幻识通灵\n\n第二回\n\n他来了。\n");
        assert_eq!(book.author, None);
        let titles: Vec<_> = book.chapters.iter().map(|c| c.title.clone().unwrap()).collect();
        assert_eq!(titles, vec!["第一回 甄士隐梦幻识通灵", "第二回"]);
    }

    #[test]
    fn classical_novel_headings() {
        let wrapped = |s: &str| format!("{s}\n");
        let mut text = String::new();
        // A bare number, separator lines, then the couplet on its own line.
        text += "第三回\n\n\n————————————————\n\n———-\n\n　　　　　　　　 賈雨村夤緣复舊職　林黛玉拋父進京都\n\n\n";
        text += &wrapped("　　卻說雨村忙回頭看時，不是別人，乃是當日同僚一案參革的號張如圭者．");
        // The couplet followed directly by text that isn't indented.
        text += "第八回\n————\n比通靈金鶯微露意　探寶釵黛玉半含酸\n話說鳳姐和寶玉回家．\n";
        // The first words of the chapter ran on into the heading line.
        text += "第三十一回　 撕扇子作千金一笑　因麒麟伏白首雙星　話\n說端陽佳節．\n";
        // The same heading twice around a separator.
        text += "第四十五回　 金蘭契互剖金蘭語　風雨夕悶制風雨詞\n————————\n\n\n第四十五回　 金蘭契互剖金蘭語　風雨夕悶制風雨詞\n\n　　話說鳳姐兒正撫恤平兒．\n";
        let chapters = chapters(&text);
        let titles: Vec<_> = chapters.iter().map(|c| c.title.clone().unwrap()).collect();
        assert_eq!(
            titles,
            vec![
                "第三回 賈雨村夤緣复舊職 林黛玉拋父進京都",
                "第八回 比通靈金鶯微露意 探寶釵黛玉半含酸",
                "第三十一回 撕扇子作千金一笑 因麒麟伏白首雙星",
                "第四十五回 金蘭契互剖金蘭語 風雨夕悶制風雨詞",
            ]
        );
        assert_eq!(chapters[1].paragraphs, vec!["話說鳳姐和寶玉回家．"]);
        assert_eq!(chapters[2].paragraphs, vec!["話說端陽佳節．"]);
        assert_eq!(chapters[3].paragraphs.len(), 1);
    }

    #[test]
    fn contents_list_is_dropped() {
        let text = "我的书\n第一章 开始\n第二章 经过\n第三章 结束\n\n第一章 开始\n正文一。\n第二章 经过\n正文二。\n第三章 结束\n正文三。\n";
        let book = structure(text);
        assert_eq!(book.title.as_deref(), Some("我的书"));
        let titles: Vec<_> = book.chapters.iter().map(|c| c.title.clone().unwrap()).collect();
        assert_eq!(titles, vec!["第一章 开始", "第二章 经过", "第三章 结束"]);
    }

    #[test]
    fn long_chapters_are_split() {
        let para = "长".repeat(1000);
        let text = format!("第一章 很长\n{}", (0..100).map(|_| format!("{para}\n")).collect::<String>());
        let book = structure(&text);
        assert!(book.chapters.len() >= 3);
        assert_eq!(book.chapters[0].title.as_deref(), Some("第一章 很长"));
        assert!(!book.chapters[0].continued);
        assert!(book.chapters[1].continued);
        assert_eq!(book.chapters[1].title.as_deref(), Some("第一章 很长"));
        assert!(!chapter_body(&book.chapters[1]).find(&|e| e.is("h2")).is_some());
    }
}
