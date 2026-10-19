//! A small owned DOM: enough to restructure book content and serialize it as HTML.
//!
//! Book files are XHTML, so they're parsed as XML first (roxmltree). XML parsers reject the HTML
//! named entities (`&nbsp;`) that EPUBs use all the time, so those are rewritten to numeric
//! references beforehand. Files that still aren't well-formed fall back to the HTML5 parser.

use std::fmt::Write as _;

use html5ever::tendril::TendrilSink;
use markup5ever_rcdom::{Handle, NodeData, RcDom};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Ns {
    Html,
    Svg,
    MathMl,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Node {
    Element(Element),
    Text(String),
}

#[derive(Clone, Debug, PartialEq)]
pub struct Element {
    /// Local name; lowercase for HTML, original case for SVG/MathML (`foreignObject`).
    pub name: String,
    pub ns: Ns,
    /// Prefixed names are kept as written: `epub:type`, `xlink:href`.
    pub attrs: Vec<(String, String)>,
    pub children: Vec<Node>,
}

impl Element {
    pub fn new(name: &str) -> Self {
        Element { name: name.to_string(), ns: Ns::Html, attrs: Vec::new(), children: Vec::new() }
    }

    pub fn with_attr(mut self, name: &str, value: impl Into<String>) -> Self {
        self.set_attr(name, value);
        self
    }

    pub fn with_text(mut self, text: impl Into<String>) -> Self {
        self.children.push(Node::Text(text.into()));
        self
    }

    pub fn with_child(mut self, child: Element) -> Self {
        self.children.push(Node::Element(child));
        self
    }

    pub fn is(&self, name: &str) -> bool {
        self.ns == Ns::Html && self.name == name
    }

    pub fn attr(&self, name: &str) -> Option<&str> {
        self.attrs.iter().find(|(k, _)| k == name).map(|(_, v)| v.as_str())
    }

    pub fn set_attr(&mut self, name: &str, value: impl Into<String>) {
        let value = value.into();
        match self.attrs.iter_mut().find(|(k, _)| k == name) {
            Some(slot) => slot.1 = value,
            None => self.attrs.push((name.to_string(), value)),
        }
    }

    pub fn remove_attr(&mut self, name: &str) -> Option<String> {
        let i = self.attrs.iter().position(|(k, _)| k == name)?;
        Some(self.attrs.remove(i).1)
    }

    pub fn has_class(&self, class: &str) -> bool {
        self.attr("class").is_some_and(|c| c.split_ascii_whitespace().any(|x| x == class))
    }

    pub fn add_class(&mut self, class: &str) {
        if self.has_class(class) {
            return;
        }
        let value = match self.attr("class") {
            Some(c) if !c.trim().is_empty() => format!("{} {}", c.trim(), class),
            _ => class.to_string(),
        };
        self.set_attr("class", value);
    }

    /// `epub:type` (or its HTML spelling) contains `word`.
    pub fn has_epub_type(&self, word: &str) -> bool {
        let matches = |v: &str| v.split_ascii_whitespace().any(|x| x == word);
        self.attr("epub:type").is_some_and(matches)
            || self.attr("role").is_some_and(|r| matches(r.trim_start_matches("doc-")))
    }

    pub fn shallow_clone(&self) -> Element {
        Element { name: self.name.clone(), ns: self.ns, attrs: self.attrs.clone(), children: Vec::new() }
    }

    pub fn text_content(&self) -> String {
        let mut out = String::new();
        collect_text(&self.children, &mut out);
        out
    }

    /// Depth-first search; returns the child-index path to the first matching descendant.
    pub fn find_path(&self, pred: &dyn Fn(&Element) -> bool) -> Option<Vec<usize>> {
        for (i, child) in self.children.iter().enumerate() {
            if let Node::Element(e) = child {
                if pred(e) {
                    return Some(vec![i]);
                }
                if let Some(mut rest) = e.find_path(pred) {
                    rest.insert(0, i);
                    return Some(rest);
                }
            }
        }
        None
    }

    pub fn find(&self, pred: &dyn Fn(&Element) -> bool) -> Option<&Element> {
        for child in &self.children {
            if let Node::Element(e) = child {
                if pred(e) {
                    return Some(e);
                }
                if let Some(found) = e.find(pred) {
                    return Some(found);
                }
            }
        }
        None
    }

    pub fn find_all<'a>(&'a self, pred: &dyn Fn(&Element) -> bool, out: &mut Vec<&'a Element>) {
        for child in &self.children {
            if let Node::Element(e) = child {
                if pred(e) {
                    out.push(e);
                }
                e.find_all(pred, out);
            }
        }
    }

    pub fn child_elements(&self) -> impl Iterator<Item = &Element> {
        self.children.iter().filter_map(|c| match c {
            Node::Element(e) => Some(e),
            Node::Text(_) => None,
        })
    }

    pub fn first_child(&self, name: &str) -> Option<&Element> {
        self.child_elements().find(|e| e.name == name)
    }

    /// Calls `f` on every element id in the subtree.
    pub fn visit_ids(&self, f: &mut dyn FnMut(&str)) {
        if let Some(id) = self.attr("id") {
            f(id);
        }
        for e in self.child_elements() {
            e.visit_ids(f);
        }
    }

    pub fn get(&self, path: &[usize]) -> Option<&Element> {
        let mut cur = self;
        for &i in path {
            cur = cur.children.get(i)?.as_element()?;
        }
        Some(cur)
    }

    pub fn get_mut(&mut self, path: &[usize]) -> Option<&mut Element> {
        let mut cur = self;
        for &i in path {
            cur = match cur.children.get_mut(i)? {
                Node::Element(e) => e,
                Node::Text(_) => return None,
            };
        }
        Some(cur)
    }
}

fn collect_text(nodes: &[Node], out: &mut String) {
    for n in nodes {
        match n {
            Node::Text(t) => out.push_str(t),
            Node::Element(e) => collect_text(&e.children, out),
        }
    }
}

impl Node {
    pub fn as_element(&self) -> Option<&Element> {
        match self {
            Node::Element(e) => Some(e),
            Node::Text(_) => None,
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Parsing

/// Parses a book file: XML first, HTML5 as a fallback. Returns the `<html>` element.
pub fn parse_markup(src: &str) -> Element {
    match parse_xhtml(src) {
        Ok(root) => root,
        Err(_) => parse_html(src),
    }
}

pub fn parse_xhtml(src: &str) -> Result<Element, String> {
    let fixed = fix_entities(src);
    let opts = roxmltree::ParsingOptions { allow_dtd: true, nodes_limit: u32::MAX, ..Default::default() };
    let doc = roxmltree::Document::parse_with_options(&fixed, opts).map_err(|e| e.to_string())?;
    let root = doc.root_element();
    match convert_xml(root) {
        Some(Node::Element(e)) => Ok(e),
        _ => Err("no root element".into()),
    }
}

/// Parses any XML document (OPF, NCX, container.xml) into the same tree, names as written.
pub fn parse_xml(src: &str) -> Result<Element, String> {
    parse_xhtml(src)
}

fn convert_xml(node: roxmltree::Node) -> Option<Node> {
    if node.is_text() {
        return Some(Node::Text(node.text().unwrap_or_default().to_string()));
    }
    if !node.is_element() {
        return None;
    }
    let tag = node.tag_name();
    let ns = match tag.namespace() {
        Some("http://www.w3.org/2000/svg") => Ns::Svg,
        Some("http://www.w3.org/1998/Math/MathML") => Ns::MathMl,
        _ => Ns::Html,
    };
    let name = if ns == Ns::Html { tag.name().to_ascii_lowercase() } else { tag.name().to_string() };
    let attrs = node
        .attributes()
        .map(|a| {
            let prefix = match a.namespace() {
                Some("http://www.w3.org/XML/1998/namespace") => "xml:",
                Some("http://www.idpf.org/2007/ops") => "epub:",
                Some("http://www.w3.org/1999/xlink") => "xlink:",
                Some("http://www.idpf.org/2007/opf") => "opf:",
                _ => "",
            };
            (format!("{prefix}{}", a.name()), a.value().to_string())
        })
        .collect();
    let children = node.children().filter_map(convert_xml).collect();
    Some(Node::Element(Element { name, ns, attrs, children }))
}

/// Rewrites HTML named entities to numeric references and escapes stray `&`, so an XML parser
/// accepts the text. The five XML entities and numeric references are left alone.
fn fix_entities(src: &str) -> std::borrow::Cow<'_, str> {
    if !src.contains('&') {
        return std::borrow::Cow::Borrowed(src);
    }
    let mut out = String::with_capacity(src.len() + 64);
    let mut rest = src;
    while let Some(pos) = rest.find('&') {
        out.push_str(&rest[..pos]);
        let after = &rest[pos + 1..];
        let name_len =
            after.bytes().take(41).take_while(|b| b.is_ascii_alphanumeric() || *b == b'#').count();
        let name = &after[..name_len];
        let terminated = after.as_bytes().get(name_len) == Some(&b';');
        if !(terminated && name_len > 0) {
            out.push_str("&amp;");
            rest = after;
            continue;
        }
        if name.starts_with('#') || matches!(name, "amp" | "lt" | "gt" | "quot" | "apos") {
            let _ = write!(out, "&{name};");
        } else {
            match html5ever::data::NAMED_ENTITIES.get(&format!("{name};")[..]) {
                Some(&(cp1, cp2)) if cp1 != 0 => {
                    let _ = write!(out, "&#{cp1};");
                    if cp2 != 0 {
                        let _ = write!(out, "&#{cp2};");
                    }
                }
                _ => {
                    let _ = write!(out, "&amp;{name};");
                }
            }
        }
        rest = &after[name_len + 1..];
    }
    out.push_str(rest);
    std::borrow::Cow::Owned(out)
}

pub fn parse_html(src: &str) -> Element {
    let dom = html5ever::parse_document(RcDom::default(), Default::default()).one(src);
    let html = dom
        .document
        .children
        .borrow()
        .iter()
        .find_map(|h| match convert_rcdom(h) {
            Some(Node::Element(e)) if e.name == "html" => Some(e),
            _ => None,
        });
    html.unwrap_or_else(|| Element::new("html").with_attr("lang", ""))
}

fn convert_rcdom(handle: &Handle) -> Option<Node> {
    match &handle.data {
        NodeData::Text { contents } => Some(Node::Text(contents.borrow().to_string())),
        NodeData::Element { name, attrs, .. } => {
            let ns = if name.ns == html5ever::ns!(svg) {
                Ns::Svg
            } else if name.ns == html5ever::ns!(mathml) {
                Ns::MathMl
            } else {
                Ns::Html
            };
            let attrs = attrs
                .borrow()
                .iter()
                .map(|a| {
                    let key = match &a.name.prefix {
                        Some(p) => format!("{}:{}", p, a.name.local),
                        None => a.name.local.to_string(),
                    };
                    (key, a.value.to_string())
                })
                .collect();
            let children = handle.children.borrow().iter().filter_map(convert_rcdom).collect();
            Some(Node::Element(Element { name: name.local.to_string(), ns, attrs, children }))
        }
        _ => None,
    }
}

// ---------------------------------------------------------------------------------------------
// Serialization (HTML syntax)

const VOID: &[&str] = &[
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr",
];

pub fn serialize_nodes(nodes: &[Node], out: &mut String) {
    for n in nodes {
        serialize_node(n, out, false);
    }
}

pub fn to_html(nodes: &[Node]) -> String {
    let mut out = String::new();
    serialize_nodes(nodes, &mut out);
    out
}

fn serialize_node(node: &Node, out: &mut String, raw: bool) {
    match node {
        Node::Text(t) => {
            if raw {
                out.push_str(t)
            } else {
                escape_text(t, out)
            }
        }
        Node::Element(e) => serialize_element(e, out),
    }
}

fn serialize_element(e: &Element, out: &mut String) {
    out.push('<');
    out.push_str(&e.name);
    for (k, v) in &e.attrs {
        out.push(' ');
        out.push_str(k);
        out.push_str("=\"");
        escape_attr(v, out);
        out.push('"');
    }
    if e.ns != Ns::Html && e.children.is_empty() {
        out.push_str("/>");
        return;
    }
    out.push('>');
    if e.ns == Ns::Html && VOID.contains(&e.name.as_str()) {
        return;
    }
    let raw = e.ns == Ns::Html && (e.name == "style" || e.name == "script");
    for c in &e.children {
        serialize_node(c, out, raw);
    }
    out.push_str("</");
    out.push_str(&e.name);
    out.push('>');
}

pub fn escape_text(s: &str, out: &mut String) {
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '\u{a0}' => out.push_str("&nbsp;"),
            _ => out.push(c),
        }
    }
}

pub fn escape_attr(s: &str, out: &mut String) {
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '"' => out.push_str("&quot;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            _ => out.push(c),
        }
    }
}

pub fn escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    escape_attr(s, &mut out);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn entities_become_xml_safe() {
        let src = r#"<p>a&nbsp;b &mdash; &amp; &lt; &#x4e2d; R&D &bogus; &fjlig;</p>"#;
        let fixed = fix_entities(src);
        assert_eq!(
            fixed,
            "<p>a&#160;b &#8212; &amp; &lt; &#x4e2d; R&amp;D &amp;bogus; &#102;&#106;</p>"
        );
        let root = parse_xhtml(src).unwrap();
        assert_eq!(root.text_content(), "a\u{a0}b \u{2014} & < 中 R&D &bogus; fj");
    }

    #[test]
    fn xhtml_with_doctype_and_namespaces() {
        let src = r##"<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en">
<head><title>T</title></head>
<body><p>Hi<a epub:type="noteref" href="#n1">1</a></p>
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 10 10"><image xlink:href="c.jpg"/></svg></body></html>"##;
        let root = parse_xhtml(src).unwrap();
        assert_eq!(root.attr("xml:lang"), Some("en"));
        let body = root.first_child("body").unwrap();
        let a = body.find(&|e| e.is("a")).unwrap();
        assert!(a.has_epub_type("noteref"));
        let image = body.find(&|e| e.name == "image").unwrap();
        assert_eq!(image.ns, Ns::Svg);
        assert_eq!(image.attr("xlink:href"), Some("c.jpg"));
        let html = to_html(&body.children);
        assert!(html.contains(r#"<svg viewBox="0 0 10 10"><image xlink:href="c.jpg"/></svg>"#), "{html}");
    }

    #[test]
    fn broken_xml_falls_back_to_html() {
        let root = parse_markup("<html><body><p>one<p>two & three<br></body></html>");
        let body = root.first_child("body").unwrap();
        assert_eq!(body.child_elements().filter(|e| e.is("p")).count(), 2);
        assert_eq!(to_html(&body.children), "<p>one</p><p>two &amp; three<br></p>");
    }

    #[test]
    fn find_path_and_get_mut() {
        let root = parse_markup("<html><body><div><p>x</p><p id='a'>y</p></div></body></html>");
        let mut body = root.first_child("body").unwrap().clone();
        let path = body.find_path(&|e| e.attr("id") == Some("a")).unwrap();
        assert_eq!(path, vec![0, 1]);
        body.get_mut(&path).unwrap().add_class("hit");
        assert_eq!(to_html(&body.children), r#"<div><p>x</p><p id="a" class="hit">y</p></div>"#);
    }
}
