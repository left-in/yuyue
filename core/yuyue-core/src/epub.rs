//! EPUB import: container, package, spine and table of contents, and the cut into
//! reader-sized sections.
//!
//! Books come in two shapes and both have to end up as one section per chapter:
//!
//! - one file per chapter with a table of contents that matches (most commercial books);
//! - files split by size, as Project Gutenberg makes them: chapters start in the middle of a
//!   file and run on into the next. Some (红楼梦, #24264) are text files wrapped in a few huge
//!   `<p>` elements, with no table of contents at all.
//!
//! So documents are cut at the anchors the table of contents points to, the leading part of a
//! file that merely continues the previous chapter is joined to it, and documents that are
//! really hard-wrapped text go through the plain-text rules in `txt`.

use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::{BufReader, Read};
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

use percent_encoding::{AsciiSet, CONTROLS, percent_decode_str, utf8_percent_encode};
use regex::Regex;
use serde::{Deserialize, Serialize};
use zip::ZipArchive;

use crate::dom::{self, Element, Node, Ns};
use crate::error::{CoreError, Result};
use crate::normalize::Link;
use crate::text::{self, is_wide};
use crate::txt;

/// Limits on decompressed data per file and per book, so a malicious archive can't exhaust
/// memory or disk.
const MAX_ENTRY: u64 = 50 << 20;
const MAX_TOTAL: u64 = 1 << 30;

/// Files shorter than this aren't cut at table-of-contents anchors.
const SPLIT_FILE_CHARS: usize = 8_000;
/// Sections longer than this are cut into parts of about `PART_CHARS`.
const MAX_SECTION_CHARS: usize = 60_000;
const PART_CHARS: usize = 40_000;
/// The leading part of a file is only joined to the previous chapter up to this size.
const MAX_JOINED_CHARS: usize = 150_000;
/// Documents with a line break inside a Chinese text block every this many characters are
/// hard-wrapped text.
const TEXT_DUMP_BREAK_CHARS: usize = 1_000;

/// Marks elements with an id with the document they came from, until sections are final.
const SRC_ATTR: &str = "data-yy-src";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Text,
    /// A page that is only a picture, such as the cover.
    Image,
    /// Project Gutenberg's licence header and footer.
    Boilerplate,
}

pub struct Section {
    pub title: Option<String>,
    /// The section's `<body>`. Links and resources still point into the archive
    /// (`/OEBPS/ch1.xhtml#note`); see `Book::link` and `Book::resource_url`.
    pub body: Element,
    /// Stylesheets, as paths under the book's `r/` directory.
    pub styles: Vec<String>,
    pub lang: Option<String>,
    pub body_class: Option<String>,
    pub linear: bool,
    pub kind: Kind,
    /// A later part of a chapter that was too long for one section.
    pub continued: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TocEntry {
    pub title: String,
    pub depth: u16,
    pub section: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub anchor: Option<String>,
}

pub struct Book {
    pub title: Option<String>,
    pub authors: Vec<String>,
    pub language: String,
    /// From `dc:identifier`, when one is a valid ISBN: 13 digits.
    pub isbn: Option<String>,
    /// Archive path of the cover image.
    pub cover: Option<String>,
    pub sections: Vec<Section>,
    pub toc: Vec<TocEntry>,
    /// The section reading starts at: past the cover and licence pages.
    pub start: u32,
    archive: Archive,
    /// Stylesheets that were inline `<style>` elements: path under `r/` → CSS.
    styles: Vec<(String, String)>,
    /// (archive path, element id) → section, and the id the element has there.
    targets: HashMap<(String, String), (u32, String)>,
    /// Archive path of a document → the section its content starts in.
    doc_sections: HashMap<String, u32>,
}

impl Book {
    /// Where an `<a href>` in a section body leads.
    pub fn link(&self, href: &str) -> Link {
        let href = href.trim();
        if has_scheme(href) {
            let lower = href.to_ascii_lowercase();
            let web = ["http://", "https://", "mailto:"].iter().any(|s| lower.starts_with(s));
            return if web { Link::External(href.to_string()) } else { Link::Dead };
        }
        let Some((path, fragment)) = href.strip_prefix('/').map(split_fragment) else { return Link::Dead };
        let Some(path) = self.archive.name(path) else { return Link::Dead };
        if let Some(id) = fragment
            && let Some((section, anchor)) = self.targets.get(&(path.to_string(), id.to_string())) {
                return Link::Internal(*section, Some(anchor.clone()));
            }
        match self.doc_sections.get(path) {
            Some(section) => Link::Internal(*section, None),
            None => Link::Dead,
        }
    }

    /// The URL a section document uses for an image in the archive, relative to the document.
    pub fn resource_url(&self, src: &str) -> Option<String> {
        let (path, _) = split_fragment(src.trim().strip_prefix('/')?);
        let name = self.archive.name(path)?;
        Some(format!("../r/{}", encode_path(name)))
    }

    /// Writes the images, fonts and stylesheets sections may use into `dir` (the book's `r/`).
    pub fn extract_resources(&mut self, dir: &Path) -> Result<()> {
        for name in self.archive.resources() {
            let Some(rel) = safe_relative(&name) else { continue };
            if self.archive.size(&name).is_none_or(|s| s > MAX_ENTRY) {
                continue;
            }
            let bytes = self.archive.read(&name)?;
            let dest = dir.join(rel);
            if let Some(parent) = dest.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::write(dest, bytes)?;
        }
        for (path, css) in &self.styles {
            let dest = dir.join(path);
            if let Some(parent) = dest.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::write(dest, css)?;
        }
        Ok(())
    }

    pub fn cover_bytes(&mut self) -> Option<Vec<u8>> {
        let cover = self.cover.clone()?;
        self.archive.read(&cover).ok()
    }
}

// ---------------------------------------------------------------------------------------------
// Archive

struct Archive {
    zip: ZipArchive<BufReader<File>>,
    /// Lowercased name → name as stored. Book paths are compared case-insensitively because
    /// books made on Windows and macOS get the case of their links wrong.
    names: HashMap<String, String>,
    order: Vec<String>,
    total: u64,
}

impl Archive {
    fn open(path: &Path) -> Result<Archive> {
        let zip = ZipArchive::new(BufReader::new(File::open(path)?))?;
        let mut names = HashMap::new();
        let mut order = Vec::new();
        for name in zip.file_names() {
            let Ok(name) = name else { continue };
            if name.is_empty() || name.ends_with('/') {
                continue;
            }
            names.entry(name.to_lowercase()).or_insert_with(|| name.to_string());
            order.push(name.to_string());
        }
        Ok(Archive { zip, names, order, total: 0 })
    }

    fn name(&self, path: &str) -> Option<&str> {
        self.names.get(&path.trim_start_matches('/').to_lowercase()).map(String::as_str)
    }

    fn size(&mut self, name: &str) -> Option<u64> {
        self.zip.by_name(name).ok().map(|f| f.size())
    }

    fn read(&mut self, path: &str) -> Result<Vec<u8>> {
        let name = self.name(path).ok_or_else(|| CoreError::not_found(path))?.to_string();
        let file = self.zip.by_name(&name)?;
        let mut bytes = Vec::new();
        file.take(MAX_ENTRY + 1).read_to_end(&mut bytes)?;
        if bytes.len() as u64 > MAX_ENTRY {
            return Err(CoreError::bad_book(format!("{name} is too large")));
        }
        self.total += bytes.len() as u64;
        if self.total > MAX_TOTAL {
            return Err(CoreError::bad_book("the book is too large"));
        }
        Ok(bytes)
    }

    /// Files a section may load: everything except the package, the documents and scripts.
    fn resources(&self) -> Vec<String> {
        const SKIP: &[&str] = &[".opf", ".ncx", ".xhtml", ".html", ".htm", ".xml", ".js"];
        self.order
            .iter()
            .filter(|name| {
                let lower = name.to_lowercase();
                !lower.starts_with("meta-inf/") && lower != "mimetype" && !SKIP.iter().any(|ext| lower.ends_with(ext))
            })
            .cloned()
            .collect()
    }
}

/// A relative path for an archive name, or `None` if it would escape the destination
/// directory ("../", absolute paths, drive letters).
fn safe_relative(name: &str) -> Option<PathBuf> {
    if name.contains(['\\', '\0']) {
        return None;
    }
    let mut path = PathBuf::new();
    for segment in name.split('/') {
        if segment.is_empty() || segment == "." || segment == ".." || segment.contains(':') {
            return None;
        }
        path.push(segment);
    }
    Some(path)
}

fn check_drm(archive: &mut Archive) -> Result<()> {
    // FairPlay and Readium LCP.
    if archive.name("META-INF/sinf.xml").is_some() || archive.name("META-INF/license.lcpl").is_some() {
        return Err(CoreError::Protected);
    }
    if archive.name("META-INF/encryption.xml").is_none() {
        return Ok(());
    }
    let text = decode_markup(&archive.read("META-INF/encryption.xml")?);
    let Ok(root) = dom::parse_xml(&text) else { return Ok(()) };
    let mut methods = Vec::new();
    root.find_all(&|e| e.name == "encryptionmethod", &mut methods);
    // Font obfuscation (IDPF, Adobe) only scrambles embedded fonts; the text is readable.
    let fonts_only = methods.iter().all(|m| {
        m.attr("Algorithm").is_some_and(|a| a == "http://www.idpf.org/2008/embedding" || a == "http://ns.adobe.com/pdf/enc#RC")
    });
    if fonts_only { Ok(()) } else { Err(CoreError::Protected) }
}

// ---------------------------------------------------------------------------------------------
// Reading

pub fn read(path: &Path) -> Result<Book> {
    let mut archive = Archive::open(path)?;
    check_drm(&mut archive)?;
    let opf = find_package(&mut archive)?;
    let mut package = parse_package(&decode_markup(&archive.read(&opf)?), &opf)?;
    for item in package.manifest.values_mut() {
        if let Some(name) = archive.name(&item.path) {
            item.path = name.to_string();
        }
    }
    let toc = read_toc(&mut archive, &package);
    let (docs, styles) = read_docs(&mut archive, &package)?;
    if docs.is_empty() {
        return Err(CoreError::bad_book("no readable content"));
    }

    let pieces = cut(&docs, &toc);
    let mut a = assemble(pieces, &docs, &toc);
    split_large(&mut a);
    if a.sections.is_empty() {
        return Err(CoreError::bad_book("no readable content"));
    }
    let targets = collect_targets(&mut a.sections, &docs);
    let doc_sections: HashMap<String, u32> =
        a.doc_sections.iter().map(|(d, s)| (docs[*d].path.clone(), *s)).collect();
    let toc = final_toc(&toc, &docs, &a, &targets, &doc_sections);

    let mut sample = String::new();
    for s in a.sections.iter().filter(|s| s.kind == Kind::Text) {
        sample.push_str(&plain_text(&s.body));
        if sample.len() > 100_000 {
            break;
        }
    }
    let language = text::refine_language(package.language.as_deref(), &sample);
    let start = a.sections.iter().position(|s| s.linear && s.kind == Kind::Text).unwrap_or(0) as u32;
    let title = package.title.or_else(|| a.sections.get(start as usize).and_then(|s| s.title.clone()));
    let cover = package.cover.and_then(|c| archive.name(&c).map(str::to_string));

    Ok(Book {
        title,
        authors: package.authors,
        language,
        isbn: package.isbn,
        cover,
        sections: a.sections,
        toc,
        start,
        archive,
        styles,
        targets,
        doc_sections,
    })
}

// ---------------------------------------------------------------------------------------------
// Package

/// An ISBN in any of its spellings (`urn:isbn:978-7-…`, ten digits), as 13 digits, if its check
/// digit is right: identifiers are often UUIDs or shop numbers that only look like one.
pub(crate) fn isbn13(text: &str) -> Option<String> {
    let t = text.trim();
    let t = t.rsplit_once(':').map_or(t, |(_, v)| v);
    let chars: Vec<char> = t.chars().filter(|c| !matches!(c, '-' | ' ')).collect();
    let digit = |c: &char| c.to_digit(10);
    match chars.len() {
        13 => {
            let d: Vec<u32> = chars.iter().map(digit).collect::<Option<_>>()?;
            let sum: u32 = d.iter().enumerate().map(|(i, v)| if i % 2 == 0 { *v } else { v * 3 }).sum();
            (sum.is_multiple_of(10) && (d[..3] == [9, 7, 8] || d[..3] == [9, 7, 9])).then(|| chars.iter().collect())
        }
        10 => {
            let mut d: Vec<u32> = chars[..9].iter().map(digit).collect::<Option<_>>()?;
            let last = if matches!(chars[9], 'x' | 'X') { 10 } else { digit(&chars[9])? };
            let sum: u32 = d.iter().enumerate().map(|(i, v)| (10 - i as u32) * v).sum::<u32>() + last;
            if !sum.is_multiple_of(11) {
                return None;
            }
            let mut full = vec![9, 7, 8];
            full.append(&mut d);
            let check = (10 - full.iter().enumerate().map(|(i, v)| if i % 2 == 0 { *v } else { v * 3 }).sum::<u32>() % 10) % 10;
            full.push(check);
            Some(full.iter().map(|v| char::from_digit(*v, 10).unwrap_or('0')).collect())
        }
        _ => None,
    }
}

struct Item {
    path: String,
    media_type: String,
    properties: Vec<String>,
}

struct Package {
    title: Option<String>,
    authors: Vec<String>,
    language: Option<String>,
    isbn: Option<String>,
    manifest: HashMap<String, Item>,
    spine: Vec<(String, bool)>,
    nav: Option<String>,
    ncx: Option<String>,
    cover: Option<String>,
}

fn find_package(archive: &mut Archive) -> Result<String> {
    if archive.name("META-INF/container.xml").is_some() {
        let text = decode_markup(&archive.read("META-INF/container.xml")?);
        if let Ok(root) = dom::parse_xml(&text) {
            let mut files = Vec::new();
            root.find_all(&|e| e.name == "rootfile", &mut files);
            let opf = files
                .iter()
                .filter(|e| e.attr("media-type").is_none_or(|m| m.contains("oebps-package")))
                .filter_map(|e| e.attr("full-path"))
                .find_map(|p| archive.name(&join("", p)).map(str::to_string));
            if let Some(opf) = opf {
                return Ok(opf);
            }
        }
    }
    archive
        .order
        .iter()
        .find(|n| n.to_lowercase().ends_with(".opf"))
        .cloned()
        .ok_or_else(|| CoreError::bad_book("not an EPUB file"))
}

fn collapse(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn parse_package(text: &str, opf: &str) -> Result<Package> {
    let root = dom::parse_xml(text).map_err(CoreError::bad_book)?;
    let base = dir_of(opf);
    let metadata = root.child_elements().find(|e| e.name == "metadata");
    let mut metas = Vec::new();
    if let Some(m) = metadata {
        m.find_all(&|e| e.name == "meta", &mut metas);
    }
    let field = |name: &str| -> Option<String> {
        let el = metadata?.find(&|e| e.name == name)?;
        Some(collapse(&el.text_content())).filter(|t| !t.is_empty())
    };

    let mut creators: Vec<(String, Option<String>)> = Vec::new();
    if let Some(m) = metadata {
        let mut nodes = Vec::new();
        m.find_all(&|e| e.name == "creator", &mut nodes);
        for e in nodes {
            let name = collapse(&e.text_content());
            if name.is_empty() {
                continue;
            }
            // EPUB 2 puts the role on the element, EPUB 3 in a <meta refines="#id">.
            let role = e.attr("opf:role").map(str::to_string).or_else(|| {
                let id = e.attr("id")?;
                metas.iter().find_map(|meta| {
                    let about = meta.attr("refines")?.strip_prefix('#')?;
                    (about == id && meta.attr("property") == Some("role")).then(|| meta.text_content())
                })
            });
            creators.push((name, role));
        }
    }
    let mut authors: Vec<String> = creators
        .iter()
        .filter(|(_, role)| role.as_deref().is_some_and(|r| r.trim() == "aut"))
        .map(|(name, _)| name.clone())
        .collect();
    if authors.is_empty() {
        authors = creators.into_iter().map(|(name, _)| name).collect();
    }

    let mut isbn = None;
    if let Some(m) = metadata {
        let mut nodes = Vec::new();
        m.find_all(&|e| e.name == "identifier", &mut nodes);
        isbn = nodes.iter().find_map(|e| isbn13(&e.text_content()));
    }

    let manifest_el = root.child_elements().find(|e| e.name == "manifest").ok_or_else(|| CoreError::bad_book("no manifest"))?;
    let mut manifest = HashMap::new();
    for item in manifest_el.child_elements().filter(|e| e.name == "item") {
        let (Some(id), Some(href)) = (item.attr("id"), item.attr("href")) else { continue };
        let Some((path, _)) = resolve(&format!("{base}/package"), href) else { continue };
        manifest.insert(
            id.to_string(),
            Item {
                path,
                media_type: item.attr("media-type").unwrap_or_default().to_ascii_lowercase(),
                properties: item.attr("properties").unwrap_or_default().split_whitespace().map(str::to_string).collect(),
            },
        );
    }

    let spine_el = root.child_elements().find(|e| e.name == "spine").ok_or_else(|| CoreError::bad_book("no spine"))?;
    let spine = spine_el
        .child_elements()
        .filter(|e| e.name == "itemref")
        .filter_map(|e| Some((e.attr("idref")?.to_string(), e.attr("linear") != Some("no"))))
        .collect();
    let nav = manifest.values().find(|i| i.properties.iter().any(|p| p == "nav")).map(|i| i.path.clone());
    let ncx = spine_el
        .attr("toc")
        .and_then(|id| manifest.get(id))
        .or_else(|| manifest.values().find(|i| i.media_type == "application/x-dtbncx+xml"))
        .map(|i| i.path.clone());

    let cover = manifest
        .values()
        .find(|i| i.properties.iter().any(|p| p == "cover-image"))
        .or_else(|| {
            let id = metas.iter().find(|e| e.attr("name") == Some("cover"))?.attr("content")?;
            manifest.get(id)
        })
        .filter(|i| i.media_type.starts_with("image/"))
        .map(|i| i.path.clone());

    Ok(Package {
        title: field("title"),
        authors,
        language: field("language"),
        isbn,
        manifest,
        spine,
        nav,
        ncx,
        cover,
    })
}

// ---------------------------------------------------------------------------------------------
// Table of contents

#[derive(Clone, Debug)]
struct RawToc {
    title: String,
    depth: u16,
    path: String,
    fragment: Option<String>,
}

fn read_toc(archive: &mut Archive, package: &Package) -> Vec<RawToc> {
    let mut out = Vec::new();
    if let Some(nav) = &package.nav
        && let Ok(bytes) = archive.read(nav) {
            out = parse_nav(&decode_markup(&bytes), nav);
        }
    if out.is_empty()
        && let Some(ncx) = &package.ncx
            && let Ok(bytes) = archive.read(ncx) {
                out = parse_ncx(&decode_markup(&bytes), ncx);
            }
    for e in &mut out {
        e.title = clean_title(&e.title);
        if let Some(name) = archive.name(&e.path) {
            e.path = name.to_string();
        }
    }
    out
}

fn parse_nav(text: &str, path: &str) -> Vec<RawToc> {
    let root = dom::parse_markup(text);
    let nav = root
        .find(&|e| e.is("nav") && e.has_epub_type("toc"))
        .or_else(|| root.find(&|e| e.is("nav") && !e.has_epub_type("landmarks") && !e.has_epub_type("page-list")));
    let mut out = Vec::new();
    if let Some(list) = nav.and_then(|n| n.find(&|e| e.is("ol") || e.is("ul"))) {
        nav_list(list, 0, path, &mut out);
    }
    out
}

fn nav_list(list: &Element, depth: u16, path: &str, out: &mut Vec<RawToc>) {
    for li in list.child_elements().filter(|e| e.is("li")) {
        let mut child_depth = depth;
        let label = li.child_elements().find(|e| e.is("a") || e.is("span"));
        if let Some((target, fragment)) = label.and_then(|a| a.attr("href")).and_then(|h| resolve(path, h)) {
            out.push(RawToc { title: plain_text(label.unwrap()), depth, path: target, fragment });
            child_depth = depth + 1;
        }
        for sub in li.child_elements().filter(|e| e.is("ol") || e.is("ul")) {
            nav_list(sub, child_depth, path, out);
        }
    }
}

fn parse_ncx(text: &str, path: &str) -> Vec<RawToc> {
    let Ok(root) = dom::parse_xml(text) else { return Vec::new() };
    let mut out = Vec::new();
    if let Some(map) = root.find(&|e| e.name == "navmap") {
        for point in map.child_elements().filter(|e| e.name == "navpoint") {
            ncx_point(point, 0, path, &mut out);
        }
    }
    out
}

fn ncx_point(point: &Element, depth: u16, path: &str, out: &mut Vec<RawToc>) {
    let title = point
        .child_elements()
        .find(|e| e.name == "navlabel")
        .map(|l| collapse(&l.text_content()))
        .unwrap_or_default();
    let target = point.child_elements().find(|e| e.name == "content").and_then(|e| e.attr("src")).and_then(|s| resolve(path, s));
    let child_depth = if let Some((p, fragment)) = target {
        out.push(RawToc { title, depth, path: p, fragment });
        depth + 1
    } else {
        depth
    };
    for sub in point.child_elements().filter(|e| e.name == "navpoint") {
        ncx_point(sub, child_depth, path, out);
    }
}

/// Gutenberg's labels carry illustration captions ("I hope Mr. Bingley will like it. CHAPTER
/// II.") and run words together ("CHAPTERXXVII.").
fn clean_title(title: &str) -> String {
    static LABEL: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"(?i)\b(chapter|book|part|volume|canto)\s*([0-9]+|[ivxlcdm]+)\b[\s.:]*$").unwrap()
    });
    let title = collapse(title);
    let mut out = title.as_str();
    if let Some(m) = LABEL.find(&title) {
        let prefix = title[..m.start()].trim_end();
        if prefix.ends_with(['.', '!', '?', '”', '"', '’']) {
            out = &title[m.start()..];
        }
    }
    let out = LABEL.replace(out, |c: &regex::Captures| format!("{} {}", &c[1], &c[2]));
    let out = out.trim().to_string();
    if out.is_empty() { title } else { out }
}

// ---------------------------------------------------------------------------------------------
// Documents

struct Doc {
    path: String,
    body: Element,
    styles: Vec<String>,
    lang: Option<String>,
    body_class: Option<String>,
    linear: bool,
    chars: usize,
    /// Hard-wrapped text in a few huge blocks: rebuilt with the plain-text rules.
    text_dump: bool,
}

fn read_docs(archive: &mut Archive, package: &Package) -> Result<(Vec<Doc>, Vec<(String, String)>)> {
    let mut docs = Vec::new();
    let mut inline = Vec::new();
    let mut seen = HashSet::new();
    for (idref, linear) in &package.spine {
        let Some(item) = package.manifest.get(idref) else { continue };
        if !seen.insert(item.path.clone()) {
            continue;
        }
        let media = item.media_type.as_str();
        let lower = item.path.to_lowercase();
        let markup = media.contains("html")
            || media.contains("svg")
            || media.ends_with("+xml") && !media.contains("ncx")
            || [".xhtml", ".html", ".htm", ".svg"].iter().any(|ext| lower.ends_with(ext));
        let mut doc = if media.starts_with("image/") && !media.contains("svg") {
            let img = Element::new("img").with_attr("src", format!("/{}", item.path)).with_attr("alt", "");
            Doc {
                path: item.path.clone(),
                body: Element::new("body").with_child(Element::new("div").with_attr("class", "yy-image").with_child(img)),
                styles: Vec::new(),
                lang: None,
                body_class: None,
                linear: *linear,
                chars: 0,
                text_dump: false,
            }
        } else if markup {
            let bytes = match archive.read(&item.path) {
                Ok(b) => b,
                Err(CoreError::NotFound { .. }) => continue,
                Err(e) => return Err(e),
            };
            read_document(&bytes, &item.path, *linear, docs.len(), &mut inline)
        } else {
            continue;
        };
        doc.styles = doc
            .styles
            .into_iter()
            .filter_map(|s| if s.starts_with("__styles/") { Some(s) } else { archive.name(&s).map(str::to_string) })
            .collect();
        docs.push(doc);
    }
    Ok((docs, inline))
}

fn read_document(bytes: &[u8], path: &str, linear: bool, index: usize, inline: &mut Vec<(String, String)>) -> Doc {
    let root = dom::parse_markup(&decode_markup(bytes));
    let mut styles = Vec::new();
    if let Some(head) = root.first_child("head") {
        for e in head.child_elements() {
            if e.is("link") {
                let rel = e.attr("rel").unwrap_or_default().to_ascii_lowercase();
                let stylesheet = rel.split_ascii_whitespace().any(|r| r == "stylesheet") && !rel.contains("alternate");
                if let Some((css, _)) = e.attr("href").filter(|_| stylesheet).and_then(|h| resolve(path, h))
                    && !styles.contains(&css) {
                        styles.push(css);
                    }
            } else if e.is("style") {
                let css = rebase_css(&e.text_content(), &dir_of(path));
                if css.trim().is_empty() {
                    continue;
                }
                let name = format!("__styles/{}.css", &blake3::hash(css.as_bytes()).to_hex()[..16]);
                if !inline.iter().any(|(n, _)| *n == name) {
                    inline.push((name.clone(), css));
                }
                styles.push(name);
            }
        }
    }
    let mut body = match root.first_child("body") {
        Some(b) => b.clone(),
        // An SVG page, or a fragment without <body>.
        None => {
            let mut body = Element::new("body");
            if root.is("html") {
                body.children = root.children.iter().filter(|n| n.as_element().is_none_or(|e| !e.is("head"))).cloned().collect();
            } else {
                body.children.push(Node::Element(root.clone()));
            }
            body
        }
    };
    prepare(&mut body, path, index);
    let lang = ["lang", "xml:lang"]
        .iter()
        .find_map(|a| root.attr(a).or_else(|| body.attr(a)))
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .map(normalize_lang);
    let chars = count_chars(&body.children);
    let text_dump = is_text_dump(&body, chars - boilerplate_chars(&body.children));
    Doc { path: path.to_string(), body_class: body.attr("class").map(str::to_string), body, styles, lang, linear, chars, text_dump }
}

/// Makes every link and resource reference archive-absolute (`/OEBPS/ch1.xhtml#n1`), so it can
/// be resolved however the document is cut up later, and tags elements that have an id.
fn prepare(el: &mut Element, doc: &str, index: usize) {
    for child in &mut el.children {
        let Node::Element(e) = child else { continue };
        if e.is("a") && e.attr("id").is_none()
            && let Some(name) = e.remove_attr("name") {
                e.set_attr("id", name);
            }
        if e.attr("id").is_some() {
            e.set_attr(SRC_ATTR, index.to_string());
        }
        let attrs: &[&str] = match (e.ns, e.name.as_str()) {
            (Ns::Html, "a" | "area") => &["href"],
            (Ns::Html, "img" | "source") => &["src"],
            (Ns::Html, "video") => &["poster"],
            (Ns::Svg, "image") => &["href", "xlink:href"],
            _ => &[],
        };
        for attr in attrs {
            let absolute = e.attr(attr).and_then(|v| resolve(doc, v)).map(|(path, fragment)| match fragment {
                Some(f) => format!("/{path}#{f}"),
                None => format!("/{path}"),
            });
            if let Some(url) = absolute {
                e.set_attr(attr, url);
            }
        }
        prepare(e, doc, index);
    }
}

/// Inline styles are saved as files under `r/__styles/`; their relative URLs are rebased so
/// they still point where they did from the document.
fn rebase_css(css: &str, doc_dir: &str) -> String {
    static URL: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r#"url\(\s*(?:"([^"]*)"|'([^']*)'|([^)"'\s]*))\s*\)|@import\s+(?:"([^"]*)"|'([^']*)')"#).unwrap()
    });
    URL.replace_all(css, |c: &regex::Captures| {
        let (value, import) = match (1..=5).find_map(|i| c.get(i).map(|m| (m.as_str(), i >= 4))) {
            Some(v) => v,
            None => return c[0].to_string(),
        };
        if value.is_empty() || value.starts_with(['#', '/']) || has_scheme(value) {
            return c[0].to_string();
        }
        let rebased = format!("../{}", join(doc_dir, value));
        if import { format!("@import \"{rebased}\"") } else { format!("url(\"{rebased}\")") }
    })
    .into_owned()
}

/// Text whose blocks hold several paragraphs each (breaks inside a block: a blank line, or a line
/// starting with "　　"), or Chinese text broken into lines, which a browser would render with a
/// space at every line end. Markup with one paragraph per block never has either, however its
/// source is wrapped.
fn is_text_dump(body: &Element, chars: usize) -> bool {
    if chars < 5_000 {
        return false;
    }
    let (mut blank_breaks, mut cjk_breaks) = (0, 0);
    count_breaks(body, &mut blank_breaks, &mut cjk_breaks);
    blank_breaks >= 3 || cjk_breaks * TEXT_DUMP_BREAK_CHARS >= chars
}

fn count_breaks(el: &Element, blank_breaks: &mut usize, cjk_breaks: &mut usize) {
    for child in &el.children {
        match child {
            Node::Text(t) => {
                let mut prev: Option<&str> = None;
                let mut blank = false;
                for line in t.split('\n') {
                    let trimmed = line.trim();
                    if trimmed.is_empty() {
                        blank = prev.is_some();
                        continue;
                    }
                    if let Some(p) = prev {
                        let wraps = p.chars().last().is_some_and(is_wide) && trimmed.chars().next().is_some_and(is_wide);
                        if blank {
                            *blank_breaks += 1;
                        } else if line.starts_with('\u{3000}') || wraps {
                            *cjk_breaks += 1;
                        }
                    }
                    prev = Some(trimmed);
                    blank = false;
                }
            }
            Node::Element(e) if !is_boilerplate(e) => count_breaks(e, blank_breaks, cjk_breaks),
            Node::Element(_) => {}
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Cutting documents into pieces

enum Content {
    Html(Element),
    Text(txt::Chapter),
}

struct Piece {
    doc: usize,
    content: Content,
    /// The table-of-contents entry this piece starts.
    entry: Option<usize>,
    /// Comes before the first cut in its document, so it may continue the previous document.
    lead: bool,
    kind: Kind,
    chars: usize,
}

fn cut(docs: &[Doc], toc: &[RawToc]) -> Vec<Piece> {
    let mut pieces = Vec::new();
    // Hard-wrapped text from consecutive documents is collected and structured at once:
    // chapters run across the file boundaries.
    let mut text = String::new();
    let mut text_doc = 0;
    let flush = |text: &mut String, doc: usize, pieces: &mut Vec<Piece>| {
        for ch in txt::chapters(text) {
            let chars = ch.paragraphs.iter().map(|p| p.chars().filter(|c| !c.is_whitespace()).count()).sum();
            pieces.push(Piece { doc, content: Content::Text(ch), entry: None, lead: false, kind: Kind::Text, chars });
        }
        text.clear();
    };
    for (d, doc) in docs.iter().enumerate() {
        if !(doc.text_dump && doc.linear) {
            flush(&mut text, text_doc, &mut pieces);
            pieces.extend(cut_document(d, doc, toc));
            continue;
        }
        let has_blocks = doc.body.child_elements().any(is_block);
        for child in &doc.body.children {
            match child {
                Node::Element(e) if is_boilerplate(e) => {
                    flush(&mut text, text_doc, &mut pieces);
                    let mut body = doc.body.shallow_clone();
                    body.children.push(child.clone());
                    let chars = count_chars(&body.children);
                    pieces.push(Piece { doc: d, content: Content::Html(body), entry: None, lead: false, kind: Kind::Boilerplate, chars });
                }
                Node::Text(t) if has_blocks && t.trim().is_empty() => {}
                _ => {
                    if text.is_empty() {
                        text_doc = d;
                    }
                    push_lines(child, &mut text);
                }
            }
        }
        if !text.ends_with('\n') {
            text.push('\n');
        }
    }
    flush(&mut text, text_doc, &mut pieces);
    pieces
}

fn cut_document(d: usize, doc: &Doc, toc: &[RawToc]) -> Vec<Piece> {
    let body = &doc.body;
    let entries: Vec<(usize, &RawToc)> = toc.iter().enumerate().filter(|(_, e)| e.path == doc.path).collect();
    let lead_entry = entries.iter().find(|(_, e)| e.fragment.is_none()).map(|(i, _)| *i);

    let mut points: Vec<(Vec<usize>, Option<usize>)> = Vec::new();
    if doc.linear && doc.chars >= SPLIT_FILE_CHARS {
        let at_depth = |depth: u16| -> Vec<(Vec<usize>, Option<usize>)> {
            entries
                .iter()
                .filter(|(_, e)| e.depth == depth)
                .filter_map(|(i, e)| {
                    let id = e.fragment.as_deref()?;
                    let path = body.find_path(&|x| x.attr("id") == Some(id))?;
                    (!inside_boilerplate(body, &path)).then(|| (hoist(body, path), Some(*i)))
                })
                .collect()
        };
        // Cut at the shallowest entries: sections listed inside a chapter don't cut it up,
        // unless the file is too long to be one section.
        if let Some(min) = entries.iter().map(|(_, e)| e.depth).min() {
            points = at_depth(min);
            if points.is_empty() && doc.chars > MAX_SECTION_CHARS {
                points = at_depth(min + 1);
            }
        }
        if points.is_empty() && doc.chars > MAX_SECTION_CHARS {
            points = heading_points(body);
        }
        if points.len() > 300 {
            points.clear();
        }
    }
    // Gutenberg's licence header and footer become sections of their own.
    for (start, after) in boilerplate_points(body) {
        points.push((start, None));
        if let Some(after) = after {
            points.push((after, None));
        }
    }
    points.sort_by(|a, b| a.0.cmp(&b.0));
    points.dedup_by(|later, earlier| later.0 == earlier.0);

    let paths: Vec<Vec<usize>> = points.iter().map(|(p, _)| p.clone()).collect();
    let mut out = Vec::new();
    for (k, part) in split(body, &paths).into_iter().enumerate() {
        if !has_content(&part) {
            continue;
        }
        let entry = if k == 0 { lead_entry } else { points[k - 1].1 };
        let chars = count_chars(&part.children);
        let kind = if chars == 0 {
            Kind::Image
        } else if boilerplate_chars(&part.children) * 2 >= chars {
            Kind::Boilerplate
        } else {
            Kind::Text
        };
        out.push(Piece { doc: d, content: Content::Html(part), entry, lead: k == 0, kind, chars });
    }
    out
}

/// Moves a cut point up to the enclosing element while the target is that element's first
/// content: `<div class="chapter"><h2 id="c2">` is cut before the div, not inside it.
fn hoist(body: &Element, mut path: Vec<usize>) -> Vec<usize> {
    while path.len() > 1 {
        let (last, parent) = path.split_last().unwrap();
        let Some(parent) = body.get(parent) else { break };
        if parent.children[..*last].iter().any(is_meaningful) {
            break;
        }
        path.pop();
    }
    path
}

/// Blocks that read like chapter headings, for long files without a usable table of contents.
fn heading_points(body: &Element) -> Vec<(Vec<usize>, Option<usize>)> {
    fn walk(el: &Element, prefix: &mut Vec<usize>, out: &mut Vec<Vec<usize>>) {
        for (i, child) in el.children.iter().enumerate() {
            let Node::Element(e) = child else { continue };
            if is_boilerplate(e) {
                continue;
            }
            prefix.push(i);
            if is_heading_element(e) || matches!(e.name.as_str(), "p" | "div") && count_chars(&e.children) <= 60 {
                let t = plain_text(e);
                if !t.is_empty() && txt::is_heading(&t) {
                    out.push(prefix.clone());
                }
            }
            if !is_heading_element(e) && !e.is("p") && prefix.len() < 6 {
                walk(e, prefix, out);
            }
            prefix.pop();
        }
    }
    let mut paths = Vec::new();
    walk(body, &mut Vec::new(), &mut paths);
    paths.into_iter().map(|p| (hoist(body, p), None)).collect()
}

/// Each licence block's path, and the path just after it if anything follows.
fn boilerplate_points(body: &Element) -> Vec<(Vec<usize>, Option<Vec<usize>>)> {
    fn walk(el: &Element, prefix: &mut Vec<usize>, out: &mut Vec<(Vec<usize>, Option<Vec<usize>>)>) {
        for (i, child) in el.children.iter().enumerate() {
            let Node::Element(e) = child else { continue };
            prefix.push(i);
            if is_boilerplate(e) {
                let after = (i + 1 < el.children.len()).then(|| {
                    let mut p = prefix.clone();
                    *p.last_mut().unwrap() += 1;
                    p
                });
                out.push((prefix.clone(), after));
            } else if prefix.len() < 4 {
                walk(e, prefix, out);
            }
            prefix.pop();
        }
    }
    let mut out = Vec::new();
    walk(body, &mut Vec::new(), &mut out);
    out
}

fn inside_boilerplate(body: &Element, path: &[usize]) -> bool {
    (1..=path.len()).any(|n| body.get(&path[..n]).is_some_and(is_boilerplate))
}

/// Cuts `body` before each of `paths` (sorted, in document order). Elements a cut passes
/// through are cloned into both halves; the right-hand clone loses its id.
fn split(body: &Element, paths: &[Vec<usize>]) -> Vec<Element> {
    let mut rest = body.clone();
    let mut parts = Vec::with_capacity(paths.len() + 1);
    // Cutting from the end keeps the earlier paths valid in what's left.
    for path in paths.iter().rev() {
        let (left, right) = split_one(rest, path);
        parts.push(right);
        rest = left;
    }
    parts.push(rest);
    parts.reverse();
    parts
}

fn split_one(mut el: Element, path: &[usize]) -> (Element, Element) {
    let mut right = el.shallow_clone();
    right.remove_attr("id");
    right.remove_attr(SRC_ATTR);
    let i = path[0].min(el.children.len());
    let mut tail = el.children.split_off(i).into_iter();
    if path.len() > 1 {
        match tail.next() {
            Some(Node::Element(child)) => {
                let (l, r) = split_one(child, &path[1..]);
                el.children.push(Node::Element(l));
                right.children.push(Node::Element(r));
            }
            Some(text) => right.children.push(text),
            None => {}
        }
    }
    right.children.extend(tail);
    (el, right)
}

// ---------------------------------------------------------------------------------------------
// Sections

#[derive(Default)]
struct Assembled {
    sections: Vec<Section>,
    chars: Vec<usize>,
    /// The section began at a table-of-contents entry, in the book's own markup.
    joinable: Vec<bool>,
    /// Table-of-contents entry → the section it starts.
    entry_sections: HashMap<usize, u32>,
    /// Document → the section its content starts in.
    doc_sections: HashMap<usize, u32>,
}

fn assemble(pieces: Vec<Piece>, docs: &[Doc], toc: &[RawToc]) -> Assembled {
    let mut a = Assembled::default();
    for piece in pieces {
        let doc = &docs[piece.doc];
        let index = a.sections.len() as u32;
        match piece.content {
            Content::Html(body) => {
                // The start of a file that only continues the chapter before it, as when a
                // chapter is split into files by size.
                let joins = piece.lead
                    && piece.entry.is_none()
                    && piece.kind == Kind::Text
                    && doc.linear
                    && a.joinable.last() == Some(&true)
                    && a.chars.last().is_some_and(|c| c + piece.chars <= MAX_JOINED_CHARS)
                    && !starts_with_heading(&body);
                if joins {
                    let last = a.sections.last_mut().unwrap();
                    last.body.children.extend(body.children);
                    for s in &doc.styles {
                        if !last.styles.contains(s) {
                            last.styles.push(s.clone());
                        }
                    }
                    *a.chars.last_mut().unwrap() += piece.chars;
                    a.doc_sections.entry(piece.doc).or_insert(index - 1);
                    continue;
                }
                let title = piece.entry.map(|i| toc[i].title.clone()).filter(|t| !t.is_empty()).or_else(|| heading_title(&body));
                a.sections.push(Section {
                    title,
                    body,
                    styles: doc.styles.clone(),
                    lang: doc.lang.clone(),
                    body_class: doc.body_class.clone(),
                    linear: doc.linear,
                    kind: piece.kind,
                    continued: false,
                });
                a.joinable.push(piece.entry.is_some() && piece.kind == Kind::Text);
                if let Some(e) = piece.entry {
                    a.entry_sections.insert(e, index);
                }
            }
            Content::Text(ch) => {
                a.sections.push(Section {
                    body: txt::chapter_body(&ch),
                    title: ch.title.clone(),
                    styles: Vec::new(),
                    lang: doc.lang.clone(),
                    body_class: None,
                    linear: true,
                    kind: Kind::Text,
                    continued: ch.continued,
                });
                a.joinable.push(false);
            }
        }
        a.chars.push(piece.chars);
        a.doc_sections.entry(piece.doc).or_insert(index);
    }
    a
}

/// Cuts sections that are still too long into parts at block boundaries.
fn split_large(a: &mut Assembled) {
    let sections = std::mem::take(&mut a.sections);
    let mut out = Vec::with_capacity(sections.len());
    let mut chars = Vec::with_capacity(sections.len());
    let mut remap = Vec::with_capacity(sections.len());
    for (i, section) in sections.into_iter().enumerate() {
        remap.push(out.len() as u32);
        let points = if a.chars[i] > MAX_SECTION_CHARS { size_points(&section.body) } else { Vec::new() };
        if points.is_empty() {
            out.push(section);
            chars.push(a.chars[i]);
            continue;
        }
        let first = out.len();
        for body in split(&section.body, &points) {
            if !has_content(&body) {
                continue;
            }
            chars.push(count_chars(&body.children));
            out.push(Section {
                title: section.title.clone(),
                body,
                styles: section.styles.clone(),
                lang: section.lang.clone(),
                body_class: section.body_class.clone(),
                linear: section.linear,
                kind: section.kind,
                continued: section.continued || out.len() > first,
            });
        }
    }
    for s in a.entry_sections.values_mut().chain(a.doc_sections.values_mut()) {
        *s = remap[*s as usize];
    }
    a.sections = out;
    a.chars = chars;
}

fn size_points(body: &Element) -> Vec<Vec<usize>> {
    // Look inside wrappers that hold nearly everything (<div class="chapter">).
    let total = count_chars(&body.children);
    let mut prefix = Vec::new();
    let mut container = body;
    while let Some((i, e)) = container.children.iter().enumerate().find_map(|(i, n)| {
        let e = n.as_element()?;
        (count_chars(&e.children) * 10 >= total * 9 && e.child_elements().count() > 1).then_some((i, e))
    }) {
        prefix.push(i);
        container = e;
    }
    let total = count_chars(&container.children);
    let mut points = Vec::new();
    let (mut size, mut consumed) = (0, 0);
    for (i, child) in container.children.iter().enumerate() {
        if size >= PART_CHARS && total - consumed >= PART_CHARS / 4 {
            let mut p = prefix.clone();
            p.push(i);
            points.push(p);
            size = 0;
        }
        let n = count_chars(std::slice::from_ref(child));
        size += n;
        consumed += n;
    }
    points
}

/// Records where every element id ended up, making ids unique within each section.
fn collect_targets(sections: &mut [Section], docs: &[Doc]) -> HashMap<(String, String), (u32, String)> {
    fn visit(el: &mut Element, f: &mut dyn FnMut(&mut Element)) {
        for child in &mut el.children {
            if let Node::Element(e) = child {
                f(e);
                visit(e, f);
            }
        }
    }
    let mut targets = HashMap::new();
    for (s, section) in sections.iter_mut().enumerate() {
        let mut seen = HashSet::new();
        visit(&mut section.body, &mut |e| {
            let src = e.remove_attr(SRC_ATTR);
            let Some(id) = e.attr("id").map(str::to_string) else { return };
            let mut unique = id.clone();
            let mut n = 2;
            while !seen.insert(unique.clone()) {
                unique = format!("{id}-{n}");
                n += 1;
            }
            if unique != id {
                e.set_attr("id", unique.clone());
            }
            if let Some(doc) = src.and_then(|i| i.parse::<usize>().ok()).and_then(|i| docs.get(i)) {
                targets.entry((doc.path.clone(), id)).or_insert((s as u32, unique));
            }
        });
    }
    targets
}

fn final_toc(
    raw: &[RawToc],
    docs: &[Doc],
    a: &Assembled,
    targets: &HashMap<(String, String), (u32, String)>,
    doc_sections: &HashMap<String, u32>,
) -> Vec<TocEntry> {
    let dumped: HashSet<&str> = docs.iter().filter(|d| d.text_dump && d.linear).map(|d| d.path.as_str()).collect();
    let mut entries: Vec<(u32, usize, TocEntry)> = Vec::new();
    for (i, e) in raw.iter().enumerate() {
        // Anchors in text that was rebuilt from hard-wrapped lines don't exist any more.
        if dumped.contains(e.path.as_str()) {
            continue;
        }
        let target = match a.entry_sections.get(&i) {
            Some(s) => Some((*s, None)),
            None => e
                .fragment
                .as_ref()
                .and_then(|f| targets.get(&(e.path.clone(), f.clone())))
                .map(|(s, id)| (*s, Some(id.clone())))
                .or_else(|| doc_sections.get(&e.path).map(|s| (*s, None))),
        };
        if let Some((section, anchor)) = target {
            let title = if e.title.is_empty() { a.sections[section as usize].title.clone().unwrap_or_default() } else { e.title.clone() };
            entries.push((section, i, TocEntry { title, depth: e.depth, section, anchor }));
        }
    }
    let generated: Vec<(u32, usize, TocEntry)> = a
        .sections
        .iter()
        .enumerate()
        .filter(|(i, s)| s.styles.is_empty() && s.body_class.is_none() && !a.joinable[*i] && is_text_chapter(s))
        .map(|(i, s)| (i as u32, raw.len() + i, TocEntry { title: s.title.clone().unwrap(), depth: 0, section: i as u32, anchor: None }))
        .collect();
    if !generated.is_empty() {
        entries.extend(generated);
        entries.sort_by_key(|(section, order, _)| (*section, *order));
    }
    if entries.is_empty() {
        // No table of contents: list the sections that have titles.
        return a
            .sections
            .iter()
            .enumerate()
            .filter(|(_, s)| s.linear && s.kind == Kind::Text && !s.continued && s.title.is_some())
            .map(|(i, s)| TocEntry { title: s.title.clone().unwrap(), depth: 0, section: i as u32, anchor: None })
            .collect();
    }
    entries.into_iter().map(|(_, _, e)| e).collect()
}

/// A chapter rebuilt from plain text, with its own title.
fn is_text_chapter(s: &Section) -> bool {
    !s.continued && s.title.is_some() && s.body.first_child("h2").is_some_and(|h| h.has_class("yy-title"))
}

// ---------------------------------------------------------------------------------------------
// Tree helpers

fn is_boilerplate(e: &Element) -> bool {
    e.has_class("pg-boilerplate") || e.attr("id") == Some("pg-footer") || e.attr("id") == Some("pg-header")
}

fn is_heading_element(e: &Element) -> bool {
    matches!(e.name.as_str(), "h1" | "h2" | "h3" | "h4" | "h5" | "h6") && e.ns == Ns::Html
}

fn is_block(e: &Element) -> bool {
    e.ns == Ns::Html
        && matches!(
            e.name.as_str(),
            "p" | "div" | "h1" | "h2" | "h3" | "h4" | "h5" | "h6" | "li" | "ul" | "ol" | "dl" | "dt" | "dd"
                | "blockquote" | "pre" | "section" | "article" | "header" | "footer" | "aside" | "nav"
                | "figure" | "figcaption" | "table" | "tr" | "hr" | "main" | "body"
        )
}

fn is_media(e: &Element) -> bool {
    e.ns != Ns::Html || matches!(e.name.as_str(), "img" | "video" | "object")
}

fn is_meaningful(n: &Node) -> bool {
    match n {
        Node::Text(t) => !t.trim().is_empty(),
        Node::Element(e) => is_media(e) || e.children.iter().any(is_meaningful),
    }
}

fn has_content(body: &Element) -> bool {
    body.children.iter().any(is_meaningful)
}

/// Non-blank characters, not counting ruby annotations.
fn count_chars(nodes: &[Node]) -> usize {
    nodes
        .iter()
        .map(|n| match n {
            Node::Text(t) => t.chars().filter(|c| !c.is_whitespace()).count(),
            Node::Element(e) if matches!(e.name.as_str(), "rt" | "rp") => 0,
            Node::Element(e) => count_chars(&e.children),
        })
        .sum()
}

fn boilerplate_chars(nodes: &[Node]) -> usize {
    nodes
        .iter()
        .map(|n| match n {
            Node::Element(e) if is_boilerplate(e) => count_chars(&e.children),
            Node::Element(e) => boilerplate_chars(&e.children),
            Node::Text(_) => 0,
        })
        .sum()
}

/// Text with line structure: `<br>` and block boundaries become line breaks.
fn push_lines(node: &Node, out: &mut String) {
    match node {
        Node::Text(t) => out.push_str(t),
        Node::Element(e) => {
            if e.is("br") {
                out.push('\n');
                return;
            }
            if matches!(e.name.as_str(), "rt" | "rp" | "script" | "style" | "head") {
                return;
            }
            let block = is_block(e);
            if block && !out.is_empty() && !out.ends_with('\n') {
                out.push('\n');
            }
            let has_blocks = e.child_elements().any(is_block);
            for child in &e.children {
                if has_blocks && matches!(child, Node::Text(t) if t.trim().is_empty()) {
                    continue;
                }
                push_lines(child, out);
            }
            if block && !out.ends_with('\n') {
                out.push('\n');
            }
        }
    }
}

/// An element's text on one line, for titles.
fn plain_text(e: &Element) -> String {
    let mut s = String::new();
    for child in &e.children {
        push_lines(child, &mut s);
    }
    collapse(&s)
}

fn heading_title(body: &Element) -> Option<String> {
    fn first(el: &Element, blocks: &mut usize) -> Option<String> {
        for e in el.child_elements() {
            if *blocks >= 3 {
                return None;
            }
            if is_heading_element(e) {
                let t = plain_text(e);
                if !t.is_empty() {
                    return Some(t);
                }
            } else if matches!(e.name.as_str(), "p" | "li" | "blockquote" | "pre" | "table") || is_media(e) {
                if is_meaningful(&Node::Element(e.clone())) {
                    *blocks += 1;
                }
            } else if let Some(t) = first(e, blocks) {
                return Some(t);
            }
        }
        None
    }
    let t = first(body, &mut 0)?;
    Some(if t.chars().count() > 80 { format!("{}…", t.chars().take(79).collect::<String>()) } else { t })
}

fn starts_with_heading(el: &Element) -> bool {
    for child in &el.children {
        match child {
            Node::Text(t) if t.trim().is_empty() => continue,
            Node::Text(_) => return false,
            Node::Element(e) => {
                if !is_meaningful(child) {
                    continue;
                }
                if is_heading_element(e) {
                    return true;
                }
                if matches!(e.name.as_str(), "div" | "section" | "article" | "header" | "hgroup" | "main") {
                    return starts_with_heading(e);
                }
                // A paragraph that reads like a heading: "第二章", "CHAPTER II."
                return txt::is_heading(&plain_text(e));
            }
        }
    }
    false
}

// ---------------------------------------------------------------------------------------------
// Paths and encodings

const PATH_SEGMENT: &AsciiSet = &CONTROLS
    .add(b' ')
    .add(b'"')
    .add(b'#')
    .add(b'%')
    .add(b'\'')
    .add(b'<')
    .add(b'>')
    .add(b'?')
    .add(b'[')
    .add(b'\\')
    .add(b']')
    .add(b'^')
    .add(b'`')
    .add(b'{')
    .add(b'|')
    .add(b'}');

pub(crate) fn encode_path(path: &str) -> String {
    path.split('/').map(|s| utf8_percent_encode(s, PATH_SEGMENT).to_string()).collect::<Vec<_>>().join("/")
}

fn has_scheme(href: &str) -> bool {
    let Some(colon) = href.find(':') else { return false };
    let scheme = &href[..colon];
    scheme.len() >= 2
        && scheme.starts_with(|c: char| c.is_ascii_alphabetic())
        && scheme.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'))
}

fn split_fragment(s: &str) -> (&str, Option<&str>) {
    match s.split_once('#') {
        Some((p, f)) => (p, Some(f).filter(|f| !f.is_empty())),
        None => (s, None),
    }
}

/// The archive path an href in `doc` names, and its fragment. `None` for URLs with a scheme.
fn resolve(doc: &str, href: &str) -> Option<(String, Option<String>)> {
    let href = href.trim();
    if href.is_empty() || has_scheme(href) {
        return None;
    }
    let (path, fragment) = split_fragment(href);
    let path = percent_decode_str(path.split('?').next().unwrap_or("")).decode_utf8_lossy();
    let path = if path.is_empty() {
        doc.to_string()
    } else if path.starts_with('/') {
        join("", &path)
    } else {
        join(&dir_of(doc), &path)
    };
    let fragment = fragment.map(|f| percent_decode_str(f).decode_utf8_lossy().into_owned());
    Some((path, fragment))
}

fn dir_of(path: &str) -> String {
    path.rfind('/').map(|i| path[..i].to_string()).unwrap_or_default()
}

/// `join("OEBPS/text", "../images/a.png")` → `OEBPS/images/a.png`. Paths never climb above the
/// archive root: books in the wild have one `..` too many and readers cope.
fn join(base: &str, href: &str) -> String {
    let mut parts: Vec<&str> = base.split('/').filter(|s| !s.is_empty()).collect();
    for segment in href.split('/') {
        match segment {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            s => parts.push(s),
        }
    }
    parts.join("/")
}

fn normalize_lang(lang: &str) -> String {
    let mut parts = lang.trim().split(['-', '_']).filter(|p| !p.is_empty());
    let mut out = parts.next().unwrap_or_default().to_ascii_lowercase();
    for part in parts {
        out.push('-');
        if part.len() == 4 {
            let mut chars = part.chars();
            out.extend(chars.next().map(|c| c.to_ascii_uppercase()));
            out.extend(chars.map(|c| c.to_ascii_lowercase()));
        } else {
            out.push_str(&part.to_ascii_uppercase());
        }
    }
    out
}

/// Decodes a book file: the BOM, UTF-8 if it is valid, the declared encoding, then a guess.
fn decode_markup(bytes: &[u8]) -> String {
    if let Some((enc, bom_len)) = encoding_rs::Encoding::for_bom(bytes) {
        return enc.decode_without_bom_handling(&bytes[bom_len..]).0.into_owned();
    }
    if let Ok(s) = std::str::from_utf8(bytes) {
        return s.to_string();
    }
    let head = String::from_utf8_lossy(&bytes[..bytes.len().min(1024)]);
    let enc = declared_encoding(&head).filter(|e| *e != encoding_rs::UTF_8).unwrap_or_else(|| {
        let mut detector = chardetng::EncodingDetector::new(chardetng::Iso2022JpDetection::Deny);
        detector.feed(bytes, true);
        detector.guess(None, chardetng::Utf8Detection::Allow)
    });
    enc.decode(bytes).0.into_owned()
}

fn declared_encoding(head: &str) -> Option<&'static encoding_rs::Encoding> {
    static DECLARED: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r#"(?i)(?:charset|encoding)\s*=\s*["']?\s*([A-Za-z0-9_.:\-]+)"#).unwrap());
    let label = DECLARED.captures(head)?.get(1)?.as_str();
    let enc = encoding_rs::Encoding::for_label(label.as_bytes())?;
    (enc != encoding_rs::UTF_16LE && enc != encoding_rs::UTF_16BE).then_some(enc)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> Book {
        read(Path::new(&format!("{}/../../fixtures/books/{name}", env!("CARGO_MANIFEST_DIR")))).unwrap()
    }

    fn titles(book: &Book) -> Vec<String> {
        book.toc.iter().map(|e| e.title.clone()).collect()
    }

    /// `YUYUE_BOOK=path cargo test -p yuyue-core --lib dump_book -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn dump_book() {
        let book = read(Path::new(&std::env::var("YUYUE_BOOK").unwrap())).unwrap();
        println!("title {:?} authors {:?} lang {} start {}", book.title, book.authors, book.language, book.start);
        for (i, s) in book.sections.iter().enumerate() {
            let text = plain_text(&s.body);
            let head: String = text.chars().take(60).collect();
            let tail: String = text.chars().rev().take(40).collect::<Vec<_>>().into_iter().rev().collect();
            println!(
                "#{i} {:?}{} {:?} {} chars | {head} … {tail}",
                s.kind,
                if s.continued { " (cont)" } else { "" },
                s.title,
                count_chars(&s.body.children)
            );
        }
        for e in &book.toc {
            println!("toc {}{} -> {} {:?}", "  ".repeat(e.depth as usize), e.title, e.section, e.anchor);
        }
    }

    #[test]
    fn paths() {
        assert_eq!(join("OEBPS/text", "../images/a.png"), "OEBPS/images/a.png");
        assert_eq!(join("", "OEBPS/ch1.xhtml"), "OEBPS/ch1.xhtml");
        assert_eq!(join("OEBPS", "../../a.css"), "a.css");
        assert_eq!(resolve("OEBPS/text/ch1.xhtml", "ch2.xhtml#p2"), Some(("OEBPS/text/ch2.xhtml".into(), Some("p2".into()))));
        assert_eq!(resolve("OEBPS/ch1.xhtml", "#n1"), Some(("OEBPS/ch1.xhtml".into(), Some("n1".into()))));
        assert_eq!(resolve("OEBPS/ch1.xhtml", "a%20b.png"), Some(("OEBPS/a b.png".into(), None)));
        assert_eq!(resolve("OEBPS/ch1.xhtml", "https://example.com/x"), None);
        assert_eq!(resolve("OEBPS/ch1.xhtml", "data:image/png;base64,AAA"), None);
        assert_eq!(encode_path("OEBPS/图片/a b.png"), "OEBPS/%E5%9B%BE%E7%89%87/a%20b.png");
        assert_eq!(safe_relative("OEBPS/a.png"), Some(PathBuf::from("OEBPS/a.png")));
        assert_eq!(safe_relative("../evil"), None);
        assert_eq!(safe_relative("OEBPS/../../evil"), None);
        assert_eq!(safe_relative("/etc/passwd"), None);
        assert_eq!(safe_relative("C:/x"), None);
    }

    #[test]
    fn langs_and_encodings() {
        assert_eq!(normalize_lang("zh"), "zh");
        assert_eq!(normalize_lang("zh-hans-cn"), "zh-Hans-CN");
        assert_eq!(normalize_lang("zh_TW"), "zh-TW");
        assert_eq!(
            declared_encoding(r#"<meta http-equiv="Content-Type" content="text/html; charset=GBK"/>"#),
            Some(encoding_rs::GBK)
        );
        assert_eq!(declared_encoding(r#"<?xml version="1.0" encoding="utf-8"?>"#), Some(encoding_rs::UTF_8));
        let (gbk, _, _) = encoding_rs::GBK.encode(r#"<?xml version="1.0" encoding="gbk"?><p>背影</p>"#);
        assert_eq!(decode_markup(&gbk), r#"<?xml version="1.0" encoding="gbk"?><p>背影</p>"#);
    }

    #[test]
    fn toc_labels() {
        assert_eq!(clean_title("I hope Mr. Bingley will like it. CHAPTER II."), "CHAPTER II");
        assert_eq!(clean_title("“On the Stairs.” CHAPTERXXVII."), "CHAPTER XXVII");
        assert_eq!(clean_title("Chapter I."), "Chapter I");
        assert_eq!(clean_title("A Tale of Two Cities, Book 2"), "A Tale of Two Cities, Book 2");
        assert_eq!(clean_title("  第一章　标点和注音 "), "第一章 标点和注音");
    }

    #[test]
    fn inline_css_is_rebased() {
        assert_eq!(
            rebase_css("p{background:url(img/a.png)} @import 'x.css'; q{src:url(data:x)}", "OEBPS/text"),
            "p{background:url(\"../OEBPS/text/img/a.png\")} @import \"../OEBPS/text/x.css\"; q{src:url(data:x)}"
        );
    }

    #[test]
    fn splitting_keeps_wrappers() {
        let root = dom::parse_markup(
            r#"<html><body><div class="ch" id="c1"><h2 id="a">One</h2><p>1</p></div><div class="ch"><p>2</p><h2 id="b">Two</h2><p>3</p></div></body></html>"#,
        );
        let body = root.first_child("body").unwrap();
        let a = hoist(body, body.find_path(&|e| e.attr("id") == Some("a")).unwrap());
        let b = hoist(body, body.find_path(&|e| e.attr("id") == Some("b")).unwrap());
        assert_eq!(a, vec![0]);
        assert_eq!(b, vec![1, 1]);
        let parts: Vec<String> = split(body, &[a, b]).iter().map(|p| dom::to_html(&p.children)).collect();
        assert_eq!(
            parts,
            vec![
                "".to_string(),
                r#"<div class="ch" id="c1"><h2 id="a">One</h2><p>1</p></div><div class="ch"><p>2</p></div>"#.into(),
                r#"<div class="ch"><h2 id="b">Two</h2><p>3</p></div>"#.into(),
            ]
        );
    }

    #[test]
    fn small_book() {
        let mut book = fixture("edge-cases.epub");
        assert_eq!(book.title.as_deref(), Some("边界情况"));
        assert_eq!(book.sections.len(), 2);
        assert_eq!(book.language, "zh-CN");
        assert_eq!(titles(&book), vec!["第一章 标点和注音", "Chapter Two", "Part Two"]);
        assert_eq!(book.toc[2], TocEntry { title: "Part Two".into(), depth: 0, section: 1, anchor: Some("part2".into()) });
        assert_eq!(book.sections[1].lang.as_deref(), Some("en"));
        assert!(matches!(book.link("/OEBPS/text/ch2.xhtml#part2"), Link::Internal(1, Some(a)) if a == "part2"));
        assert!(matches!(book.link("/OEBPS/text/ch1.xhtml#fn1"), Link::Internal(0, Some(a)) if a == "fn1"));
        assert!(matches!(book.link("/oebps/TEXT/ch2.xhtml"), Link::Internal(1, None)));
        assert!(matches!(book.link("https://example.com/"), Link::External(_)));
        assert!(matches!(book.link("javascript:alert(1)"), Link::Dead));
        assert_eq!(book.resource_url("/OEBPS/images/dot.png").as_deref(), Some("../r/OEBPS/images/dot.png"));
        assert_eq!(book.resource_url("/OEBPS/missing.png"), None);
        assert!(book.sections[0].styles.iter().any(|s| s.ends_with("style.css")));
        let dir = std::env::temp_dir().join(format!("yuyue-epub-test-{}", std::process::id()));
        book.extract_resources(&dir).unwrap();
        assert!(dir.join("OEBPS/images/dot.png").exists());
        assert!(!dir.join("OEBPS/text/ch1.xhtml").exists());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn pride_and_prejudice_chapters() {
        let book = fixture("pride-and-prejudice.epub");
        assert_eq!(book.authors, vec!["Jane Austen"]);
        assert_eq!(book.language, "en");
        let chapters: Vec<&TocEntry> = book.toc.iter().filter(|e| e.title.to_lowercase().starts_with("chapter")).collect();
        assert_eq!(chapters.len(), 61);
        // Every chapter starts its own section, at the top.
        let mut sections: Vec<u32> = chapters.iter().map(|e| e.section).collect();
        sections.dedup();
        assert_eq!(sections.len(), 61);
        assert!(chapters.iter().all(|e| e.anchor.is_none()), "{chapters:?}");
        assert_eq!(chapters[1].title, "CHAPTER II");
        // Chapter I runs on into the second file; the run-on part is joined to it.
        let one = &book.sections[chapters[0].section as usize];
        let two = &book.sections[chapters[1].section as usize];
        assert!(plain_text(&one.body).contains("This was invitation enough."));
        assert!(plain_text(&two.body).trim_start().starts_with("I hope Mr. Bingley will like it."), "{}", &plain_text(&two.body)[..200]);
        assert_eq!(book.sections[book.start as usize].kind, Kind::Text);
        assert_eq!(book.sections.first().unwrap().kind, Kind::Image);
        assert_eq!(book.sections.last().unwrap().kind, Kind::Boilerplate);
        assert!(book.sections.iter().any(|s| s.kind == Kind::Boilerplate && plain_text(&s.body).contains("START OF THE PROJECT GUTENBERG")));
        assert!(book.sections.iter().all(|s| count_chars(&s.body.children) <= MAX_JOINED_CHARS));
    }

    #[test]
    fn gatsby_chapters_inside_big_files() {
        let book = fixture("great-gatsby.epub");
        let numbered: Vec<&TocEntry> = book.toc.iter().filter(|e| e.title.chars().all(|c| "IVX".contains(c))).collect();
        assert_eq!(numbered.len(), 9);
        let mut sections: Vec<u32> = numbered.iter().map(|e| e.section).collect();
        sections.dedup();
        assert_eq!(sections.len(), 9);
    }

    #[test]
    fn hongloumeng_is_rebuilt_from_text() {
        let book = fixture("hongloumeng.epub");
        assert_eq!(book.language, "zh-Hant");
        let chapters: Vec<&TocEntry> = book.toc.iter().filter(|e| e.title.starts_with('第')).collect();
        assert_eq!(chapters.len(), 120, "{:?}", titles(&book));
        assert_eq!(chapters[0].title, "第一回 甄士隱夢幻識通靈 賈雨村風塵怀閨秀");
        assert_eq!(chapters[2].title, "第三回 賈雨村夤緣复舊職 林黛玉拋父進京都");
        assert_eq!(chapters[119].title, "第一二零回 甄士隱詳說太虛情 賈雨村歸結紅樓夢");
        let first = &book.sections[chapters[0].section as usize];
        let p = first.body.child_elements().find(|e| e.is("p")).unwrap();
        assert!(p.text_content().starts_with("此開卷第一回也"), "{}", p.text_content());
        assert!(book.toc.iter().any(|e| e.title.contains("LICENSE")));
        assert!(book.sections[book.start as usize].title.as_deref().unwrap().starts_with("第一回"));
    }

    #[test]
    fn isbn_only_when_it_checks_out() {
        assert_eq!(isbn13("urn:isbn:978-7-5366-9293-0").as_deref(), Some("9787536692930"));
        assert_eq!(isbn13("7536692935").as_deref(), Some("9787536692930"));
        assert_eq!(isbn13("ISBN 978 7 5366 9293 1"), None);
        assert_eq!(isbn13("urn:uuid:5a5f6a2e-9d65-4c4b-9c25-6f6d1e1f2a3b"), None);
    }

}
