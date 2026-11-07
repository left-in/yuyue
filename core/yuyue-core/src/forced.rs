//! 强制对齐: the book's words laid along a recording directly, without
//! first guessing what was said.
//!
//! The app runs the acoustic model (Meta's MMS forced-alignment model) over the recording and
//! hands over what it gives: for each 20 ms frame, how likely each of its letters is (log
//! probabilities, in the model's own order, `-` the blank first). Here the book's sentences
//! become those letters — Chinese through its pinyin (`reading`), English as it's spelt — and a
//! CTC Viterbi finds where each letter, so each sentence, is read.
//!
//! What's in the recording but not in the book (片头, “this is a LibriVox recording”, 章末的话)
//! is taken by a wildcard, `*`, allowed before and after each chapter's title: each frame it
//! scores a little under the best letter, so reading the book wins wherever the book is read.
//! The book's end needn't be reached (notes at the back nobody reads). The search follows the
//! best place with a window, so memory grows with the recording, not with recording × book.
//!
//! What's in the book but not in the recording, inside a chapter (a picture's caption, a note,
//! a paragraph the reader missed), is jumped over: from the end of one sentence the search may go
//! straight to the start of one a few sentences on, paying `SKIP_PENALTY` a jump and a little
//! more for each sentence left out. Without it one sentence the reader didn't read pulls every
//! sentence after it out of place. The sentences jumped over come back as not in the recording.
//!
//! What's in the recording but not in the book inside a chapter (an ad, “本节目由……”, a word
//! from the reader) is taken by the pause between the two sentences around it, which may hold
//! speech at `GAP_PENALTY` a letter heard. Taken that way it's left out of both sentences, so
//! playing one after the other passes over it; before, the sentence next to it took it in.
//!
//! A recording in several files is placed file by file (`align_files`), a long file a piece at a
//! time.

use crate::align::{Alignment, SectionFit, SentenceTime, UNSURE_BELOW};
use crate::api::YuyueCore;
use crate::error::{CoreError, Result};

/// The model's letters, in the order its output gives them.
pub const LETTERS: &str = "-aienoutsrmkldghybpwcvjzf'qx";
const BLANK: usize = 0;
/// The wildcard's place, after the model's own letters.
const STAR: usize = 28;
/// How much under the best letter the wildcard scores each frame (实测: 0.2 best).
const STAR_PENALTY: f32 = 0.2;
/// How much of a long file is laid out at once (seconds): enough for the search to find its
/// way, small enough that a whole book in one file fits a phone.
const PIECE_SECONDS: f64 = 600.0;
/// States on each side of the best one that the search keeps.
const WINDOW: usize = 1000;
/// How far behind the best state the window reaches. More than a jump can go (`MAX_JUMP`): when
/// a jump ahead is the best for a moment, where the reader really is stays in the window.
const BEHIND: usize = WINDOW * 6 / 5;
/// The furthest a jump goes, in states (two a letter): about 400 letters, four or five English
/// sentences or a hundred-odd Chinese characters.
const MAX_JUMP: usize = WINDOW * 4 / 5;
/// What one jump over sentences not in the recording costs: about what a few frames of a letter
/// the model doesn't hear cost, so a jump wins only where reading on would cost more.
const SKIP_PENALTY: f32 = 12.0;
/// And each sentence jumped over, so the search jumps no further than it has to.
const SKIP_EACH: f32 = 2.0;
/// The most sentences one jump leaves out.
const MAX_SKIP: usize = 12;
/// The pause between two sentences of a chapter can also hold speech that isn't in the book (an
/// ad, “本节目由……”, a word from the reader), scoring this much under the best letter each frame:
/// dearer than the wildcard around titles, so it takes only what reading the book can't explain.
const GAP_PENALTY: f32 = 2.0;
/// Speech taken by a pause, this long (frames) or more and with this many letters heard in it,
/// is left out of both sentences around it.
const GAP_FRAMES: usize = 50;
const GAP_LETTERS: usize = 8;

fn letter(c: char) -> Option<usize> {
    LETTERS.chars().position(|l| l == c).filter(|&i| i != BLANK)
}

/// A sentence as the model's letters.
pub fn letters(text: &str, chinese: bool) -> Vec<usize> {
    if chinese {
        crate::reading::for_alignment(text).iter().flat_map(|s| s.pinyin.chars().filter_map(letter).collect::<Vec<_>>()).collect()
    } else {
        spoken_english(text).chars().filter_map(letter).collect()
    }
}

/// English as it's read: lower case, ’ as ', and a chapter's Roman number in words
/// (CHAPTER IV → chapter four).
fn spoken_english(text: &str) -> String {
    let t = text.replace(['’', '‘'], "'");
    let mut out = String::new();
    let mut words = t.split_whitespace().peekable();
    while let Some(w) = words.next() {
        out.push_str(&w.to_lowercase());
        out.push(' ');
        if w.trim_end_matches('.').eq_ignore_ascii_case("chapter")
            && let Some(n) = words.peek().and_then(|r| roman(r.trim_end_matches('.'))) {
                out.push_str(&number_words(n));
                out.push(' ');
                words.next();
            }
    }
    out
}

fn roman(s: &str) -> Option<u32> {
    let v = |c: char| match c.to_ascii_uppercase() {
        'I' => Some(1),
        'V' => Some(5),
        'X' => Some(10),
        'L' => Some(50),
        'C' => Some(100),
        _ => None,
    };
    let vals: Vec<u32> = s.chars().map(v).collect::<Option<_>>()?;
    if vals.is_empty() {
        return None;
    }
    Some(vals.iter().enumerate().map(|(i, &x)| if vals.get(i + 1).is_some_and(|&n| n > x) { -(x as i64) } else { x as i64 }).sum::<i64>() as u32)
}

fn number_words(n: u32) -> String {
    const ONES: [&str; 20] = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
    ];
    const TENS: [&str; 10] = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"];
    match n {
        0..=19 => ONES[n as usize].into(),
        20..=99 => if n.is_multiple_of(10) { TENS[(n / 10) as usize].into() } else { format!("{} {}", TENS[(n / 10) as usize], ONES[(n % 10) as usize]) },
        _ => format!("{} hundred{}", ONES[(n / 100) as usize], if n.is_multiple_of(100) { String::new() } else { format!(" and {}", number_words(n % 100)) }),
    }
}

/// The token sequence: the wildcard, then each sentence's letters, with the wildcard again around
/// each chapter's title and at the end. `owner` says whose each token is (None: the wildcard).
fn tokens(book: &[(u32, Vec<String>)], chinese: bool, firsts: &[u32]) -> (Vec<usize>, Vec<Option<usize>>) {
    let mut tokens = vec![STAR];
    let mut owner = vec![None];
    let mut k = 0;
    for (n, (_, sentences)) in book.iter().enumerate() {
        let first = firsts.get(n).copied().unwrap_or(0);
        for (i, text) in sentences.iter().enumerate() {
            // A chapter's title: its sentence 0, where the stretch starts at the chapter's start.
            let title = i == 0 && first == 0;
            if title && n > 0 {
                tokens.push(STAR);
                owner.push(None);
            }
            for l in letters(text, chinese) {
                tokens.push(l);
                owner.push(Some(k));
            }
            if title {
                tokens.push(STAR);
                owner.push(None);
            }
            k += 1;
        }
    }
    tokens.push(STAR);
    owner.push(None);
    (tokens, owner)
}

/// The jumps over sentences not in the recording: for the state of a sentence's first letter,
/// the states it may be reached from (the end of a sentence 2..=MAX_SKIP+1 back, its last letter
/// or the blank after it) and what the jump costs.
/// Indexed by state: `u32::MAX` where no jump lands, else the place of its list.
fn jumps(tokens: &[usize], owner: &[Option<usize>]) -> (Vec<u32>, Vec<Vec<(usize, f32)>>) {
    // Each sentence's first and last token.
    let mut ends: Vec<(usize, usize)> = Vec::new();
    let mut whose: Vec<usize> = Vec::new();
    for (j, o) in owner.iter().enumerate() {
        let Some(k) = *o else { continue };
        if whose.last() == Some(&k) {
            ends.last_mut().unwrap().1 = j;
        } else {
            whose.push(k);
            ends.push((j, j));
        }
    }
    let mut at = vec![u32::MAX; 2 * tokens.len() + 1];
    let mut lists: Vec<Vec<(usize, f32)>> = Vec::new();
    for m in 0..ends.len() {
        let into = 2 * ends[m].0 + 1;
        let mut list = Vec::new();
        for back in 2..=MAX_SKIP + 1 {
            let Some(k) = m.checked_sub(back) else { break };
            let last = ends[k].1;
            let from = 2 * last + 1;
            // Out of the search's reach anyway.
            if into - from > MAX_JUMP {
                break;
            }
            let cost = SKIP_PENALTY + SKIP_EACH * (whose[m] - whose[k] - 1) as f32;
            // From the blank after the last letter; from the letter itself only when the two
            // letters differ (CTC: the same letter twice needs a blank between).
            list.push((from + 1, cost));
            if tokens[last] != tokens[ends[m].0] {
                list.push((from, cost));
            }
        }
        if !list.is_empty() {
            at[into] = lists.len() as u32;
            lists.push(list);
        }
    }
    (at, lists)
}

/// Each token's first and last frame (end exclusive), or None when the path skipped it.
fn viterbi(em: &[f32], frames: usize, tokens: &[usize], owner: &[Option<usize>]) -> (Vec<Option<(usize, usize)>>, Vec<(usize, usize)>) {
    let (jump_at, jump_lists) = jumps(tokens, owner);
    // Where a jump was taken, in the order the search goes (frame, then state), packed as
    // frame << 32 | state, and which of that state's jumps it was. Kept as two plain lists, not
    // a map: there can be hundreds of thousands in a long piece.
    let mut jumped: Vec<u64> = Vec::new();
    let mut jumped_which: Vec<u8> = Vec::new();
    let classes = em.len() / frames;
    let score = |t: usize, c: usize| -> f32 {
        let row = &em[t * classes..(t + 1) * classes];
        if c == STAR { row.iter().copied().fold(f32::MIN, f32::max) - STAR_PENALTY } else { row[c] }
    };
    // States: blank, token 0, blank, token 1, …, blank.
    let states = 2 * tokens.len() + 1;
    let label = |s: usize| if s.is_multiple_of(2) { BLANK } else { tokens[s / 2] };
    // The pauses between two sentences, which may hold speech not in the book.
    let gap = |s: usize| s.is_multiple_of(2) && s >= 2 && s / 2 < tokens.len() && matches!((owner[s / 2 - 1], owner[s / 2]), (Some(a), Some(b)) if a != b);
    let best_of = |t: usize| em[t * classes..(t + 1) * classes].iter().copied().fold(f32::MIN, f32::max);
    let state_score = |t: usize, s: usize| if gap(s) { score(t, BLANK).max(best_of(t) - GAP_PENALTY) } else { score(t, label(s)) };
    // A state may be reached from two back when it's a token unlike the one before (CTC).
    let can_skip = |s: usize| s % 2 == 1 && s >= 3 && tokens[s / 2] != tokens[s / 2 - 1];
    let width = (2 * WINDOW).min(states);
    const NEG: f32 = -1e30;
    // Where each frame's window starts, and how each state in it was reached (0 stay, 1 from
    // one back, 2 from two back), two bits a state.
    let mut lows = vec![0usize; frames];
    let mut back = vec![0u8; (frames * width).div_ceil(4)];
    let set = |back: &mut [u8], t: usize, k: usize, v: u8| {
        let i = t * width + k;
        back[i / 4] |= v << ((i % 4) * 2);
    };
    let get = |back: &[u8], t: usize, k: usize| -> u8 {
        let i = t * width + k;
        (back[i / 4] >> ((i % 4) * 2)) & 3
    };
    let mut alpha = vec![NEG; width];
    alpha[0] = state_score(0, 0);
    if width > 1 {
        alpha[1] = state_score(0, 1);
    }
    let mut low = 0;
    let mut next = vec![NEG; width];
    for t in 1..frames {
        let best = low + alpha.iter().enumerate().max_by(|a, b| a.1.total_cmp(b.1)).map(|(i, _)| i).unwrap_or(0);
        let new_low = best.saturating_sub(BEHIND).min(states - width).max(low);
        let at = |s: usize| if s >= low && s < low + width { alpha[s - low] } else { NEG };
        for k in 0..width {
            let s = new_low + k;
            let stay = at(s);
            let one = if s >= 1 { at(s - 1) } else { NEG };
            let two = if can_skip(s) { at(s - 2) } else { NEG };
            let (mut from, mut v) = if two > one && two > stay { (2, two) } else if one > stay { (1, one) } else { (0, stay) };
            if jump_at[s] != u32::MAX {
                let mut which = None;
                for (i, &(src, cost)) in jump_lists[jump_at[s] as usize].iter().enumerate() {
                    let j = at(src);
                    if j > NEG && j - cost > v {
                        v = j - cost;
                        which = Some(i as u8);
                    }
                }
                if let Some(i) = which {
                    from = 3;
                    jumped.push((t as u64) << 32 | s as u64);
                    jumped_which.push(i);
                }
            }
            next[k] = if v <= NEG { NEG } else { v + state_score(t, s) };
            set(&mut back, t, k, from);
        }
        std::mem::swap(&mut alpha, &mut next);
        lows[t] = new_low;
        low = new_low;
    }
    // From the best state at the end: the book needn't be read to its last letter.
    let mut s = low + alpha.iter().enumerate().max_by(|a, b| a.1.total_cmp(b.1)).map(|(i, _)| i).unwrap_or(0);
    let mut spans = vec![None; tokens.len()];
    // Each stretch the path spent in a pause between sentences, last first, as (state, first
    // frame, last frame + 1), and how many of its frames heard a letter more than the quiet.
    let mut pauses: Vec<(usize, usize, usize)> = Vec::new();
    for t in (0..frames).rev() {
        if gap(s) {
            match pauses.last_mut() {
                Some((st, a, _)) if *st == s && *a == t + 1 => *a = t,
                _ => pauses.push((s, t, t + 1)),
            }
        }
        if s % 2 == 1 {
            let k = s / 2;
            spans[k] = Some(match spans[k] {
                Some((_, end)) => (t, end),
                None => (t, t + 1),
            });
        }
        if t > 0 {
            s = match get(&back, t, s - lows[t]) {
                3 => {
                    let i = jumped.binary_search(&((t as u64) << 32 | s as u64)).expect("a jump taken is recorded");
                    jump_lists[jump_at[s] as usize][jumped_which[i] as usize].0
                }
                d => s - d as usize,
            };
        }
    }
    // Speech in a pause: from its first letter heard to its last, when there are enough of them
    // to be words rather than a breath or a cough.
    let mut runs: Vec<(usize, usize)> = Vec::new();
    for &(_, a, b) in pauses.iter().rev() {
        let heard: Vec<usize> = (a..b).filter(|&t| best_of(t) > score(t, BLANK)).collect();
        if let (Some(&x), Some(&y)) = (heard.first(), heard.last())
            && heard.len() >= GAP_LETTERS
            && y + 1 - x >= GAP_FRAMES
        {
            runs.push((x, y + 1));
        }
    }
    (spans, runs)
}

/// The book's sentences by section against the model's output for one recording: `em` is
/// `frames` rows of log probabilities, one for each of the model's letters; `seconds` is how
/// long the recording is.
pub fn align(book: &[(u32, Vec<String>)], chinese: bool, em: &[f32], frames: usize, seconds: f64) -> Alignment {
    align_from(book, &vec![0; book.len()], chinese, em, frames, seconds)
}

/// As `align`, for a stretch of the book: `firsts` says which sentence of its section each
/// group starts at, and the sentences keep their numbers.
fn align_from(book: &[(u32, Vec<String>)], firsts: &[u32], chinese: bool, em: &[f32], frames: usize, seconds: f64) -> Alignment {
    let (tokens, owner) = tokens(book, chinese, firsts);
    let (spans, extra) = if frames > 0 { viterbi(em, frames, &tokens, &owner) } else { (vec![None; tokens.len()], Vec::new()) };
    let fps = frames as f64 / seconds.max(0.001);
    let classes = if frames > 0 { em.len() / frames } else { 0 };
    let list: Vec<(u32, u32)> = book.iter().zip(firsts).flat_map(|((sec, s), &f)| (0..s.len() as u32).map(move |i| (*sec, f + i))).collect();
    // Each sentence: its first and last frame, and how sure the model was of its letters.
    let mut found: Vec<Option<(usize, usize, f32, usize)>> = vec![None; list.len()];
    let mut letters_of = vec![0usize; list.len()];
    for (j, o) in owner.iter().enumerate() {
        let Some(k) = *o else { continue };
        letters_of[k] += 1;
        let Some((a, b)) = spans[j] else { continue };
        let sum: f32 = (a..b).map(|t| em[t * classes + tokens[j]]).sum();
        found[k] = Some(match found[k] {
            Some((s, _, total, n)) => (s, b, total + sum, n + b - a),
            None => (a, b, sum, b - a),
        });
    }
    let mut sentences: Vec<SentenceTime> = list
        .iter()
        .zip(&found)
        .zip(&letters_of)
        .map(|((&(section, sentence), f), &n)| match f {
            Some((a, b, sum, count)) => SentenceTime {
                section,
                sentence,
                start: *a as f64 / fps,
                end: *b as f64 / fps,
                heard: (sum / (*count).max(1) as f32).exp().clamp(0.0, 1.0),
            },
            None => SentenceTime { section, sentence, start: -1.0, end: -1.0, heard: if n == 0 { 1.0 } else { 0.0 } },
        })
        .collect();
    // A letter lights up only for a moment: the first late, the last early. The pause between two
    // sentences is cut in the middle and shared.
    let timed: Vec<usize> = (0..sentences.len()).filter(|&k| sentences[k].start >= 0.0).collect();
    // Speech not in the book between two sentences stays out of both: each gets half the quiet
    // on its side of it, and playing the one after the other passes over it.
    for w in timed.windows(2) {
        let (a, b) = (sentences[w[0]].end, sentences[w[1]].start);
        let inside = extra.iter().find(|&&(x, y)| x as f64 / fps >= a - 0.05 && y as f64 / fps <= b + 0.05);
        if let Some(&(x, y)) = inside {
            sentences[w[0]].end = (a + x as f64 / fps) / 2.0;
            sentences[w[1]].start = (y as f64 / fps + b) / 2.0;
        } else {
            let mid = (a + b) / 2.0;
            sentences[w[0]].end = mid;
            sentences[w[1]].start = mid;
        }
    }
    if let (Some(&f), Some(&l)) = (timed.first(), timed.last()) {
        sentences[f].start = (sentences[f].start - 0.15).max(0.0);
        sentences[l].end = (sentences[l].end + 0.3).min(seconds);
    }
    let letters_of: std::collections::HashMap<(u32, u32), usize> = list.iter().zip(&letters_of).map(|(&k, &n)| (k, n)).collect();
    summarize(book, sentences, &letters_of)
}

/// The sections' counts and the recording's pace, from the sentences' times.
fn summarize(book: &[(u32, Vec<String>)], sentences: Vec<SentenceTime>, letters_of: &std::collections::HashMap<(u32, u32), usize>) -> Alignment {
    let n = |t: &SentenceTime| letters_of.get(&(t.section, t.sentence)).copied().unwrap_or(0);
    let timed: Vec<&SentenceTime> = sentences.iter().filter(|t| t.start >= 0.0).collect();
    let intro = timed.first().map(|t| t.start).unwrap_or(0.0);
    let total_letters: usize = timed.iter().map(|t| n(t)).sum();
    let unit_seconds = match (timed.first(), timed.last()) {
        (Some(f), Some(l)) if total_letters > 0 => (l.end - f.start) / total_letters as f64,
        _ => 0.25,
    };
    let mut sections = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for (sec, _) in book {
        if !seen.insert(*sec) {
            continue;
        }
        let mine: Vec<&SentenceTime> = sentences.iter().filter(|t| t.section == *sec).collect();
        let worded: Vec<&&SentenceTime> = mine.iter().filter(|t| n(t) > 0).collect();
        sections.push(SectionFit {
            section: *sec,
            sentences: mine.len() as u32,
            heard: if worded.is_empty() { 1.0 } else { worded.iter().map(|t| t.heard).sum::<f32>() / worded.len() as f32 },
            missing: worded.iter().filter(|t| t.start < 0.0).count() as u32,
            unsure: worded.iter().filter(|t| t.start >= 0.0 && t.heard < UNSURE_BELOW).count() as u32,
        });
    }
    Alignment { sentences, sections, intro, unit_seconds }
}

/// A downloaded file's BLAKE3, in hex, to check it's the one meant.
#[uniffi::export]
pub fn file_digest(path: String) -> Result<String> {
    let mut h = blake3::Hasher::new();
    h.update_reader(std::fs::File::open(&path)?)?;
    Ok(h.finalize().to_hex().to_string())
}

/// Unpacks a downloaded model (a zip) into `to`, keeping its folders. Entries that would land
/// outside `to` are refused.
#[uniffi::export]
pub fn unpack_model(zip: String, to: String) -> Result<()> {
    let file = std::fs::File::open(&zip)?;
    let mut archive = ::zip::ZipArchive::new(std::io::BufReader::new(file)).map_err(|_| CoreError::bad_book("zip"))?;
    let root = std::path::Path::new(&to);
    std::fs::create_dir_all(root)?;
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i).map_err(|_| CoreError::bad_book("zip"))?;
        let Some(name) = entry.enclosed_name() else { return Err(CoreError::bad_book("zip")) };
        let path = root.join(name);
        if entry.is_dir() {
            std::fs::create_dir_all(&path)?;
            continue;
        }
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut out = std::fs::File::create(&path)?;
        std::io::copy(&mut entry, &mut out)?;
    }
    Ok(())
}

/// One file of a recording: the model's output for it, `frames` rows of `LETTERS.len()`.
pub struct FileEmissions {
    pub em: Vec<f32>,
    pub frames: usize,
    pub seconds: f64,
}

/// A whole recording, file by file, against the whole book (先粗再细): each file is first
/// placed in the book — where what the model hears in its first minute best matches — then
/// laid against the stretch it could hold from there, so neither the search nor memory grows
/// with the book. Files needn't come in the book's order, nor the book be read whole (a
/// collection read story by story); what no file holds comes back as not in the recording.
pub fn align_files(book: &[(u32, Vec<String>)], chinese: bool, files: &[FileEmissions]) -> Alignment {
    // Every sentence, in order, with its letters.
    let list: Vec<(u32, u32, Vec<usize>)> = book.iter().flat_map(|(sec, s)| s.iter().enumerate().map(move |(i, t)| (*sec, i as u32, letters(t, chinese)))).collect();
    // Lines that read like a title: short, no sentence punctuation (孔乙己, 故鄉, CHAPTER IV).
    let titles: Vec<bool> = book
        .iter()
        .flat_map(|(_, s)| s.iter().map(|t| t.chars().count() <= 12 && !t.contains(['，', '。', '？', '！', '︰', '：', '“', '”', ',', '?', '!', '、', '；']) && t.chars().any(char::is_alphanumeric)))
        .collect();
    let mut sentences: Vec<SentenceTime> = list.iter().map(|(section, sentence, l)| SentenceTime { section: *section, sentence: *sentence, start: -1.0, end: -1.0, heard: if l.is_empty() { 1.0 } else { 0.0 } }).collect();
    let mut offset = 0.0;
    for f in files {
        // 先粗: where in the book this file starts — the sentence whose letters best match what
        // the model hears in its first minute and a half. Anywhere in the book: files needn't
        // come in the book's order (a collection read story by story), nor all of it be there.
        let start = find_start(&list, &titles, f);
        // A long file (a whole book in one M4B) is laid out a piece at a time: each piece of the
        // recording against the stretch of the book from where the last piece reached, so memory
        // stays the same however long the file is.
        let classes = if f.frames > 0 { f.em.len() / f.frames } else { 0 };
        let fps = if f.seconds > 0.0 { f.frames as f64 / f.seconds } else { 50.0 };
        let piece = (PIECE_SECONDS * fps) as usize;
        let mut at = start;
        let mut frame = 0;
        while frame < f.frames && at < list.len() {
            let to = if f.frames - frame <= piece * 3 / 2 { f.frames } else { frame + piece };
            let last_piece = to == f.frames;
            let seconds = (to - frame) as f64 / fps;
            // A little more of the book than the piece could hold at an ordinary pace (8 letters a
            // second).
            let room = (seconds * 14.0) as usize + 200;
            let mut end = at;
            let mut count = 0;
            while end < list.len() && count < room {
                count += list[end].2.len();
                end += 1;
            }
            if last_piece && end == at {
                break;
            }
            let part: Vec<(u32, u32, usize)> = list[at..end].iter().map(|(a, b, l)| (*a, *b, l.len())).collect();
            let (part, firsts) = group(&part, book);
            let em = &f.em[frame * classes..to * classes];
            let a = align_from(&part, &firsts, chinese, em, to - frame, seconds);
            let base = offset + frame as f64 / fps;
            // Keep what this piece found, except the last sentence it reached, which may run on
            // into the next piece: the next piece starts there.
            let found: Vec<usize> = (0..a.sentences.len()).filter(|&k| a.sentences[k].start >= 0.0).collect();
            let keep = if last_piece { found.len() } else { found.len().saturating_sub(1) };
            let mut next_frame = to;
            for (n, &k) in found[..keep].iter().enumerate() {
                let mut t = a.sentences[k].clone();
                t.start += base;
                t.end += base;
                // A piece's first sentence starts where the last piece's last one ended: the pause
                // between them was shared there already.
                if n == 0 && at > 0 && sentences[at - 1].start >= 0.0 && sentences[at - 1].end < t.end {
                    t.start = sentences[at - 1].end;
                }
                sentences[at + k] = t;
            }
            if !last_piece {
                if let Some(&k) = found.get(keep) {
                    // The next piece begins where the held-back sentence began.
                    next_frame = frame + ((a.sentences[k].start * fps) as usize).max(1);
                    at += k;
                } else if let Some(&k) = found.last() {
                    at += k + 1;
                } else {
                    // Nothing in this piece (music, a long silence): on to the next.
                }
            }
            frame = next_frame.max(frame + 1);
            if last_piece {
                break;
            }
        }
        offset += f.seconds;
    }
    let letters_of: std::collections::HashMap<(u32, u32), usize> = list.iter().map(|(a, b, l)| ((*a, *b), l.len())).collect();
    summarize(book, sentences, &letters_of)
}

/// The sentence a recording file most likely starts at, from `from` on: what the model hears in
/// its first minute, letter by letter (best letter a frame, repeats and blanks dropped), against
/// a minute's worth of letters starting at each sentence; the closest wins.
fn find_start(list: &[(u32, u32, Vec<usize>)], titles: &[bool], f: &FileEmissions) -> usize {
    let from = 0;
    let classes = if f.frames > 0 { f.em.len() / f.frames } else { return from };
    // Up to a minute and a half, past the first few seconds (an announcer's words aren't the
    // book's, and they'd pull the match toward whatever sounds alike).
    let frames = f.frames.min(50 * 90);
    let skip = if f.frames > 50 * 60 { 50 * 15 } else { 0 };
    let mut heard = Vec::new();
    let mut last = BLANK;
    for t in skip..frames {
        let row = &f.em[t * classes..(t + 1) * classes];
        let best = row.iter().enumerate().max_by(|a, b| a.1.total_cmp(b.1)).map(|(i, _)| i).unwrap_or(BLANK);
        if best != BLANK && best != last {
            heard.push(best);
        }
        last = best;
    }
    if heard.len() < 20 {
        return from;
    }
    // Letter trigrams: cheap, and forgiving of the model's slips.
    let grams = |v: &[usize]| -> std::collections::HashSet<(usize, usize, usize)> { v.windows(3).map(|w| (w[0], w[1], w[2])).collect() };
    let want = grams(&heard);
    let span = heard.len() * 3 / 2;
    let score = |s: usize| {
        let mut text = Vec::with_capacity(span);
        let mut k = s;
        while k < list.len() && text.len() < span {
            text.extend_from_slice(&list[k].2);
            k += 1;
        }
        // Hits less a little for each letter trigram of the text the recording doesn't have, so a
        // stretch of footnotes full of common syllables doesn't win over the story itself.
        let g = grams(&text);
        let hits = g.intersection(&want).count();
        hits.saturating_sub((g.len() - hits) / 4)
    };
    let mut best = (from, 0usize);
    for s in from..list.len() {
        let hits = score(s);
        if hits > best.1 {
            best = (s, hits);
        }
    }
    // A file usually holds whole chapters: the best chapter start wins when it's nearly as
    // good as the best place anywhere (the reader's own opening words cost it a little).
    // Only titles close to the best place, and the one there with the most words heard after it.
    let near = best.0.saturating_sub(6)..(best.0 + 12).min(list.len());
    let chapter = near.filter(|&k| k >= from && (list[k].1 == 0 || titles[k])).map(|k| (k, score(k))).max_by_key(|x| (x.1, std::cmp::Reverse(x.0)));
    match chapter {
        Some((k, hits)) if hits * 10 >= best.1 * 8 => k,
        _ => best.0,
    }
}

/// The sentences `part` of the book, grouped back into their sections, with the sentence each
/// group starts at.
fn group(part: &[(u32, u32, usize)], book: &[(u32, Vec<String>)]) -> (Vec<(u32, Vec<String>)>, Vec<u32>) {
    let mut out: Vec<(u32, Vec<String>)> = Vec::new();
    let mut firsts = Vec::new();
    for &(sec, i, _) in part {
        let text = book.iter().find(|(s, _)| *s == sec).map(|(_, v)| v[i as usize].clone()).unwrap_or_default();
        match out.last_mut() {
            Some((s, v)) if *s == sec => v.push(text),
            _ => {
                out.push((sec, vec![text]));
                firsts.push(i);
            }
        }
    }
    (out, firsts)
}

/// One file's model output, for `align_recording_files`.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct Emissions {
    /// `frames` rows of `LETTERS.len()` log probabilities.
    pub values: Vec<f32>,
    pub frames: u32,
    pub seconds: f64,
}

#[uniffi::export]
impl YuyueCore {
    /// 强制对齐 a whole recording, file by file, against the whole book (the chapters with
    /// something to read). Files not yet run can be left out; the book after them comes back as
    /// not yet in the recording.
    pub fn align_recording_files(&self, book_id: String, files: Vec<Emissions>) -> Result<Alignment> {
        let detail = self.book(book_id.clone())?;
        let chinese = detail.summary.language.starts_with("zh");
        let mut book = Vec::new();
        for (i, s) in detail.sections.iter().enumerate() {
            if s.sentences == 0 || !s.linear {
                continue;
            }
            book.push((i as u32, self.sentences(book_id.clone(), i as u32)?));
        }
        let classes = LETTERS.chars().count();
        let files: Vec<FileEmissions> = files
            .into_iter()
            .filter(|f| f.frames > 0 && f.values.len() == f.frames as usize * classes)
            .map(|f| FileEmissions { em: f.values, frames: f.frames as usize, seconds: f.seconds })
            .collect();
        Ok(align_files(&book, chinese, &files))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A made-up recording: each letter of the text in turn is sure for three frames, with blanks
    /// between and noise at the start the wildcard takes.
    fn recording(text: &str, noise: usize) -> (Vec<f32>, usize) {
        let ls = letters(text, false);
        let mut em = Vec::new();
        let row = |hot: usize| (0..28).map(|c| if c == hot { -0.01 } else { -8.0 }).collect::<Vec<f32>>();
        for i in 0..noise {
            em.extend((0..28).map(|c| if c == 1 + i % 20 { -1.0 } else { -3.0 }));
        }
        for l in &ls {
            for _ in 0..3 {
                em.extend(row(*l));
            }
            em.extend(row(BLANK));
        }
        let frames = em.len() / 28;
        (em, frames)
    }

    #[test]
    fn sentences_found_after_an_intro() {
        let book = vec![(0u32, vec!["Chapter one.".to_string(), "It was a dark night.".into(), "The end.".into()])];
        let text = "chapter one it was a dark night the end";
        let (em, frames) = recording(text, 50);
        let a = align(&book, false, &em, frames, frames as f64 / 50.0);
        let s = &a.sentences;
        assert!(s.iter().all(|t| t.start >= 0.0), "{s:?}");
        // The title starts after the noise (50 frames = 1 s).
        assert!((a.intro - 1.0).abs() < 0.2, "intro {}", a.intro);
        assert!(s[0].end <= s[1].start + 1e-9 && s[1].end <= s[2].start + 1e-9);
        assert_eq!(a.sections[0].missing, 0);
    }

    /// A file far longer than a piece comes out as it would at once.
    #[test]
    fn a_long_file_in_pieces() {
        let line = |i: usize| format!("Sentence number {} goes on a while here.", ["one", "two", "three", "four", "five", "six", "seven", "eight"][i % 8]);
        let sentences: Vec<String> = std::iter::once("Chapter one.".to_string()).chain((0..1000).map(line)).collect();
        let text: String = sentences.iter().map(|s| s.to_lowercase().replace('.', "")).collect::<Vec<_>>().join(" ");
        let (em, frames) = recording(&text, 20);
        // 50 frames a second: several pieces of PIECE_SECONDS.
        let seconds = frames as f64 / 50.0;
        assert!(seconds > PIECE_SECONDS * 2.5, "{seconds}");
        let book = vec![(0u32, sentences)];
        let out = align_files(&book, false, &[FileEmissions { em, frames, seconds }]);
        let s = &out.sentences;
        assert!(s.iter().all(|t| t.start >= 0.0), "missing: {}", s.iter().filter(|t| t.start < 0.0).count());
        assert!(s.windows(2).all(|w| w[0].end <= w[1].start + 1e-6 && w[0].start < w[1].start), "out of order");
    }

    #[test]
    fn a_recording_in_two_files() {
        let book = vec![
            (0u32, vec!["Chapter one.".to_string(), "It was a dark night.".into()]),
            (1u32, vec!["Chapter two.".to_string(), "The rain stopped.".into(), "The end.".into()]),
        ];
        let (a, fa) = recording("chapter one it was a dark night", 20);
        let (b, fb) = recording("chapter two the rain stopped the end", 20);
        let files = vec![FileEmissions { em: a, frames: fa, seconds: fa as f64 / 50.0 }, FileEmissions { em: b, frames: fb, seconds: fb as f64 / 50.0 }];
        let out = align_files(&book, false, &files);
        let s = &out.sentences;
        assert_eq!(s.len(), 5);
        assert!(s.iter().all(|t| t.start >= 0.0), "{s:?}");
        // The second file's sentences come after the first file.
        assert!(s[2].start >= fa as f64 / 50.0, "{s:?}");
        assert_eq!(out.sections.iter().map(|x| x.sentences).collect::<Vec<_>>(), [2, 3]);
    }

    /// A caption in the middle of the chapter nobody reads: jumped over, and the sentences after
    /// it still found where they're read.
    #[test]
    fn a_sentence_not_read_is_skipped() {
        let book = vec![(
            0u32,
            vec![
                "Chapter one.".to_string(),
                "It was a dark night.".into(),
                "Figure two shows the lighthouse keeper with his lamp.".into(),
                "The rain stopped.".into(),
                "Morning came slowly over the hills.".into(),
                "The end.".into(),
            ],
        )];
        let read = "chapter one it was a dark night the rain stopped morning came slowly over the hills the end";
        let (em, frames) = recording(read, 20);
        let a = align(&book, false, &em, frames, frames as f64 / 50.0);
        let s = &a.sentences;
        assert!(s[2].start < 0.0, "the caption should be left out: {s:?}");
        assert!([0, 1, 3, 4, 5].iter().all(|&k| s[k].start >= 0.0), "{s:?}");
        // "the rain stopped" starts where it's read: after "chapter one it was a dark night".
        let before = letters("chapter one it was a dark night", false).len();
        let at = (20 + before * 4) as f64 / 50.0;
        assert!((s[3].start - at).abs() < 0.3, "rain stopped at {} not {at}", s[3].start);
        assert_eq!(a.sections[0].missing, 1);
    }

    /// Words in the recording that aren't in the book (an ad between two sentences) are left
    /// out of both sentences around them, and everything after is still found.
    #[test]
    fn speech_not_in_the_book_is_left_out() {
        let book = vec![(
            0u32,
            vec![
                "Chapter one.".to_string(),
                "It was a dark night.".into(),
                "The rain stopped.".into(),
                "Morning came slowly over the hills.".into(),
                "The end.".into(),
            ],
        )];
        let (mut em, _) = recording("chapter one it was a dark night", 0);
        let from = em.len() / 28;
        // The ad as the model gives speech: each letter a frame, quiet between.
        for l in letters("this part is brought to you by a coffee shop", false) {
            em.extend((0..28).map(|c| if c == l { -0.3 } else { -6.0 }));
            for _ in 0..3 {
                em.extend((0..28).map(|c| if c == BLANK { -0.05 } else { -6.0 }));
            }
        }
        let to = em.len() / 28;
        em.extend(recording("the rain stopped morning came slowly over the hills the end", 0).0);
        let frames = em.len() / 28;
        let a = align(&book, false, &em, frames, frames as f64 / 50.0);
        let s = &a.sentences;
        assert!(s.iter().all(|t| t.start >= 0.0), "{s:?}");
        let (from, to) = (from as f64 / 50.0, to as f64 / 50.0);
        assert!(s[1].end < from + 0.3, "the night ends at {} (ad from {from})", s[1].end);
        assert!(s[2].start > to - 0.3, "the rain starts at {} (ad to {to})", s[2].start);
    }

    /// Every sentence read: nothing jumped over.
    #[test]
    fn nothing_skipped_when_all_is_read() {
        let book = vec![(0u32, vec!["Chapter one.".to_string(), "It was a dark night.".into(), "The rain stopped.".into(), "The end.".into()])];
        let (em, frames) = recording("chapter one it was a dark night the rain stopped the end", 20);
        let a = align(&book, false, &em, frames, frames as f64 / 50.0);
        assert!(a.sentences.iter().all(|t| t.start >= 0.0), "{:?}", a.sentences);
    }

    #[test]
    fn english_and_chinese_letters() {
        assert_eq!(spoken_english("CHAPTER IV."), "chapter four ");
        let zh: String = letters("寶玉笑道", true).iter().map(|&i| LETTERS.chars().nth(i).unwrap()).collect();
        assert_eq!(zh, "baoyuxiaodao");
    }
}
