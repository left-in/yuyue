//! 读音: how a Chinese sentence is read, syllable by syllable (听书开发方案 §4.2). Forced
//! alignment needs it to lay the book's words along the recording; 分角色朗读 will use it to
//! put a voice right where it misreads.
//!
//! Each character's usual reading comes from the `pinyin` crate. Where a phrase reads its
//! characters otherwise (银行 yín háng, 了解 liǎo jiě), the phrase list in
//! data/pinyin-phrases.txt says so; the longest phrase that fits wins. Then a few rules the
//! lists can't hold: 一 and 不 change their tone before another syllable, 儿 after a syllable
//! joins it, and numbers are read as words. 繁體 is read through its 简体.
//!
//! Not yet: a name read one way all through the book, and the reader's own corrections.

use std::collections::HashMap;
use std::sync::OnceLock;

use pinyin::ToPinyin;

/// One syllable as it's read, or a character that isn't read (punctuation, a letter).
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct Syllable {
    /// The character's place in the text (characters, not bytes).
    pub at: u32,
    /// `hang2`; the tone 1–4, or 5 for a light one.
    pub pinyin: String,
}

fn phrases() -> &'static (HashMap<String, Vec<String>>, usize) {
    static P: OnceLock<(HashMap<String, Vec<String>>, usize)> = OnceLock::new();
    P.get_or_init(|| {
        let mut map = HashMap::new();
        let mut longest = 0;
        for line in include_str!("../data/pinyin-phrases.txt").lines() {
            if line.starts_with('#') {
                continue;
            }
            let Some((p, r)) = line.split_once('\t') else { continue };
            longest = longest.max(p.chars().count());
            map.insert(p.to_string(), r.split(' ').map(str::to_string).collect());
        }
        (map, longest)
    })
}

fn is_han(c: char) -> bool {
    ('\u{4e00}'..='\u{9fff}').contains(&c) || ('\u{3400}'..='\u{4dbf}').contains(&c)
}

/// The syllables of `text`, in order. Characters that aren't read are left out; a number is
/// read as its words, all its syllables at the number's first digit.
pub fn syllables(text: &str) -> Vec<Syllable> {
    // Read 繁體 through its 简体: the phrase list is in 简体, and the readings are the same.
    let simple: Vec<char> = zhconv::zhconv(text, zhconv::Variant::ZhHans).chars().collect();
    let original: Vec<char> = text.chars().collect();
    // zhconv keeps one character for one in all but rare cases; when it doesn't, read as it is.
    let chars = if simple.len() == original.len() { simple } else { original };
    let (table, longest) = phrases();
    let mut out: Vec<Syllable> = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if c.is_ascii_digit() {
            let start = i;
            while i < chars.len() && (chars[i].is_ascii_digit() || chars[i] == '.' && chars.get(i + 1).is_some_and(char::is_ascii_digit)) {
                i += 1;
            }
            let number: String = chars[start..i].iter().collect();
            // 1978 年 is read 一九七八年, digit by digit, not as how many.
            let year = number.len() == 4 && chars[i..].iter().find(|c| **c != ' ').is_some_and(|&c| c == '年');
            let words = if year { number.chars().map(|c| DIGITS[c.to_digit(10).unwrap() as usize].to_string()).collect() } else { number_words(&number) };
            for p in words {
                out.push(Syllable { at: start as u32, pinyin: p });
            }
            continue;
        }
        if !is_han(c) {
            i += 1;
            continue;
        }
        // The longest phrase from here that the list knows.
        let mut matched = false;
        for n in (2..=(*longest).min(chars.len() - i)).rev() {
            if !chars[i..i + n].iter().all(|&c| is_han(c)) {
                continue;
            }
            let key: String = chars[i..i + n].iter().collect();
            if let Some(r) = table.get(&key) {
                for (k, p) in r.iter().enumerate() {
                    out.push(Syllable { at: (i + k) as u32, pinyin: p.clone() });
                }
                i += n;
                matched = true;
                break;
            }
        }
        if matched {
            continue;
        }
        if let Some(p) = c.to_pinyin() {
            let mut p = p.with_tone_num_end().to_string();
            // A light tone comes with no number; write it as 5, as the phrase list does.
            if !p.ends_with(|c: char| c.is_ascii_digit()) {
                p.push('5');
            }
            // 得 的 了 着 子 们 after another syllable are light: 觉得, 我们, 桌子.
            if matches!(c, '得' | '的' | '了' | '着' | '子' | '们' | '么' | '吗' | '呢' | '吧') && i > 0 && is_han(chars[i - 1]) {
                p = format!("{}5", p.trim_end_matches(|c: char| c.is_ascii_digit()));
            }
            out.push(Syllable { at: i as u32, pinyin: p });
        }
        i += 1;
    }
    tone_changes(&mut out, &chars);
    out
}

/// 一 and 不 before a fourth tone read second (不要 bú yào, 一个 yí gè), and 一 before any other
/// tone reads fourth (一天 yì tiān) — except counting (第一, 一二三), where it stays first.
/// 儿 after a syllable is that syllable's r (哪儿 nǎr) when it isn't a word of its own.
fn tone_changes(out: &mut Vec<Syllable>, chars: &[char]) {
    let mut k = 0;
    while k < out.len() {
        let c = chars.get(out[k].at as usize).copied();
        let next_tone = out.get(k + 1).filter(|n| n.at == out[k].at + 1).and_then(|n| n.pinyin.chars().last());
        match (c, next_tone) {
            (Some('不'), Some('4')) if out[k].pinyin == "bu4" => out[k].pinyin = "bu2".into(),
            (Some('一'), Some(t)) if out[k].pinyin == "yi1" => {
                let counting = out[k].at > 0 && matches!(chars.get(out[k].at as usize - 1), Some('第' | '十' | '一' | '二' | '三' | '四' | '五' | '六' | '七' | '八' | '九' | '〇' | '零' | '百' | '千' | '万'))
                    || matches!(chars.get(out[k].at as usize + 1), Some('二' | '三' | '四' | '五' | '六' | '七' | '八' | '九' | '十' | '〇' | '零'));
                if !counting {
                    out[k].pinyin = if t == '4' || t == '5' { "yi2".into() } else { "yi4".into() };
                }
            }
            _ => {}
        }
        // 儿化: 儿 right after a syllable, not 儿子 / 儿童 / 女儿 (the list reads those).
        if c == Some('儿') && out[k].pinyin == "er2" && k > 0 && out[k - 1].at + 1 == out[k].at {
            let next = chars.get(out[k].at as usize + 1).copied();
            if !matches!(next, Some('子' | '童' | '女' | '孙' | '时' | '科' | '歌' | '媳')) {
                let prev = &mut out[k - 1].pinyin;
                let tone = prev.pop().unwrap_or('5');
                if !prev.ends_with('r') {
                    prev.push('r');
                }
                prev.push(tone);
                out.remove(k);
                continue;
            }
        }
        k += 1;
    }
}

const DIGITS: [&str; 10] = ["ling2", "yi1", "er4", "san1", "si4", "wu3", "liu4", "qi1", "ba1", "jiu3"];

/// A number read out: 1894 as a year-like run of digits reads digit by digit (yī bā jiǔ sì);
/// up to four digits otherwise as a quantity (三百二十五); a decimal point as 点.
fn number_words(n: &str) -> Vec<String> {
    let (whole, frac) = n.split_once('.').unwrap_or((n, ""));
    let mut out = Vec::new();
    let digit = |c: char| DIGITS[c.to_digit(10).unwrap() as usize].to_string();
    if whole.len() > 4 || whole.len() > 1 && whole.starts_with('0') {
        out.extend(whole.chars().map(digit));
    } else {
        out.extend(quantity(whole.parse().unwrap_or(0)));
    }
    if !frac.is_empty() {
        out.push("dian3".into());
        out.extend(frac.chars().map(digit));
    }
    out
}

fn quantity(n: u32) -> Vec<String> {
    if n == 0 {
        return vec!["ling2".into()];
    }
    let units = ["", "shi2", "bai3", "qian1"];
    let digits: Vec<u32> = n.to_string().chars().map(|c| c.to_digit(10).unwrap()).collect();
    let mut out = Vec::new();
    let mut zero = false;
    for (i, &d) in digits.iter().enumerate() {
        let place = digits.len() - 1 - i;
        if d == 0 {
            zero = true;
            continue;
        }
        if zero && !out.is_empty() {
            out.push("ling2".into());
        }
        zero = false;
        // 十五, not 一十五, at the front.
        if !(d == 1 && place == 1 && out.is_empty()) {
            out.push(if d == 2 && place >= 2 { "liang3".into() } else { DIGITS[d as usize].to_string() });
        }
        if place > 0 {
            out.push(units[place].into());
        }
    }
    out
}

/// The pinyin of a sentence without tones, space-separated: what forced alignment lays along
/// the recording.
pub fn plain(text: &str) -> String {
    syllables(text).iter().map(|s| s.pinyin.trim_end_matches(|c: char| c.is_ascii_digit()).to_string()).collect::<Vec<_>>().join(" ")
}

/// For forced alignment: toneless, ü as v, and 儿 a syllable of its own (the acoustic model
/// knows yu and er, not yur). One entry per syllable, with where its character is.
pub fn for_alignment(text: &str) -> Vec<Syllable> {
    let mut out = Vec::new();
    for s in syllables(text) {
        let p = s.pinyin.trim_end_matches(|c: char| c.is_ascii_digit()).replace('ü', "v");
        if p.len() > 2 && p.ends_with('r') && p != "er" {
            out.push(Syllable { at: s.at, pinyin: p[..p.len() - 1].to_string() });
            out.push(Syllable { at: s.at + 1, pinyin: "er".into() });
        } else {
            out.push(Syllable { at: s.at, pinyin: p });
        }
    }
    out
}

#[uniffi::export]
pub fn reading(text: String) -> Vec<Syllable> {
    syllables(&text)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read(t: &str) -> String {
        syllables(t).into_iter().map(|s| s.pinyin).collect::<Vec<_>>().join(" ")
    }

    #[test]
    fn phrases_over_characters() {
        assert_eq!(read("银行行长"), "yin2 hang2 hang2 zhang3");
        assert_eq!(read("我还是觉得"), "wo3 hai2 shi4 jue2 de5");
        assert_eq!(read("他去睡觉了"), "ta1 qu4 shui4 jiao4 le5");
    }

    #[test]
    fn years_digit_by_digit() {
        assert_eq!(read("1978 年"), "yi1 jiu3 qi1 ba1 nian2");
        assert_eq!(read("1978年"), "yi1 jiu3 qi1 ba1 nian2");
        assert_eq!(read("4892 米"), read("四千八百九十二米"));
    }

    #[test]
    fn traditional_reads_as_simplified() {
        assert_eq!(read("銀行"), read("银行"));
        assert_eq!(syllables("寶玉，笑道")[2].at, 3);
    }

    #[test]
    fn yi_and_bu() {
        assert_eq!(read("不要"), "bu2 yao4");
        assert_eq!(read("不好"), "bu4 hao3");
        assert_eq!(read("一个"), "yi2 ge4");
        assert_eq!(read("一天"), "yi4 tian1");
        assert_eq!(read("第一"), "di4 yi1");
    }

    #[test]
    fn er_joins_the_syllable() {
        assert_eq!(read("哪儿"), "nar3");
        assert_eq!(read("儿子"), "er2 zi5");
    }

    #[test]
    fn for_the_aligner() {
        let a: Vec<String> = for_alignment("一會兒，女人").into_iter().map(|s| s.pinyin).collect();
        assert_eq!(a, ["yi", "hui", "er", "nv", "ren"]);
    }

    #[test]
    fn numbers() {
        assert_eq!(read("325"), "san1 bai3 er4 shi2 wu3");
        assert_eq!(read("15"), "shi2 wu3");
        assert_eq!(read("2003"), "liang3 qian1 ling2 san1");
        assert_eq!(read("3.14"), "san1 dian3 yi1 si4");
        assert_eq!(read("13800138000"), "yi1 san1 ba1 ling2 ling2 yi1 san1 ba1 ling2 ling2 ling2");
    }
}
