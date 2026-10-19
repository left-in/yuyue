//! 导出成 EPUB: a book as the reader sees it (the replace rules applied), its highlights drawn
//! in, each thought a footnote after its highlight. Any reader that opens EPUB 3 shows them.
//!
//! The sections are the normalized ones the app reads (`s/<n>.html`), so their resource URLs
//! (`../r/…`) still work with the sections at `OEBPS/s/` and the resources at `OEBPS/r/`.

use std::fmt::Write as _;
use std::fs::{self, File};
use std::io::Write as _;
use std::path::Path;

use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipWriter};

use crate::api::YuyueCore;
use crate::book::{self, Format, Manifest};
use crate::dom::{self, Element, Node, Ns};
use crate::error::{CoreError, Result};
use crate::i18n::tr;
use crate::notes::{Mark, MarkStyle, TextPoint};

#[uniffi::export]
impl YuyueCore {
    /// Writes the book to `path` as an EPUB; with `notes`, its highlights and thoughts in it.
    pub fn export_epub(&self, book_id: String, notes: bool, path: String) -> Result<()> {
        let m = self.manifest(&book_id)?;
        if matches!(m.format, Format::Comic | Format::Pdf) {
            return Err(CoreError::Invalid { message: tr("漫画和 PDF 不能导出成 EPUB", "Comics and PDFs can't be exported as EPUB") });
        }
        let dir = self.book_dir(&book_id)?;
        let rules = self.rules_for(&book_id, false)?;
        let marks = if notes { self.marks(book_id.clone())? } else { Vec::new() };
        let tmp = format!("{path}.part");
        let result = write_epub(&m, &dir, &|n| Ok(rules.apply_html(&book::section_html(&dir, n)?)), &marks, Path::new(&tmp));
        match result {
            Ok(()) => Ok(fs::rename(&tmp, &path)?),
            Err(e) => {
                let _ = fs::remove_file(&tmp);
                Err(e)
            }
        }
    }
}

fn write_epub(m: &Manifest, dir: &Path, section: &dyn Fn(u32) -> Result<String>, marks: &[Mark], out: &Path) -> Result<()> {
    let mut zip = ZipWriter::new(File::create(out)?);
    let stored = SimpleFileOptions::default().compression_method(CompressionMethod::Stored);
    let deflated = SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
    let z = |e: zip::result::ZipError| CoreError::Io { message: e.to_string() };

    // The mimetype comes first and uncompressed (EPUB OCF).
    zip.start_file("mimetype", stored).map_err(z)?;
    zip.write_all(b"application/epub+zip")?;
    zip.start_file("META-INF/container.xml", deflated).map_err(z)?;
    zip.write_all(CONTAINER.as_bytes())?;

    let mut items = String::new();
    let mut spine = String::new();

    // Resources: pictures, stylesheets and fonts, where the sections already point.
    let r = dir.join("r");
    if r.is_dir() {
        let mut files = Vec::new();
        walk(&r, &mut files)?;
        for (i, f) in files.iter().enumerate() {
            let rel = f.strip_prefix(dir).unwrap_or(f).to_string_lossy().replace('\\', "/");
            let Some(media) = media_type(&rel) else {
                continue;
            };
            zip.start_file(format!("OEBPS/{rel}"), deflated).map_err(z)?;
            zip.write_all(&fs::read(f)?)?;
            let _ = writeln!(items, r#"    <item id="r{i}" href="{}" media-type="{media}"/>"#, dom::escape(&rel));
        }
    }

    let mut cover_meta = String::new();
    if let Some(cover) = m.cover.as_deref()
        && let (Ok(bytes), Some(media)) = (fs::read(dir.join(cover)), media_type(cover))
    {
        zip.start_file(format!("OEBPS/{cover}"), deflated).map_err(z)?;
        zip.write_all(&bytes)?;
        let _ = writeln!(items, r#"    <item id="cover" href="{}" media-type="{media}" properties="cover-image"/>"#, dom::escape(cover));
        cover_meta = r#"    <meta name="cover" content="cover"/>"#.to_string() + "\n";
    }

    zip.start_file("OEBPS/yuyue.css", deflated).map_err(z)?;
    zip.write_all(CSS.as_bytes())?;
    items.push_str("    <item id=\"css\" href=\"yuyue.css\" media-type=\"text/css\"/>\n");

    for (n, info) in m.sections.iter().enumerate() {
        let n = n as u32;
        let content = section(n)?;
        let mine: Vec<&Mark> = marks.iter().filter(|k| k.section == n).collect();
        let body = nodes_xhtml(&draw_marks(&content, &mine));
        let lang = m.section_lang(n);
        let mut x = String::new();
        let _ = write!(
            x,
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE html>\n<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\" lang=\"{0}\" xml:lang=\"{0}\">\n<head>\n<meta charset=\"UTF-8\"/>\n<title>{1}</title>\n",
            dom::escape(lang),
            dom::escape(info.title.as_deref().unwrap_or(&m.title)),
        );
        for s in &info.styles {
            let _ = writeln!(x, r#"<link rel="stylesheet" href="../r/{}"/>"#, dom::escape(s));
        }
        x.push_str("<link rel=\"stylesheet\" href=\"../yuyue.css\"/>\n</head>\n");
        match info.body_class.as_deref() {
            Some(c) => {
                let _ = writeln!(x, r#"<body class="{}">"#, dom::escape(c));
            }
            None => x.push_str("<body>\n"),
        }
        x.push_str(&body);
        x.push_str("\n</body>\n</html>\n");
        zip.start_file(format!("OEBPS/s/{n}.xhtml"), deflated).map_err(z)?;
        zip.write_all(x.as_bytes())?;
        let _ = writeln!(items, r#"    <item id="s{n}" href="s/{n}.xhtml" media-type="application/xhtml+xml"/>"#);
        let _ = writeln!(spine, r#"    <itemref idref="s{n}"{}/>"#, if info.linear { "" } else { r#" linear="no""# });
    }

    zip.start_file("OEBPS/nav.xhtml", deflated).map_err(z)?;
    zip.write_all(nav(m).as_bytes())?;
    items.push_str("    <item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n");

    let mut meta = String::new();
    let _ = writeln!(meta, "    <dc:identifier id=\"id\">urn:yuyue:{}</dc:identifier>", m.id);
    let _ = writeln!(meta, "    <dc:title>{}</dc:title>", dom::escape(&m.title));
    for a in &m.authors {
        let _ = writeln!(meta, "    <dc:creator>{}</dc:creator>", dom::escape(a));
    }
    let _ = writeln!(meta, "    <dc:language>{}</dc:language>", dom::escape(&m.language));
    if let Some(isbn) = &m.isbn {
        let _ = writeln!(meta, "    <dc:source>urn:isbn:{isbn}</dc:source>");
    }
    let _ = writeln!(meta, "    <meta property=\"dcterms:modified\">{}</meta>", modified());
    meta.push_str(&cover_meta);

    let opf = format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"id\">\n  <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\n{meta}  </metadata>\n  <manifest>\n{items}  </manifest>\n  <spine>\n{spine}  </spine>\n</package>\n"
    );
    zip.start_file("OEBPS/content.opf", deflated).map_err(z)?;
    zip.write_all(opf.as_bytes())?;
    zip.finish().map_err(z)?;
    Ok(())
}

// ---------------------------------------------------------------------------------------------
// Highlights

/// The section's HTML with each highlight wrapped in `<mark>` (split wherever it crosses an
/// element) and, after a highlight with a thought, a note reference; the thoughts follow the
/// section as footnotes.
fn draw_marks(html: &str, marks: &[&Mark]) -> Vec<Node> {
    let mut root = dom::parse_html(html);
    let body = take_body(&mut root);
    let mut walk = Walk { marks, used: vec![0; marks.len()], counts: Default::default(), ended: vec![false; marks.len()] };
    let mut nodes = body;
    walk.nodes(&mut nodes, None, false);
    // A highlight whose end lies past the last text it could find gets its reference at the end.
    let mut tail = Vec::new();
    for i in 0..marks.len() {
        if walk.used[i] > 0 {
            walk.close(i, &mut tail);
        }
    }
    nodes.extend(tail);
    let mut notes = Element::new("section").with_attr("class", "yy-notes").with_attr("epub:type", "footnotes");
    for (i, m) in marks.iter().enumerate() {
        if let Some(note) = &m.note
            && walk.ended[i]
        {
            let mut aside = Element::new("aside").with_attr("id", format!("yy-n{i}")).with_attr("epub:type", "footnote");
            aside.children.push(Node::Element(Element::new("p").with_text(note.clone())));
            notes.children.push(Node::Element(aside));
        }
    }
    if !notes.children.is_empty() {
        nodes.push(Node::Element(notes));
    }
    nodes
}

/// The children of `<body>`, or the root's when there is none.
fn take_body(root: &mut Element) -> Vec<Node> {
    fn find(e: &mut Element) -> Option<&mut Element> {
        if e.is("body") {
            return Some(e);
        }
        e.children.iter_mut().find_map(|c| match c {
            Node::Element(c) => find(c),
            Node::Text(_) => None,
        })
    }
    match find(root) {
        Some(b) => std::mem::take(&mut b.children),
        None => std::mem::take(&mut root.children),
    }
}

struct Walk<'a> {
    marks: &'a [&'a Mark],
    /// For each mark, whether some of it has been drawn.
    used: Vec<u32>,
    /// UTF-16 units of each sentence seen so far.
    counts: std::collections::HashMap<u32, u32>,
    /// Marks whose end has been reached, so their note reference has been placed.
    ended: Vec<bool>,
}

impl Walk<'_> {
    fn nodes(&mut self, nodes: &mut Vec<Node>, sentence: Option<u32>, skipped: bool) {
        let mut out = Vec::with_capacity(nodes.len());
        for node in std::mem::take(nodes) {
            match node {
                Node::Element(mut e) => {
                    let s = if e.is("span") && has_class(&e, "s") { e.attr("data-s").and_then(|v| v.parse().ok()).or(sentence) } else { sentence };
                    let skip = skipped || e.is("rt") || e.is("rp") || has_class(&e, "yy-noteref");
                    self.nodes(&mut e.children, s, skip);
                    out.push(Node::Element(e));
                }
                Node::Text(t) => match sentence {
                    Some(s) if !skipped => self.text(t, s, &mut out),
                    _ => out.push(Node::Text(t)),
                },
            }
        }
        *nodes = out;
    }

    /// Splits one text node of sentence `s` at the highlights' edges.
    fn text(&mut self, t: String, s: u32, out: &mut Vec<Node>) {
        let units: Vec<u16> = t.encode_utf16().collect();
        let start = *self.counts.get(&s).unwrap_or(&0);
        let end = start + units.len() as u32;
        self.counts.insert(s, end);
        // Cut points inside this node, and which marks cover each piece.
        let mut cuts = vec![start, end];
        for m in self.marks {
            for p in [m.start, m.end] {
                if p.sentence == s && p.offset > start && p.offset < end {
                    cuts.push(p.offset);
                }
            }
        }
        cuts.sort_unstable();
        cuts.dedup();
        for w in cuts.windows(2) {
            let (a, b) = (w[0], w[1]);
            let piece = String::from_utf16_lossy(&units[(a - start) as usize..(b - start) as usize]);
            let at = TextPoint { sentence: s, offset: a };
            let to = TextPoint { sentence: s, offset: b };
            let covering = self.marks.iter().position(|m| m.start <= at && to <= m.end);
            match covering {
                Some(i) => {
                    self.used[i] += 1;
                    let mark = Element::new("mark").with_attr("class", format!("yy-mark yy-{}", style_name(self.marks[i].style))).with_text(piece);
                    out.push(Node::Element(mark));
                    // The note reference goes after the highlight's last piece.
                    if to == self.marks[i].end {
                        self.close(i, out);
                    }
                }
                None => out.push(Node::Text(piece)),
            }
        }
        // A highlight that ended before this node (its end lay past the sentence's text).
        for i in 0..self.marks.len() {
            let m = self.marks[i];
            if !self.ended[i] && self.used[i] > 0 && (m.end.sentence < s) {
                self.close(i, out);
            }
        }
    }

    fn close(&mut self, i: usize, out: &mut Vec<Node>) {
        if self.ended[i] {
            return;
        }
        self.ended[i] = true;
        if self.marks[i].note.is_some() {
            let a = Element::new("a")
                .with_attr("class", "yy-ref")
                .with_attr("epub:type", "noteref")
                .with_attr("href", format!("#yy-n{i}"))
                .with_text("✎");
            out.push(Node::Element(a));
        }
    }
}

fn has_class(e: &Element, class: &str) -> bool {
    e.attr("class").is_some_and(|c| c.split_ascii_whitespace().any(|x| x == class))
}

fn style_name(s: MarkStyle) -> &'static str {
    match s {
        MarkStyle::Yellow => "yellow",
        MarkStyle::Blue => "blue",
        MarkStyle::Pink => "pink",
        MarkStyle::Wave => "wave",
        MarkStyle::Underline => "underline",
        MarkStyle::Dotted => "dotted",
    }
}

// ---------------------------------------------------------------------------------------------
// XHTML

const VOID: &[&str] = &["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"];

/// Section content as well-formed XHTML: void elements closed, no named entities.
#[cfg(test)]
fn to_xhtml(src: &str) -> String {
    let mut root = dom::parse_html(src);
    let nodes = take_body(&mut root);
    nodes_xhtml(&nodes)
}

fn nodes_xhtml(nodes: &[Node]) -> String {
    let mut out = String::new();
    for n in nodes {
        node_xhtml(n, &mut out);
    }
    out
}

fn node_xhtml(node: &Node, out: &mut String) {
    match node {
        Node::Text(t) => escape_xml(t, out),
        Node::Element(e) => {
            out.push('<');
            out.push_str(&e.name);
            if e.ns == Ns::Svg && e.attr("xmlns").is_none() {
                out.push_str(r#" xmlns="http://www.w3.org/2000/svg""#);
            }
            for (k, v) in &e.attrs {
                // Only attributes XML accepts and EPUB checkers don't trip over.
                if k.is_empty() || k.contains(|c: char| !(c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == ':')) {
                    continue;
                }
                out.push(' ');
                out.push_str(k);
                out.push_str("=\"");
                escape_xml(v, out);
                out.push('"');
            }
            if e.children.is_empty() && (VOID.contains(&e.name.as_str()) || e.ns != Ns::Html) {
                out.push_str("/>");
                return;
            }
            out.push('>');
            for c in &e.children {
                node_xhtml(c, out);
            }
            out.push_str("</");
            out.push_str(&e.name);
            out.push('>');
        }
    }
}

fn escape_xml(s: &str, out: &mut String) {
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\u{a0}' => out.push_str("&#160;"),
            c if (c as u32) < 0x20 && c != '\n' && c != '\t' && c != '\r' => {}
            _ => out.push(c),
        }
    }
}

fn nav(m: &Manifest) -> String {
    let mut x = String::new();
    let _ = write!(
        x,
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE html>\n<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\" lang=\"{0}\" xml:lang=\"{0}\">\n<head><meta charset=\"UTF-8\"/><title>{1}</title></head>\n<body>\n<nav epub:type=\"toc\" id=\"toc\">\n<h1>{1}</h1>\n",
        dom::escape(&m.language),
        dom::escape(&m.title),
    );
    // Nested lists by depth; a list item may hold one nested list.
    let entries: Vec<(u16, String, String)> = if m.toc.is_empty() {
        m.sections
            .iter()
            .enumerate()
            .filter(|(_, s)| s.linear)
            .map(|(n, s)| (0, s.title.clone().unwrap_or_else(|| format!("{}", n + 1)), format!("s/{n}.xhtml")))
            .collect()
    } else {
        m.toc
            .iter()
            .map(|t| (t.depth, t.title.clone(), format!("s/{}.xhtml{}", t.section, t.anchor.as_deref().map(|a| format!("#{a}")).unwrap_or_default())))
            .collect()
    };
    let base = entries.iter().map(|e| e.0).min().unwrap_or(0);
    let mut depth = 0usize;
    x.push_str("<ol>\n");
    for (i, (d, title, href)) in entries.iter().enumerate() {
        let d = (*d - base) as usize;
        // Never deeper than one level past the previous entry.
        let d = d.min(depth + if i == 0 { 0 } else { 1 });
        if i > 0 {
            if d > depth {
                x.push_str("\n<ol>\n");
            } else {
                x.push_str("</li>\n");
                for _ in d..depth {
                    x.push_str("</ol>\n</li>\n");
                }
            }
        }
        depth = d;
        let _ = write!(x, "<li><a href=\"{}\">{}</a>", dom::escape(href), dom::escape(title));
    }
    if !entries.is_empty() {
        x.push_str("</li>\n");
        for _ in 0..depth {
            x.push_str("</ol>\n</li>\n");
        }
    }
    x.push_str("</ol>\n</nav>\n</body>\n</html>\n");
    x
}

fn walk(dir: &Path, out: &mut Vec<std::path::PathBuf>) -> Result<()> {
    let mut entries: Vec<_> = fs::read_dir(dir)?.filter_map(|e| e.ok()).map(|e| e.path()).collect();
    entries.sort();
    for p in entries {
        if p.is_dir() {
            walk(&p, out)?;
        } else {
            out.push(p);
        }
    }
    Ok(())
}

fn media_type(path: &str) -> Option<&'static str> {
    let ext = path.rsplit('.').next()?.to_ascii_lowercase();
    Some(match ext.as_str() {
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "svg" => "image/svg+xml",
        "css" => "text/css",
        "ttf" => "font/ttf",
        "otf" => "font/otf",
        "woff" => "font/woff",
        "woff2" => "font/woff2",
        "mp3" => "audio/mpeg",
        "m4a" | "mp4" => "audio/mp4",
        _ => return None,
    })
}

/// Now, as EPUB wants it: 2026-10-20T08:00:00Z.
fn modified() -> String {
    let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
    let (days, rem) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    // Civil date from days since 1970 (Howard Hinnant's algorithm).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let mo = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(mo <= 2);
    format!("{y:04}-{mo:02}-{d:02}T{:02}:{:02}:{:02}Z", rem / 3600, rem % 3600 / 60, rem % 60)
}

const CONTAINER: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"#;

/// The 划线 colours as 语阅 draws them, and the thoughts at the end of a section.
const CSS: &str = "mark.yy-mark { color: inherit; background: none; }
mark.yy-yellow { background: rgba(240, 200, 80, 0.38); }
mark.yy-blue { background: rgba(110, 160, 230, 0.30); }
mark.yy-pink { background: rgba(240, 160, 150, 0.38); }
mark.yy-wave { text-decoration: underline wavy #c0504d; text-underline-offset: 0.2em; }
mark.yy-underline { text-decoration: underline #c0504d; text-underline-offset: 0.2em; }
mark.yy-dotted { text-decoration: underline dotted #c0504d; text-underline-offset: 0.2em; }
a.yy-ref { font-size: 0.75em; vertical-align: super; text-decoration: none; }
section.yy-notes { margin-top: 2em; border-top: 1px solid #ccc; font-size: 0.9em; }
";

#[cfg(test)]
mod tests {
    use super::*;

    fn mark(s: u32, a: u32, e: u32, b: u32, note: Option<&str>) -> Mark {
        Mark {
            id: format!("{s}-{a}"),
            section: 0,
            start: TextPoint { sentence: s, offset: a },
            end: TextPoint { sentence: e, offset: b },
            text: String::new(),
            style: MarkStyle::Yellow,
            note: note.map(str::to_string),
            at: 0,
            heard: false,
        }
    }

    #[test]
    fn highlights_split_at_elements_and_notes_follow() {
        let html = r#"<p><span class="s" data-s="0">我与<em>父亲</em>不相见</span><span class="s" data-s="1">已二年余了。</span></p>"#;
        let m = mark(0, 1, 1, 2, Some("想起来了"));
        let out = nodes_xhtml(&draw_marks(html, &[&m]));
        assert!(out.contains(r#"<span class="s" data-s="0">我<mark class="yy-mark yy-yellow">与</mark><em><mark class="yy-mark yy-yellow">父亲</mark></em><mark class="yy-mark yy-yellow">不相见</mark></span>"#), "{out}");
        assert!(out.contains(r##"<span class="s" data-s="1"><mark class="yy-mark yy-yellow">已二</mark><a class="yy-ref" epub:type="noteref" href="#yy-n0">✎</a>年余了。</span>"##), "{out}");
        assert!(out.contains(r#"<aside id="yy-n0" epub:type="footnote"><p>想起来了</p></aside>"#), "{out}");
    }

    #[test]
    fn ruby_readings_take_no_offsets() {
        let html = r#"<p><span class="s" data-s="0"><ruby>背<rt>bèi</rt></ruby>影是散文。</span></p>"#;
        let m = mark(0, 1, 0, 2, None);
        let out = nodes_xhtml(&draw_marks(html, &[&m]));
        assert!(out.contains(r#"<rt>bèi</rt></ruby><mark class="yy-mark yy-yellow">影</mark>是散文"#), "{out}");
    }

    #[test]
    fn xhtml_closes_void_elements_and_drops_named_entities() {
        let out = to_xhtml("<p>a&nbsp;b<br><img src=\"../r/x.png\" alt=\"点\"></p>");
        assert_eq!(out, r#"<p>a&#160;b<br/><img src="../r/x.png" alt="点"/></p>"#);
    }

    #[test]
    fn exports_a_book_that_parses_back() {
        let dir = std::env::temp_dir().join(format!("yuyue-export-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let core = YuyueCore::open(dir.to_string_lossy().into(), "Mac".into(), "macos".into()).unwrap();
        let fixture = format!("{}/../../fixtures/books/beiying.epub", env!("CARGO_MANIFEST_DIR"));
        let b = core.import_book(fixture).unwrap();
        let p = |s, o| TextPoint { sentence: s, offset: o };
        let first = (0..10).find(|&n| core.sentences(b.id.clone(), n).is_ok_and(|s| !s.is_empty())).unwrap();
        core.add_mark(b.id.clone(), first, p(0, 0), p(0, 2), "我与".into(), MarkStyle::Blue, Some("开头".into())).unwrap();
        let out = dir.join("out.epub");
        core.export_epub(b.id.clone(), true, out.to_string_lossy().into()).unwrap();
        let again = core.import_book(out.to_string_lossy().into()).unwrap();
        assert_eq!(again.title, b.title);
        let mut zip = zip::ZipArchive::new(File::open(&out).unwrap()).unwrap();
        let mut s = String::new();
        std::io::Read::read_to_string(&mut zip.by_name(&format!("OEBPS/s/{first}.xhtml")).unwrap(), &mut s).unwrap();
        assert!(s.contains("yy-blue") && s.contains("开头"), "{s}");
        dom::parse_xhtml(&s).expect("well-formed XHTML");
        let _ = fs::remove_dir_all(&dir);
    }
}
