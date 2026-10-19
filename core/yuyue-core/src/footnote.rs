//! 脚注 (FEATURES §2): the text a note marker points to, for the card the reader opens in place
//! instead of turning to the notes at the back.

use std::sync::LazyLock;

use regex::Regex;

use crate::api::YuyueCore;
use crate::book;
use crate::dom::{self, Element};
use crate::error::Result;

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct Footnote {
    pub text: String,
    /// Which of the notes this chapter points to the same place it is, from 1; with `count`,
    /// "注释 1 / 8".
    pub index: Option<u32>,
    pub count: u32,
    /// Where the notes are, for 到注释页.
    pub section: u32,
    /// The title of that section.
    pub title: Option<String>,
}

/// Longest note shown in the card; the rest is on the notes page.
const MAX_CHARS: usize = 1_200;

/// "[1]", "1.", "①", "注1：", "*" before a note's words (not the "1921" of "1921年"), and the
/// "↩" back links after them.
static LEADING_MARK: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^\s*(?:\[\d+\]|【\d+】|〔\d+〕|\(\d+\)|（\d+）|\d{1,3}(?:\s*[\.．、:：)）]|\s)|[①-⑳㉑-㉟]|注\s*\d*\s*[:：]?|\*+)\s*").unwrap()
});
static TRAILING_MARK: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s*(?:↩\u{FE0E}?|↑|返回|Back)\s*$").unwrap());

const BLOCKS: &[&str] = &["p", "li", "aside", "div", "dd", "dt", "td", "blockquote", "section", "ol", "body"];

#[uniffi::export]
impl YuyueCore {
    /// The note a marker in `from_section` points to (`target` as the reader reports it,
    /// "12#note1"); none when there is no such place or nothing in it to show.
    pub fn footnote(&self, book_id: String, from_section: u32, target: String) -> Result<Option<Footnote>> {
        let dir = self.book_dir(&book_id)?;
        let m = self.manifest(&book_id)?;
        let Some((section, anchor)) = target.split_once('#') else { return Ok(None) };
        let Ok(section) = section.parse::<u32>() else { return Ok(None) };
        if section as usize >= m.sections.len() || anchor.is_empty() {
            return Ok(None);
        }
        let page = dom::parse_html(&book::section_html(&dir, section)?);
        let Some(text) = note_text(&page, anchor) else { return Ok(None) };
        let text = self.rules_for(&book_id, false)?.apply(&text);

        // The markers in the chapter read, pointing into the same notes page.
        let mut targets: Vec<String> = Vec::new();
        if let Ok(html) = book::section_html(&dir, from_section) {
            let from = dom::parse_html(&html);
            let mut refs = Vec::new();
            from.find_all(&|e| e.is("a") && e.has_class("yy-noteref"), &mut refs);
            let prefix = format!("{section}#");
            for t in refs.iter().filter_map(|e| e.attr("data-yy-target")) {
                if t.starts_with(&prefix) && !targets.iter().any(|x| x == t) {
                    targets.push(t.to_string());
                }
            }
        }
        let index = targets.iter().position(|t| *t == target).map(|i| i as u32 + 1);
        Ok(Some(Footnote {
            text,
            index,
            count: targets.len() as u32,
            section,
            title: m.sections[section as usize].title.clone(),
        }))
    }
}

/// The words of the note with this id: the element itself when it is a block, else the block
/// it is in ("<p><a id="n1">[1]</a> …</p>").
fn note_text(page: &Element, id: &str) -> Option<String> {
    let path = page.find_path(&|e| e.attr("id") == Some(id))?;
    let block = (1..=path.len())
        .rev()
        .filter_map(|n| page.get(&path[..n]))
        .find(|e| BLOCKS.iter().any(|b| e.is(b)))?;
    // A heading or a whole chapter isn't a note.
    if block.is("body") || block.is("section") && block.text_content().chars().count() > MAX_CHARS * 2 {
        return None;
    }
    let raw = block.text_content();
    let collapsed = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    let text = TRAILING_MARK.replace(&collapsed, "");
    let text = LEADING_MARK.replace(&text, "").trim().to_string();
    if text.is_empty() {
        return None;
    }
    Some(if text.chars().count() > MAX_CHARS { format!("{}…", text.chars().take(MAX_CHARS).collect::<String>()) } else { text })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_the_note_and_drops_its_markers() {
        let page = dom::parse_html(
            r##"<h2>注释</h2><aside class="yy-footnote" id="fn1"><p>[1] 曲尺是木匠画直角用的尺。 ↩</p></aside><p><a id="n2" href="#">2</a>. 短衣帮：穿短衣的劳动者。</p><ol><li id="e3"><p>③ 第三条。</p></li></ol>"##,
        );
        assert_eq!(note_text(&page, "fn1").as_deref(), Some("曲尺是木匠画直角用的尺。"));
        assert_eq!(note_text(&page, "n2").as_deref(), Some("短衣帮：穿短衣的劳动者。"));
        assert_eq!(note_text(&page, "e3").as_deref(), Some("第三条。"));
        assert_eq!(note_text(&page, "nothing"), None);
        let year = dom::parse_html(r#"<p id="y">1921年写成。</p>"#);
        assert_eq!(note_text(&year, "y").as_deref(), Some("1921年写成。"));
    }
}
