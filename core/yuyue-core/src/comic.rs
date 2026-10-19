//! Comics (FEATURES §3.6): a CBZ or ZIP of pictures, a CBR (RAR), or a folder of them.
//!
//! ```text
//! books/<id>/
//!   original.cbz     the archive (a folder or a RAR is packed into one first)
//!   cover.jpg        the first page
//!   p/<n>.<ext>      every page, numbered through the whole book
//!   p/<section>.json the file names of a section's pages, in order
//! ```
//!
//! Pages are sorted the way people number files (`2.jpg` before `10.jpg`). Pictures in
//! sub-folders make one 话 per folder, named after it; pictures loose at the top are one 话
//! named after the book.

use std::cmp::Ordering;
use std::fs;
use std::io::{Cursor, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use zip::ZipArchive;
use zip::write::SimpleFileOptions;

use crate::book::{FORMAT_VERSION, Format, Manifest, SectionInfo};
use crate::epub::{Kind, TocEntry};
use crate::error::{CoreError, Result};

const IMAGES: [&str; 9] = ["jpg", "jpeg", "png", "webp", "gif", "avif", "heic", "bmp", "tif"];

fn is_image(name: &str) -> bool {
    let file = name.rsplit('/').next().unwrap_or(name);
    if file.starts_with('.') || name.starts_with("__MACOSX/") || name.contains("/__MACOSX/") {
        return false;
    }
    let ext = file.rsplit_once('.').map(|(_, e)| e.to_ascii_lowercase()).unwrap_or_default();
    IMAGES.contains(&ext.as_str())
}

/// A ZIP that holds pictures and isn't an EPUB.
pub fn is_comic(bytes: &[u8]) -> bool {
    let Ok(mut zip) = ZipArchive::new(Cursor::new(bytes)) else { return false };
    if zip.by_name("META-INF/container.xml").is_ok() {
        return false;
    }
    zip.file_names().flatten().any(|n| is_image(&n))
}

/// Packs the pictures in a folder (and its sub-folders) into a ZIP, stored as they are. The same
/// folder always packs to the same bytes, so importing it again finds the first import.
pub fn pack_folder(dir: &Path) -> Result<Vec<u8>> {
    let mut files = Vec::new();
    collect(dir, dir, &mut files)?;
    if files.is_empty() {
        return Err(CoreError::bad_book("the folder has no pictures"));
    }
    files.sort_by(|a, b| natural(&a.0, &b.0));
    let mut zip = zip::ZipWriter::new(Cursor::new(Vec::new()));
    let options = SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Stored)
        .last_modified_time(zip::DateTime::default());
    for (name, path) in files {
        zip.start_file(name, options).map_err(|e| CoreError::bad_book(e.to_string()))?;
        zip.write_all(&fs::read(path)?)?;
    }
    Ok(zip.finish().map_err(|e| CoreError::bad_book(e.to_string()))?.into_inner())
}

/// A RAR archive (`.cbr`), by its signature.
pub fn is_rar(bytes: &[u8]) -> bool {
    bytes.starts_with(b"Rar!\x1a\x07")
}

/// Unpacks the pictures in a RAR and packs them into a ZIP the way [`pack_folder`] does, so the
/// rest of the comic is built the same. Pictures only, and never more than 4 GB in all.
pub fn pack_rar(bytes: &[u8]) -> Result<Vec<u8>> {
    #[derive(Clone)]
    struct Sink(Arc<Mutex<Vec<u8>>>);
    impl Write for Sink {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.0.lock().map_err(|_| std::io::Error::other("poisoned"))?.extend_from_slice(buf);
            Ok(buf.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    let options = rars::ArchiveReadOptions::new().with_max_total_output_bytes(4 << 30);
    let archive = rars::ArchiveReader::read_with_options(bytes, options).map_err(rar_error)?;
    if archive.members().any(|m| m.meta.is_encrypted) {
        return Err(CoreError::bad_book("the archive has a password"));
    }
    let mut files: Vec<(String, Sink)> = Vec::new();
    archive
        .extract_to_with_options(rars::ArchiveReadOptions::new().with_max_total_output_bytes(4 << 30), |entry| {
            let name = entry.name_lossy().replace('\\', "/");
            if !is_image(&name) || name.split('/').any(|s| s == ".." || s.is_empty()) {
                return Ok(Box::new(std::io::sink()));
            }
            let sink = Sink(Arc::default());
            files.push((name, sink.clone()));
            Ok(Box::new(sink))
        })
        .map_err(rar_error)?;
    if files.is_empty() {
        return Err(CoreError::bad_book("the archive has no pictures"));
    }
    files.sort_by(|a, b| natural(&a.0, &b.0));
    let mut zip = zip::ZipWriter::new(Cursor::new(Vec::new()));
    let options = SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Stored)
        .last_modified_time(zip::DateTime::default());
    for (name, sink) in files {
        let data = std::mem::take(&mut *sink.0.lock().map_err(|_| CoreError::bad_book("poisoned"))?);
        zip.start_file(name, options).map_err(|e| CoreError::bad_book(e.to_string()))?;
        zip.write_all(&data)?;
    }
    Ok(zip.finish().map_err(|e| CoreError::bad_book(e.to_string()))?.into_inner())
}

fn rar_error(e: rars::Error) -> CoreError {
    CoreError::bad_book(format!("RAR: {e}"))
}

fn collect(root: &Path, dir: &Path, out: &mut Vec<(String, PathBuf)>) -> Result<()> {
    for entry in fs::read_dir(dir)? {
        let path = entry?.path();
        let Some(rel) = path.strip_prefix(root).ok().and_then(|p| p.to_str()).map(|s| s.replace('\\', "/")) else { continue };
        if rel.rsplit('/').next().is_some_and(|f| f.starts_with('.')) {
            continue;
        }
        if path.is_dir() {
            collect(root, &path, out)?;
        } else if is_image(&rel) {
            out.push((rel, path));
        }
    }
    Ok(())
}

/// `2.jpg` before `10.jpg`; case doesn't matter.
pub(crate) fn natural(a: &str, b: &str) -> Ordering {
    fn chunks(s: &str) -> Vec<(bool, String)> {
        let mut out: Vec<(bool, String)> = Vec::new();
        for c in s.to_lowercase().chars() {
            let digit = c.is_ascii_digit();
            match out.last_mut() {
                Some((d, run)) if *d == digit => run.push(c),
                _ => out.push((digit, c.to_string())),
            }
        }
        out
    }
    let (x, y) = (chunks(a), chunks(b));
    for (p, q) in x.iter().zip(&y) {
        let o = match (p, q) {
            ((true, m), (true, n)) => {
                let (m, n) = (m.trim_start_matches('0'), n.trim_start_matches('0'));
                m.len().cmp(&n.len()).then_with(|| m.cmp(n))
            }
            _ => p.1.cmp(&q.1),
        };
        if o != Ordering::Equal {
            return o;
        }
    }
    x.len().cmp(&y.len()).then_with(|| a.cmp(b))
}

pub fn build(tmp: &Path, id: &str, original: &Path, fallback_title: &str) -> Result<Manifest> {
    let mut zip = ZipArchive::new(fs::File::open(original)?).map_err(|e| CoreError::bad_book(e.to_string()))?;
    let mut names: Vec<String> = zip.file_names().flatten().filter(|n| is_image(n)).map(|n| n.to_string()).collect();
    names.sort_by(|a, b| {
        let dir = |n: &str| n.rsplit_once('/').map(|(d, _)| d.to_string()).unwrap_or_default();
        natural(&dir(a), &dir(b)).then_with(|| natural(a, b))
    });
    if names.is_empty() {
        return Err(CoreError::bad_book("the archive has no pictures"));
    }
    // One 话 per folder; a single folder holding everything is just the book.
    let folder = |n: &str| n.rsplit_once('/').map(|(d, _)| d.to_string());
    let mut groups: Vec<(Option<String>, Vec<String>)> = Vec::new();
    for n in names {
        let f = folder(&n);
        match groups.last_mut() {
            Some((g, list)) if *g == f => list.push(n),
            _ => groups.push((f, vec![n])),
        }
    }
    let single = groups.len() == 1;

    let pages = tmp.join("p");
    fs::create_dir_all(&pages)?;
    let mut sections = Vec::new();
    let mut toc = Vec::new();
    let mut n = 0u32;
    let mut cover = None;
    for (i, (folder, list)) in groups.iter().enumerate() {
        let mut files = Vec::with_capacity(list.len());
        for name in list {
            let ext = name.rsplit_once('.').map(|(_, e)| e.to_ascii_lowercase()).unwrap_or_else(|| "jpg".into());
            let file = format!("{n}.{ext}");
            let mut bytes = Vec::new();
            zip.by_name(name).map_err(|e| CoreError::bad_book(e.to_string()))?.read_to_end(&mut bytes)?;
            fs::write(pages.join(&file), &bytes)?;
            if cover.is_none() {
                let name = format!("cover.{ext}");
                fs::write(tmp.join(&name), &bytes)?;
                cover = Some(name);
            }
            files.push(file);
            n += 1;
        }
        fs::write(pages.join(format!("{i}.json")), serde_json::to_string(&files)?)?;
        let title = if single { None } else { folder.as_ref().map(|f| f.rsplit('/').next().unwrap_or(f).to_string()) };
        if let Some(t) = &title {
            toc.push(TocEntry { title: t.clone(), depth: 0, section: i as u32, anchor: None });
        }
        sections.push(SectionInfo {
            title,
            lang: None,
            styles: Vec::new(),
            body_class: None,
            linear: true,
            kind: Kind::Image,
            continued: false,
            sentences: 0,
            units: list.len() as u32,
            pages: list.len() as u32,
        });
    }
    // A minute for every four pages, roughly.
    let minutes = n.div_ceil(4).max(1);
    let manifest = Manifest {
        version: FORMAT_VERSION,
        id: id.to_string(),
        format: Format::Comic,
        title: fallback_title.to_string(),
        authors: Vec::new(),
        language: "und".into(),
        isbn: None,
        cover,
        start: 0,
        sections,
        toc,
        units: n,
        read_minutes: minutes,
        listen_minutes: 0,
    };
    fs::write(tmp.join("book.json"), serde_json::to_string_pretty(&manifest)?)?;
    Ok(manifest)
}

/// The pictures of a section, in order.
pub fn pages(dir: &Path, section: u32) -> Result<Vec<PathBuf>> {
    let text = fs::read_to_string(dir.join("p").join(format!("{section}.json"))).map_err(|_| CoreError::not_found("section"))?;
    let files: Vec<String> = serde_json::from_str(&text)?;
    Ok(files.into_iter().map(|f| dir.join("p").join(f)).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn imports_a_folder_and_an_archive() {
        let fixtures = PathBuf::from(format!("{}/../../fixtures/comics", env!("CARGO_MANIFEST_DIR")));
        let books = std::env::temp_dir().join(format!("yuyue-comic-{}", std::process::id()));
        let _ = fs::remove_dir_all(&books);
        fs::create_dir_all(&books).unwrap();

        let m = crate::book::import(&books, &fixtures.join("月下信使")).unwrap();
        assert_eq!((m.format, m.title.as_str(), m.language.as_str()), (Format::Comic, "月下信使", "und"));
        let titles: Vec<_> = m.sections.iter().map(|s| s.title.as_deref().unwrap_or("")).collect();
        assert_eq!(titles, ["第1话", "第2话"]);
        assert_eq!((m.sections[0].pages, m.sections[1].pages, m.units), (6, 5, 11));
        assert_eq!(m.toc.len(), 2);
        let dir = books.join(&m.id);
        let first = pages(&dir, 0).unwrap();
        assert!(first[0].ends_with("p/0.png") && first[5].ends_with("p/5.png") && first[0].is_file());
        assert!(pages(&dir, 1).unwrap()[0].ends_with("p/6.png"));
        assert!(dir.join("cover.png").is_file() && dir.join("original.cbz").is_file());
        // The same folder again is the same book.
        assert_eq!(crate::book::import(&books, &fixtures.join("月下信使")).unwrap().id, m.id);

        // The packed folder, as a CBZ with the files under one top folder: one 话 per sub-folder.
        let cbz = books.join("x.cbz");
        fs::write(&cbz, fs::read(dir.join("original.cbz")).unwrap()).unwrap();
        assert!(is_comic(&fs::read(&cbz).unwrap()));
        let again = crate::book::import(&books, &cbz).unwrap();
        assert_eq!(again.id, m.id);
        fs::remove_dir_all(&books).unwrap();
    }

    #[test]
    fn imports_a_rar() {
        let fixtures = PathBuf::from(format!("{}/../../fixtures/comics/月下信使", env!("CARGO_MANIFEST_DIR")));
        let mut files = Vec::new();
        collect(&fixtures, &fixtures, &mut files).unwrap();
        let books = std::env::temp_dir().join(format!("yuyue-cbr-{}", std::process::id()));
        let _ = fs::remove_dir_all(&books);
        fs::create_dir_all(&books).unwrap();
        let folder = crate::book::import(&books, &fixtures).unwrap();
        // Old and new RAR, compressed; a stray text file is left out.
        for version in [rars::ArchiveVersion::Rar29, rars::ArchiveVersion::Rar50] {
            let mut rar = rars::Builder::new(version);
            for (name, path) in &files {
                rar.add_bytes(name.replace('/', "\\").into_bytes(), fs::read(path).unwrap(), None, None).unwrap();
            }
            rar.add_bytes(b"readme.txt".to_vec(), b"hello".to_vec(), None, None).unwrap();
            let cbr = books.join("x.cbr");
            fs::write(&cbr, rar.to_bytes().unwrap()).unwrap();
            assert!(is_rar(&fs::read(&cbr).unwrap()));
            // The same pictures make the same book as the folder.
            let m = crate::book::import(&books, &cbr).unwrap();
            assert_eq!((m.format, m.id.as_str(), m.units), (Format::Comic, folder.id.as_str(), 11), "{version:?}");
        }
        fs::remove_dir_all(&books).unwrap();
    }

    #[test]
    fn sorts_like_people_do() {
        let mut v = vec!["p10.jpg", "p2.jpg", "P1.jpg", "p02b.jpg"];
        v.sort_by(|a, b| natural(a, b));
        assert_eq!(v, ["P1.jpg", "p2.jpg", "p02b.jpg", "p10.jpg"]);
        assert!(is_image("第1话/001.JPG"));
        assert!(!is_image("__MACOSX/第1话/._001.jpg"));
        assert!(!is_image("notes.txt"));
    }
}
