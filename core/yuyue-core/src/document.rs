//! The document the WebView loads for one section (docs/dev/reader-contract.md §2): the stored
//! normalized content inside the page template, with the page settings on `<html>` so the
//! first layout is already the right one.

use std::fmt::Write as _;

use serde::{Deserialize, Serialize};

use crate::book::Manifest;
use crate::dom::escape;
use crate::epub::{Kind, encode_path};

/// Only the reader's own script runs; book content can load nothing from outside the book.
pub const CSP: &str = "default-src 'self' data: blob:; style-src 'self' 'unsafe-inline' data:; \
    img-src 'self' data: blob:; font-src 'self' data:; script-src 'self'; media-src 'self' data: blob:; \
    connect-src 'self'";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "lowercase")]
pub enum Paper {
    /// 素白
    Plain,
    /// 暗黑
    Dark,
    /// 纸本
    Kami,
    /// 纸本·夜
    KamiNight,
    /// 墨水屏
    Eink,
}

impl Paper {
    fn css(self) -> &'static str {
        match self {
            Paper::Plain => "plain",
            Paper::Dark => "dark",
            Paper::Kami => "kami",
            Paper::KamiNight => "kaminight",
            Paper::Eink => "eink",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "lowercase")]
pub enum LayoutMode {
    /// 翻页
    Paginated,
    /// 滚动
    Scrolled,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "lowercase")]
pub enum Paging {
    /// The platform's scroll view pages (iOS).
    Native,
    /// CSS scroll snapping inside the WebView (Mac, Android).
    Snap,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "lowercase")]
pub enum Font {
    Sans,
    Serif,
    Kai,
    /// 霞鹜文楷, an open-source 楷体 the app downloads when it is first chosen.
    #[serde(rename = "wenkai")]
    WenKai,
}

/// Everything that shapes a page. Typography comes from the synced reader settings; the
/// geometry (paging, margins that clear the status bar and floating controls, columns) is
/// decided by each device.
#[derive(Clone, Debug, PartialEq)]
pub struct PageSettings {
    pub paper: Paper,
    pub mode: LayoutMode,
    pub paging: Paging,
    /// `None`: the paper's default.
    pub justify: Option<bool>,
    pub indent: Option<bool>,
    /// 中文标点挤压.
    pub compress: bool,
    pub reduced_motion: bool,
    /// CSS pixels.
    pub font_size: f64,
    pub line_height: Option<f64>,
    /// Em after each paragraph.
    pub paragraph_spacing: Option<f64>,
    pub font: Option<Font>,
    /// Left and right page margin, CSS pixels.
    pub margin: f64,
    pub top: f64,
    pub bottom: f64,
    /// 1, or 2 for 双栏 on wide screens.
    pub columns: u8,
}

impl Default for PageSettings {
    fn default() -> Self {
        PageSettings {
            paper: Paper::Plain,
            mode: LayoutMode::Paginated,
            paging: Paging::Snap,
            justify: None,
            indent: None,
            compress: true,
            reduced_motion: false,
            font_size: 18.0,
            line_height: None,
            paragraph_spacing: None,
            font: None,
            margin: 24.0,
            top: 56.0,
            bottom: 88.0,
            columns: 1,
        }
    }
}

/// The full HTML for section `n` of a book, given its stored content (`s/<n>.html`).
pub fn section_document(manifest: &Manifest, n: u32, content: &str, settings: &PageSettings) -> String {
    let section = manifest.sections.get(n as usize);
    let s = settings;
    let mut html = String::with_capacity(content.len() + 2048);
    html.push_str("<!DOCTYPE html>\n");
    let _ = write!(
        html,
        r#"<html lang="{}" data-yy-paper="{}" data-yy-mode="{}" data-yy-paging="{}" data-yy-justify="{}" data-yy-indent="{}" data-yy-compress="{}" data-yy-motion="{}" style="{}">"#,
        escape(&html_lang(manifest.section_lang(n))),
        s.paper.css(),
        match s.mode {
            LayoutMode::Paginated => "paginated",
            LayoutMode::Scrolled => "scrolled",
        },
        match s.paging {
            Paging::Native => "native",
            Paging::Snap => "snap",
        },
        tristate(s.justify),
        tristate(s.indent),
        u8::from(s.compress),
        if s.reduced_motion || s.paper == Paper::Eink { "reduced" } else { "full" },
        escape(&custom_properties(s)),
    );
    html.push_str("\n<head>\n<meta charset=\"utf-8\">\n");
    let _ = writeln!(html, r#"<meta http-equiv="Content-Security-Policy" content="{CSP}">"#);
    html.push_str(
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover\">\n",
    );
    for style in section.map(|s| s.styles.as_slice()).unwrap_or_default() {
        let _ = writeln!(html, r#"<link rel="stylesheet" href="../r/{}">"#, escape(&encode_path(style)));
    }
    html.push_str("<link rel=\"stylesheet\" href=\"/app/reader.css\">\n</head>\n");
    match section.and_then(|s| s.body_class.as_deref()) {
        Some(class) => {
            let _ = writeln!(html, r#"<body class="{}">"#, escape(class));
        }
        None => html.push_str("<body>\n"),
    }
    let kind = match section.map(|s| s.kind) {
        Some(Kind::Image) => r#" data-kind="image""#,
        Some(Kind::Boilerplate) => r#" data-kind="boilerplate""#,
        _ => "",
    };
    let _ = write!(html, r#"<main id="yy-content" class="yy-section" data-section="{n}"{kind}>"#);
    html.push_str(content);
    html.push_str("</main>\n<script src=\"/app/reader.js\"></script>\n</body>\n</html>\n");
    html
}

/// A bare "zh" leaves the WebView to guess which glyphs to use; mainland forms are the
/// common case when the script couldn't be told from the text.
fn html_lang(lang: &str) -> String {
    if lang.eq_ignore_ascii_case("zh") { "zh-CN".to_string() } else { lang.to_string() }
}

fn tristate(v: Option<bool>) -> &'static str {
    match v {
        None => "auto",
        Some(false) => "0",
        Some(true) => "1",
    }
}

fn custom_properties(s: &PageSettings) -> String {
    let clamp = |v: f64, lo: f64, hi: f64, default: f64| if v.is_finite() { v.clamp(lo, hi) } else { default };
    let mut css = format!(
        "--yy-fs:{}px;--yy-margin:{}px;--yy-top:{}px;--yy-bottom:{}px;--yy-cols:{}",
        round(clamp(s.font_size, 8.0, 96.0, 18.0)),
        round(clamp(s.margin, 0.0, 400.0, 24.0)),
        round(clamp(s.top, 0.0, 600.0, 56.0)),
        round(clamp(s.bottom, 0.0, 600.0, 88.0)),
        s.columns.clamp(1, 2),
    );
    if let Some(lh) = s.line_height.filter(|v| v.is_finite()) {
        let _ = write!(css, ";--yy-lh:{}", round(lh.clamp(1.0, 4.0)));
    }
    if let Some(ps) = s.paragraph_spacing.filter(|v| v.is_finite()) {
        let _ = write!(css, ";--yy-ps:{}em", round(ps.clamp(0.0, 4.0)));
    }
    if let Some(font) = s.font {
        // CJK faces have poor Latin letters, so Latin text gets a matching Latin face.
        let (name, latin) = match font {
            Font::Sans => ("sans", "sans"),
            Font::Serif => ("serif", "latin-serif"),
            Font::Kai => ("kaiti", "latin-serif"),
            Font::WenKai => ("wenkai", "latin-serif"),
        };
        let _ = write!(css, ";--yy-font:var(--yy-{name});--yy-font-en:var(--yy-{latin})");
    }
    css
}

/// Two decimals at most: "18", "1.85".
fn round(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::book::{Format, SectionInfo};

    fn manifest() -> Manifest {
        let section = |lang: Option<&str>, styles: Vec<&str>, kind| SectionInfo {
            title: None,
            lang: lang.map(str::to_string),
            styles: styles.into_iter().map(str::to_string).collect(),
            body_class: Some("x-ebookmaker \"q\"".into()),
            linear: true,
            kind,
            continued: false,
            sentences: 1,
            units: 1,
            pages: 0,
        };
        Manifest {
            version: 1,
            id: "abc".into(),
            format: Format::Epub,
            title: "书".into(),
            authors: vec![],
            language: "zh".into(),
            isbn: None,
            cover: None,
            start: 0,
            sections: vec![
                section(None, vec!["OEBPS/style sheet.css", "__styles/0123.css"], Kind::Text),
                section(Some("en"), vec![], Kind::Image),
            ],
            toc: vec![],
            units: 1,
            read_minutes: 1,
            listen_minutes: 1,
        }
    }

    #[test]
    fn document_template() {
        let m = manifest();
        let html = section_document(&m, 0, r#"<p><span class="s" data-s="0">正文。</span></p>"#, &PageSettings::default());
        assert!(html.starts_with("<!DOCTYPE html>\n<html lang=\"zh-CN\" data-yy-paper=\"plain\" data-yy-mode=\"paginated\" data-yy-paging=\"snap\" data-yy-justify=\"auto\" data-yy-indent=\"auto\" data-yy-compress=\"1\" data-yy-motion=\"full\" style=\"--yy-fs:18px;--yy-margin:24px;--yy-top:56px;--yy-bottom:88px;--yy-cols:1\">"), "{html}");
        assert!(html.contains(&format!(r#"<meta http-equiv="Content-Security-Policy" content="{CSP}">"#)));
        assert!(html.contains(r#"<link rel="stylesheet" href="../r/OEBPS/style%20sheet.css">"#), "{html}");
        let publisher = html.find("../r/__styles/0123.css").unwrap();
        assert!(publisher < html.find("/app/reader.css").unwrap(), "the reader's CSS comes last");
        assert!(html.contains(r#"<body class="x-ebookmaker &quot;q&quot;">"#), "{html}");
        assert!(html.contains(r#"<main id="yy-content" class="yy-section" data-section="0"><p><span class="s" data-s="0">正文。</span></p></main>"#));
        assert!(html.trim_end().ends_with("<script src=\"/app/reader.js\"></script>\n</body>\n</html>"));
    }

    #[test]
    fn settings_become_attributes() {
        let m = manifest();
        let s = PageSettings {
            paper: Paper::KamiNight,
            mode: LayoutMode::Scrolled,
            paging: Paging::Native,
            justify: Some(false),
            indent: Some(true),
            compress: false,
            reduced_motion: true,
            font_size: 20.5,
            line_height: Some(1.857),
            paragraph_spacing: Some(0.5),
            font: Some(Font::Kai),
            margin: f64::NAN,
            top: 60.0,
            bottom: 90.0,
            columns: 3,
        };
        let html = section_document(&m, 1, "", &s);
        assert!(html.contains(r#"<html lang="en" data-yy-paper="kaminight" data-yy-mode="scrolled" data-yy-paging="native" data-yy-justify="0" data-yy-indent="1" data-yy-compress="0" data-yy-motion="reduced""#), "{html}");
        assert!(html.contains(r#"style="--yy-fs:20.5px;--yy-margin:24px;--yy-top:60px;--yy-bottom:90px;--yy-cols:2;--yy-lh:1.86;--yy-ps:0.5em;--yy-font:var(--yy-kaiti);--yy-font-en:var(--yy-latin-serif)""#), "{html}");
        assert!(html.contains(r#"data-section="1" data-kind="image""#));
        let eink = PageSettings { paper: Paper::Eink, ..PageSettings::default() };
        assert!(section_document(&m, 0, "", &eink).contains(r#"data-yy-motion="reduced""#));
    }
}
