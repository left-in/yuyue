//! Sentence segmentation: ICU's UAX #29 rules, plus fixes for abbreviations, sentences that
//! continue in lowercase after a quote, stray punctuation, and sentences too long to highlight
//! or speak comfortably.

use icu_segmenter::SentenceSegmenter;
use icu_segmenter::options::SentenceBreakInvariantOptions;

use crate::text::{is_speakable, looks_cjk};

/// Longest sentence before it's split at ；：，, in characters (CJK) or bytes (other scripts).
const MAX_CJK: usize = 80;
const MIN_CJK: usize = 12;
const MAX_LATIN: usize = 300;
const MIN_LATIN: usize = 40;

const ABBREVIATIONS: &[&str] = &[
    "mr", "mrs", "ms", "messrs", "mme", "mlle", "dr", "st", "jr", "sr", "prof", "rev", "hon", "gen",
    "col", "capt", "cmdr", "lt", "sgt", "maj", "gov", "pres", "mt", "ft", "no", "nos", "vol", "vols",
    "p", "pp", "ch", "chap", "fig", "figs", "ed", "eds", "vs", "viz", "cf", "al", "approx", "dept",
    "est", "inc", "ltd", "co", "corp", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept",
    "oct", "nov", "dec",
];

/// Byte ranges of the sentences in `text`, trimmed of surrounding whitespace. Every range
/// contains at least one letter, digit or CJK character.
pub fn sentences(text: &str) -> Vec<(usize, usize)> {
    let segmenter = SentenceSegmenter::new(SentenceBreakInvariantOptions::default());
    let breaks: Vec<usize> = segmenter.segment_str(text).collect();

    // Undo breaks after abbreviations and before lowercase continuations.
    let mut merged: Vec<(usize, usize)> = Vec::new();
    for w in breaks.windows(2) {
        let (s, e) = (w[0], w[1]);
        if let Some(last) = merged.last_mut() {
            let prev = &text[last.0..last.1];
            let starts_lower = text[s..e].trim_start().chars().next().is_some_and(|c| c.is_lowercase());
            if ends_with_abbreviation(prev) || starts_lower {
                last.1 = e;
                continue;
            }
        }
        merged.push((s, e));
    }

    // Attach pieces with nothing to say ("……", "”", "* * *") to a neighbour.
    let mut attached: Vec<(usize, usize)> = Vec::new();
    let mut carry: Option<usize> = None;
    for (s, e) in merged {
        let speakable = text[s..e].chars().any(is_speakable);
        match (speakable, attached.last_mut()) {
            (false, Some(last)) => last.1 = e,
            (false, None) => carry = Some(carry.unwrap_or(s)),
            (true, _) => attached.push((carry.take().unwrap_or(s), e)),
        }
    }

    let mut out = Vec::new();
    for (s, e) in attached {
        if let Some(r) = trim(text, s, e) {
            split_long(text, r, &mut out);
        }
    }
    out
}

/// A sentence on a PDF page: where it is in the page's text, counted in UTF-16 units as the
/// system's PDF page counts them, and the words to say, its line breaks undone.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct PageSentence {
    pub start: u32,
    pub end: u32,
    pub text: String,
}

/// The sentences of a PDF page's text. A line break is where the printed line ran out, not
/// where a sentence stops, so lines are read as one run; an empty line still ends a paragraph,
/// and so does a short line that doesn't stop on a comma (a heading, a paragraph's last line).
/// A word broken over two lines with a hyphen is put back together for speech.
#[uniffi::export]
pub fn page_sentences(text: String) -> Vec<PageSentence> {
    // Same length, so the ranges found in it are ranges in `text`. A run of line breaks
    // holding one break ("\n", "\r" or "\r\n") becomes spaces; a longer run stays.
    let width = |l: &str| l.trim().chars().map(|c| if crate::text::is_wide(c) { 2 } else { 1 }).sum::<usize>();
    let widest = text.lines().map(width).max().unwrap_or(0);
    let short_line = |before: &str, widest: usize| {
        let line = before.rsplit(['\n', '\r']).next().unwrap_or("").trim();
        let last = line.chars().last();
        widest >= 20
            && !line.is_empty()
            && width(line) * 10 < widest * 6
            && !last.is_some_and(|c| matches!(c, '，' | ',' | '、' | '；' | ';' | '：' | ':' | '-'))
    };
    let mut flat = text.clone().into_bytes();
    let mut i = 0;
    while i < flat.len() {
        if !matches!(flat[i], b'\n' | b'\r') {
            i += 1;
            continue;
        }
        let start = i;
        while i < flat.len() && matches!(flat[i], b'\n' | b'\r') {
            i += 1;
        }
        if (&flat[start..i] == b"\r\n" || i - start == 1) && !short_line(&text[..start], widest) {
            flat[start..i].fill(b' ');
        }
    }
    let flat = String::from_utf8(flat).unwrap_or_default();
    let units = |b: usize| text[..b].encode_utf16().count() as u32;
    sentences(&flat)
        .into_iter()
        .map(|(s, e)| PageSentence { start: units(s), end: units(e), text: spoken(&text[s..e]) })
        .collect()
}

/// A sentence's lines put back into one: nothing between Chinese, a space between words, and
/// "exam-" + "ple" as "example".
fn spoken(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for line in s.split(['\n', '\r', '\u{2028}']).map(str::trim).filter(|l| !l.is_empty()) {
        match (out.chars().last(), line.chars().next()) {
            (Some('-'), Some(n)) if n.is_lowercase() && out.chars().rev().nth(1).is_some_and(char::is_alphabetic) => {
                out.pop();
            }
            (Some(p), Some(n)) if !crate::text::joins_without_space(p, n) => out.push(' '),
            _ => {}
        }
        out.push_str(line);
    }
    out
}

fn ends_with_abbreviation(s: &str) -> bool {
    let token = s.trim_end().rsplit(char::is_whitespace).next().unwrap_or("");
    let token = token.trim_start_matches(|c: char| !c.is_alphanumeric());
    let Some(word) = token.strip_suffix('.') else { return false };
    if word.is_empty() {
        return false;
    }
    // Initials: "J." Multi-dot abbreviations: "e.g.", "U.S."
    let mut chars = word.chars();
    if let (Some(c), None) = (chars.next(), chars.next()) {
        if c.is_uppercase() {
            return true;
        }
    }
    if word.contains('.') && word.split('.').all(|p| p.chars().count() == 1) {
        return true;
    }
    ABBREVIATIONS.contains(&word.to_lowercase().as_str())
}

fn trim(text: &str, s: usize, e: usize) -> Option<(usize, usize)> {
    let piece = &text[s..e];
    let is_space = |c: char| c.is_whitespace();
    let lead = piece.len() - piece.trim_start_matches(is_space).len();
    let tail = piece.len() - piece.trim_end_matches(is_space).len();
    if lead + tail >= piece.len() { None } else { Some((s + lead, e - tail)) }
}

fn length(s: &str, cjk: bool) -> usize {
    if cjk { s.chars().count() } else { s.len() }
}

const CLOSERS: &[char] = &['”', '’', '」', '』', '）', ')', '"', '\'', '》'];

fn split_long(text: &str, (s, e): (usize, usize), out: &mut Vec<(usize, usize)>) {
    let piece = &text[s..e];
    let cjk = looks_cjk(piece);
    let (max, min) = if cjk { (MAX_CJK, MIN_CJK) } else { (MAX_LATIN, MIN_LATIN) };
    let total = length(piece, cjk);
    if total <= max {
        out.push((s, e));
        return;
    }
    let classes: [&[char]; 3] = [&['；', ';'], &['：', ':'], &['，', ',']];
    for class in classes {
        let mut best: Option<(usize, usize)> = None; // (distance from middle, split offset)
        for (i, c) in piece.char_indices() {
            if !class.contains(&c) {
                continue;
            }
            let mut j = i + c.len_utf8();
            // ASCII punctuation only counts when followed by a space ("3:30", "1,000").
            if c.is_ascii() && !piece[j..].starts_with(char::is_whitespace) {
                continue;
            }
            while let Some(n) = piece[j..].chars().next().filter(|n| CLOSERS.contains(n)) {
                j += n.len_utf8();
            }
            let left = length(&piece[..j], cjk);
            if left < min || total - left < min {
                continue;
            }
            let distance = left.abs_diff(total / 2);
            if best.is_none_or(|(d, _)| distance < d) {
                best = Some((distance, j));
            }
        }
        if let Some((_, j)) = best {
            for (a, b) in [(s, s + j), (s + j, e)] {
                if let Some(r) = trim(text, a, b) {
                    split_long(text, r, out);
                }
            }
            return;
        }
    }
    out.push((s, e));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn split(text: &str) -> Vec<&str> {
        sentences(text).into_iter().map(|(s, e)| &text[s..e]).collect()
    }

    #[test]
    fn chinese() {
        assert_eq!(
            split("他说：“我买几个橘子去。你就在此地，不要走动。”我看那边月台的栅栏外有几个卖东西的等着顾客。"),
            vec!["他说：“我买几个橘子去。", "你就在此地，不要走动。”", "我看那边月台的栅栏外有几个卖东西的等着顾客。"]
        );
        assert_eq!(split("真的吗？！是的……"), vec!["真的吗？！", "是的……"]);
        assert_eq!(split("事務．惟恐各誥命來往．"), vec!["事務．", "惟恐各誥命來往．"]);
    }

    #[test]
    fn english() {
        assert_eq!(
            split("Mr. Bennet met Dr. Jones at 3.30 p.m. on St. James Street. “Is he married?” she asked. “Oh! single, my dear, to be sure!”"),
            vec![
                "Mr. Bennet met Dr. Jones at 3.30 p.m. on St. James Street.",
                "“Is he married?” she asked.",
                "“Oh! single, my dear, to be sure!”"
            ]
        );
        assert_eq!(split("J. K. Rowling wrote it. E.g. this one."), vec!["J. K. Rowling wrote it.", "E.g. this one."]);
    }

    #[test]
    fn punctuation_only_pieces_attach() {
        assert_eq!(split("* * *"), Vec::<&str>::new());
        assert_eq!(split("“……” 他说完了。"), vec!["“……” 他说完了。"]);
        assert_eq!(split("Line one\nLine two"), vec!["Line one", "Line two"]);
    }

    #[test]
    fn long_sentences_split_at_commas() {
        let s = "他一面走，一面想，想到家里的光景，想到父亲的差使，想到祖母的丧事，想到自己将要远行，\
                 想到这一路上的种种，想到许多说不出的心事，心里便觉得沉甸甸的，脚下也越走越慢了。";
        let parts = split(s);
        assert!(parts.len() >= 2, "{parts:?}");
        assert!(parts.iter().all(|p| p.chars().count() <= MAX_CJK));
        assert_eq!(parts.concat(), s);
        assert!(parts[0].ends_with('，'));
    }

    #[test]
    fn semicolons_win_over_commas() {
        let a = "甲".repeat(30);
        let b = "乙".repeat(30);
        let s = format!("{a}，{a}；{b}，{b}。");
        let parts = split(&s);
        assert_eq!(parts, vec![format!("{a}，{a}；"), format!("{b}，{b}。")]);
    }

    #[test]
    fn pdf_headings_stand_alone() {
        let text = "第二章 夏\n夏天的雨来得快，去得也快。荷塘里的叶子出水很高，\n像亭亭的舞女的裙。层层的叶子中间，零星地点缀着些\n白花。";
        let said: Vec<String> = page_sentences(text.into()).into_iter().map(|s| s.text).collect();
        assert_eq!(said, vec!["第二章 夏", "夏天的雨来得快，去得也快。", "荷塘里的叶子出水很高，像亭亭的舞女的裙。", "层层的叶子中间，零星地点缀着些白花。"]);
    }

    #[test]
    fn pdf_windows_line_ends() {
        let said: Vec<String> = page_sentences("One line\r\nand more.\r\n\r\nNext one.".into()).into_iter().map(|s| s.text).collect();
        assert_eq!(said, vec!["One line and more.", "Next one."]);
    }

    #[test]
    fn pdf_lines_run_together() {
        let text = "The quick brown fox jumps over the lazy dog and keeps on run-\nning. Then it stops.\n\n第二段的文字写得很长很长很长很长很长很长\n接着写完。下一句。";
        let found = page_sentences(text.to_string());
        let said: Vec<&str> = found.iter().map(|s| s.text.as_str()).collect();
        assert_eq!(said, vec!["The quick brown fox jumps over the lazy dog and keeps on running.", "Then it stops.", "第二段的文字写得很长很长很长很长很长很长接着写完。", "下一句。"]);
        // The ranges count UTF-16 units of the page's own text.
        let utf16: Vec<u16> = text.encode_utf16().collect();
        let third = &found[2];
        assert_eq!(String::from_utf16(&utf16[third.start as usize..third.end as usize]).unwrap(), "第二段的文字写得很长很长很长很长很长很长\n接着写完。");
    }
}
