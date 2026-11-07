//! Character classes and small text utilities shared by the importers and the normalizer.

/// Han, kana, hangul, bopomofo: characters that are read one by one and set without spaces.
pub fn is_cjk(c: char) -> bool {
    matches!(c as u32,
        0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xF900..=0xFAFF | 0x20000..=0x3FFFF // Han
        | 0x3040..=0x30FF | 0x31F0..=0x31FF // kana
        | 0xAC00..=0xD7AF | 0x1100..=0x11FF // hangul
        | 0x3100..=0x312F | 0x31A0..=0x31BF // bopomofo
        | 0x3005 | 0x3007 // 々 〇
    )
}

/// Punctuation that is full width in CJK text (including the curly quotes, which are
/// "ambiguous width" in Unicode but full width in Chinese fonts).
pub fn is_cjk_punct(c: char) -> bool {
    matches!(c as u32, 0x3000..=0x3004 | 0x3008..=0x303F | 0xFE10..=0xFE1F | 0xFE30..=0xFE4F | 0xFF01..=0xFF0F
        | 0xFF1A..=0xFF20 | 0xFF3B..=0xFF40 | 0xFF5B..=0xFF65)
        || matches!(c, '“' | '”' | '‘' | '’' | '…' | '—' | '·' | '・')
}

pub fn is_wide(c: char) -> bool {
    is_cjk(c) || is_cjk_punct(c)
}

/// Curly quotes, ellipsis, dash, middle dot: full width next to CJK, narrow in Latin text.
/// Columns a line takes: a wide character is two.
pub fn width(s: &str) -> usize {
    s.chars().map(|c| if is_wide(c) { 2 } else { 1 }).sum()
}

fn is_ambiguous_punct(c: char) -> bool {
    matches!(c, '“' | '”' | '‘' | '’' | '…' | '—' | '·')
}

fn is_fullwidth(c: char) -> bool {
    is_cjk(c) || (is_cjk_punct(c) && !is_ambiguous_punct(c))
}

/// Whether a line break between `p` and `n` should vanish instead of becoming a space.
pub fn joins_without_space(p: char, n: char) -> bool {
    (is_fullwidth(p) && (is_fullwidth(n) || is_ambiguous_punct(n)))
        || (is_fullwidth(n) && is_ambiguous_punct(p))
}

/// Characters a sentence must contain to be worth speaking or highlighting.
pub fn is_speakable(c: char) -> bool {
    c.is_alphanumeric() || is_cjk(c)
}

/// Prepares text from a book for layout and speech:
/// - drops zero-width spaces, BOMs and carriage returns;
/// - removes line breaks between CJK characters (browsers would show them as spaces), and turns
///   other line breaks into spaces.
///
/// `before`/`after` are the characters next to `s` in the surrounding text, if any.
pub fn clean(s: &str, before: Option<char>, after: Option<char>) -> String {
    let mut out = String::with_capacity(s.len());
    let chars: Vec<char> = s.chars().filter(|c| !matches!(c, '\u{200B}' | '\u{FEFF}' | '\r')).collect();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if c == '\n' || (c.is_ascii_whitespace() && run_has_newline(&chars, i)) {
            // A run of ASCII whitespace containing a line break.
            let start = i;
            while i < chars.len() && chars[i].is_ascii_whitespace() {
                i += 1;
            }
            let prev = if start == 0 { out.chars().last().or(before) } else { out.chars().last() };
            let next = if i < chars.len() { Some(chars[i]) } else { after };
            let drop = match (prev, next) {
                (Some(p), Some(n)) => joins_without_space(p, n),
                // At the edge of the text: keep a space only if the neighbour is not CJK.
                (Some(p), None) => is_fullwidth(p),
                (None, Some(n)) => is_fullwidth(n),
                (None, None) => false,
            };
            if !drop {
                out.push(' ');
            }
            continue;
        }
        out.push(c);
        i += 1;
    }
    out
}

fn run_has_newline(chars: &[char], start: usize) -> bool {
    chars[start..].iter().take_while(|c| c.is_ascii_whitespace()).any(|&c| c == '\n')
}

/// Collapses whitespace runs to one space and trims. Line breaks between CJK characters
/// disappear entirely.
pub fn collapse_ws(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut pending_space = false;
    for c in s.chars() {
        if c.is_whitespace() && c != '\u{3000}' {
            pending_space = !out.is_empty();
            continue;
        }
        if pending_space {
            let prev = out.chars().last().unwrap_or(' ');
            if !joins_without_space(prev, c) {
                out.push(' ');
            }
            pending_space = false;
        }
        out.push(c);
    }
    out
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Stats {
    /// CJK characters (each is read as one unit).
    pub cjk: u32,
    /// Words in alphabetic scripts.
    pub words: u32,
}

impl Stats {
    pub fn of(s: &str) -> Stats {
        let mut st = Stats::default();
        let mut in_word = false;
        for c in s.chars() {
            if is_cjk(c) {
                st.cjk += 1;
                in_word = false;
            } else if c.is_alphanumeric() || (in_word && (c == '\'' || c == '’' || c == '-')) {
                if !in_word {
                    st.words += 1;
                    in_word = true;
                }
            } else {
                in_word = false;
            }
        }
        st
    }

    pub fn add(&mut self, other: Stats) {
        self.cjk += other.cjk;
        self.words += other.words;
    }

    /// A rough length used for progress: CJK characters count one, words count two.
    pub fn units(&self) -> u32 {
        self.cjk + self.words * 2
    }

    /// Minutes to read: 300 CJK characters or 230 words per minute.
    pub fn read_minutes(&self) -> u32 {
        minutes(self.cjk as f64 / 300.0 + self.words as f64 / 230.0)
    }

    /// Minutes to listen: 220 CJK characters or 160 words per minute.
    pub fn listen_minutes(&self) -> u32 {
        minutes(self.cjk as f64 / 220.0 + self.words as f64 / 160.0)
    }
}

fn minutes(m: f64) -> u32 {
    if m <= 0.0 { 0 } else { (m.round() as u32).max(1) }
}

/// Mostly CJK? Used to pick thresholds when the book's language is unknown or mixed.
pub fn looks_cjk(s: &str) -> bool {
    let st = Stats::of(s);
    st.cjk > 0 && st.cjk as f64 >= st.words as f64 * 2.0
}

/// Detects the main language of a plain text: "zh" or "en" (other alphabetic scripts are
/// treated as "en" for now; only the layout rules depend on it).
pub fn guess_language(s: &str) -> &'static str {
    let sample: String = s.chars().take(20_000).collect();
    let mut kana = 0;
    let mut hangul = 0;
    for c in sample.chars() {
        match c as u32 {
            0x3040..=0x30FF => kana += 1,
            0xAC00..=0xD7AF => hangul += 1,
            _ => {}
        }
    }
    if looks_cjk(&sample) {
        if kana > 50 {
            "ja"
        } else if hangul > 50 {
            "ko"
        } else {
            "zh"
        }
    } else {
        "en"
    }
}

/// Common characters that only exist in one of the two Chinese scripts.
const HANT_ONLY: &str = "們個這說來時為會學與對國過還樣後麼見進現動開種經兒頭實點東問間關機聽讓邊嗎師業體給氣書話電車樂員記認號錢雖衛無愛當從長觀樓夢門閒";
const HANS_ONLY: &str = "们个这说来时为会学与对国过还样后么见进现动开种经儿头实点东问间关机听让边吗师业体给气书话电车乐员记认号钱虽卫无爱当从长观楼梦门闲";

/// "Hant" or "Hans" when a Chinese text is clearly written in one script.
pub fn chinese_script(sample: &str) -> Option<&'static str> {
    let (mut hant, mut hans) = (0usize, 0usize);
    for c in sample.chars().take(50_000) {
        if HANT_ONLY.contains(c) {
            hant += 1;
        } else if HANS_ONLY.contains(c) {
            hans += 1;
        }
    }
    if hant >= 10 && hant > hans * 3 {
        Some("Hant")
    } else if hans >= 10 && hans > hant * 3 {
        Some("Hans")
    } else {
        None
    }
}

/// The language to lay a book out in: what the book declares, unless its text plainly says
/// otherwise (Chinese books labelled "en" or "und" are common), with the script added to a bare
/// "zh" so traditional texts get traditional fonts and punctuation.
pub fn refine_language(declared: Option<&str>, sample: &str) -> String {
    let guessed = guess_language(sample);
    let declared = declared.map(str::trim).filter(|d| !d.is_empty() && !d.eq_ignore_ascii_case("und"));
    let lang = match declared {
        Some(d) => {
            let primary = d.split(['-', '_']).next().unwrap_or(d).to_ascii_lowercase();
            let declared_cjk = matches!(primary.as_str(), "zh" | "ja" | "ko");
            if declared_cjk == (guessed != "en") { d.to_string() } else { guessed.to_string() }
        }
        None => guessed.to_string(),
    };
    if lang.eq_ignore_ascii_case("zh")
        && let Some(script) = chinese_script(sample) {
            return format!("zh-{script}");
        }
    lang
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chinese_scripts() {
        let hant = "只是賈珍雖然此時心意滿足，但里面尤氏又犯了舊疾，不能料理事務，惟恐各誥命來往，虧了禮數，怕人笑話。寶玉听說笑道：這有何難，我荐一個人與你權理這一個月的事，管必妥當。賈珍忙問：是誰？寶玉見座間還有許多親友，不便明言，走至賈珍耳邊說了兩句。賈珍聽了喜不自禁。";
        let hans = "我与父亲不相见已二年余了，我最不能忘记的是他的背影。那年冬天，祖母死了，父亲的差使也交卸了，正是祸不单行的日子，我从北京到徐州，打算跟着父亲奔丧回家。到徐州见着父亲，看见满院狼藉的东西，又想起祖母，不禁簌簌地流下眼泪。父亲说，事已如此，不必难过，好在天无绝人之路！回家变卖典质，父亲还了亏空；又借钱办了丧事。这些日子，家中光景很是惨淡，一半为了丧事，一半为了父亲赋闲。";
        assert_eq!(chinese_script(hant), Some("Hant"));
        assert_eq!(chinese_script(hans), Some("Hans"));
        assert_eq!(refine_language(Some("zh"), hant), "zh-Hant");
        assert_eq!(refine_language(Some("zh-TW"), hant), "zh-TW");
        assert_eq!(refine_language(Some("en"), hans), "zh-Hans");
        assert_eq!(refine_language(None, "It is a truth universally acknowledged."), "en");
        assert_eq!(refine_language(Some("fr"), "C'est la vie."), "fr");
    }

    #[test]
    fn cleaning_line_breaks() {
        assert_eq!(clean("我们过了江，\n进了车站。", None, None), "我们过了江，进了车站。");
        assert_eq!(clean("不能料理事務\n，惟恐", None, None), "不能料理事務，惟恐");
        assert_eq!(clean("hello\n  world", None, None), "hello world");
        assert_eq!(clean("中文\nEnglish", None, None), "中文 English");
        assert_eq!(clean("他\u{200B}忙着\u{FEFF}", None, None), "他忙着");
        // Neighbours from other text nodes decide at the edges.
        assert_eq!(clean("\n强调", Some('文'), None), "强调");
        assert_eq!(clean("\nword", Some('a'), None), " word");
        assert_eq!(clean("keep  double spaces", None, None), "keep  double spaces");
        assert_eq!(clean("the end.”\n“Next", None, None), "the end.” “Next");
        assert_eq!(clean("說道：“\n大師", None, None), "說道：“大師");
    }

    #[test]
    fn collapsing() {
        assert_eq!(collapse_ws("  a \n b  "), "a b");
        assert_eq!(collapse_ws("中\n文"), "中文");
        assert_eq!(collapse_ws("　　缩进"), "　　缩进");
    }

    #[test]
    fn stats_and_minutes() {
        let st = Stats::of("我与父亲不相见已二年余了 and some English words.");
        assert_eq!(st.cjk, 12);
        assert_eq!(st.words, 4);
        assert_eq!(Stats { cjk: 3000, words: 0 }.read_minutes(), 10);
        assert_eq!(Stats { cjk: 3000, words: 0 }.listen_minutes(), 14);
        assert_eq!(Stats { cjk: 10, words: 0 }.read_minutes(), 1);
        assert_eq!(Stats::default().read_minutes(), 0);
    }

    #[test]
    fn languages() {
        assert_eq!(guess_language("我与父亲不相见已二年余了，我最不能忘记的是他的背影。"), "zh");
        assert_eq!(guess_language("It is a truth universally acknowledged."), "en");
    }
}
