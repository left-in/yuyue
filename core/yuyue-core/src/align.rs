//! 听读对齐: a recording of a book (an audiobook) laid against the book's sentences, so the voice
//! can be the narrator's and the ink line still knows where it is.
//!
//! The app transcribes the recording on the device and hands over what it heard, word by word
//! with times. Both sides become the same kind of units — a CJK character each, a Latin word
//! each, punctuation and spacing dropped — and are matched: first on runs of units that occur
//! once on each side, kept only where they run forwards together, then again inside the gaps
//! between them with shorter runs, and small gaps by a full comparison. Mishearings and the
//! narrator's slips cost a few units, not the place.
//!
//! Each sentence then gets the stretch of the recording it was read in. One the recording skips
//! has none, and the app reads it with a system voice instead (录音里没有); one heard only in
//! part is marked as such, so the app can ask for a look (对得不准).

use std::collections::HashMap;
use std::hash::{Hash, Hasher};

use crate::api::YuyueCore;
use crate::error::Result;

/// A word the transcriber heard, with when, in seconds from the start of the whole recording.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct HeardWord {
    pub text: String,
    pub start: f64,
    pub end: f64,
}

/// Where a sentence of the book was read, in seconds from the start of the whole recording.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct SentenceTime {
    pub section: u32,
    pub sentence: u32,
    /// Negative when the recording doesn't have it.
    pub start: f64,
    pub end: f64,
    /// How much of it was heard, 0–1; a sentence with nothing to say counts as heard.
    pub heard: f32,
}

/// How well a chapter came out.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct SectionFit {
    pub section: u32,
    pub sentences: u32,
    /// Share of its words found in the recording, 0–1.
    pub heard: f32,
    /// Sentences the recording doesn't have.
    pub missing: u32,
    /// Sentences only partly heard, whose times are partly guessed.
    pub unsure: u32,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct Alignment {
    pub sentences: Vec<SentenceTime>,
    pub sections: Vec<SectionFit>,
    /// Seconds of recording before the book's first words: an announcer, music (片头).
    pub intro: f64,
    /// Seconds a unit (a character, a word) takes to say, on average.
    pub unit_seconds: f64,
}

/// A sentence that counts as only partly heard.
pub const UNSURE_BELOW: f32 = 0.5;

#[uniffi::export]
impl YuyueCore {
    /// Lays what was heard in a recording of the book against its sentences. `heard` may cover
    /// only the start of the recording, while it is still being transcribed; the sentences after
    /// it then come back as not in the recording.
    pub fn align_recording(&self, book_id: String, heard: Vec<HeardWord>) -> Result<Alignment> {
        let dir = self.book_dir(&book_id)?;
        let detail = self.book(book_id)?;
        let mut book = Vec::new();
        for (i, section) in detail.sections.iter().enumerate() {
            if section.sentences == 0 {
                continue;
            }
            let Ok(sentences) = crate::book::sentences(&dir, i as u32) else { continue };
            book.push((i as u32, sentences));
        }
        Ok(align(&book, &heard))
    }
}

/// The book's sentences by section, against what was heard.
pub fn align(book: &[(u32, Vec<String>)], heard: &[HeardWord]) -> Alignment {
    // The book's units, each knowing its sentence.
    let mut a = Vec::new();
    let mut spans = Vec::new();
    for (section, sentences) in book {
        for (s, text) in sentences.iter().enumerate() {
            let from = a.len();
            for unit in units(text) {
                a.push(unit);
            }
            spans.push((*section, s as u32, from, a.len()));
        }
    }
    // What was heard, a word's time shared among its units.
    let mut b = Vec::new();
    let mut times = Vec::new();
    for word in heard {
        let us = units(&word.text);
        let n = us.len().max(1) as f64;
        let step = (word.end - word.start).max(0.0) / n;
        for (k, unit) in us.into_iter().enumerate() {
            b.push(unit);
            times.push((word.start + step * k as f64, word.start + step * (k + 1) as f64));
        }
    }
    let matched = match_units(&a, &b);

    // How long a unit takes, from the stretches matched.
    let pairs: Vec<(usize, usize)> = matched.iter().enumerate().filter_map(|(i, j)| j.map(|j| (i, j))).collect();
    let unit_seconds = match (pairs.first(), pairs.last()) {
        (Some(&(i0, j0)), Some(&(i1, j1))) if i1 > i0 => ((times[j1].1 - times[j0].0) / (i1 - i0 + 1) as f64).clamp(0.05, 1.5),
        _ => 0.25,
    };
    let intro = pairs.first().map(|&(_, j)| times[j].0).unwrap_or(0.0);

    // First and last heard time of each sentence, and how much of it was heard.
    struct Seen {
        first: Option<(usize, f64)>,
        last: Option<(usize, f64)>,
        heard: f32,
    }
    let seen: Vec<Seen> = spans
        .iter()
        .map(|&(_, _, from, to)| {
            let hits: Vec<(usize, usize)> = (from..to).filter_map(|i| matched[i].map(|j| (i, j))).collect();
            Seen {
                first: hits.first().map(|&(i, j)| (i - from, times[j].0)),
                last: hits.last().map(|&(i, j)| (to - 1 - i, times[j].1)),
                heard: if to == from { 1.0 } else { hits.len() as f32 / (to - from) as f32 },
            }
        })
        .collect();

    // The time each sentence's words began and ended, with what wasn't heard at either end
    // filled in at the usual pace.
    let mut core: Vec<Option<(f64, f64)>> = seen
        .iter()
        .map(|s| match (s.first, s.last) {
            (Some((before, start)), Some((after, end))) => {
                Some(((start - before as f64 * unit_seconds).max(0.0), end + after as f64 * unit_seconds))
            }
            _ => None,
        })
        .collect();

    // Runs of sentences nobody heard, between two that were: read in the gap between them when
    // it is long enough to hold them, otherwise not in the recording.
    let mut s = 0;
    while s < spans.len() {
        if core[s].is_some() || spans[s].3 == spans[s].2 {
            s += 1;
            continue;
        }
        let run_from = s;
        while s < spans.len() && core[s].is_none() {
            s += 1;
        }
        let run_to = s;
        let (Some(prev), Some(next)) = (
            (0..run_from).rev().find_map(|k| core[k]),
            core.get(run_to).copied().flatten(),
        ) else {
            continue;
        };
        let units: usize = (run_from..run_to).map(|k| spans[k].3 - spans[k].2).sum();
        let gap = next.0 - prev.1;
        if units == 0 || gap < units as f64 * unit_seconds * 0.5 {
            continue;
        }
        let mut at = prev.1;
        for k in run_from..run_to {
            let len = gap * (spans[k].3 - spans[k].2) as f64 / units as f64;
            core[k] = Some((at, at + len));
            at += len;
        }
    }

    // Cut the recording between sentences halfway through the pause, but no more than a little
    // way into a long one, which is left out.
    const PAD: f64 = 0.35;
    let mut sentences = Vec::with_capacity(spans.len());
    let mut prev_end: Option<f64> = None;
    for k in 0..spans.len() {
        let (section, sentence, _, _) = spans[k];
        let Some((start, end)) = core[k] else {
            sentences.push(SentenceTime { section, sentence, start: -1.0, end: -1.0, heard: if spans[k].3 == spans[k].2 { 1.0 } else { 0.0 } });
            if spans[k].3 != spans[k].2 {
                prev_end = None;
            }
            continue;
        };
        let start = match prev_end {
            Some(p) if start - p < 2.0 * PAD => (p + start) / 2.0,
            _ => (start - PAD).max(0.0),
        };
        let next_start = (k + 1..spans.len()).find_map(|n| if spans[n].3 == spans[n].2 { None } else { Some(core[n].map(|c| c.0)) }).flatten();
        let end = match next_start {
            Some(n) if n - end < 2.0 * PAD => (end + n) / 2.0,
            _ => end + PAD,
        };
        let start = start.min(end);
        sentences.push(SentenceTime { section, sentence, start, end, heard: seen[k].heard });
        prev_end = Some(end);
    }
    // A sentence with nothing to say sits at the point between its neighbours.
    for k in 0..sentences.len() {
        if spans[k].3 == spans[k].2 && sentences[k].start < 0.0 {
            if let Some(p) = (0..k).rev().find(|&p| sentences[p].start >= 0.0) {
                let at = sentences[p].end;
                sentences[k].start = at;
                sentences[k].end = at;
            }
        }
    }

    let mut sections: Vec<SectionFit> = Vec::new();
    for k in 0..spans.len() {
        let (section, _, from, to) = spans[k];
        if sections.last().map(|f| f.section) != Some(section) {
            sections.push(SectionFit { section, sentences: 0, heard: 0.0, missing: 0, unsure: 0 });
        }
        let fit = sections.last_mut().unwrap();
        fit.sentences += 1;
        // `heard` holds matched units for now.
        fit.heard += (from..to).filter(|&i| matched[i].is_some()).count() as f32;
        if sentences[k].start < 0.0 {
            fit.missing += 1;
        } else if seen[k].heard < UNSURE_BELOW && to > from {
            fit.unsure += 1;
        }
    }
    for fit in &mut sections {
        let total: usize = spans.iter().filter(|s| s.0 == fit.section).map(|s| s.3 - s.2).sum();
        fit.heard = if total == 0 { 1.0 } else { fit.heard / total as f32 };
    }
    Alignment { sentences, sections, intro, unit_seconds }
}

/// Text as units to match: each CJK character, each run of letters and digits (lower-cased),
/// full-width forms folded to ASCII; everything else dropped.
fn units(text: &str) -> Vec<u64> {
    let mut out = Vec::new();
    let mut word = String::new();
    let flush = |word: &mut String, out: &mut Vec<u64>| {
        if !word.is_empty() {
            out.push(hash(word));
            word.clear();
        }
    };
    for c in text.chars() {
        let c = match c {
            '\u{FF01}'..='\u{FF5E}' => char::from_u32(c as u32 - 0xFEE0).unwrap_or(c),
            _ => c,
        };
        // The transcriber writes numbers in figures (第1章) where books mostly spell them
        // (第一章): each figure counts as its character, so they meet at least digit by digit.
        let c = match c {
            '0'..='9' => ['〇', '一', '二', '三', '四', '五', '六', '七', '八', '九'][c as usize - '0' as usize],
            '零' => '〇',
            _ => c,
        };
        if is_cjk(c) {
            flush(&mut word, &mut out);
            let mut s = String::new();
            s.push(c);
            out.push(hash(&s));
        } else if c.is_alphanumeric() || (c == '\'' && !word.is_empty()) {
            word.extend(c.to_lowercase());
        } else {
            flush(&mut word, &mut out);
        }
    }
    flush(&mut word, &mut out);
    out
}

fn is_cjk(c: char) -> bool {
    matches!(c as u32,
        0x3007 | 0x3040..=0x30FF | 0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xF900..=0xFAFF | 0xAC00..=0xD7AF | 0x20000..=0x2FA1F)
}

fn hash(s: &str) -> u64 {
    let mut h = std::collections::hash_map::DefaultHasher::new();
    s.hash(&mut h);
    h.finish()
}

/// For each unit of `a`, the unit of `b` it matched, if any; matches only ever run forwards.
fn match_units(a: &[u64], b: &[u64]) -> Vec<Option<usize>> {
    let mut out = vec![None; a.len()];
    let mut todo = vec![(0, a.len(), 0, b.len(), 0usize)];
    const KS: [usize; 4] = [8, 5, 3, 2];
    while let Some((a0, a1, b0, b1, level)) = todo.pop() {
        if a0 >= a1 || b0 >= b1 {
            continue;
        }
        if (a1 - a0) * (b1 - b0) <= 300 * 300 {
            lcs(a, b, a0, a1, b0, b1, &mut out);
            continue;
        }
        let Some(&k) = KS.get(level) else { continue };
        let blocks = anchors(a, b, a0, a1, b0, b1, k);
        if blocks.is_empty() {
            todo.push((a0, a1, b0, b1, level + 1));
            continue;
        }
        let (mut pa, mut pb) = (a0, b0);
        for (i, j, len) in blocks {
            todo.push((pa, i, pb, j, level));
            for d in 0..len {
                out[i + d] = Some(j + d);
            }
            pa = i + len;
            pb = j + len;
        }
        todo.push((pa, a1, pb, b1, level));
    }
    out
}

/// Runs of `k` units found exactly once on each side within the ranges, the longest chain of
/// them that runs forwards on both, each grown while the two sides keep agreeing. As
/// (start in a, start in b, length), in order, not overlapping.
fn anchors(a: &[u64], b: &[u64], a0: usize, a1: usize, b0: usize, b1: usize, k: usize) -> Vec<(usize, usize, usize)> {
    if a1 - a0 < k || b1 - b0 < k {
        return Vec::new();
    }
    let key = |s: &[u64]| s.iter().fold(0xcbf29ce484222325u64, |h, &u| (h ^ u).wrapping_mul(0x100000001b3));
    let mut in_a: HashMap<u64, (usize, u32)> = HashMap::new();
    for i in a0..=a1 - k {
        let e = in_a.entry(key(&a[i..i + k])).or_insert((i, 0));
        e.1 += 1;
    }
    let mut in_b: HashMap<u64, (usize, u32)> = HashMap::new();
    for j in b0..=b1 - k {
        let e = in_b.entry(key(&b[j..j + k])).or_insert((j, 0));
        e.1 += 1;
    }
    let mut pairs: Vec<(usize, usize)> = in_a
        .iter()
        .filter(|&(_, &(_, n))| n == 1)
        .filter_map(|(h, &(i, _))| in_b.get(h).filter(|&&(_, n)| n == 1).map(|&(j, _)| (i, j)))
        .filter(|&(i, j)| a[i..i + k] == b[j..j + k])
        .collect();
    pairs.sort_unstable();
    // Longest run of pairs rising on both sides (patience sorting on b).
    let mut tails: Vec<usize> = Vec::new();
    let mut back = vec![usize::MAX; pairs.len()];
    for (p, &(_, j)) in pairs.iter().enumerate() {
        let at = tails.partition_point(|&t| pairs[t].1 < j);
        if at > 0 {
            back[p] = tails[at - 1];
        }
        if at == tails.len() {
            tails.push(p);
        } else {
            tails[at] = p;
        }
    }
    let mut chain = Vec::new();
    let mut p = tails.last().copied().unwrap_or(usize::MAX);
    while p != usize::MAX {
        chain.push(pairs[p]);
        p = back[p];
    }
    chain.reverse();
    // Grow each forwards and backwards; drop any that run into the one before.
    let mut out: Vec<(usize, usize, usize)> = Vec::new();
    for (mut i, mut j) in chain {
        let (lo_a, lo_b) = out.last().map(|&(i, j, n)| (i + n, j + n)).unwrap_or((a0, b0));
        if i < lo_a || j < lo_b {
            continue;
        }
        while i > lo_a && j > lo_b && a[i - 1] == b[j - 1] {
            i -= 1;
            j -= 1;
        }
        let mut n = 0;
        while i + n < a1 && j + n < b1 && a[i + n] == b[j + n] {
            n += 1;
        }
        out.push((i, j, n));
    }
    out
}

/// Longest common subsequence of two small ranges, written into `out`.
fn lcs(a: &[u64], b: &[u64], a0: usize, a1: usize, b0: usize, b1: usize, out: &mut [Option<usize>]) {
    let (n, m) = (a1 - a0, b1 - b0);
    let mut t = vec![0u16; (n + 1) * (m + 1)];
    let at = |i: usize, j: usize| i * (m + 1) + j;
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            t[at(i, j)] = if a[a0 + i] == b[b0 + j] { t[at(i + 1, j + 1)] + 1 } else { t[at(i + 1, j)].max(t[at(i, j + 1)]) };
        }
    }
    let (mut i, mut j) = (0, 0);
    while i < n && j < m {
        if a[a0 + i] == b[b0 + j] {
            out[a0 + i] = Some(b0 + j);
            i += 1;
            j += 1;
        } else if t[at(i + 1, j)] >= t[at(i, j + 1)] {
            i += 1;
        } else {
            j += 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Says `text` a character (or word) at a time, `pace` seconds each, from `at`; returns the
    /// words and where it ended.
    fn say(text: &str, at: f64, pace: f64) -> (Vec<HeardWord>, f64) {
        let mut out = Vec::new();
        let mut t = at;
        let mut word = String::new();
        for c in text.chars().chain(std::iter::once(' ')) {
            if is_cjk(c) || !c.is_alphanumeric() {
                if !word.is_empty() {
                    out.push(HeardWord { text: std::mem::take(&mut word), start: t, end: t + pace });
                    t += pace;
                }
                if is_cjk(c) {
                    out.push(HeardWord { text: c.to_string(), start: t, end: t + pace });
                    t += pace;
                }
            } else {
                word.push(c);
            }
        }
        (out, t)
    }

    fn book() -> Vec<(u32, Vec<String>)> {
        vec![
            (0, vec!["背影".into(), "朱自清".into()]),
            (1, vec![
                "我与父亲不相见已二年余了，我最不能忘记的是他的背影。".into(),
                "那年冬天，祖母死了，父亲的差使也交卸了，正是祸不单行的日子。".into(),
                "我从北京到徐州，打算跟着父亲奔丧回家。".into(),
                "——".into(),
                "到徐州见着父亲，看见满院狼藉的东西，又想起祖母，不禁簌簌地流下眼泪。".into(),
                "父亲说，“事已如此，不必难过，好在天无绝人之路！”".into(),
            ]),
        ]
    }

    #[test]
    fn figures_meet_spelled_numbers() {
        assert_eq!(units("第1章 雨夜"), units("第一章，雨夜"));
        assert_eq!(units("2020年"), units("二〇二〇年"));
    }

    #[test]
    fn every_sentence_gets_its_stretch() {
        let mut heard = Vec::new();
        let (intro, mut t) = say("欢迎收听有声书", 0.0, 0.2);
        heard.extend(intro);
        t += 2.0;
        for (_, sentences) in book() {
            for s in sentences {
                let (w, end) = say(&s, t, 0.25);
                heard.extend(w);
                t = end + 0.6;
            }
        }
        let got = align(&book(), &heard);
        assert!((got.intro - 3.4).abs() < 0.01, "{}", got.intro);
        assert!((got.unit_seconds - 0.25).abs() < 0.1, "{}", got.unit_seconds);
        let times: Vec<_> = got.sentences.iter().filter(|s| s.start != s.end).collect();
        assert_eq!(times.len(), 7);
        for w in times.windows(2) {
            assert!(w[0].end <= w[1].start + 1e-9, "{:?}", w);
        }
        assert!(got.sentences.iter().all(|s| s.heard > 0.99));
        assert!(got.sections.iter().all(|f| f.missing == 0 && f.unsure == 0));
        // The dash has nothing to say and sits between its neighbours.
        let dash = &got.sentences[5];
        assert_eq!((dash.section, dash.sentence), (1, 3));
        assert_eq!(dash.start, dash.end);
    }

    #[test]
    fn a_sentence_left_out_is_missing_and_mistakes_cost_little() {
        let mut heard = Vec::new();
        let mut t = 0.0;
        for (_, sentences) in book() {
            for (i, s) in sentences.iter().enumerate() {
                if s.starts_with("那年冬天") {
                    continue;
                }
                // A misheard word.
                let s = if i == 0 && s.starts_with("我与") { s.replace("背影", "被影") } else { s.clone() };
                let (w, end) = say(&s, t, 0.25);
                heard.extend(w);
                t = end + 0.5;
            }
        }
        let got = align(&book(), &heard);
        let missing: Vec<_> = got.sentences.iter().filter(|s| s.start < 0.0).map(|s| (s.section, s.sentence)).collect();
        assert_eq!(missing, vec![(1, 1)]);
        let first = got.sentences.iter().find(|s| (s.section, s.sentence) == (1, 0)).unwrap();
        assert!(first.heard > 0.9 && first.heard < 1.0);
        assert_eq!(got.sections[1].missing, 1);
    }

    #[test]
    fn english_by_words_and_a_partial_recording() {
        let book = vec![(0, vec![
            "It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife.".to_string(),
            "However little known the feelings or views of such a man may be on his first entering a neighbourhood, this truth is so well fixed.".to_string(),
            "“My dear Mr. Bennet,” said his lady to him one day, “have you heard that Netherfield Park is let at last?”".to_string(),
        ])];
        let (heard, _) = say(&book[0].1[..2].join(" "), 1.0, 0.3);
        let got = align(&book, &heard);
        assert!(got.sentences[0].start >= 0.0 && got.sentences[1].start > got.sentences[0].start);
        assert!(got.sentences[2].start < 0.0);
        assert_eq!(got.sections[0].missing, 1);
    }

    #[test]
    fn a_long_book_aligns_quickly() {
        // Twenty chapters of varied text, said with every fortieth character misheard.
        let base: Vec<char> = "天地玄黄宇宙洪荒日月盈昃辰宿列张寒来暑往秋收冬藏闰余成岁律吕调阳云腾致雨露结为霜金生丽水玉出昆冈剑号巨阙珠称夜光果珍李柰菜重芥姜海咸河淡鳞潜羽翔".chars().collect();
        let mut seed = 7u64;
        let mut rnd = || {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            (seed >> 33) as usize
        };
        let book: Vec<(u32, Vec<String>)> = (0..20)
            .map(|c| (c, (0..120).map(|_| (0..30).map(|_| base[rnd() % base.len()]).collect::<String>() + "。").collect()))
            .collect();
        let mut heard = Vec::new();
        let mut t = 0.0;
        let mut n = 0;
        for (_, sentences) in &book {
            for s in sentences {
                for c in s.chars().filter(|c| is_cjk(*c)) {
                    n += 1;
                    let c = if n % 40 == 0 { '错' } else { c };
                    heard.push(HeardWord { text: c.to_string(), start: t, end: t + 0.2 });
                    t += 0.2;
                }
                t += 0.4;
            }
        }
        let started = std::time::Instant::now();
        let got = align(&book, &heard);
        assert!(started.elapsed().as_secs_f64() < 5.0, "{:?}", started.elapsed());
        let missing = got.sentences.iter().filter(|s| s.start < 0.0).count();
        assert_eq!(missing, 0);
        let mean: f32 = got.sentences.iter().map(|s| s.heard).sum::<f32>() / got.sentences.len() as f32;
        assert!(mean > 0.95, "{mean}");
        // Each sentence starts within a pause of where it was really said.
        let mut t = 0.0;
        for (k, s) in got.sentences.iter().enumerate() {
            assert!((s.start - t).abs() < 0.6, "sentence {k}: {} vs {t}", s.start);
            t += 30.0 * 0.2 + 0.4;
        }
    }
}
