//! Chinese punctuation compression (标点挤压) for adjacent full-width punctuation.
//!
//! Each full-width punctuation mark is drawn in one half of its em box; the other half is blank.
//! When two marks meet, one blank half is removed so the pair takes 1.5em instead of 2em
//! (CLREQ §3.1.6). The reader applies the marks core finds here:
//! - `pz-r`: drop the blank on the right (a closing mark followed by another mark);
//! - `pz-l`: drop the blank on the left (an opening mark preceded by another opening mark).

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Style {
    /// Mainland style (zh-CN, zh-Hans, ja): ，。、；：！？ sit in the left half.
    Simplified,
    /// Taiwan/Hong Kong style: ，。、；：！？ are centred, only brackets and quotes compress.
    Traditional,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mark {
    Right,
    Left,
}

impl Mark {
    pub fn class(self) -> &'static str {
        match self {
            Mark::Right => "pz-r",
            Mark::Left => "pz-l",
        }
    }
}

/// The compression style for a book language, or `None` if the language doesn't use
/// full-width punctuation.
pub fn style_for(lang: &str) -> Option<Style> {
    let l = lang.to_ascii_lowercase();
    if l.starts_with("zh") {
        if l.contains("tw") || l.contains("hk") || l.contains("mo") || l.contains("hant") {
            Some(Style::Traditional)
        } else {
            Some(Style::Simplified)
        }
    } else if l.starts_with("ja") {
        Some(Style::Simplified)
    } else {
        None
    }
}

fn is_opening(c: char) -> bool {
    matches!(c, '“' | '‘' | '「' | '『' | '（' | '《' | '〈' | '【' | '〔' | '［' | '｛' | '〖' | '〘')
}

fn is_closing(c: char, style: Style) -> bool {
    let brackets = matches!(c, '”' | '’' | '」' | '』' | '）' | '》' | '〉' | '】' | '〕' | '］' | '｝' | '〗' | '〙');
    let stops = matches!(c, '，' | '。' | '、' | '；' | '：' | '？' | '！' | '．');
    brackets || (stops && style == Style::Simplified)
}

/// Byte offsets of the characters in `text` that lose half their width.
pub fn marks(text: &str, style: Style) -> Vec<(usize, Mark)> {
    let mut out = Vec::new();
    let mut prev: Option<(usize, char)> = None;
    for (i, c) in text.char_indices() {
        if let Some((pi, p)) = prev {
            if is_closing(p, style) && (is_closing(c, style) || is_opening(c)) {
                out.push((pi, Mark::Right));
            } else if is_opening(p) && is_opening(c) {
                out.push((i, Mark::Left));
            }
        }
        prev = Some((i, c));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn marked(text: &str, style: Style) -> String {
        let marks = marks(text, style);
        let mut out = String::new();
        for (i, c) in text.char_indices() {
            match marks.iter().find(|(m, _)| *m == i) {
                Some((_, Mark::Right)) => out.push_str(&format!("[{c}>")),
                Some((_, Mark::Left)) => out.push_str(&format!("<{c}]")),
                None => out.push(c),
            }
        }
        out
    }

    #[test]
    fn pairs() {
        let s = Style::Simplified;
        assert_eq!(marked("不要走动。”我看", s), "不要走动[。>”我看");
        assert_eq!(marked("叫《“红楼”梦》（又名《石头记》）。", s), "叫《<“]红楼”梦[》>（又名《石头记[》>[）>。");
        assert_eq!(marked("真的吗？！", s), "真的吗[？>！");
        assert_eq!(marked("他说：“好。”", s), "他说[：>“好[。>”");
        assert_eq!(marked("没有挤压。", s), "没有挤压。");
    }

    #[test]
    fn traditional_keeps_centred_stops() {
        let t = Style::Traditional;
        assert_eq!(marked("說道：「好。」", t), "說道：「好。」");
        assert_eq!(marked("「『書』」", t), "「<『]書[』>」");
    }

    #[test]
    fn styles() {
        assert_eq!(style_for("zh-CN"), Some(Style::Simplified));
        assert_eq!(style_for("zh"), Some(Style::Simplified));
        assert_eq!(style_for("zh-Hant-TW"), Some(Style::Traditional));
        assert_eq!(style_for("en"), None);
    }
}
