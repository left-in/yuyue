//! Turns a section's body into the normalized markup described in docs/dev/reader-contract.md:
//! unsafe markup removed, resource and link URLs rewritten, footnote references marked, line
//! breaks between CJK characters removed, every sentence wrapped in `<span class="s" data-s>`,
//! and adjacent full-width punctuation marked for compression.

use crate::dom::{Element, Node};
use crate::punct::{self, Style};
use crate::segment;
use crate::text::{self, Stats};

/// Where a link in the book points, as decided by the importer.
pub enum Link {
    /// Section index and optional element id.
    Internal(u32, Option<String>),
    External(String),
    Dead,
}

pub struct Context<'a> {
    /// Book or section language; decides punctuation compression.
    pub lang: &'a str,
    /// Maps a resource reference (img src, svg image href) to the URL used in the section
    /// document (`../r/...`), or `None` to drop it.
    pub resource: &'a dyn Fn(&str) -> Option<String>,
    /// Maps an `<a href>` to its target.
    pub link: &'a dyn Fn(&str) -> Link,
}

pub struct Normalized {
    pub content: Vec<Node>,
    /// Text of each sentence (whitespace collapsed), indexed by `data-s`.
    pub sentences: Vec<String>,
    pub stats: Stats,
}

pub fn normalize(mut body: Element, ctx: &Context) -> Normalized {
    sanitize(&mut body, ctx);
    let mut st = WrapState { sentences: Vec::new(), style: punct::style_for(ctx.lang) };
    wrap_container(&mut body, &mut st);
    let mut stats = Stats::default();
    for s in &st.sentences {
        stats.add(Stats::of(s));
    }
    Normalized { content: body.children, sentences: st.sentences, stats }
}

/// Inserts `<div class="yy-meta">` after the first heading near the top of the section.
/// Returns false if there was no heading to put it under.
pub fn insert_meta(content: &mut Vec<Node>, text: &str) -> bool {
    let meta = Node::Element(Element::new("div").with_attr("class", "yy-meta").with_text(text));
    // Only look at the first few top-level blocks: a heading deep inside the chapter isn't
    // the chapter title.
    let mut seen_blocks = 0;
    for i in 0..content.len() {
        let Node::Element(e) = &content[i] else { continue };
        if is_heading(e) {
            content.insert(i + 1, meta);
            return true;
        }
        if let Some(mut path) = e.find_path(&|x| is_heading(x)) {
            // Heading wrapped in a <div class="chapter"> or similar.
            if !has_text_before(e, &path) {
                let last = path.pop().unwrap();
                let Node::Element(e) = &mut content[i] else { unreachable!() };
                let parent = if path.is_empty() { e } else { e.get_mut(&path).unwrap() };
                parent.children.insert(last + 1, meta);
                return true;
            }
        }
        if !e.text_content().trim().is_empty() {
            seen_blocks += 1;
            if seen_blocks >= 3 {
                break;
            }
        }
    }
    false
}

fn is_heading(e: &Element) -> bool {
    matches!(e.name.as_str(), "h1" | "h2" | "h3" | "h4" | "h5" | "h6") || e.has_class("yy-title")
}

fn has_text_before(root: &Element, path: &[usize]) -> bool {
    let mut cur = root;
    for &i in path {
        for c in &cur.children[..i] {
            let t = match c {
                Node::Text(t) => t.clone(),
                Node::Element(e) => e.text_content(),
            };
            if !t.trim().is_empty() {
                return true;
            }
        }
        match &cur.children[i] {
            Node::Element(e) => cur = e,
            Node::Text(_) => break,
        }
    }
    false
}

// ---------------------------------------------------------------------------------------------
// Sanitizing and rewriting

const DROP: &[&str] = &[
    "script", "noscript", "iframe", "frame", "frameset", "object", "embed", "applet", "template",
    "link", "meta", "base", "style", "title", "head", "input", "button", "select", "textarea",
    "audio", "video", "canvas", "dialog", "portal",
];

const UNWRAP: &[&str] = &["form", "font", "body", "html", "basefont"];

/// Inline style properties we keep from the book; everything else (sizes, colours, fonts,
/// positions) would fight the reader's layout and paper themes.
const KEEP_STYLE: &[&str] = &[
    "text-align", "font-style", "font-weight", "font-variant", "text-decoration", "vertical-align",
    "text-transform", "white-space",
];

fn sanitize(el: &mut Element, ctx: &Context) {
    let children = std::mem::take(&mut el.children);
    for child in children {
        match child {
            Node::Text(t) => el.children.push(Node::Text(t)),
            Node::Element(mut e) => {
                let is_html = e.ns == crate::dom::Ns::Html;
                if is_html && DROP.contains(&e.name.as_str()) {
                    continue;
                }
                if e.ns == crate::dom::Ns::Svg && matches!(e.name.as_str(), "script" | "foreignObject") {
                    continue;
                }
                sanitize(&mut e, ctx);
                if is_html && UNWRAP.contains(&e.name.as_str()) {
                    el.children.append(&mut e.children);
                    continue;
                }
                if is_html && e.name == "center" {
                    e.name = "div".into();
                    e.set_attr("style", "text-align: center");
                }
                clean_attrs(&mut e, ctx);
                el.children.push(Node::Element(e));
            }
        }
    }
}

fn clean_attrs(e: &mut Element, ctx: &Context) {
    let attrs = std::mem::take(&mut e.attrs);
    for (k, v) in attrs {
        let lower = k.to_ascii_lowercase();
        if lower.starts_with("on") || lower.starts_with("xmlns") || lower == "srcset" || lower == "contenteditable" {
            continue;
        }
        match lower.as_str() {
            "xml:lang" => {
                if e.attr("lang").is_none() {
                    e.attrs.push(("lang".into(), v));
                }
            }
            "style" => {
                if let Some(style) = filter_style(&v) {
                    e.attrs.push(("style".into(), style));
                }
            }
            "name" if e.is("a") => {
                if e.attr("id").is_none() {
                    e.attrs.push(("id".into(), v));
                }
            }
            _ => e.attrs.push((k, v)),
        }
    }

    // Resources.
    let is_img = e.is("img") || e.is("source");
    if is_img {
        rewrite_resource(e, "src", ctx);
    }
    if e.ns == crate::dom::Ns::Svg && e.name == "image" {
        rewrite_resource(e, "xlink:href", ctx);
        rewrite_resource(e, "href", ctx);
    }
    if e.is("a") {
        rewrite_link(e, ctx);
    }
    if e.is("aside") && (e.has_epub_type("footnote") || e.has_epub_type("endnote") || e.has_epub_type("rearnote")) {
        e.add_class("yy-footnote");
    }
}

fn filter_style(style: &str) -> Option<String> {
    if style.contains("url(") || style.contains("expression") {
        return None;
    }
    let kept: Vec<String> = style
        .split(';')
        .filter_map(|decl| {
            let (prop, value) = decl.split_once(':')?;
            let prop = prop.trim().to_ascii_lowercase();
            KEEP_STYLE.contains(&prop.as_str()).then(|| format!("{}: {}", prop, value.trim()))
        })
        .collect();
    (!kept.is_empty()).then(|| kept.join("; "))
}

fn rewrite_resource(e: &mut Element, attr: &str, ctx: &Context) {
    let Some(v) = e.attr(attr).map(str::to_string) else { return };
    if v.starts_with("data:") {
        return;
    }
    match (ctx.resource)(&v) {
        Some(url) => e.set_attr(attr, url),
        None => {
            e.remove_attr(attr);
        }
    }
}

fn rewrite_link(e: &mut Element, ctx: &Context) {
    let Some(href) = e.remove_attr("href") else { return };
    let noteref = e.has_epub_type("noteref")
        || e.has_class("fnanchor")
        || e.has_class("noteref")
        || e.has_class("footnote-ref");
    match (ctx.link)(&href) {
        Link::Internal(section, anchor) => {
            let target = match anchor {
                Some(a) => format!("{section}#{a}"),
                None => section.to_string(),
            };
            e.set_attr("href", "#");
            e.set_attr("data-yy-target", target);
            if noteref || looks_like_noteref(e) {
                e.add_class("yy-noteref");
            }
        }
        Link::External(url) => {
            e.set_attr("href", "#");
            e.set_attr("data-yy-external", url);
        }
        Link::Dead => {}
    }
}

/// `<a>1</a>`, `<a>[12]</a>`, `<a>*</a>`, `<a>注3</a>`: short markers that point inside the book.
fn looks_like_noteref(e: &Element) -> bool {
    let t = e.text_content();
    let t = t.trim().trim_matches(|c| matches!(c, '[' | ']' | '(' | ')' | '（' | '）' | '〔' | '〕'));
    if t.is_empty() || t.chars().count() > 4 {
        return false;
    }
    let t = t.trim_start_matches('注');
    !t.is_empty() && t.chars().all(|c| c.is_ascii_digit() || c == '*' || c == '†' || c == '‡' || ('①'..='⑳').contains(&c))
}

// ---------------------------------------------------------------------------------------------
// Sentence wrapping

struct WrapState {
    sentences: Vec<String>,
    style: Option<Style>,
}

const BLOCKS: &[&str] = &[
    "address", "article", "aside", "blockquote", "body", "dd", "details", "div", "dl", "dt",
    "fieldset", "figcaption", "figure", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header",
    "hgroup", "hr", "li", "main", "nav", "ol", "p", "pre", "section", "table", "tbody", "thead",
    "tfoot", "tr", "td", "th", "caption", "ul", "summary", "colgroup", "col", "center", "menu",
];

fn is_block(e: &Element) -> bool {
    e.ns == crate::dom::Ns::Html && BLOCKS.contains(&e.name.as_str())
}

/// Subtrees that hold no sentence text: ruby annotations, note markers, non-text content.
fn is_excluded(e: &Element) -> bool {
    matches!(e.name.as_str(), "rt" | "rp" | "img" | "svg" | "math" | "picture")
        || e.has_class("yy-noteref")
        || e.has_class("yy-meta")
        || e.has_class("yy-footnote")
}

fn contains_block(e: &Element) -> bool {
    e.child_elements().any(|c| is_block(c) || contains_block(c))
}

fn is_blockish(n: &Node) -> bool {
    match n {
        Node::Element(e) => is_block(e) || (!is_excluded(e) && contains_block(e)),
        Node::Text(_) => false,
    }
}

fn wrap_container(el: &mut Element, st: &mut WrapState) {
    if is_excluded(el) || el.is("nav") {
        return;
    }
    let children = std::mem::take(&mut el.children);
    let mut out = Vec::with_capacity(children.len());
    let mut run: Vec<Node> = Vec::new();
    for mut child in children {
        if is_blockish(&child) {
            flush_run(&mut run, &mut out, st);
            if let Node::Element(e) = &mut child {
                wrap_container(e, st);
            }
            out.push(child);
        } else {
            run.push(child);
        }
    }
    flush_run(&mut run, &mut out, st);
    el.children = out;
}

/// One piece of a run's text, in document order: a text node or a `<br>`.
enum Piece {
    Text(String),
    Break,
}

fn collect(nodes: &[Node], out: &mut Vec<Piece>) {
    for n in nodes {
        match n {
            Node::Text(t) => out.push(Piece::Text(t.clone())),
            Node::Element(e) if e.is("br") => out.push(Piece::Break),
            Node::Element(e) if is_excluded(e) => {}
            Node::Element(e) => collect(&e.children, out),
        }
    }
}

struct Plan {
    /// Cleaned text of each piece (`"\n"` for breaks).
    pieces: Vec<String>,
    /// Sentence byte ranges in the run text and their global index.
    sentences: Vec<(usize, usize, usize)>,
    /// Byte offsets (in the run text) of characters to compress, with their class.
    marks: Vec<(usize, &'static str)>,
}

fn flush_run(run: &mut Vec<Node>, out: &mut Vec<Node>, st: &mut WrapState) {
    if run.is_empty() {
        return;
    }
    let nodes = std::mem::take(run);
    let mut raw = Vec::new();
    collect(&nodes, &mut raw);

    // Clean each text piece knowing its neighbours, so line breaks at element boundaries
    // between CJK characters vanish too.
    let raw_text: Vec<&str> = raw.iter().map(|p| match p { Piece::Text(t) => t.as_str(), Piece::Break => "\n" }).collect();
    let mut pieces = Vec::with_capacity(raw.len());
    for (i, p) in raw.iter().enumerate() {
        match p {
            Piece::Break => pieces.push("\n".to_string()),
            Piece::Text(t) => {
                let before = pieces.iter().rev().find_map(|s: &String| s.chars().last());
                let after = raw_text[i + 1..].iter().find_map(|s| s.chars().next());
                pieces.push(text::clean(t, before, after));
            }
        }
    }
    let run_text: String = pieces.concat();
    if !run_text.chars().any(text::is_speakable) {
        // Nothing to wrap, but keep the cleaned text.
        let plan = Plan { pieces, sentences: Vec::new(), marks: Vec::new() };
        out.extend(rebuild(nodes, &mut 0, &mut 0, &plan));
        return;
    }

    let mut sentences = Vec::new();
    for (s, e) in segment::sentences(&run_text) {
        sentences.push((s, e, st.sentences.len()));
        st.sentences.push(text::collapse_ws(&run_text[s..e]));
    }
    let marks = match st.style {
        Some(style) => punct::marks(&run_text, style).into_iter().map(|(i, m)| (i, m.class())).collect(),
        None => Vec::new(),
    };
    let plan = Plan { pieces, sentences, marks };
    out.extend(rebuild(nodes, &mut 0, &mut 0, &plan));
}

/// Rebuilds the run's nodes, replacing each text node with its cleaned text split into sentence
/// spans. `idx` walks the pieces, `offset` the run text, in the same order `collect` used.
fn rebuild(nodes: Vec<Node>, idx: &mut usize, offset: &mut usize, plan: &Plan) -> Vec<Node> {
    let mut out = Vec::with_capacity(nodes.len());
    for n in nodes {
        match n {
            Node::Text(_) => {
                let t = &plan.pieces[*idx];
                *idx += 1;
                let start = *offset;
                *offset += t.len();
                render_text(t, start, plan, &mut out);
            }
            Node::Element(e) if e.is("br") => {
                *idx += 1;
                *offset += 1;
                out.push(Node::Element(e));
            }
            Node::Element(e) if is_excluded(&e) => out.push(Node::Element(e)),
            Node::Element(mut e) => {
                e.children = rebuild(std::mem::take(&mut e.children), idx, offset, plan);
                out.push(Node::Element(e));
            }
        }
    }
    out
}

/// Emits `t` (which starts at `start` in the run text) as plain text and sentence spans.
fn render_text(t: &str, start: usize, plan: &Plan, out: &mut Vec<Node>) {
    if t.is_empty() {
        return;
    }
    let end = start + t.len();
    let mut pos = start;
    for &(s, e, k) in &plan.sentences {
        if e <= pos || s >= end {
            continue;
        }
        let (a, b) = (s.max(pos), e.min(end));
        if a > pos {
            out.push(Node::Text(t[pos - start..a - start].to_string()));
        }
        let mut span = Element::new("span").with_attr("class", "s").with_attr("data-s", k.to_string());
        render_marks(&t[a - start..b - start], a, plan, &mut span.children);
        out.push(Node::Element(span));
        pos = b;
    }
    if pos < end {
        render_marks(&t[pos - start..], pos, plan, out);
    }
}

/// Emits text with compression spans around the marked characters.
fn render_marks(t: &str, start: usize, plan: &Plan, out: &mut Vec<Node>) {
    let end = start + t.len();
    let mut pos = start;
    for &(i, class) in &plan.marks {
        if i < start || i >= end {
            continue;
        }
        let c = t[i - start..].chars().next().unwrap();
        if i > pos {
            out.push(Node::Text(t[pos - start..i - start].to_string()));
        }
        out.push(Node::Element(Element::new("span").with_attr("class", class).with_text(c.to_string())));
        pos = i + c.len_utf8();
    }
    if pos < end {
        out.push(Node::Text(t[pos - start..].to_string()));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dom::{parse_markup, to_html};

    fn run(body: &str, lang: &str) -> Normalized {
        let root = parse_markup(&format!(
            r#"<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>{body}</body></html>"#
        ));
        let body = root.first_child("body").unwrap().clone();
        let resource = |src: &str| Some(format!("../r/OEBPS/{}", src.trim_start_matches("../")));
        let link = |href: &str| {
            if href.starts_with("http") {
                Link::External(href.to_string())
            } else if let Some(a) = href.strip_prefix('#') {
                Link::Internal(0, Some(a.to_string()))
            } else {
                Link::Internal(1, None)
            }
        };
        normalize(body, &Context { lang, resource: &resource, link: &link })
    }

    #[test]
    fn wraps_sentences_and_compresses() {
        let n = run("<p>他说：“我买几个橘子去。你就在此地，不要走动。”我看那边。</p>", "zh-CN");
        assert_eq!(n.sentences, vec!["他说：“我买几个橘子去。", "你就在此地，不要走动。”", "我看那边。"]);
        assert_eq!(
            to_html(&n.content),
            r#"<p><span class="s" data-s="0">他说<span class="pz-r">：</span>“我买几个橘子去。</span><span class="s" data-s="1">你就在此地，不要走动<span class="pz-r">。</span>”</span><span class="s" data-s="2">我看那边。</span></p>"#
        );
    }

    #[test]
    fn sentence_crossing_inline_markup() {
        let n = run("<p>前半句<em>强调的部分。后面</em>接着说完。</p>", "zh-CN");
        assert_eq!(n.sentences, vec!["前半句强调的部分。", "后面接着说完。"]);
        assert_eq!(
            to_html(&n.content),
            r#"<p><span class="s" data-s="0">前半句</span><em><span class="s" data-s="0">强调的部分。</span><span class="s" data-s="1">后面</span></em><span class="s" data-s="1">接着说完。</span></p>"#
        );
    }

    #[test]
    fn ruby_and_noterefs_are_not_spoken() {
        let n = run(
            r##"<p><ruby>背<rp>(</rp><rt>bèi</rt><rp>)</rp></ruby>影是散文。注释<a epub:type="noteref" href="#fn1">1</a>在这里。</p>"##,
            "zh-CN",
        );
        assert_eq!(n.sentences, vec!["背影是散文。", "注释在这里。"]);
        let html = to_html(&n.content);
        assert!(html.contains(r#"<rt>bèi</rt>"#), "{html}");
        assert!(html.contains(r##"<a epub:type="noteref" href="#" data-yy-target="0#fn1" class="yy-noteref">1</a>"##), "{html}");
    }

    #[test]
    fn line_breaks_and_invisible_characters() {
        let n = run("<p>我们过了江，\n进了车站。我买票，\u{200B}他忙着照看行李。\u{FEFF}</p>", "zh-CN");
        assert_eq!(n.sentences, vec!["我们过了江，进了车站。", "我买票，他忙着照看行李。"]);
        assert!(!to_html(&n.content).contains('\n'));
    }

    #[test]
    fn sanitizes_markup() {
        let n = run(
            r#"<p onclick="alert(1)" style="color: red; text-align: center">点我。</p><script>alert(1)</script><iframe src="x"></iframe>"#,
            "zh-CN",
        );
        assert_eq!(
            to_html(&n.content),
            r#"<p style="text-align: center"><span class="s" data-s="0">点我。</span></p>"#
        );
    }

    #[test]
    fn links_and_images() {
        let n = run(
            r#"<p><a href="ch2.xhtml#part2">跳过去</a>，或者看<a href="https://example.com/">外部</a>。<img src="../images/dot.png" alt="点"/></p>"#,
            "zh-CN",
        );
        let html = to_html(&n.content);
        assert!(html.contains(r##"<a href="#" data-yy-target="1">"##), "{html}");
        assert!(html.contains(r##"<a href="#" data-yy-external="https://example.com/">"##), "{html}");
        assert!(html.contains(r#"<img src="../r/OEBPS/images/dot.png" alt="点">"#), "{html}");
        assert_eq!(n.sentences, vec!["跳过去，或者看外部。"]);
    }

    #[test]
    fn english_has_no_compression_and_keeps_spaces() {
        let n = run("<p>“Is he married?” she asked.\n“Oh! single, my dear.”</p>", "en");
        assert_eq!(n.sentences, vec!["“Is he married?” she asked.", "“Oh! single, my dear.”"]);
        let html = to_html(&n.content);
        assert!(!html.contains("pz-"));
        assert!(html.contains("asked.</span> <span"), "{html}");
    }

    #[test]
    fn nested_blocks_and_footnotes() {
        let n = run(
            r#"<div class="chapter"><h2>第一章</h2><blockquote><p>引文。</p></blockquote>正文直接在 div 里。</div><aside epub:type="footnote" id="fn1"><p>注释的内容。</p></aside>"#,
            "zh-CN",
        );
        assert_eq!(n.sentences, vec!["第一章", "引文。", "正文直接在 div 里。"]);
        assert!(to_html(&n.content).contains(r#"<aside epub:type="footnote" id="fn1" class="yy-footnote"><p>注释的内容。</p></aside>"#));
    }

    #[test]
    fn meta_goes_under_the_first_heading() {
        let mut n = run(r#"<div class="chapter"><h2>第一章</h2><p>正文。</p></div>"#, "zh-CN");
        assert!(insert_meta(&mut n.content, "读 1 分钟 · 听 1 分钟"));
        assert!(to_html(&n.content).contains(r#"第一章</span></h2><div class="yy-meta">读 1 分钟 · 听 1 分钟</div><p>"#));
        let mut n = run(r#"<p>没有标题。</p><p>第二段。</p><p>第三段。</p><h2>很后面</h2>"#, "zh-CN");
        assert!(!insert_meta(&mut n.content, "x"));
    }

    #[test]
    fn breaks_split_poetry_lines() {
        let n = run("<p>床前明月光<br/>疑是地上霜</p>", "zh-CN");
        assert_eq!(n.sentences, vec!["床前明月光", "疑是地上霜"]);
        assert_eq!(
            to_html(&n.content),
            r#"<p><span class="s" data-s="0">床前明月光</span><br><span class="s" data-s="1">疑是地上霜</span></p>"#
        );
    }
}
