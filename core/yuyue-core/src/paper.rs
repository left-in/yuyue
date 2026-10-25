//! 我的纸: papers the reader makes beside the five presets.
//!
//! The reader picks a background from twelve made for reading (six for the day, six for the
//! night) or moves it within bounds that stay restful (`paper_palette`), one of four textures,
//! and the text: picked for the background, or one of four inks that all read well. Every other
//! colour on the page (grey text, rules, highlights, buttons) is worked out from those, the same
//! on every device. Each paper reads like a preset (素白 or 纸本: face, spacing, indents) and the
//! page takes that preset's typography, with this paper's colours over it.
//!
//! Registers: `settings/paper/<id>` · `name` / `bg` / `ink` / `layout` / `texture` / `order` /
//! `deleted` (`grain` from before textures reads as `texture: grain`). Under `settings/`, so they
//! sync and back up with the other settings.

use std::collections::BTreeMap;
use std::fmt::Write as _;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::api::{YuyueCore, lock, now_ms};
use crate::document::Paper;
use crate::error::{CoreError, Result};
use crate::store::Store;

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct CustomPaper {
    /// Empty for one not saved yet.
    pub id: String,
    pub name: String,
    /// `#RRGGBB`.
    pub bg: String,
    /// `#RRGGBB`; `None` picks one that reads well on `bg`.
    pub ink: Option<String>,
    /// The preset it reads like: `Plain` (素白: sans, space between paragraphs) or `Kami`
    /// (纸本: serif, first-line indents). Their night sides count as the same.
    pub layout: Paper,
    pub texture: PaperTexture,
}

/// 纹理, drawn over the background: nothing to download, no pictures of anyone's.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "lowercase")]
pub enum PaperTexture {
    None,
    /// 细颗粒: the e-ink paper's grain.
    Grain,
    /// 宣纸: long faint fibres.
    Xuan,
    /// 亚麻: a fine weave.
    Linen,
}

impl PaperTexture {
    /// `data-yy-texture` (reader contract §2).
    pub(crate) fn css(self) -> Option<&'static str> {
        match self {
            PaperTexture::None => None,
            PaperTexture::Grain => Some("grain"),
            PaperTexture::Xuan => Some("xuan"),
            PaperTexture::Linen => Some("linen"),
        }
    }
}

/// A colour with the name it gives a new paper.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct PaperSwatch {
    pub name: String,
    /// `#RRGGBB`.
    pub color: String,
}

/// What 调纸 offers on one side (day or night): the made backgrounds, the inks, and how far
/// 微调 goes. Hue is 0–360, saturation and lightness 0–100.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct PaperPalette {
    pub swatches: Vec<PaperSwatch>,
    pub inks: Vec<PaperSwatch>,
    /// 浓淡 stops here: stronger colours tire the eyes.
    pub saturation_max: f64,
    /// 深浅 stays in this band: between the day's and the night's, neither black nor white text
    /// reads well.
    pub lightness_min: f64,
    pub lightness_max: f64,
}

#[derive(Clone, Copy, Debug, PartialEq, uniffi::Record)]
pub struct PaperHsl {
    pub h: f64,
    pub s: f64,
    pub l: f64,
}

/// Every colour a page and the controls over it take from a paper. Opaque ones are `#RRGGBB`,
/// `glass` is `#RRGGBBAA`.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct PaperColors {
    pub dark: bool,
    /// The preset the page takes its typography and marks from, and that older apps show.
    pub preset: Paper,
    pub bg: String,
    pub ink: String,
    pub ink2: String,
    pub line: String,
    pub accent: String,
    pub hl: String,
    pub wave: String,
    pub glass: String,
    pub main: String,
    pub on_main: String,
    pub paper_accent: String,
    /// Text against background, 1–21 (WCAG). Under 4.5 is hard to read.
    pub contrast: f64,
}

/// Contrast under this is hard to read.
pub const READABLE_CONTRAST: f64 = 4.5;

/// (中文名, English, hue, saturation, lightness)
const DAY: [(&str, &str, f64, f64, f64); 6] = [
    ("素白", "Paper white", 40.0, 25.0, 97.0),
    ("米黄", "Cream", 44.0, 48.0, 90.0),
    ("豆沙绿", "Sage", 115.0, 24.0, 85.0),
    ("天青", "Celadon", 203.0, 32.0, 90.0),
    ("藕荷", "Blush", 8.0, 40.0, 91.0),
    ("雾灰", "Mist", 40.0, 6.0, 89.0),
];
const NIGHT: [(&str, &str, f64, f64, f64); 6] = [
    ("墨夜", "Ink night", 220.0, 10.0, 8.0),
    ("深蓝", "Deep blue", 216.0, 30.0, 13.0),
    ("墨绿", "Pine", 150.0, 20.0, 11.0),
    ("茶褐", "Tea brown", 28.0, 22.0, 12.0),
    ("暮紫", "Dusk", 258.0, 16.0, 13.0),
    ("炭灰", "Charcoal", 0.0, 0.0, 15.0),
];
const DAY_INKS: [(&str, &str, &str); 4] = [("墨", "Ink", "#1D1E20"), ("褐", "Brown", "#3B2D20"), ("蓝", "Blue", "#1E2E48"), ("绿", "Green", "#1F3326")];
const NIGHT_INKS: [(&str, &str, &str); 4] = [("白", "White", "#E7E1D3"), ("灰", "Grey", "#CDD0D5"), ("蓝", "Blue", "#C3D2E4"), ("金", "Gold", "#E6D3A6")];
const DAY_BAND: (f64, f64) = (82.0, 98.0);
const NIGHT_BAND: (f64, f64) = (5.0, 16.0);
const SATURATION_MAX: f64 = 50.0;

#[derive(Clone, Copy, Debug, PartialEq)]
struct Rgb(f64, f64, f64);

impl Rgb {
    const BLACK: Rgb = Rgb(0.0, 0.0, 0.0);
    const WHITE: Rgb = Rgb(255.0, 255.0, 255.0);

    fn parse(s: &str) -> Option<Rgb> {
        let h = s.trim().strip_prefix('#')?;
        if h.len() != 6 || !h.bytes().all(|b| b.is_ascii_hexdigit()) {
            return None;
        }
        let at = |i: usize| u8::from_str_radix(&h[i..i + 2], 16).ok().map(f64::from);
        Some(Rgb(at(0)?, at(2)?, at(4)?))
    }

    fn from_hsl(h: f64, s: f64, l: f64) -> Rgb {
        let (s, l) = (s / 100.0, l / 100.0);
        let a = s * l.min(1.0 - l);
        let f = |n: f64| {
            let k = (n + h.rem_euclid(360.0) / 30.0) % 12.0;
            (l - a * (k - 3.0).min(9.0 - k).clamp(-1.0, 1.0)) * 255.0
        };
        Rgb(f(0.0), f(8.0), f(4.0))
    }

    fn hsl(self) -> PaperHsl {
        let (r, g, b) = (self.0 / 255.0, self.1 / 255.0, self.2 / 255.0);
        let (max, min) = (r.max(g).max(b), r.min(g).min(b));
        let l = (max + min) / 2.0;
        let d = max - min;
        if d < 1e-9 {
            return PaperHsl { h: 0.0, s: 0.0, l: l * 100.0 };
        }
        let s = d / (1.0 - (2.0 * l - 1.0).abs());
        let h = if max == r {
            60.0 * ((g - b) / d).rem_euclid(6.0)
        } else if max == g {
            60.0 * ((b - r) / d + 2.0)
        } else {
            60.0 * ((r - g) / d + 4.0)
        };
        PaperHsl { h, s: s * 100.0, l: l * 100.0 }
    }

    fn hex(self) -> String {
        let c = |v: f64| v.round().clamp(0.0, 255.0) as u8;
        format!("#{:02X}{:02X}{:02X}", c(self.0), c(self.1), c(self.2))
    }

    /// `t` of the way from self to `other`.
    fn mix(self, other: Rgb, t: f64) -> Rgb {
        Rgb(self.0 + (other.0 - self.0) * t, self.1 + (other.1 - self.1) * t, self.2 + (other.2 - self.2) * t)
    }

    /// WCAG relative luminance, 0–1.
    fn luminance(self) -> f64 {
        let ch = |v: f64| {
            let v = v / 255.0;
            if v <= 0.03928 { v / 12.92 } else { ((v + 0.055) / 1.055).powf(2.4) }
        };
        0.2126 * ch(self.0) + 0.7152 * ch(self.1) + 0.0722 * ch(self.2)
    }
}

fn contrast(a: Rgb, b: Rgb) -> f64 {
    let (x, y) = (a.luminance(), b.luminance());
    (x.max(y) + 0.05) / (x.min(y) + 0.05)
}

/// Darker than this, a background is a night paper: light text, dimmed marks.
fn is_dark(bg: Rgb) -> bool {
    bg.luminance() < 0.18
}

/// Text that reads well on `bg` and keeps a little of its hue, like 纸本's warm black.
fn auto_ink(bg: Rgb) -> Rgb {
    let toward = if is_dark(bg) { Rgb::WHITE } else { Rgb::BLACK };
    let mut t = 0.84;
    let mut ink = bg.mix(toward, t);
    while contrast(ink, bg) < 9.0 && t < 1.0 {
        t = (t + 0.02).min(1.0);
        ink = bg.mix(toward, t);
    }
    ink
}

/// The preset of `layout`'s typography on the side (day or night) of `dark`.
fn preset(layout: Paper, dark: bool) -> Paper {
    match (layout, dark) {
        (Paper::Plain | Paper::Dark, false) => Paper::Plain,
        (Paper::Plain | Paper::Dark, true) => Paper::Dark,
        (_, false) => Paper::Kami,
        (_, true) => Paper::KamiNight,
    }
}

fn layout_of(p: Paper) -> Paper {
    match p {
        Paper::Plain | Paper::Dark => Paper::Plain,
        _ => Paper::Kami,
    }
}

/// The colours of `paper`. A colour that isn't `#RRGGBB` is taken as white (background) or
/// left to be picked (text).
#[uniffi::export]
pub fn paper_colors(paper: CustomPaper) -> PaperColors {
    let bg = Rgb::parse(&paper.bg).unwrap_or(Rgb::WHITE);
    let dark = is_dark(bg);
    let ink = paper.ink.as_deref().and_then(Rgb::parse).unwrap_or_else(|| auto_ink(bg));
    // The presets' blues: deep on day papers, pale on night ones.
    let main = if dark { Rgb(143.0, 168.0, 200.0) } else { Rgb(43.0, 76.0, 126.0) };
    let (hl, wave, glass) = if dark {
        (bg.mix(Rgb(251.0, 231.0, 160.0), 0.24), Rgb(229.0, 122.0, 110.0), bg.mix(Rgb::WHITE, 0.08))
    } else {
        (bg.mix(Rgb(247.0, 214.0, 100.0), 0.5), Rgb(239.0, 127.0, 113.0), bg.mix(Rgb::WHITE, 0.4))
    };
    PaperColors {
        dark,
        preset: preset(paper.layout, dark),
        bg: bg.hex(),
        ink: ink.hex(),
        ink2: bg.mix(ink, 0.55).hex(),
        line: bg.mix(ink, 0.1).hex(),
        accent: ink.hex(),
        hl: hl.hex(),
        wave: wave.hex(),
        glass: format!("{}D6", glass.hex()),
        main: main.hex(),
        on_main: if dark { bg.hex() } else { Rgb::WHITE.hex() },
        paper_accent: main.hex(),
        contrast: (contrast(ink, bg) * 100.0).round() / 100.0,
    }
}

/// What `yy.applySettings` takes as `paperStyle` for `paper`.
#[uniffi::export]
pub fn paper_style(paper: CustomPaper) -> String {
    page_style(&paper_colors(paper))
}

/// The custom properties over the preset's (reader contract §2), as `name:value;…`.
pub(crate) fn page_style(c: &PaperColors) -> String {
    let mut css = String::new();
    for (name, value) in [
        ("bg", &c.bg),
        ("ink", &c.ink),
        ("ink-2", &c.ink2),
        ("line", &c.line),
        ("accent", &c.accent),
        ("hl", &c.hl),
        ("wave", &c.wave),
        ("glass", &c.glass),
        ("main", &c.main),
        ("on-main", &c.on_main),
        ("pa", &c.paper_accent),
    ] {
        let _ = write!(css, "--yy-p-{name}:{value};");
    }
    css.push_str(if c.dark { "color-scheme:dark" } else { "color-scheme:light" });
    css
}

/// 调纸's choices for the day (`night` false) or the night.
#[uniffi::export]
pub fn paper_palette(night: bool) -> PaperPalette {
    let tr = crate::i18n::tr;
    let (made, inks, band) = if night { (&NIGHT, &NIGHT_INKS, NIGHT_BAND) } else { (&DAY, &DAY_INKS, DAY_BAND) };
    PaperPalette {
        swatches: made.iter().map(|&(zh, en, h, s, l)| PaperSwatch { name: tr(zh, en), color: Rgb::from_hsl(h, s, l).hex() }).collect(),
        inks: inks.iter().map(|&(zh, en, c)| PaperSwatch { name: tr(zh, en), color: c.to_string() }).collect(),
        saturation_max: SATURATION_MAX,
        lightness_min: band.0,
        lightness_max: band.1,
    }
}

/// `#RRGGBB` as hue, saturation and lightness, for 微调 (white if it isn't a colour).
#[uniffi::export]
pub fn paper_hsl(color: String) -> PaperHsl {
    Rgb::parse(&color).unwrap_or(Rgb::WHITE).hsl()
}

/// The background 微调 lands on: kept within the side's bounds, so it stays restful and readable.
#[uniffi::export]
pub fn paper_color(hsl: PaperHsl, night: bool) -> String {
    let (lo, hi) = if night { NIGHT_BAND } else { DAY_BAND };
    Rgb::from_hsl(hsl.h, hsl.s.clamp(0.0, SATURATION_MAX), hsl.l.clamp(lo, hi)).hex()
}

/// The made colour `bg` is close to, or 我的纸.
fn suggested_name(bg: Rgb) -> String {
    let c = bg.hsl();
    let made = if is_dark(bg) { &NIGHT } else { &DAY };
    made.iter()
        .map(|&(zh, en, h, s, l)| {
            let dh = (h - c.h).abs().min(360.0 - (h - c.h).abs());
            (dh * (s + c.s) / 100.0 + (s - c.s).abs() * 0.6 + (l - c.l).abs() * 2.0, zh, en)
        })
        .min_by(|a, b| a.0.total_cmp(&b.0))
        .filter(|m| m.0 < 14.0)
        .map_or_else(|| crate::i18n::tr("我的纸", "My paper"), |(_, zh, en)| crate::i18n::tr(zh, en))
}

fn check_id(id: &str) -> Result<()> {
    if id.len() == 16 && id.bytes().all(|b| b.is_ascii_hexdigit()) { Ok(()) } else { Err(CoreError::not_found("paper")) }
}

fn new_id() -> String {
    format!("{:016x}", getrandom::u64().unwrap_or_else(|_| now_ms() as u64 ^ (std::process::id() as u64) << 40))
}

fn colour(s: &str) -> Result<String> {
    Rgb::parse(s).map(Rgb::hex).ok_or_else(|| CoreError::Invalid { detail: format!("not a colour: {s}") })
}

fn read(id: &str, f: &BTreeMap<String, Value>) -> Option<(f64, CustomPaper)> {
    if f.get("deleted") == Some(&json!(true)) {
        return None;
    }
    let bg = f.get("bg")?.as_str().and_then(Rgb::parse)?.hex();
    Some((
        f.get("order").and_then(Value::as_f64).unwrap_or(0.0),
        CustomPaper {
            id: id.to_string(),
            name: f.get("name").and_then(Value::as_str).unwrap_or_default().to_string(),
            bg,
            ink: f.get("ink").and_then(Value::as_str).and_then(Rgb::parse).map(Rgb::hex),
            layout: f.get("layout").cloned().and_then(|v| serde_json::from_value(v).ok()).map_or(Paper::Plain, layout_of),
            texture: match f.get("texture") {
                Some(t) => serde_json::from_value(t.clone()).unwrap_or(PaperTexture::None),
                None if f.get("grain") == Some(&json!(true)) => PaperTexture::Grain,
                None => PaperTexture::None,
            },
        },
    ))
}

pub(crate) fn live_papers(store: &Store) -> Result<Vec<CustomPaper>> {
    let mut out: Vec<(f64, CustomPaper)> = store
        .entities("settings/paper/")?
        .into_iter()
        .filter_map(|(e, f)| {
            let id = e.strip_prefix("settings/paper/")?;
            read(id, &f)
        })
        .collect();
    out.sort_by(|a, b| a.0.total_cmp(&b.0).then_with(|| a.1.id.cmp(&b.1.id)));
    Ok(out.into_iter().map(|(_, p)| p).collect())
}

pub(crate) fn find_paper(store: &Store, id: &str) -> Result<Option<CustomPaper>> {
    if check_id(id).is_err() {
        return Ok(None);
    }
    let f = store.fields(&format!("settings/paper/{id}"))?;
    Ok(read(id, &f).map(|(_, p)| p))
}

#[uniffi::export]
impl YuyueCore {
    /// 我的纸, in the order they were made.
    pub fn custom_papers(&self) -> Result<Vec<CustomPaper>> {
        live_papers(&lock(&self.store))
    }

    /// Saves a paper: a new one (empty `id`) goes last. Without a name it is named after the made
    /// colour it is closest to (豆沙绿, 豆沙绿 2…), or 我的纸. Returns it as stored.
    pub fn save_custom_paper(&self, paper: CustomPaper) -> Result<CustomPaper> {
        let bg = colour(&paper.bg)?;
        let ink = paper.ink.as_deref().map(colour).transpose()?;
        let layout = layout_of(paper.layout);
        let mut store = lock(&self.store);
        let name = paper.name.split_whitespace().collect::<Vec<_>>().join(" ");
        let name = if name.is_empty() {
            let base = suggested_name(Rgb::parse(&bg).unwrap_or(Rgb::WHITE));
            let taken: Vec<String> = live_papers(&store)?.into_iter().filter(|p| p.id != paper.id).map(|p| p.name).collect();
            (1..).map(|i| if i == 1 { base.clone() } else { format!("{base} {i}") }).find(|n| !taken.contains(n)).unwrap_or(base)
        } else {
            name.chars().take(20).collect()
        };
        let id = if paper.id.is_empty() {
            new_id()
        } else {
            check_id(&paper.id)?;
            paper.id.clone()
        };
        let mut fields = vec![
            ("name", json!(name)),
            ("bg", json!(bg)),
            ("ink", ink.as_ref().map_or(Value::Null, |i| json!(i))),
            ("layout", json!(layout)),
            ("texture", json!(paper.texture)),
            ("deleted", json!(false)),
        ];
        if paper.id.is_empty() {
            let last = live_papers(&store)?.len();
            fields.push(("order", json!(now_ms() as f64 + last as f64)));
        }
        store.set_fields(&format!("settings/paper/{id}"), &fields)?;
        find_paper(&store, &id)?.ok_or_else(|| CoreError::not_found("paper"))
    }

    /// Removes a paper. Pages on it go back to the preset it read like.
    pub fn delete_custom_paper(&self, id: String) -> Result<()> {
        check_id(&id)?;
        lock(&self.store).set(&format!("settings/paper/{id}"), "deleted", json!(true))?;
        let mut shared = self.reader_settings()?;
        if shared.custom_paper.as_deref() == Some(id.as_str()) {
            shared.custom_paper = None;
            self.set_reader_settings(shared)?;
        }
        Ok(())
    }

    /// Brings back a paper just removed (撤销).
    pub fn restore_custom_paper(&self, id: String) -> Result<()> {
        check_id(&id)?;
        lock(&self.store).set(&format!("settings/paper/{id}"), "deleted", json!(false))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn paper(bg: &str, ink: Option<&str>, layout: Paper) -> CustomPaper {
        CustomPaper { id: String::new(), name: String::new(), bg: bg.into(), ink: ink.map(str::to_string), layout, texture: PaperTexture::None }
    }

    #[test]
    fn colours_follow_the_background() {
        let green = paper_colors(paper("#CCE3CB", None, Paper::Kami));
        assert!(!green.dark);
        assert_eq!(green.preset, Paper::Kami);
        assert!(green.contrast >= 9.0, "{green:?}");
        // The text keeps a little green.
        let ink = Rgb::parse(&green.ink).unwrap();
        assert!(ink.1 > ink.0 && ink.1 > ink.2, "{green:?}");

        let night = paper_colors(paper("#18202B", None, Paper::Plain));
        assert!(night.dark);
        assert_eq!(night.preset, Paper::Dark);
        assert_eq!(night.on_main, night.bg);
        assert!(night.contrast >= 9.0, "{night:?}");
        assert_eq!(paper_colors(paper("#18202B", None, Paper::KamiNight)).preset, Paper::KamiNight);

        // Text the reader chose stays, even when it is hard to read.
        let faint = paper_colors(paper("#FFFFFF", Some("#dddddd"), Paper::Plain));
        assert_eq!(faint.ink, "#DDDDDD");
        assert!(faint.contrast < READABLE_CONTRAST);
        assert_eq!(paper_colors(paper("nope", None, Paper::Plain)).bg, "#FFFFFF");

        // Every made colour, every ink and every corner 微调 can reach reads well.
        for night in [false, true] {
            let p = paper_palette(night);
            assert_eq!((p.swatches.len(), p.inks.len()), (6, 4));
            let mut bgs: Vec<String> = p.swatches.iter().map(|s| s.color.clone()).collect();
            for h in [0.0, 60.0, 120.0, 180.0, 240.0, 300.0] {
                for s in [0.0, 100.0] {
                    for l in [0.0, 100.0] {
                        bgs.push(paper_color(PaperHsl { h, s, l }, night));
                    }
                }
            }
            for bg in bgs {
                let auto = paper_colors(paper(&bg, None, Paper::Plain));
                assert_eq!(auto.dark, night, "{bg}");
                assert!(auto.contrast >= 7.0, "{bg} {auto:?}");
                for ink in &p.inks {
                    assert!(paper_colors(paper(&bg, Some(&ink.color), Paper::Plain)).contrast >= 7.0, "{bg} {}", ink.color);
                }
            }
        }
        let back = paper_hsl(paper_color(PaperHsl { h: 115.0, s: 24.0, l: 85.0 }, false));
        assert!((back.h - 115.0).abs() < 2.0 && (back.s - 24.0).abs() < 2.0 && (back.l - 85.0).abs() < 1.0, "{back:?}");

        let style = page_style(&green);
        assert!(style.starts_with("--yy-p-bg:#CCE3CB;--yy-p-ink:#") && style.ends_with(";color-scheme:light"), "{style}");
        assert!(!style.contains('"'));
    }

    #[test]
    fn papers_are_saved_listed_and_removed() {
        let dir = std::env::temp_dir().join(format!("yuyue-paper-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let core = YuyueCore::open(dir.to_string_lossy().into_owned(), "Mac".into(), "macos".into()).unwrap();
        assert!(core.save_custom_paper(paper("green", None, Paper::Plain)).is_err());
        let a = core.save_custom_paper(CustomPaper { name: "  豆沙  绿 ".into(), ..paper("#cce3cb", None, Paper::KamiNight) }).unwrap();
        assert_eq!((a.name.as_str(), a.bg.as_str(), a.layout), ("豆沙 绿", "#CCE3CB", Paper::Kami));
        let b = core.save_custom_paper(paper("#18202B", Some("#C9D3DE"), Paper::Plain)).unwrap();
        assert!(!b.name.is_empty());
        let ids: Vec<_> = core.custom_papers().unwrap().into_iter().map(|p| p.id).collect();
        assert_eq!(ids, [a.id.clone(), b.id.clone()]);

        // No name: named after the made colour it is closest to, numbered when taken.
        let sage = paper_palette(false).swatches[2].color.clone();
        let n1 = core.save_custom_paper(paper(&sage, None, Paper::Plain)).unwrap();
        let n2 = core.save_custom_paper(paper(&sage, None, Paper::Plain)).unwrap();
        assert_eq!((n1.name.as_str(), n2.name.as_str()), ("豆沙绿", "豆沙绿 2"));
        assert_eq!(core.save_custom_paper(paper("#FF00FF", None, Paper::Plain)).unwrap().name, "我的纸");
        for p in core.custom_papers().unwrap().into_iter().skip(2) {
            core.delete_custom_paper(p.id).unwrap();
        }

        let edited = core.save_custom_paper(CustomPaper { texture: PaperTexture::Xuan, ..a.clone() }).unwrap();
        assert_eq!(edited.texture, PaperTexture::Xuan);
        assert_eq!(core.custom_papers().unwrap()[0], edited, "editing keeps its place");

        // A page on it gets its colours over 纸本's typography.
        let mut s = core.reader_settings().unwrap();
        s.custom_paper = Some(b.id.clone());
        s.paper = Paper::Kami;
        core.set_reader_settings(s).unwrap();
        let s = core.reader_settings().unwrap();
        assert_eq!((s.custom_paper.as_deref(), s.paper), (Some(b.id.as_str()), Paper::Dark), "the paper older apps see matches");

        core.delete_custom_paper(b.id.clone()).unwrap();
        assert_eq!(core.custom_papers().unwrap().len(), 1);
        let s = core.reader_settings().unwrap();
        assert_eq!((s.custom_paper, s.paper), (None, Paper::Dark));
        core.restore_custom_paper(b.id.clone()).unwrap();
        assert_eq!(core.custom_papers().unwrap().len(), 2);
        assert!(core.delete_custom_paper("../x".into()).is_err());
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
