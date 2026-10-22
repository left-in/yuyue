//! The core from the command line, for development.
//!
//! ```text
//! yuyue import <library> <file>...
//! yuyue list <library>
//! yuyue toc <library> <book>
//! yuyue doc <library> <book> <section> [--native]
//! yuyue sentences <library> <book> <section>
//! yuyue site <library> <out> [--app <reader build>] [--native]
//! ```
//!
//! `<book>` is an id or the start of one. `site` writes every book as static files laid out
//! like the app's URLs (`/book/<id>/s/<n>.html`, `/book/<id>/r/…`, `/app/…`), so the reader
//! can be tried in a desktop browser: `python3 -m http.server -d <out>`.

use std::fmt::Write as _;
use std::fs;
use std::path::Path;
use std::process::ExitCode;
use std::sync::Arc;

use yuyue_core::document::Paging;
use yuyue_core::{BookSummary, CoreError, MarkStyle, PageGeometry, Position, SectionKind, TextPoint, YuyueCore};

const USAGE: &str = "usage:
  yuyue import <library> <file>...
  yuyue list <library>
  yuyue toc <library> <book>
  yuyue doc <library> <book> <section> [--native]
  yuyue sentences <library> <book> <section>
  yuyue site <library> <out> [--app <reader build>] [--native]
  yuyue progress <library> <book> <section> <sentence>
  yuyue heard <library> <book> <section> <sentence>
  yuyue word <library> <book> <section> <sentence> <word> <phonetic|-> <meaning> <context>
  yuyue words <library>
  yuyue export <library>          (every change, as a device puts it in the sync folder)
  yuyue import-changes <library> <file>
  yuyue devices <library>";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("yuyue: {e}");
            ExitCode::FAILURE
        }
    }
}

fn run(args: &[String]) -> Result<(), String> {
    let native = args.iter().any(|a| a == "--native");
    let app = args.iter().position(|a| a == "--app").map(|i| args.get(i + 1).cloned().ok_or("--app needs a folder"));
    let app = app.transpose()?;
    let plain: Vec<&str> = args
        .iter()
        .enumerate()
        .filter(|(i, a)| *a != "--native" && *a != "--app" && !(*i > 0 && args[i - 1] == "--app"))
        .map(|(_, a)| a.as_str())
        .collect();
    let geometry = PageGeometry {
        paging: if native { Paging::Native } else { Paging::Snap },
        margin: 24.0,
        top: 56.0,
        bottom: 88.0,
        columns: 1,
        reduced_motion: false,
    };
    let open = |library: &str| YuyueCore::open(library.to_string(), "yuyue cli".into(), "cli".into()).map_err(err);
    match plain.as_slice() {
        ["import", library, files @ ..] if !files.is_empty() => {
            let core = open(library)?;
            for file in files {
                match core.import_book(file.to_string()) {
                    Ok(b) => println!("{}  {}  ({} sections)", b.id, b.title, core.book(b.id.clone()).map_err(err)?.sections.len()),
                    Err(e) => eprintln!("{file}: {e}"),
                }
            }
            Ok(())
        }
        ["list", library] => {
            for b in open(library)?.books().map_err(err)? {
                println!(
                    "{}  {} — {}  [{}]  读 {} 分钟 · 听 {} 分钟  {:.0}%",
                    b.id,
                    b.title,
                    b.authors.join(", "),
                    b.language,
                    b.read_minutes,
                    b.listen_minutes,
                    b.progress * 100.0
                );
            }
            Ok(())
        }
        ["toc", library, book] => {
            let core = open(library)?;
            let detail = core.book(find(&core, book)?.id).map_err(err)?;
            println!("start: section {}", detail.start);
            for e in &detail.toc {
                let anchor = e.anchor.as_deref().map(|a| format!("#{a}")).unwrap_or_default();
                println!("{}{}  → {}{anchor}", "  ".repeat(e.depth as usize), e.title, e.section);
            }
            println!();
            for (i, s) in detail.sections.iter().enumerate() {
                let kind = match s.kind {
                    SectionKind::Text => "",
                    SectionKind::Image => " image",
                    SectionKind::Boilerplate => " boilerplate",
                };
                let flags = format!("{kind}{}{}", if s.linear { "" } else { " non-linear" }, if s.continued { " continued" } else { "" });
                println!("#{i} {}  {} sentences, {} units{flags}", s.title.as_deref().unwrap_or("—"), s.sentences, s.units);
            }
            Ok(())
        }
        ["doc", library, book, section] => {
            let core = open(library)?;
            let id = find(&core, book)?.id;
            print!("{}", core.section_document(id, number(section)?, geometry).map_err(err)?);
            Ok(())
        }
        ["script", library, book, to] => {
            let core = open(library)?;
            let id = find(&core, book)?.id;
            let script = match *to {
                "simplified" => Some(yuyue_core::Script::Simplified),
                "traditional" => Some(yuyue_core::Script::Traditional),
                _ => None,
            };
            core.set_book_script(id, script).map_err(err)?;
            Ok(())
        }
        ["sentences", library, book, section] => {
            let core = open(library)?;
            let id = find(&core, book)?.id;
            for (i, s) in core.sentences(id, number(section)?).map_err(err)?.iter().enumerate() {
                println!("{i}\t{s}");
            }
            Ok(())
        }
        ["progress", library, book, section, sentence] => {
            let core = open(library)?;
            let id = find(&core, book)?.id;
            let position = Position { section: number(section)?, sentence: number(sentence)? };
            core.save_progress(id, position).map_err(err)
        }
        // 双击耳机: highlights a whole sentence as if marked while listening.
        ["heard", library, book, section, sentence] => {
            let core = open(library)?;
            let id = find(&core, book)?.id;
            let (section, sentence): (u32, u32) = (number(section)?, number(sentence)?);
            let raw = core.sentences(id.clone(), section).map_err(err)?.into_iter().nth(sentence as usize).ok_or("no such sentence")?;
            let text = raw.trim();
            let lead = raw.len() - raw.trim_start().len();
            let at = |bytes: usize| TextPoint { sentence, offset: raw[..bytes].encode_utf16().count() as u32 };
            let mark = core.mark_heard(id, section, at(lead), at(lead + text.len()), text.to_string(), MarkStyle::Yellow).map_err(err)?;
            println!("{}", mark.text);
            Ok(())
        }
        ["word", library, book, section, sentence, word, phonetic, meaning, context] => {
            let core = open(library)?;
            let id = find(&core, book)?.id;
            let w = core
                .add_word(word.to_string(), Some(phonetic.to_string()).filter(|p| p != "-"), Some(meaning.to_string()), id, number(section)?, number(sentence)?, context.to_string())
                .map_err(err)?;
            println!("{} · {}", w.word, w.meaning.unwrap_or_default());
            Ok(())
        }
        ["words", library] => {
            for w in open(library)?.words().map_err(err)? {
                println!("{}\t{}\t{}", w.word, if w.known { "掌握了" } else { "在学" }, w.meaning.unwrap_or_default());
            }
            Ok(())
        }
        ["export", library] => {
            print!("{}", open(library)?.export_changes("{}".into()).map_err(err)?);
            Ok(())
        }
        ["import-changes", library, file] => {
            let batch = fs::read_to_string(file).map_err(|e| e.to_string())?;
            println!("{} values changed", open(library)?.import_changes(batch).map_err(err)?);
            Ok(())
        }
        ["devices", library] => {
            for d in open(library)?.devices().map_err(err)? {
                let this = if d.this_device { " (this)" } else { "" };
                println!("{}  {} [{}]{this}  last: {:?} {:?} at {:?}", d.id, d.name, d.platform, d.last_book, d.last_fraction, d.last_at);
            }
            Ok(())
        }
        ["site", library, out] => site(&open(library)?, Path::new(library), Path::new(out), app.as_deref(), &geometry),
        _ => Err(USAGE.to_string()),
    }
}

fn err(e: CoreError) -> String {
    e.to_string()
}

fn number(s: &str) -> Result<u32, String> {
    s.parse().map_err(|_| format!("not a section number: {s}"))
}

fn find(core: &Arc<YuyueCore>, prefix: &str) -> Result<BookSummary, String> {
    let mut matches: Vec<_> = core.books().map_err(err)?.into_iter().filter(|b| b.id.starts_with(prefix)).collect();
    match matches.len() {
        1 => Ok(matches.remove(0)),
        0 => Err(format!("no book {prefix}")),
        _ => Err(format!("{prefix} matches more than one book")),
    }
}

fn site(core: &Arc<YuyueCore>, library: &Path, out: &Path, app: Option<&str>, geometry: &PageGeometry) -> Result<(), String> {
    let io = |e: std::io::Error| e.to_string();
    let mut index = String::from(
        "<!DOCTYPE html>\n<html lang=\"zh-CN\"><meta charset=\"utf-8\"><title>语阅 · 书页</title>\n<body style=\"font:16px/1.6 system-ui;margin:2em\">\n<h1>书页</h1>\n<ul>\n",
    );
    for b in core.books().map_err(err)? {
        let detail = core.book(b.id.clone()).map_err(err)?;
        let dir = out.join("book").join(&b.id);
        fs::create_dir_all(dir.join("s")).map_err(io)?;
        for n in 0..detail.sections.len() as u32 {
            let html = core.section_document(b.id.clone(), n, geometry.clone()).map_err(err)?;
            fs::write(dir.join("s").join(format!("{n}.html")), html).map_err(io)?;
        }
        let resources = library.join("books").join(&b.id).join("r");
        if resources.is_dir() {
            copy_dir(&resources, &dir.join("r")).map_err(io)?;
        }
        let _ = write!(index, "<li><a href=\"book/{}/s/{}.html\">{}</a> <small>", b.id, detail.start, escape(&b.title));
        for e in detail.toc.iter().filter(|e| e.depth == 0).take(200) {
            let _ = write!(index, " · <a href=\"book/{}/s/{}.html\">{}</a>", b.id, e.section, escape(&e.title));
        }
        index.push_str("</small></li>\n");
        println!("{}  {}", b.id, b.title);
    }
    index.push_str("</ul>\n</body>\n</html>\n");
    fs::write(out.join("index.html"), index).map_err(io)?;
    if let Some(app) = app {
        copy_dir(Path::new(app), &out.join("app")).map_err(io)?;
    }
    Ok(())
}

fn copy_dir(from: &Path, to: &Path) -> std::io::Result<()> {
    fs::create_dir_all(to)?;
    for entry in fs::read_dir(from)? {
        let entry = entry?;
        let target = to.join(entry.file_name());
        if entry.file_type()?.is_dir() {
            copy_dir(&entry.path(), &target)?;
        } else {
            fs::copy(entry.path(), target)?;
        }
    }
    Ok(())
}

fn escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}
