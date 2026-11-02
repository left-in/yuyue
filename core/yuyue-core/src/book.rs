//! The book folder: everything an import produces, read back while reading.
//!
//! ```text
//! books/<id>/
//!   book.json        the manifest: title, sections, table of contents
//!   original.epub    the imported file, kept to re-import when the importer improves
//!   cover.jpg
//!   s/<n>.html       section n, normalized (docs/dev/reader-contract.md §3)
//!   s/<n>.json       its sentences, for speech
//!   layout.json      a TXT's encoding and chapter rule, if the reader chose them
//!   r/…              images, stylesheets and fonts, at their paths in the EPUB
//! ```
//!
//! The id is the file's BLAKE3 hash, so importing the same file again finds the first import.
//! A book is built in a temporary folder and renamed into place, so a failed or interrupted
//! import never leaves half a book behind.

use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::dom;
use crate::epub::{self, Kind, TocEntry};
use crate::error::{CoreError, Result};
use crate::normalize::{self, Context, Link, Normalized};
use crate::text::{self, Stats};
use crate::txt;

/// Bumped whenever an import would come out differently; books from older versions are
/// re-imported from their original file.
pub const FORMAT_VERSION: u32 = 1;

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Format {
    Epub,
    Txt,
    /// Shown as it is printed (PDFKit, PdfRenderer); its pages are the one section's positions.
    Pdf,
    /// MOBI and AZW3, turned into an EPUB to read.
    Mobi,
    /// 有声书: a recording on its own (`audio`); its chapters' positions are milliseconds.
    Audio,
    /// 播客: an episode's script, written here (`podcast`), read like a TXT.
    Podcast,
}

impl Format {
    pub(crate) fn extension(self) -> &'static str {
        match self {
            Format::Epub => "epub",
            Format::Txt => "txt",
            Format::Pdf => "pdf",
            Format::Mobi => "mobi",
            // No one file it came from: the recording is its files under `a/`.
            Format::Audio => "audio",
            Format::Podcast => "podcast",
        }
    }
}

/// How a TXT was read: the encoding and the chapter rule chosen in 编码和目录 (none means the
/// importer's own guess), and what looked doubtful about the result.
#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
pub struct TxtOptions {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub encoding: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rule: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub doubt: Option<String>,
}

impl TxtOptions {
    pub fn same_choice(&self, other: &TxtOptions) -> bool {
        self.encoding == other.encoding && self.rule == other.rule
    }
}

pub fn txt_options(dir: &Path) -> TxtOptions {
    fs::read_to_string(dir.join("layout.json")).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Manifest {
    pub version: u32,
    pub id: String,
    pub format: Format,
    pub title: String,
    pub authors: Vec<String>,
    pub language: String,
    /// 13 digits, when the book says.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub isbn: Option<String>,
    /// File name of the cover image in the book folder.
    pub cover: Option<String>,
    /// The section reading starts at.
    pub start: u32,
    pub sections: Vec<SectionInfo>,
    pub toc: Vec<TocEntry>,
    /// Length of the main text (linear text sections), for progress and reading time.
    pub units: u32,
    pub read_minutes: u32,
    pub listen_minutes: u32,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct SectionInfo {
    pub title: Option<String>,
    /// Only when it differs from the book's language (an English chapter in a Chinese book).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lang: Option<String>,
    /// Stylesheets, as paths under `r/`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub styles: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub body_class: Option<String>,
    pub linear: bool,
    pub kind: Kind,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub continued: bool,
    pub sentences: u32,
    pub units: u32,
    /// A PDF's pages; its positions count pages instead of sentences.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub pages: u32,
    /// An audiobook chapter's length in milliseconds; its positions count milliseconds.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub ms: u32,
}

fn is_zero(n: &u32) -> bool {
    *n == 0
}

impl Manifest {
    pub fn section_lang(&self, n: u32) -> &str {
        self.sections.get(n as usize).and_then(|s| s.lang.as_deref()).unwrap_or(&self.language)
    }
}

pub fn book_id(bytes: &[u8]) -> String {
    blake3::hash(bytes).to_hex()[..32].to_string()
}

/// Imports a book file into `books_dir`. Importing a file that is already there returns the
/// existing book.
pub fn import(books_dir: &Path, source: &Path) -> Result<Manifest> {
    let bytes = fs::read(source)?;
    let id = book_id(&bytes);
    let dir = books_dir.join(&id);
    if let Ok(existing) = load(&dir)
        && existing.version == FORMAT_VERSION {
            return Ok(existing);
        }
    let format = detect(&bytes)?;
    let fallback_title = source.file_stem().and_then(|s| s.to_str()).unwrap_or("").trim().to_string();
    build_into(books_dir, &id, |tmp| {
        let original = tmp.join(format!("original.{}", format.extension()));
        fs::write(&original, &bytes)?;
        match format {
            Format::Epub => build_epub(tmp, &id, &original, &fallback_title, Format::Epub),
            Format::Mobi => build_mobi(tmp, &id, &bytes, &fallback_title),
            Format::Txt => build_txt(tmp, &id, &bytes, &fallback_title, &TxtOptions::default()),
            Format::Pdf => build_pdf(tmp, &id, &fallback_title),
            Format::Audio | Format::Podcast => Err(CoreError::bad_book("not a book file")),
        }
    })
}

/// Rebuilds a book from its original file, after the importer changed, or to read a TXT in
/// another encoding or with another chapter rule (`txt`; none keeps how it was read).
pub fn reimport(books_dir: &Path, id: &str, txt: Option<&TxtOptions>) -> Result<Manifest> {
    let dir = books_dir.join(id);
    let manifest = load(&dir)?;
    let options = txt.cloned().unwrap_or_else(|| txt_options(&dir));
    let original = dir.join(format!("original.{}", manifest.format.extension()));
    let bytes = fs::read(&original)?;
    let title = manifest.title.clone();
    build_into(books_dir, id, |tmp| {
        let copy = tmp.join(format!("original.{}", manifest.format.extension()));
        fs::write(&copy, &bytes)?;
        let built = match manifest.format {
            Format::Epub => build_epub(tmp, id, &copy, &title, Format::Epub),
            Format::Mobi => build_mobi(tmp, id, &bytes, &title),
            Format::Txt => build_txt(tmp, id, &bytes, &title, &options),
            // What the app read from the PDF is kept; there is nothing of ours to rebuild.
            Format::Pdf => {
                if let Some(cover) = &manifest.cover {
                    fs::copy(dir.join(cover), tmp.join(cover))?;
                }
                let m = Manifest { version: FORMAT_VERSION, ..manifest.clone() };
                fs::write(tmp.join("book.json"), serde_json::to_string_pretty(&m)?)?;
                Ok(m)
            }
            // A recording or an episode isn't rebuilt (see `YuyueCore::manifest`).
            Format::Audio | Format::Podcast => Err(CoreError::bad_book("not a book file")),
        };
        // A cover the user picked (换封面) outlives the rebuild.
        match (built, manifest.cover.as_deref().filter(|c| c.starts_with("cover-own-"))) {
            (Ok(mut m), Some(own)) if m.format != Format::Pdf => {
                fs::copy(dir.join(own), tmp.join(own))?;
                m.cover = Some(own.to_string());
                fs::write(tmp.join("book.json"), serde_json::to_string_pretty(&m)?)?;
                Ok(m)
            }
            (built, _) => built,
        }
    })
}

pub fn load(dir: &Path) -> Result<Manifest> {
    let text = match fs::read_to_string(dir.join("book.json")) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Err(CoreError::not_found("book")),
        Err(e) => return Err(e.into()),
    };
    Ok(serde_json::from_str(&text)?)
}

pub fn section_html(dir: &Path, n: u32) -> Result<String> {
    fs::read_to_string(dir.join("s").join(format!("{n}.html"))).map_err(|_| CoreError::not_found("section"))
}

pub fn sentences(dir: &Path, n: u32) -> Result<Vec<String>> {
    let text = fs::read_to_string(dir.join("s").join(format!("{n}.json"))).map_err(|_| CoreError::not_found("section"))?;
    Ok(serde_json::from_str(&text)?)
}

/// The file for a resource URL path (`OEBPS/images/a.jpg`, already percent-decoded), if it
/// stays inside the book's `r/` folder.
pub fn resource_path(dir: &Path, path: &str) -> Option<PathBuf> {
    let mut out = dir.join("r");
    for segment in path.split('/') {
        if segment.is_empty() || segment == "." || segment == ".." || segment.contains(['\\', '\0', ':']) {
            return None;
        }
        out.push(segment);
    }
    out.is_file().then_some(out)
}

fn detect(bytes: &[u8]) -> Result<Format> {
    if bytes.starts_with(b"PK\x03\x04") {
        return Ok(Format::Epub);
    }
    if encoding_rs::Encoding::for_bom(bytes).is_some() {
        return Ok(Format::Txt);
    }
    let head = &bytes[..bytes.len().min(8192)];
    // Readers allow a little junk before the header.
    if head[..head.len().min(1024)].windows(5).any(|w| w == b"%PDF-") {
        return Ok(Format::Pdf);
    }
    if crate::mobi::is_mobi(bytes) {
        return Ok(Format::Mobi);
    }
    // Other binary formats; text files don't contain NUL.
    if bytes.is_empty() || head.contains(&0) {
        return Err(CoreError::Unsupported);
    }
    Ok(Format::Txt)
}

/// A PDF is kept as it is. How many pages it has, its title and its cover come from the app,
/// which reads PDFs with the system's own viewer (`set_pdf_info`); until then it is one empty
/// section named after the file.
fn build_pdf(tmp: &Path, id: &str, fallback_title: &str) -> Result<Manifest> {
    let manifest = Manifest {
        version: FORMAT_VERSION,
        id: id.to_string(),
        format: Format::Pdf,
        title: fallback_title.to_string(),
        authors: Vec::new(),
        language: "und".into(),
        isbn: None,
        cover: None,
        start: 0,
        sections: vec![pdf_section(0)],
        toc: Vec::new(),
        units: 0,
        read_minutes: 0,
        listen_minutes: 0,
    };
    fs::write(tmp.join("book.json"), serde_json::to_string_pretty(&manifest)?)?;
    Ok(manifest)
}

pub(crate) fn pdf_section(pages: u32) -> SectionInfo {
    SectionInfo {
        title: None,
        lang: None,
        styles: Vec::new(),
        body_class: None,
        linear: true,
        kind: Kind::Image,
        continued: false,
        sentences: 0,
        units: pages,
        pages,
        ms: 0,
    }
}

/// Builds a book folder in a temporary folder next to its final place, then swaps it in.
pub(crate) fn build_into(books_dir: &Path, id: &str, build: impl FnOnce(&Path) -> Result<Manifest>) -> Result<Manifest> {
    let nonce = format!("{:016x}", getrandom::u64().unwrap_or_else(|_| std::process::id() as u64));
    let tmp = books_dir.join(format!(".import-{id}-{nonce}"));
    fs::create_dir_all(tmp.join("s"))?;
    let manifest = match build(&tmp) {
        Ok(m) => m,
        Err(e) => {
            let _ = fs::remove_dir_all(&tmp);
            return Err(e);
        }
    };
    let dir = books_dir.join(id);
    let old = books_dir.join(format!(".old-{id}-{nonce}"));
    let had_old = dir.exists();
    if had_old {
        fs::rename(&dir, &old)?;
    }
    if let Err(e) = fs::rename(&tmp, &dir) {
        if had_old {
            let _ = fs::rename(&old, &dir);
        }
        let _ = fs::remove_dir_all(&tmp);
        return Err(e.into());
    }
    if had_old {
        let _ = fs::remove_dir_all(&old);
    }
    Ok(manifest)
}

/// A section ready to be written: its normalized content and what the manifest says about it.
struct Built {
    info: SectionInfo,
    normalized: Normalized,
    stats: Stats,
}

fn build_epub(tmp: &Path, id: &str, original: &Path, fallback_title: &str, format: Format) -> Result<Manifest> {
    let mut book = epub::read(original)?;
    book.extract_resources(&tmp.join("r"))?;
    let cover = match (book.cover.clone(), book.cover_bytes()) {
        (Some(path), Some(bytes)) => {
            let ext = Path::new(&path).extension().and_then(|e| e.to_str()).unwrap_or("jpg").to_ascii_lowercase();
            let name = format!("cover.{ext}");
            fs::write(tmp.join(&name), bytes)?;
            Some(name)
        }
        _ => None,
    };
    let sections = std::mem::take(&mut book.sections);
    let mut built = Vec::with_capacity(sections.len());
    for s in sections {
        let lang = s.lang.as_deref().unwrap_or(&book.language).to_string();
        let resource = |src: &str| book.resource_url(src);
        let link = |href: &str| book.link(href);
        let ctx = Context { lang: &lang, resource: &resource, link: &link };
        let normalized = normalize::normalize(s.body, &ctx);
        let stats = normalized.stats;
        built.push(Built {
            info: SectionInfo {
                title: s.title,
                lang: own_lang(s.lang.as_deref(), &book.language),
                styles: s.styles,
                body_class: s.body_class,
                linear: s.linear,
                kind: s.kind,
                continued: s.continued,
                sentences: normalized.sentences.len() as u32,
                units: stats.units(),
                pages: 0,
                ms: 0,
            },
            normalized,
            stats,
        });
    }
    let title = book.title.clone().filter(|t| !t.is_empty()).unwrap_or_else(|| fallback_title.to_string());
    finish(tmp, id, format, title, book.authors.clone(), book.language.clone(), book.isbn.clone(), cover, book.start, built, book.toc.clone())
}

/// A Kindle book, read as the EPUB it turns into; the EPUB isn't kept.
fn build_mobi(tmp: &Path, id: &str, bytes: &[u8], fallback_title: &str) -> Result<Manifest> {
    let converted = tmp.join("converted.epub");
    fs::write(&converted, crate::mobi::to_epub(bytes)?)?;
    let built = build_epub(tmp, id, &converted, fallback_title, Format::Mobi);
    fs::remove_file(&converted)?;
    built
}

fn build_txt(tmp: &Path, id: &str, bytes: &[u8], fallback_title: &str, options: &TxtOptions) -> Result<Manifest> {
    let encoding = match &options.encoding {
        Some(name) => Some(txt::encoding_for(name).ok_or_else(|| CoreError::Invalid { detail: format!("{}{name}", crate::i18n::tr("不认识的编码：", "Unknown encoding: ")) })?),
        None => None,
    };
    let headings = txt::Headings::rule(options.rule.as_deref()).map_err(|_| CoreError::Invalid { detail: crate::i18n::tr("目录规则写得不对", "The chapter rule isn't valid") })?;
    let analysis = txt::analyze(bytes, encoding, &headings);
    let layout = TxtOptions { doubt: analysis.doubt.clone(), ..options.clone() };
    if layout != TxtOptions::default() {
        fs::write(tmp.join("layout.json"), serde_json::to_string_pretty(&layout)?)?;
    }
    let text = analysis.decoded.text;
    let structured = analysis.book;
    let sample: String = text.chars().take(100_000).collect();
    let language = text::refine_language(Some(structured.language), &sample);
    let no_resource = |_: &str| None;
    let no_link = |_: &str| Link::Dead;
    let ctx = Context { lang: &language, resource: &no_resource, link: &no_link };
    let mut built = Vec::new();
    let mut toc = Vec::new();
    // Project Gutenberg's licence header is a chapter of its own; reading starts after it.
    let mut start = 0;
    for (i, ch) in structured.chapters.iter().enumerate() {
        if ch.paragraphs.iter().any(|p| p.starts_with("*** START OF")) && i < 3 {
            start = i + 1;
        }
        if let (Some(t), false) = (&ch.title, ch.continued) {
            toc.push(TocEntry { title: t.clone(), depth: 0, section: i as u32, anchor: None });
        }
        let normalized = normalize::normalize(txt::chapter_body(ch), &ctx);
        let stats = normalized.stats;
        built.push(Built {
            info: SectionInfo {
                title: ch.title.clone(),
                lang: None,
                styles: Vec::new(),
                body_class: None,
                linear: true,
                kind: Kind::Text,
                continued: ch.continued,
                sentences: normalized.sentences.len() as u32,
                units: stats.units(),
                pages: 0,
                ms: 0,
            },
            normalized,
            stats,
        });
    }
    if built.is_empty() {
        return Err(CoreError::bad_book("the file has no text"));
    }
    let start = start.min(built.len() - 1) as u32;
    let title = structured.title.clone().filter(|t| !t.is_empty()).unwrap_or_else(|| fallback_title.to_string());
    let authors = structured.author.clone().into_iter().collect();
    finish(tmp, id, Format::Txt, title, authors, language, None, None, start, built, toc)
}

/// Adds the reading-time line to chapter openings, writes the sections and the manifest.
#[allow(clippy::too_many_arguments)]
fn finish(
    tmp: &Path,
    id: &str,
    format: Format,
    title: String,
    authors: Vec<String>,
    language: String,
    isbn: Option<String>,
    cover: Option<String>,
    start: u32,
    mut built: Vec<Built>,
    toc: Vec<TocEntry>,
) -> Result<Manifest> {
    let chapter_starts: HashSet<u32> = toc.iter().filter(|e| e.anchor.is_none()).map(|e| e.section).collect();
    for i in 0..built.len() {
        if !chapter_starts.contains(&(i as u32)) || built[i].info.kind != Kind::Text || built[i].info.continued {
            continue;
        }
        // A chapter cut into parts is timed as a whole.
        let mut stats = built[i].stats;
        for next in built[i + 1..].iter().take_while(|b| b.info.continued) {
            stats.add(next.stats);
        }
        if stats.units() > 0 {
            let line = meta_line(&stats);
            normalize::insert_meta(&mut built[i].normalized.content, &line);
        }
    }

    let mut total = Stats::default();
    let mut sections = Vec::with_capacity(built.len());
    for (i, b) in built.into_iter().enumerate() {
        if b.info.linear && b.info.kind == Kind::Text {
            total.add(b.stats);
        }
        let s = tmp.join("s");
        fs::write(s.join(format!("{i}.html")), dom::to_html(&b.normalized.content))?;
        fs::write(s.join(format!("{i}.json")), serde_json::to_string(&b.normalized.sentences)?)?;
        sections.push(b.info);
    }
    let manifest = Manifest {
        version: FORMAT_VERSION,
        id: id.to_string(),
        format,
        title,
        authors,
        language,
        isbn,
        cover,
        start,
        sections,
        toc,
        units: total.units(),
        read_minutes: total.read_minutes(),
        listen_minutes: total.listen_minutes(),
    };
    fs::write(tmp.join("book.json"), serde_json::to_string_pretty(&manifest)?)?;
    Ok(manifest)
}

/// "读 8 分钟 · 听 12 分钟"
pub fn meta_line(stats: &Stats) -> String {
    if crate::i18n::english() {
        format!("Read {} min · Listen {} min", stats.read_minutes(), stats.listen_minutes())
    } else {
        format!("读 {} 分钟 · 听 {} 分钟", stats.read_minutes(), stats.listen_minutes())
    }
}

/// A section's language, unless it's just a variant of the book's: the book's language was
/// checked against the text, so it wins over a publisher's "zh" or "zh-CN" on each file.
fn own_lang(section: Option<&str>, book: &str) -> Option<String> {
    let section = section?;
    let primary = |l: &str| l.split('-').next().unwrap_or("").to_ascii_lowercase();
    (primary(section) != primary(book)).then(|| section.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> PathBuf {
        PathBuf::from(format!("{}/../../fixtures/books/{name}", env!("CARGO_MANIFEST_DIR")))
    }

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("yuyue-book-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn imports_an_epub() {
        let books = temp_dir("epub");
        let m = import(&books, &fixture("edge-cases.epub")).unwrap();
        let dir = books.join(&m.id);
        assert_eq!(m.id.len(), 32);
        assert_eq!(m.format, Format::Epub);
        assert_eq!(m.title, "边界情况");
        assert_eq!(m.sections.len(), 2);
        assert_eq!(m.section_lang(0), "zh-CN");
        assert_eq!(m.section_lang(1), "en");
        assert!(dir.join("original.epub").is_file());
        assert!(resource_path(&dir, "OEBPS/images/dot.png").is_some());
        assert!(resource_path(&dir, "../book.json").is_none());

        let html = section_html(&dir, 0).unwrap();
        assert!(html.contains(r#"<div class="yy-meta">读 1 分钟 · 听 1 分钟</div>"#), "{html}");
        assert!(html.contains(r#"class="pz-r""#), "{html}");
        assert!(html.contains(r#"src="../r/OEBPS/images/dot.png""#), "{html}");
        assert!(html.contains(r##"data-yy-target="1#part2""##), "{html}");
        assert!(html.contains("yy-noteref"), "{html}");
        let sentences = sentences(&dir, 0).unwrap();
        assert_eq!(sentences.len() as u32, m.sections[0].sentences);
        assert!(sentences[0].starts_with("第一章"));

        // The same file again is the same book, without another import.
        let again = import(&books, &fixture("edge-cases.epub")).unwrap();
        assert_eq!(again, m);
        let leftovers: Vec<_> = fs::read_dir(&books).unwrap().filter_map(|e| e.ok()).map(|e| e.file_name()).collect();
        assert_eq!(leftovers.len(), 1, "{leftovers:?}");
        fs::remove_dir_all(&books).unwrap();
    }

    #[test]
    fn imports_a_text_file() {
        let books = temp_dir("txt");
        let m = import(&books, &fixture("beiying.txt")).unwrap();
        assert_eq!(m.format, Format::Txt);
        assert_eq!(m.title, "背影");
        assert_eq!(m.authors, vec!["朱自清"]);
        let gbk = import(&books, &fixture("beiying-gbk.txt")).unwrap();
        assert_ne!(gbk.id, m.id);
        assert_eq!((gbk.title.as_str(), gbk.language.as_str()), ("背影", "zh-Hans"));
        assert_eq!(m.language, "zh-Hans");
        assert_eq!(m.toc.len(), 1);
        assert!(m.read_minutes >= 1);
        let html = section_html(&books.join(&m.id), 0).unwrap();
        assert!(html.starts_with(r#"<h2 class="yy-title"><span class="s" data-s="0">背影</span></h2><div class="yy-meta">"#), "{html}");
        let again = reimport(&books, &m.id, None).unwrap();
        assert_eq!(again, m);
        fs::remove_dir_all(&books).unwrap();
    }

    #[test]
    fn rejects_other_files() {
        let books = temp_dir("bad");
        let bin = books.join("a.bin");
        fs::write(&bin, b"\x7fELF\x02\x01\x01\x00\x00").unwrap();
        assert!(matches!(import(&books, &bin), Err(CoreError::Unsupported)));
        let zip = books.join("a.epub");
        fs::write(&zip, b"PK\x03\x04garbage").unwrap();
        assert!(matches!(import(&books, &zip), Err(CoreError::BadBook { .. })));
        let names: Vec<_> = fs::read_dir(&books).unwrap().filter_map(|e| e.ok()).map(|e| e.file_name()).collect();
        assert_eq!(names.len(), 2, "no temporary folders left: {names:?}");
        fs::remove_dir_all(&books).unwrap();
    }
}
