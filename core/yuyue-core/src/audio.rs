//! 有声书 on the shelf: a recording in one or more files, listened to on its own.
//!
//! ```text
//! books/<id>/
//!   book.json    the manifest: format `audio`, a section per chapter with its length (`ms`)
//!   audio.json   the files in order, each with its length
//!   a/<n>.<ext>  the files, copied in
//!   cover.jpg
//! ```
//!
//! A position is a chapter and the milliseconds into it, so progress, bookmarks and time
//! listened are kept as for any book. The app reads the files (lengths, chapter marks, tags,
//! cover) with the system's player and hands them over; the core keeps the order and the shelf.
//!
//! The id is a hash of each file's size and its first and last megabyte: the same recording
//! imported on another device is the same book, so its progress follows. The recording itself
//! stays on each device; 同步 carries the library only.

use std::cmp::Ordering;
use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::api::{BookSummary, YuyueCore, lock, now_ms};
use crate::book::{self, Format, Manifest, SectionInfo};
use crate::epub::{Kind, TocEntry};
use crate::error::{CoreError, Result};

/// One file of a recording, as the app read it.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AudioFile {
    pub path: String,
    pub seconds: f64,
}

/// Where a chapter begins, in seconds from the start of the whole recording.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AudioMark {
    pub title: Option<String>,
    pub start: f64,
}

/// A recording to bring in: its files in the order they play, and what the app read of them.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AudioImport {
    pub files: Vec<AudioFile>,
    pub title: String,
    pub authors: Vec<String>,
    /// The chapter marks in the files (an M4B's); none makes each file a chapter.
    pub marks: Vec<AudioMark>,
    /// The cover in the files' tags, JPEG or PNG.
    pub cover: Option<Vec<u8>>,
}

/// A recording on this device, for the player.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AudioRecording {
    /// Absolute paths, in order, and how long each is.
    pub files: Vec<AudioFile>,
    pub chapters: Vec<AudioChapter>,
    pub seconds: f64,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AudioChapter {
    /// None when the recording doesn't name it: the app calls it 第 n 集.
    pub title: Option<String>,
    /// Seconds from the start of the whole recording.
    pub start: f64,
    pub seconds: f64,
}

#[derive(Serialize, Deserialize)]
struct Stored {
    files: Vec<StoredFile>,
}

#[derive(Serialize, Deserialize)]
struct StoredFile {
    name: String,
    seconds: f64,
}

/// The recording's id: each file's size and first and last megabyte, in order.
pub fn audio_id(paths: &[&Path]) -> Result<String> {
    const EDGE: u64 = 1 << 20;
    let mut h = blake3::Hasher::new();
    h.update(b"yuyue-audio-1");
    for p in paths {
        let mut f = fs::File::open(p)?;
        let size = f.metadata()?.len();
        h.update(&size.to_le_bytes());
        let mut buf = vec![0; EDGE.min(size) as usize];
        f.read_exact(&mut buf)?;
        h.update(&buf);
        if size > EDGE {
            let tail = EDGE.min(size - EDGE);
            f.seek(SeekFrom::Start(size - tail))?;
            let mut buf = vec![0; tail as usize];
            f.read_exact(&mut buf)?;
            h.update(&buf);
        }
    }
    Ok(h.finalize().to_hex()[..32].to_string())
}

/// File names in the order they play: numbers compared as numbers, so 第2集 comes before 第10集.
pub fn natural_order(a: &str, b: &str) -> Ordering {
    let (mut x, mut y) = (a.chars().peekable(), b.chars().peekable());
    loop {
        match (x.peek().copied(), y.peek().copied()) {
            (None, None) => return a.cmp(b),
            (None, _) => return Ordering::Less,
            (_, None) => return Ordering::Greater,
            (Some(c), Some(d)) if c.is_ascii_digit() && d.is_ascii_digit() => {
                let take = |it: &mut std::iter::Peekable<std::str::Chars>| {
                    let mut s = String::new();
                    while let Some(c) = it.peek().copied().filter(char::is_ascii_digit) {
                        s.push(c);
                        it.next();
                    }
                    s
                };
                let (m, n) = (take(&mut x), take(&mut y));
                let (m, n) = (m.trim_start_matches('0'), n.trim_start_matches('0'));
                match m.len().cmp(&n.len()).then_with(|| m.cmp(n)) {
                    Ordering::Equal => {}
                    other => return other,
                }
            }
            (Some(c), Some(d)) => {
                let (c, d) = (c.to_lowercase().next().unwrap_or(c), d.to_lowercase().next().unwrap_or(d));
                if c != d {
                    return c.cmp(&d);
                }
                x.next();
                y.next();
            }
        }
    }
}

/// The chapters: the recording's own marks when it has them, else one per file.
fn chapters(files: &[AudioFile], marks: &[AudioMark]) -> Vec<AudioChapter> {
    let total: f64 = files.iter().map(|f| f.seconds).sum();
    let mut starts: Vec<(Option<String>, f64)> = if marks.is_empty() {
        let mut at = 0.0;
        files
            .iter()
            .map(|f| {
                let start = at;
                at += f.seconds;
                (None, start)
            })
            .collect()
    } else {
        let mut m: Vec<_> = marks.iter().filter(|m| m.start >= 0.0 && m.start < total).map(|m| (m.title.clone(), m.start)).collect();
        m.sort_by(|a, b| a.1.total_cmp(&b.1));
        m.dedup_by(|b, a| b.1 - a.1 < 0.5);
        m
    };
    // A first mark after the start leaves nothing before it unheard.
    match starts.first_mut() {
        Some(first) => first.1 = 0.0,
        None => starts.push((None, 0.0)),
    }
    let ends: Vec<f64> = starts.iter().skip(1).map(|s| s.1).chain([total]).collect();
    starts
        .into_iter()
        .zip(ends)
        .map(|((title, start), end)| AudioChapter {
            title: title.map(|t| t.trim().to_string()).filter(|t| !t.is_empty()),
            start,
            seconds: (end - start).max(0.0),
        })
        .collect()
}

fn guess_language(title: &str) -> &'static str {
    if title.chars().any(|c| ('\u{4e00}'..='\u{9fff}').contains(&c)) { "zh" } else { "en" }
}

#[uniffi::export]
impl YuyueCore {
    /// An M4B's chapter marks, read from the file, for a system player that doesn't give them;
    /// empty when it has none or can't be read.
    pub fn audio_chapter_marks(&self, path: String) -> Vec<AudioMark> {
        crate::m4b::chapter_marks(Path::new(&path)).unwrap_or_default()
    }

    /// The order files of one recording play in, by name (第2集 before 第10集).
    pub fn sort_audio_files(&self, paths: Vec<String>) -> Vec<String> {
        let name = |p: &String| Path::new(p).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let mut out = paths;
        out.sort_by(|a, b| natural_order(&name(a), &name(b)));
        out
    }

    /// Brings a recording onto the shelf, copying its files in. The same files again (here or
    /// on another device) give the same book.
    pub fn import_audiobook(&self, import: AudioImport) -> Result<BookSummary> {
        if import.files.is_empty() {
            return Err(CoreError::bad_book("no files"));
        }
        let paths: Vec<&Path> = import.files.iter().map(|f| Path::new(&f.path)).collect();
        let id = audio_id(&paths)?;
        if !matches!(book::load(&self.books_dir.join(&id)), Ok(m) if m.format == Format::Audio) {
            let manifest = book::build_into(&self.books_dir, &id, |tmp| build(tmp, &id, &import))?;
            lock(&self.manifests).insert(id.clone(), std::sync::Arc::new(manifest));
        }
        let m = self.manifest(&id)?;
        self.record_import(&m)?;
        self.summary(&id)
    }

    /// 长按改名: a chapter's own name, or none to have it called 第 n 集 again. Kept on this
    /// device with the recording.
    pub fn rename_audio_chapter(&self, book_id: String, chapter: u32, title: Option<String>) -> Result<BookSummary> {
        let dir = self.book_dir(&book_id)?;
        let mut m = (*self.manifest(&book_id)?).clone();
        if m.format != Format::Audio {
            return Err(CoreError::not_found("audiobook"));
        }
        let i = chapter as usize;
        let Some(section) = m.sections.get_mut(i) else { return Err(CoreError::not_found("chapter")) };
        section.title = title.map(|t| t.trim().to_string()).filter(|t| !t.is_empty());
        m.toc = m
            .sections
            .iter()
            .enumerate()
            .filter_map(|(i, s)| s.title.clone().map(|title| TocEntry { title, depth: 0, section: i as u32, anchor: None }))
            .collect();
        let tmp = dir.join(format!("book.json.{}", std::process::id()));
        fs::write(&tmp, serde_json::to_string_pretty(&m)?)?;
        fs::rename(&tmp, dir.join("book.json"))?;
        lock(&self.manifests).insert(book_id.clone(), std::sync::Arc::new(m));
        self.summary(&book_id)
    }

    /// The recording, when it's on this device.
    pub fn audio_recording(&self, book_id: String) -> Result<AudioRecording> {
        let m = self.manifest(&book_id)?;
        if m.format != Format::Audio {
            return Err(CoreError::not_found("audiobook"));
        }
        let dir = self.book_dir(&book_id)?;
        let stored: Stored = serde_json::from_str(&fs::read_to_string(dir.join("audio.json"))?)?;
        let files: Vec<AudioFile> = stored
            .files
            .into_iter()
            .map(|f| AudioFile { path: dir.join("a").join(&f.name).to_string_lossy().into_owned(), seconds: f.seconds })
            .collect();
        let mut at = 0.0;
        let chapters = m
            .sections
            .iter()
            .map(|s| {
                let (start, seconds) = (at, s.ms as f64 / 1000.0);
                at += seconds;
                AudioChapter { title: s.title.clone(), start, seconds }
            })
            .collect();
        Ok(AudioRecording { seconds: files.iter().map(|f| f.seconds).sum(), files, chapters })
    }
}

fn build(tmp: &Path, id: &str, import: &AudioImport) -> Result<Manifest> {
    fs::create_dir_all(tmp.join("a"))?;
    let mut stored = Vec::new();
    for (i, f) in import.files.iter().enumerate() {
        let ext = Path::new(&f.path).extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_else(|| "m4a".into());
        let name = format!("{i:03}.{ext}");
        fs::copy(&f.path, tmp.join("a").join(&name))?;
        stored.push(StoredFile { name, seconds: f.seconds });
    }
    fs::write(tmp.join("audio.json"), serde_json::to_string_pretty(&Stored { files: stored })?)?;
    let cover = match &import.cover {
        Some(image) if !image.is_empty() => {
            let name = if image.starts_with(&[0x89, b'P', b'N', b'G']) { "cover.png" } else { "cover.jpg" };
            fs::write(tmp.join(name), image)?;
            Some(name.to_string())
        }
        _ => None,
    };
    let chapters = chapters(&import.files, &import.marks);
    let sections: Vec<SectionInfo> = chapters
        .iter()
        .map(|c| SectionInfo {
            title: c.title.clone(),
            lang: None,
            styles: Vec::new(),
            body_class: None,
            linear: true,
            kind: Kind::Text,
            continued: false,
            sentences: 0,
            units: (c.seconds.round() as u32).max(1),
            pages: 0,
            ms: ((c.seconds * 1000.0).round() as u32).max(1),
        })
        .collect();
    let toc = chapters
        .iter()
        .enumerate()
        .filter_map(|(i, c)| c.title.clone().map(|title| TocEntry { title, depth: 0, section: i as u32, anchor: None }))
        .collect();
    let total: f64 = import.files.iter().map(|f| f.seconds).sum();
    let title = import.title.trim();
    let manifest = Manifest {
        version: book::FORMAT_VERSION,
        id: id.to_string(),
        format: Format::Audio,
        title: title.to_string(),
        authors: import.authors.iter().map(|a| a.trim().to_string()).filter(|a| !a.is_empty()).collect(),
        language: guess_language(title).into(),
        isbn: None,
        cover,
        start: 0,
        units: sections.iter().map(|s| s.units).sum(),
        sections,
        toc,
        read_minutes: 0,
        listen_minutes: ((total / 60.0).round() as u32).max(1),
    };
    fs::write(tmp.join("book.json"), serde_json::to_string_pretty(&manifest)?)?;
    Ok(manifest)
}

impl YuyueCore {
    /// The library's record of a book just imported (title, format, 加入时间), as `import_book`
    /// writes it.
    pub(crate) fn record_import(&self, manifest: &Manifest) -> Result<()> {
        let mut store = lock(&self.store);
        let entity = format!("book/{}", manifest.id);
        let existing = store.fields(&entity)?;
        let mut fields = vec![
            ("title", json!(manifest.title)),
            ("authors", json!(manifest.authors)),
            ("language", json!(manifest.language)),
            ("format", json!(manifest.format)),
        ];
        if let Some(isbn) = &manifest.isbn {
            fields.push(("isbn", json!(isbn)));
        }
        if existing.get("deleted") != Some(&json!(false)) {
            fields.push(("deleted", json!(false)));
        }
        if !existing.contains_key("addedAt") || existing.get("deleted") == Some(&json!(true)) {
            fields.push(("addedAt", json!(now_ms())));
        }
        let fields: Vec<_> = fields.into_iter().filter(|(k, v)| existing.get(*k) != Some(v)).collect();
        if !fields.is_empty() {
            store.set_fields(&entity, &fields)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::Position;

    fn temp() -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("yuyue-audio-{}", getrandom::u64().unwrap()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn files(dir: &Path, n: usize) -> Vec<AudioFile> {
        (0..n)
            .map(|i| {
                let p = dir.join(format!("活着_第{}集.mp3", i + 1));
                fs::write(&p, vec![i as u8; 3000 + i]).unwrap();
                AudioFile { path: p.to_string_lossy().into_owned(), seconds: 600.0 }
            })
            .collect()
    }

    #[test]
    fn numbers_in_names_sort_as_numbers() {
        let mut names = vec!["第10集.mp3", "第2集.mp3", "第1集.mp3", "序.mp3", "第02集b.mp3"];
        names.sort_by(|a, b| natural_order(a, b));
        assert_eq!(names, ["序.mp3", "第1集.mp3", "第2集.mp3", "第02集b.mp3", "第10集.mp3"]);
    }

    #[test]
    fn marks_or_files_make_the_chapters() {
        let f = |s| AudioFile { path: String::new(), seconds: s };
        let by_file = chapters(&[f(10.0), f(20.0)], &[]);
        assert_eq!(by_file.iter().map(|c| (c.start, c.seconds)).collect::<Vec<_>>(), [(0.0, 10.0), (10.0, 20.0)]);
        let mark = |t: &str, s| AudioMark { title: Some(t.into()), start: s };
        let marked = chapters(&[f(30.0)], &[mark("二", 12.0), mark("一", 0.2), mark("dup", 12.1), mark("past", 40.0)]);
        assert_eq!(marked.iter().map(|c| (c.title.clone().unwrap(), c.start, c.seconds)).collect::<Vec<_>>(), [("一".into(), 0.0, 12.0), ("二".into(), 12.0, 18.0)]);
    }

    #[test]
    fn a_recording_is_a_book_on_the_shelf() {
        let dir = temp();
        let core = YuyueCore::open(dir.join("lib").to_string_lossy().into_owned(), "Mac".into(), "macos".into()).unwrap();
        let import = AudioImport { files: files(&dir, 3), title: " 活着 ".into(), authors: vec!["余华".into()], marks: vec![], cover: None };
        let b = core.import_audiobook(import.clone()).unwrap();
        assert_eq!(b.format, crate::api::BookFormat::Audio);
        assert_eq!((b.title.as_str(), b.listen_minutes, b.available), ("活着", 30, true));
        // The same files again are the same book.
        assert_eq!(core.import_audiobook(import).unwrap().id, b.id);
        assert_eq!(core.books().unwrap().len(), 1);

        let a = core.audio_recording(b.id.clone()).unwrap();
        assert_eq!(a.chapters.len(), 3);
        assert_eq!((a.chapters[2].start, a.seconds), (1200.0, 1800.0));
        assert!(Path::new(&a.files[1].path).is_file());
        let d = core.book(b.id.clone()).unwrap();
        assert_eq!(d.sections[0].ms, 600_000);

        // A chapter renamed, and back.
        core.rename_audio_chapter(b.id.clone(), 1, Some(" 中间 ".into())).unwrap();
        assert_eq!(core.audio_recording(b.id.clone()).unwrap().chapters[1].title.as_deref(), Some("中间"));
        core.rename_audio_chapter(b.id.clone(), 1, None).unwrap();
        assert_eq!(core.audio_recording(b.id.clone()).unwrap().chapters[1].title, None);

        // Halfway through the second chapter is halfway through the book.
        core.save_progress(b.id.clone(), Position { section: 1, sentence: 300_000 }).unwrap();
        assert!((core.summary(&b.id).unwrap().progress - 0.5).abs() < 1e-6);
        fs::remove_dir_all(dir).ok();
    }
}
