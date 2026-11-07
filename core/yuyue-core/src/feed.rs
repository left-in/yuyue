//! 播客的信息源: reading what the apps downloaded. The core
//! never goes online; the apps fetch a URL and hand the bytes here.
//!
//! - RSS 2.0, RSS 1.0 (RDF) and Atom feeds into one list of [`FeedItem`]s;
//! - a web page's own feed links (`<link rel="alternate" type="application/rss+xml">`), so
//!   pasting a blog's address finds its feed;
//! - Hacker News' API (top stories, one item with its comments);
//! - an article's main text, without the menus, ads and comment box around it ([`article`]);
//! - one key per article (its URL tidied, hashed), so an episode doesn't tell the same story
//!   twice.

use std::collections::HashSet;

use serde::Deserialize;

use crate::dom::{self, Element, Node};
use crate::error::{CoreError, Result};
use crate::text;

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct Feed {
    pub title: String,
    /// The site the feed belongs to, when it says.
    pub site: Option<String>,
    pub items: Vec<FeedItem>,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct FeedItem {
    pub title: String,
    /// Where the article is; the key for 只用新内容.
    pub url: String,
    pub author: Option<String>,
    /// Milliseconds since 1970 (UTC), when the feed gives a date it can be read from.
    pub published: Option<i64>,
    /// The feed's own text, as plain text: the whole article when the feed carries it, else a
    /// summary.
    pub text: String,
    /// `text` is only a summary; the article itself has to be fetched.
    pub summary_only: bool,
    /// Hacker News: points and comments.
    pub score: Option<u32>,
    pub comments: Option<u32>,
    /// Where people talk about it, when that isn't `url` (Hacker News).
    pub discussion: Option<String>,
}

/// A feed a web page names, from its `<link rel="alternate">`.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct FeedLink {
    pub url: String,
    pub title: Option<String>,
}

/// An article's main text, found in its web page.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct Article {
    pub title: Option<String>,
    /// Paragraphs, in order, as plain text.
    pub paragraphs: Vec<String>,
    /// Characters of text (CJK characters, or letters of words), to cut it to a length.
    pub units: u32,
}

/// A feed has fewer than this many characters per item: it carries summaries, not articles.
const SUMMARY_UNITS: u32 = 600;

/// Reads an RSS or Atom feed. `base` is the address it was downloaded from, for relative links.
#[uniffi::export]
pub fn parse_feed(bytes: Vec<u8>, base: String) -> Result<Feed> {
    let src = decode_xml(&bytes);
    let root = dom::parse_xml(&src).map_err(|e| CoreError::Invalid { detail: format!("{}{e}", crate::i18n::tr("不是 RSS 或 Atom：", "Not an RSS or Atom feed: ")) })?;
    let name = local(&root.name).to_ascii_lowercase();
    let name = name.as_str();
    let feed = match name {
        "rss" => rss(root.child_elements().find(|e| is(e, "channel")).unwrap_or(&root), &root, &base),
        "rdf" => rss(root.child_elements().find(|e| is(e, "channel")).unwrap_or(&root), &root, &base),
        "feed" => atom(&root, &base),
        _ => return Err(CoreError::Invalid { detail: crate::i18n::tr("不是 RSS 或 Atom", "Not an RSS or Atom feed") }),
    };
    Ok(feed)
}

/// The feeds a web page links to, the way browsers find them. Relative links are resolved
/// against `base`.
#[uniffi::export]
pub fn feed_links(html: String, base: String) -> Vec<FeedLink> {
    let root = dom::parse_html(&html);
    let mut found = Vec::new();
    root.find_all(&|e| e.is("link"), &mut found);
    let mut seen = HashSet::new();
    found
        .into_iter()
        .filter(|e| e.attr("rel").is_some_and(|r| r.split_ascii_whitespace().any(|w| w.eq_ignore_ascii_case("alternate"))))
        .filter(|e| e.attr("type").is_some_and(|t| matches!(t.trim().to_ascii_lowercase().as_str(), "application/rss+xml" | "application/atom+xml" | "application/feed+json" | "application/rdf+xml")))
        .filter_map(|e| {
            let url = resolve(&base, e.attr("href")?.trim())?;
            seen.insert(url.clone()).then(|| FeedLink { url, title: e.attr("title").map(text::collapse_ws).filter(|t| !t.is_empty()) })
        })
        .collect()
}

/// The 只用新内容 key of an article: its address without the fragment, tracking parameters,
/// `www.` and the scheme, hashed. Two links to one article get one key.
#[uniffi::export]
pub fn article_key(url: String) -> String {
    let tidy = tidy_url(&url);
    blake3::hash(tidy.as_bytes()).to_hex()[..24].to_string()
}

/// The main text of an article's web page.
#[uniffi::export]
pub fn article(html: String) -> Article {
    let root = dom::parse_html(&html);
    let title = page_title(&root);
    let body = main_block(&root);
    let mut paragraphs = Vec::new();
    if let Some(b) = body {
        blocks(b, &mut paragraphs);
    }
    // A heading repeating the title isn't text to read.
    if let (Some(t), Some(first)) = (&title, paragraphs.first())
        && first == t {
            paragraphs.remove(0);
        }
    let units = paragraphs.iter().map(|p| text::Stats::of(p).units()).sum();
    Article { title, paragraphs, units }
}

// ---------------------------------------------------------------------------------------------
// Hacker News (https://github.com/HackerNews/API)

#[derive(Deserialize)]
struct HnItem {
    id: u64,
    #[serde(default)]
    by: Option<String>,
    #[serde(default)]
    time: Option<i64>,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    text: Option<String>,
    #[serde(default)]
    score: Option<u32>,
    #[serde(default)]
    descendants: Option<u32>,
    #[serde(default)]
    kids: Vec<u64>,
    #[serde(default)]
    deleted: bool,
    #[serde(default)]
    dead: bool,
    #[serde(default, rename = "type")]
    kind: Option<String>,
}

/// A Hacker News story or comment, from `/v0/item/<id>.json`.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct HnEntry {
    pub id: u64,
    pub by: Option<String>,
    pub title: Option<String>,
    /// The story's link; a 'Ask HN' has none.
    pub url: Option<String>,
    /// Its own text (a comment, an Ask HN), as plain text.
    pub text: String,
    pub score: Option<u32>,
    pub comments: Option<u32>,
    /// Comments under it, the order Hacker News ranks them.
    pub kids: Vec<u64>,
    pub published: Option<i64>,
}

/// The story ids of `/v0/topstories.json` (or best, new, ask, show).
#[uniffi::export]
pub fn parse_hn_ids(bytes: Vec<u8>) -> Result<Vec<u64>> {
    Ok(serde_json::from_slice(&bytes)?)
}

/// One `/v0/item/<id>.json`. None for a deleted or flagged one, and for a JSON `null`.
#[uniffi::export]
pub fn parse_hn_item(bytes: Vec<u8>) -> Result<Option<HnEntry>> {
    let item: Option<HnItem> = serde_json::from_slice(&bytes)?;
    let Some(i) = item.filter(|i| !i.deleted && !i.dead) else { return Ok(None) };
    let story = i.kind.as_deref() != Some("comment");
    Ok(Some(HnEntry {
        id: i.id,
        by: i.by,
        title: i.title.map(|t| text::collapse_ws(&t)),
        url: i.url.filter(|u| !u.is_empty()),
        text: i.text.map(|t| html_text(&t)).unwrap_or_default(),
        score: i.score,
        comments: if story { i.descendants } else { None },
        kids: i.kids,
        published: i.time.map(|t| t * 1000),
    }))
}

/// A Hacker News story as a feed item: its link, or the discussion when it has none (Ask HN).
#[uniffi::export]
pub fn hn_feed_item(story: HnEntry) -> FeedItem {
    let discussion = format!("https://news.ycombinator.com/item?id={}", story.id);
    let url = story.url.clone().unwrap_or_else(|| discussion.clone());
    FeedItem {
        title: story.title.unwrap_or_default(),
        summary_only: story.url.is_some(),
        text: story.text,
        url,
        author: story.by,
        published: story.published,
        score: story.score,
        comments: story.comments,
        discussion: Some(discussion),
    }
}

// ---------------------------------------------------------------------------------------------
// RSS and Atom

fn rss(channel: &Element, root: &Element, base: &str) -> Feed {
    let site = child_text(channel, "link").and_then(|l| resolve(base, &l));
    let base = site.clone().unwrap_or_else(|| base.to_string());
    // RSS 1.0 keeps its items next to the channel, not in it.
    let mut items: Vec<&Element> = channel.child_elements().filter(|e| is(e, "item")).collect();
    if items.is_empty() {
        items = root.child_elements().filter(|e| is(e, "item")).collect();
    }
    let items = items
        .into_iter()
        .filter_map(|it| {
            let link = child_text(it, "link").or_else(|| it.child_elements().find(|e| is(e, "guid") && e.attr("isPermaLink") != Some("false")).map(|g| g.text_content()));
            let url = resolve(&base, link?.trim())?;
            let full = it.child_elements().find(|e| is(e, "content:encoded") || is(e, "encoded")).map(|e| html_text(&e.text_content()));
            let summary = child_text(it, "description").map(|d| html_text(&d));
            let date = child_text(it, "pubDate").or_else(|| child_text(it, "date")).and_then(|d| parse_date(&d));
            let author = child_text(it, "creator").or_else(|| child_text(it, "author"));
            Some(item(child_text(it, "title"), url, author, date, full, summary))
        })
        .collect();
    Feed { title: child_text(channel, "title").unwrap_or_default(), site, items }
}

fn atom(root: &Element, base: &str) -> Feed {
    let site = alternate(root).and_then(|l| resolve(base, &l));
    let base = site.clone().unwrap_or_else(|| base.to_string());
    let items = root
        .child_elements()
        .filter(|e| is(e, "entry"))
        .filter_map(|en| {
            let url = resolve(&base, alternate(en).or_else(|| child_text(en, "id").filter(|i| i.starts_with("http")))?.trim())?;
            let content = en.child_elements().find(|e| is(e, "content")).map(atom_text);
            let summary = en.child_elements().find(|e| is(e, "summary")).map(atom_text);
            let date = child_text(en, "published").or_else(|| child_text(en, "updated")).and_then(|d| parse_date(&d));
            let author = en.child_elements().find(|e| is(e, "author")).and_then(|a| child_text(a, "name"));
            Some(item(en.child_elements().find(|e| is(e, "title")).map(atom_text), url, author, date, content, summary))
        })
        .collect();
    let title = root.child_elements().find(|e| is(e, "title")).map(atom_text).unwrap_or_default();
    Feed { title, site, items }
}

fn item(title: Option<String>, url: String, author: Option<String>, published: Option<i64>, full: Option<String>, summary: Option<String>) -> FeedItem {
    let full = full.filter(|t| !t.is_empty());
    let summary = summary.filter(|t| !t.is_empty());
    // Some feeds put the whole article in the description.
    let (text, summary_only) = match (full, summary) {
        (Some(f), _) => {
            let short = text::Stats::of(&f).units() < SUMMARY_UNITS;
            (f, short)
        }
        (None, Some(s)) => {
            let short = text::Stats::of(&s).units() < SUMMARY_UNITS;
            (s, short)
        }
        (None, None) => (String::new(), true),
    };
    FeedItem {
        title: title.map(|t| text::collapse_ws(&t)).unwrap_or_default(),
        url,
        author: author.map(|a| text::collapse_ws(&a)).filter(|a| !a.is_empty()),
        published,
        text,
        summary_only,
        score: None,
        comments: None,
        discussion: None,
    }
}

/// An Atom text construct: `type="html"` is escaped markup, `xhtml` is markup, `text` is text.
fn atom_text(e: &Element) -> String {
    match e.attr("type") {
        Some("html") => html_text(&e.text_content()),
        Some("xhtml") => {
            let mut out = Vec::new();
            blocks(e, &mut out);
            out.join("\n")
        }
        _ => text::collapse_ws(&e.text_content()),
    }
}

/// Atom's `<link rel="alternate" href>` (no `rel` means alternate).
fn alternate(e: &Element) -> Option<String> {
    e.child_elements()
        .filter(|l| is(l, "link"))
        .find(|l| l.attr("rel").is_none_or(|r| r == "alternate"))
        .and_then(|l| l.attr("href").map(str::to_string))
}

fn child_text(e: &Element, name: &str) -> Option<String> {
    e.child_elements().find(|c| is(c, name)).map(|c| text::collapse_ws(&c.text_content())).filter(|t| !t.is_empty())
}

/// `dc:creator` → `creator`.
fn local(name: &str) -> &str {
    name.rsplit(':').next().unwrap_or(name)
}

/// The element is `name` (`pubDate`, `content:encoded`), whatever the case and prefix. The XML
/// reader lower-cases names in no namespace and leaves out prefixes.
fn is(e: &Element, name: &str) -> bool {
    local(&e.name).eq_ignore_ascii_case(local(name))
}

/// XML declares its encoding; a feed in GBK says so in its first line.
fn decode_xml(bytes: &[u8]) -> String {
    let head = String::from_utf8_lossy(&bytes[..bytes.len().min(200)]).to_ascii_lowercase();
    let declared = head
        .split("encoding=")
        .nth(1)
        .and_then(|r| r.trim_start_matches(['"', '\'']).split(['"', '\'']).next())
        .and_then(|name| encoding_rs::Encoding::for_label(name.as_bytes()));
    let mut s = match declared {
        Some(enc) if enc != encoding_rs::UTF_8 => enc.decode(bytes).0.into_owned(),
        _ => String::from_utf8_lossy(bytes).into_owned(),
    };
    // roxmltree refuses an encoding it doesn't read; the text is UTF-8 now.
    if let Some(end) = s.find("?>").filter(|_| s.trim_start().starts_with("<?xml")) {
        s.replace_range(..end + 2, "");
    }
    s.trim_start_matches('\u{feff}').to_string()
}

// ---------------------------------------------------------------------------------------------
// Dates

/// RFC 822 (`Sat, 31 Oct 2026 13:29:19 +0800`, RSS) or RFC 3339 (`2026-10-31T05:29:19Z`, Atom).
pub fn parse_date(s: &str) -> Option<i64> {
    let s = s.trim();
    if s.as_bytes().first().is_some_and(u8::is_ascii_digit) && s.contains('-') {
        return rfc3339(s);
    }
    rfc822(s)
}

fn rfc3339(s: &str) -> Option<i64> {
    let (date, rest) = s.split_at(s.find(['T', 't', ' ']).unwrap_or(s.len()));
    let mut d = date.split('-').map(|p| p.parse::<i64>().ok());
    let (y, m, day) = (d.next()??, d.next()??, d.next()??);
    let rest = rest.get(1..).unwrap_or("");
    let (time, zone) = match rest.find(['Z', 'z', '+', '-']) {
        Some(i) => rest.split_at(i),
        None => (rest, ""),
    };
    let mut t = time.split(':');
    let h = t.next().and_then(|v| v.parse::<i64>().ok()).unwrap_or(0);
    let mi = t.next().and_then(|v| v.parse::<i64>().ok()).unwrap_or(0);
    let sec = t.next().and_then(|v| v.split('.').next()?.parse::<i64>().ok()).unwrap_or(0);
    Some(epoch(y, m, day, h, mi, sec)? - offset(zone)? * 60_000)
}

fn rfc822(s: &str) -> Option<i64> {
    let s = s.split_once(',').map_or(s, |(_, r)| r).trim();
    let mut p = s.split_ascii_whitespace();
    let day: i64 = p.next()?.parse().ok()?;
    let month = p.next()?.to_ascii_lowercase();
    let m = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"].iter().position(|x| month.starts_with(x))? as i64 + 1;
    let mut y: i64 = p.next()?.parse().ok()?;
    if y < 100 {
        y += if y < 50 { 2000 } else { 1900 };
    }
    let mut t = p.next().unwrap_or("0:0").split(':').map(|v| v.parse::<i64>().unwrap_or(0));
    let (h, mi, sec) = (t.next().unwrap_or(0), t.next().unwrap_or(0), t.next().unwrap_or(0));
    let zone = p.next().unwrap_or("GMT");
    let minutes = match zone.to_ascii_uppercase().as_str() {
        "GMT" | "UT" | "UTC" | "Z" => 0,
        "EST" => -300,
        "EDT" => -240,
        "CST" => -360,
        "CDT" => -300,
        "MST" => -420,
        "MDT" => -360,
        "PST" => -480,
        "PDT" => -420,
        z => offset(z)?,
    };
    Some(epoch(y, m, day, h, mi, sec)? - minutes * 60_000)
}

/// `+08:00`, `+0800`, `Z` → minutes east of UTC.
fn offset(z: &str) -> Option<i64> {
    let z = z.trim();
    if z.is_empty() || z.eq_ignore_ascii_case("z") {
        return Some(0);
    }
    let sign = match z.as_bytes()[0] {
        b'+' => 1,
        b'-' => -1,
        _ => return None,
    };
    let digits: String = z[1..].chars().filter(char::is_ascii_digit).collect();
    if digits.len() < 2 {
        return None;
    }
    let h: i64 = digits[..2].parse().ok()?;
    let m: i64 = digits.get(2..4).and_then(|v| v.parse().ok()).unwrap_or(0);
    Some(sign * (h * 60 + m))
}

/// Milliseconds since 1970 of a UTC date and time (days from civil, Howard Hinnant's).
fn epoch(y: i64, m: i64, d: i64, h: i64, mi: i64, s: i64) -> Option<i64> {
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) || h > 24 || mi > 59 || s > 60 {
        return None;
    }
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    Some(((days * 24 + h) * 60 + mi) * 60_000 + s * 1000)
}

// ---------------------------------------------------------------------------------------------
// URLs

/// Resolves `href` against `base`. Only http(s) results; `javascript:`, `mailto:` give None.
pub fn resolve(base: &str, href: &str) -> Option<String> {
    let href = href.trim();
    if href.is_empty() {
        return None;
    }
    if let Some((scheme, _)) = href.split_once(':').filter(|(s, _)| !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || "+-.".contains(c))) {
        return matches!(scheme.to_ascii_lowercase().as_str(), "http" | "https").then(|| href.to_string());
    }
    let (scheme, rest) = base.split_once("://")?;
    if href.starts_with("//") {
        return Some(format!("{scheme}:{href}"));
    }
    let host_end = rest.find('/').unwrap_or(rest.len());
    let origin = format!("{scheme}://{}", &rest[..host_end]);
    if href.starts_with('/') {
        return Some(format!("{origin}{href}"));
    }
    let path = &rest[host_end..];
    let path = path.split(['?', '#']).next().unwrap_or("");
    let dir = &path[..path.rfind('/').map_or(0, |i| i + 1)];
    let mut parts: Vec<&str> = dir.split('/').filter(|p| !p.is_empty()).collect();
    for seg in href.split('/') {
        match seg {
            "." => {}
            ".." => {
                parts.pop();
            }
            s => parts.push(s),
        }
    }
    Some(format!("{origin}/{}", parts.join("/")))
}

const TRACKING: &[&str] = &["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id", "fbclid", "gclid", "mc_cid", "mc_eid", "ref", "ref_src", "spm", "from", "source"];

fn tidy_url(url: &str) -> String {
    let url = url.trim();
    let url = url.split('#').next().unwrap_or(url);
    let rest = url.split_once("://").map_or(url, |(_, r)| r);
    let (hostpath, query) = rest.split_once('?').unwrap_or((rest, ""));
    let (host, path) = hostpath.split_at(hostpath.find('/').unwrap_or(hostpath.len()));
    let host = host.to_ascii_lowercase();
    let host = host.strip_prefix("www.").or_else(|| host.strip_prefix("m.")).unwrap_or(&host);
    let path = path.trim_end_matches('/');
    let mut params: Vec<&str> = query.split('&').filter(|p| !p.is_empty()).filter(|p| !TRACKING.contains(&p.split('=').next().unwrap_or("").to_ascii_lowercase().as_str())).collect();
    params.sort_unstable();
    if params.is_empty() { format!("{host}{path}") } else { format!("{host}{path}?{}", params.join("&")) }
}

// ---------------------------------------------------------------------------------------------
// Article text

/// Blocks that hold text to read.
const BLOCKS: &[&str] = &["p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "pre", "figcaption", "dd", "dt", "td"];

/// Never article text.
const NOISE: &[&str] = &["script", "style", "noscript", "nav", "header", "footer", "aside", "form", "button", "select", "iframe", "svg", "template", "menu", "dialog"];

/// Class or id words of page furniture.
const NOISE_WORDS: &[&str] = &[
    "comment", "comments", "sidebar", "footer", "header", "nav", "navbar", "menu", "share", "social", "related", "recommend", "advert", "ad", "ads", "banner",
    "subscribe", "newsletter", "popup", "modal", "breadcrumb", "pagination", "toolbar", "cookie", "promo", "sponsor", "widget", "author-bio", "tags",
];

/// Class or id words of the article itself.
const MAIN_WORDS: &[&str] = &["article", "content", "post", "entry", "main", "body", "text", "story", "markdown", "prose"];

fn words_of(e: &Element) -> Vec<String> {
    let mut v = Vec::new();
    for a in ["class", "id", "role"] {
        if let Some(s) = e.attr(a) {
            for w in s.split(|c: char| c.is_ascii_whitespace() || c == '_' || c == '-' || c == '.') {
                if !w.is_empty() {
                    v.push(w.to_ascii_lowercase());
                }
            }
        }
    }
    v
}

fn is_noise(e: &Element) -> bool {
    if NOISE.contains(&e.name.as_str()) || e.attr("hidden").is_some() || e.attr("aria-hidden") == Some("true") {
        return true;
    }
    let w = words_of(e);
    // `article-content` has "content", not noise; `comment-list` is noise. A main word wins.
    !w.iter().any(|x| MAIN_WORDS.contains(&x.as_str())) && w.iter().any(|x| NOISE_WORDS.contains(&x.as_str()))
}

/// The element with the article: `<article>` or `<main>` when there's one, else the one whose
/// paragraphs hold the most text, with links counted against it (Readability's idea).
fn main_block(root: &Element) -> Option<&Element> {
    let body = root.first_child("body").unwrap_or(root);
    let mut articles = Vec::new();
    body.find_all(&|e| e.is("article") || e.is("main") || e.attr("role") == Some("main") || e.attr("itemprop") == Some("articleBody"), &mut articles);
    let best_landmark = articles.into_iter().filter(|e| !is_noise(e)).max_by_key(|e| score(e));
    let mut candidates = Vec::new();
    collect_candidates(body, &mut candidates);
    let best = candidates.into_iter().max_by_key(|(_, s)| *s);
    match (best_landmark, best) {
        // An <article> holding most of the best block's text is the better frame.
        (Some(a), Some((b, s))) => Some(if score(a) * 10 >= s * 7 { a } else { b }),
        (Some(a), None) => Some(a),
        (None, b) => b.map(|(e, _)| e),
    }
}

fn collect_candidates<'a>(e: &'a Element, out: &mut Vec<(&'a Element, i64)>) {
    if is_noise(e) {
        return;
    }
    if matches!(e.name.as_str(), "div" | "section" | "article" | "main" | "td") {
        let s = score(e);
        if s > 0 {
            let bonus = if words_of(e).iter().any(|w| MAIN_WORDS.contains(&w.as_str())) { s / 4 } else { 0 };
            out.push((e, s + bonus));
        }
    }
    for c in e.child_elements() {
        collect_candidates(c, out);
    }
}

/// Text in the element's own paragraphs (one level of wrappers down), less the link text.
fn score(e: &Element) -> i64 {
    let mut total = 0i64;
    for c in e.child_elements() {
        if is_noise(c) {
            continue;
        }
        if BLOCKS.contains(&c.name.as_str()) {
            let t = c.text_content();
            let len = text::Stats::of(&t).units() as i64;
            let link = link_units(c) as i64;
            if len >= 10 {
                total += len - link * 2;
            }
        } else if matches!(c.name.as_str(), "div" | "section" | "span") {
            total += score(c) / 2;
        }
    }
    total
}

fn link_units(e: &Element) -> u32 {
    let mut links = Vec::new();
    e.find_all(&|x| x.is("a"), &mut links);
    links.iter().map(|a| text::Stats::of(&a.text_content()).units()).sum()
}

/// The element's blocks as paragraphs of plain text.
fn blocks(e: &Element, out: &mut Vec<String>) {
    let mut loose = String::new();
    for n in &e.children {
        match n {
            Node::Text(t) => loose.push_str(t),
            Node::Element(c) if is_noise(c) => {}
            Node::Element(c) if c.is("br") => loose.push('\n'),
            Node::Element(c) if BLOCKS.contains(&c.name.as_str()) => {
                flush(&mut loose, out);
                // A list item that is all link is a menu.
                let t = inline_text(c);
                let units = text::Stats::of(&t).units();
                let menu = c.name == "li" && link_units(c) * 2 > units;
                if units > 0 && !menu {
                    out.push(t);
                }
            }
            Node::Element(c) if is_inline(c) => loose.push_str(&inline_text(c)),
            Node::Element(c) => {
                flush(&mut loose, out);
                blocks(c, out);
            }
        }
    }
    flush(&mut loose, out);
}

fn flush(loose: &mut String, out: &mut Vec<String>) {
    for line in loose.split('\n') {
        let t = text::collapse_ws(line);
        if text::Stats::of(&t).units() > 0 {
            out.push(t);
        }
    }
    loose.clear();
}

fn is_inline(e: &Element) -> bool {
    matches!(e.name.as_str(), "a" | "b" | "strong" | "i" | "em" | "span" | "code" | "small" | "sub" | "sup" | "mark" | "abbr" | "cite" | "q" | "time" | "u" | "s" | "del" | "ins" | "kbd" | "var" | "font" | "label")
}

/// An element's text with its inline markup gone, without the noise inside it.
fn inline_text(e: &Element) -> String {
    let mut s = String::new();
    fn walk(e: &Element, s: &mut String) {
        for n in &e.children {
            match n {
                Node::Text(t) => s.push_str(t),
                Node::Element(c) if is_noise(c) => {}
                Node::Element(c) if c.is("br") => s.push(' '),
                Node::Element(c) => walk(c, s),
            }
        }
    }
    walk(e, &mut s);
    text::collapse_ws(&s)
}

/// The `og:title`, or else `<title>`; less the " - Site name" after it.
fn page_title(root: &Element) -> Option<String> {
    let mut metas = Vec::new();
    root.find_all(&|e| e.is("meta") && e.attr("property") == Some("og:title"), &mut metas);
    let og = metas.first().and_then(|m| m.attr("content")).map(text::collapse_ws).filter(|t| !t.is_empty());
    let t = match og {
        Some(t) => t,
        None => text::collapse_ws(&root.find(&|e| e.is("title"))?.text_content()),
    };
    let t = [" | ", " - ", " — ", " – ", " · ", "_"].iter().fold(t, |acc, sep| match acc.rsplit_once(sep) {
        Some((head, _)) if text::Stats::of(head).units() >= 2 => head.to_string(),
        _ => acc,
    });
    (!t.is_empty()).then_some(t)
}

/// Markup (an RSS description, a Hacker News comment) as plain text, one paragraph a line.
pub fn html_text(src: &str) -> String {
    let root = dom::parse_html(&format!("<body>{src}</body>"));
    let mut out = Vec::new();
    blocks(root.first_child("body").unwrap_or(&root), &mut out);
    out.join("\n")
}
