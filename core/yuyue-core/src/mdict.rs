//! 导入 MDict 词典: a `.mdx` file read once into a small database of its own beside the library,
//! then looked up before the system dictionary. Dictionaries stay on the device they were
//! imported on (they are often hundreds of megabytes); only the list of them is kept here.
//!
//! The `.mdx` layout (engine 1.2 and 2.0): a UTF-16 XML header; the keyword section (a block
//! index, then key blocks of "record offset + headword"); the record section (blocks of the
//! entries' HTML, one stream across the blocks). Blocks are stored, LZO or zlib; with
//! `Encrypted="2"` the key block index is lightly scrambled with a RIPEMD-128 key.

use std::io::Read;
use std::path::{Path, PathBuf};

use ripemd::{Digest, Ripemd128};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};

use crate::api::{YuyueCore, now_ms};
use crate::error::{CoreError, Result};

/// One imported dictionary.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct DictionaryInfo {
    pub id: String,
    pub title: String,
    pub entries: u64,
    /// Looked up, in the list's order, when on.
    pub enabled: bool,
    pub added_at: i64,
}

/// What a dictionary says about a word.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct DictEntry {
    pub dictionary: String,
    pub headword: String,
    /// The entry as the dictionary writes it (HTML), for 完整释义.
    pub html: String,
    /// The entry as plain text, one line, for the word card.
    pub summary: String,
}

#[uniffi::export]
impl YuyueCore {
    /// Reads a `.mdx` file into the library's dictionaries. Can take a while for a big one; call
    /// it off the main thread.
    pub fn import_dictionary(&self, path: String) -> Result<DictionaryInfo> {
        let dir = self.dicts_dir()?;
        let id = format!("{:016x}", now_ms() as u64 ^ blake3::hash(path.as_bytes()).as_bytes()[0] as u64);
        let db_path = dir.join(format!("{id}.sqlite"));
        let parsed = (|| {
            let mut conn = Connection::open(&db_path)?;
            conn.execute_batch(
                "PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF;
                 CREATE TABLE entry (word TEXT NOT NULL, lower TEXT NOT NULL, body TEXT NOT NULL);",
            )?;
            let tx = conn.transaction()?;
            let header = {
                let mut insert = tx.prepare("INSERT INTO entry (word, lower, body) VALUES (?1, ?2, ?3)")?;
                read_mdx(Path::new(&path), |word, body| {
                    insert.execute(params![word, word.to_lowercase(), body])?;
                    Ok(())
                })?
            };
            tx.execute_batch("CREATE INDEX entry_lower ON entry (lower);")?;
            tx.commit()?;
            let count: i64 = conn.query_row("SELECT count(*) FROM entry", [], |r| r.get(0))?;
            let count = count as u64;
            Ok::<_, CoreError>((header, count))
        })();
        let (header, count) = match parsed {
            Ok(v) => v,
            Err(e) => {
                let _ = std::fs::remove_file(&db_path);
                return Err(e);
            }
        };
        let fallback = Path::new(&path).file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        let title = header.title.filter(|t| !t.trim().is_empty() && !t.contains("Title (No HTML code allowed)")).unwrap_or(fallback);
        let info = DictionaryInfo { id, title, entries: count, enabled: true, added_at: now_ms() };
        let mut list = self.dictionaries()?;
        list.push(info.clone());
        self.save_dictionaries(&list)?;
        Ok(info)
    }

    /// The imported dictionaries, in the order they are looked up.
    pub fn dictionaries(&self) -> Result<Vec<DictionaryInfo>> {
        let file = self.dicts_dir()?.join("list.json");
        match std::fs::read(&file) {
            Ok(bytes) => Ok(serde_json::from_slice(&bytes).unwrap_or_default()),
            Err(_) => Ok(Vec::new()),
        }
    }

    /// Turns one on or off.
    pub fn set_dictionary(&self, id: String, enabled: bool) -> Result<()> {
        let mut list = self.dictionaries()?;
        if let Some(d) = list.iter_mut().find(|d| d.id == id) {
            d.enabled = enabled;
        }
        self.save_dictionaries(&list)
    }

    pub fn order_dictionaries(&self, ids: Vec<String>) -> Result<()> {
        let mut list = self.dictionaries()?;
        list.sort_by_key(|d| ids.iter().position(|i| *i == d.id).unwrap_or(usize::MAX));
        self.save_dictionaries(&list)
    }

    pub fn remove_dictionary(&self, id: String) -> Result<()> {
        let mut list = self.dictionaries()?;
        list.retain(|d| d.id != id);
        self.save_dictionaries(&list)?;
        let _ = std::fs::remove_file(self.dicts_dir()?.join(format!("{id}.sqlite")));
        Ok(())
    }

    /// The first entry the dictionaries that are on have for `word`, trying its base form too
    /// (fortunes → fortune, carried → carry), following the dictionaries' cross-references.
    pub fn look_up(&self, word: String) -> Result<Option<DictEntry>> {
        let list = self.dictionaries()?;
        if !list.iter().any(|d| d.enabled) {
            return Ok(None);
        }
        let dir = self.dicts_dir()?;
        let candidates = base_forms(&word);
        for d in list.iter().filter(|d| d.enabled) {
            let Ok(conn) = Connection::open_with_flags(dir.join(format!("{}.sqlite", d.id)), rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY) else {
                continue;
            };
            for c in &candidates {
                if let Some((headword, html)) = find(&conn, c)? {
                    let summary = summarize(&html, &headword);
                    return Ok(Some(DictEntry { dictionary: d.title.clone(), headword, html, summary }));
                }
            }
        }
        Ok(None)
    }
}

impl YuyueCore {
    fn dicts_dir(&self) -> Result<PathBuf> {
        let dir = self.books_dir.parent().map(|p| p.join("dicts")).ok_or_else(|| CoreError::not_found("library"))?;
        std::fs::create_dir_all(&dir)?;
        Ok(dir)
    }

    fn save_dictionaries(&self, list: &[DictionaryInfo]) -> Result<()> {
        let bytes = serde_json::to_vec_pretty(list).map_err(|e| CoreError::Invalid { detail: e.to_string() })?;
        std::fs::write(self.dicts_dir()?.join("list.json"), bytes)?;
        Ok(())
    }
}

/// The entry for `word`, following `@@@LINK=` a few times.
fn find(conn: &Connection, word: &str) -> Result<Option<(String, String)>> {
    let mut want = word.to_lowercase();
    for _ in 0..4 {
        let row: Option<(String, String)> = conn
            .query_row("SELECT word, body FROM entry WHERE lower = ?1 LIMIT 1", [&want], |r| Ok((r.get(0)?, r.get(1)?)))
            .optional()?;
        let Some((headword, body)) = row else { return Ok(None) };
        match body.trim().strip_prefix("@@@LINK=") {
            Some(next) => want = next.trim().to_lowercase(),
            None => return Ok(Some((headword, body))),
        }
    }
    Ok(None)
}

/// The word as clicked, then what it may be an inflection of.
fn base_forms(word: &str) -> Vec<String> {
    let w = word.trim().trim_matches(|c: char| !c.is_alphanumeric() && c != '-' && c != '\'').to_string();
    let lower = w.to_lowercase();
    let mut out = vec![w.clone()];
    let mut push = |s: String| {
        if !s.is_empty() && !out.contains(&s) {
            out.push(s);
        }
    };
    push(lower.clone());
    if lower.chars().all(|c| c.is_ascii_alphabetic() || c == '\'') && lower.len() > 3 {
        let l = lower.as_str();
        if let Some(s) = l.strip_suffix("'s") { push(s.into()); }
        if let Some(s) = l.strip_suffix("ies") { push(format!("{s}y")); }
        if let Some(s) = l.strip_suffix("ied") { push(format!("{s}y")); }
        if let Some(s) = l.strip_suffix("es") { push(s.into()); }
        if let Some(s) = l.strip_suffix('s') { push(s.into()); }
        if let Some(s) = l.strip_suffix("ed") {
            push(s.into());
            push(format!("{s}e"));
            if let Some(t) = undouble(s) { push(t); }
        }
        if let Some(s) = l.strip_suffix("ing") {
            push(s.into());
            push(format!("{s}e"));
            if let Some(t) = undouble(s) { push(t); }
        }
        if let Some(s) = l.strip_suffix("er") { push(s.into()); }
        if let Some(s) = l.strip_suffix("est") { push(s.into()); }
        if let Some(s) = l.strip_suffix("ly") { push(s.into()); }
    }
    out
}

/// stopp → stop.
fn undouble(s: &str) -> Option<String> {
    let b = s.as_bytes();
    (b.len() > 2 && b[b.len() - 1] == b[b.len() - 2]).then(|| s[..s.len() - 1].to_string())
}

/// The entry as one line of text: tags out, the headword and its repeats dropped from the front,
/// cut at about 80 characters.
fn summarize(html: &str, headword: &str) -> String {
    let no_style = strip_between(&strip_between(html, "<style", "</style>"), "<script", "</script>");
    let mut text = String::with_capacity(no_style.len());
    let mut in_tag = false;
    for c in no_style.chars() {
        match c {
            '<' => {
                in_tag = true;
                text.push(' ');
            }
            '>' => in_tag = false,
            _ if !in_tag => text.push(c),
            _ => {}
        }
    }
    let text = text.replace("&nbsp;", " ").replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&#39;", "'");
    let mut line = text.split_whitespace().collect::<Vec<_>>().join(" ");
    let lower = headword.to_lowercase();
    while line.to_lowercase().starts_with(&lower) && !lower.is_empty() {
        line = line[headword.len().min(line.len())..].trim_start().to_string();
    }
    if line.chars().count() > 80 {
        line = line.chars().take(78).collect::<String>() + "…";
    }
    line
}

fn strip_between(s: &str, open: &str, close: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    loop {
        let lower = rest.to_lowercase();
        match lower.find(open) {
            Some(i) => {
                out.push_str(&rest[..i]);
                match lower[i..].find(close) {
                    Some(j) => rest = &rest[i + j + close.len()..],
                    None => return out,
                }
            }
            None => {
                out.push_str(rest);
                return out;
            }
        }
    }
}

// MARK: Reading a .mdx

#[derive(Default, Debug)]
pub(crate) struct Header {
    pub(crate) title: Option<String>,
}

#[derive(Clone, Copy, PartialEq)]
enum Encoding {
    Utf8,
    Utf16,
    Gb18030,
    Big5,
}

struct Reader<'a> {
    data: &'a [u8],
    at: usize,
}

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8]> {
        let end = self.at.checked_add(n).filter(|e| *e <= self.data.len()).ok_or_else(|| bad("the file ends too early"))?;
        let out = &self.data[self.at..end];
        self.at = end;
        Ok(out)
    }

    fn number(&mut self, wide: bool) -> Result<u64> {
        Ok(if wide {
            u64::from_be_bytes(self.take(8)?.try_into().unwrap())
        } else {
            u32::from_be_bytes(self.take(4)?.try_into().unwrap()) as u64
        })
    }
}

fn bad(why: &str) -> CoreError {
    CoreError::Invalid { detail: format!("not a dictionary this app can read ({why})") }
}

/// Reads every headword and its entry, in the file's order, into `each`.
pub(crate) fn read_mdx(path: &Path, mut each: impl FnMut(&str, &str) -> Result<()>) -> Result<Header> {
    let data = std::fs::read(path)?;
    let mut r = Reader { data: &data, at: 0 };

    // The header: XML in UTF-16LE.
    let header_len = r.number(false)? as usize;
    let header_bytes = r.take(header_len)?;
    r.take(4)?;
    let header_text = String::from_utf16_lossy(&header_bytes.as_chunks::<2>().0.iter().map(|c| u16::from_le_bytes([c[0], c[1]])).collect::<Vec<_>>());
    let attr = |name: &str| -> Option<String> {
        let key = format!("{name}=\"");
        let start = header_text.find(&key)? + key.len();
        let end = header_text[start..].find('"')? + start;
        Some(unescape_xml(&header_text[start..end]))
    };
    if attr("GeneratedByEngineVersion").is_none() && !header_text.contains("<Dictionary") {
        return Err(bad("no MDict header"));
    }
    let version: f64 = attr("GeneratedByEngineVersion").and_then(|v| v.trim().parse().ok()).unwrap_or(2.0);
    if version >= 3.0 {
        return Err(bad("MDict 3 files aren't supported yet"));
    }
    let wide = version >= 2.0;
    let encrypted: u32 = match attr("Encrypted").as_deref() {
        Some("Yes") => 1,
        Some(v) => v.trim().parse().unwrap_or(0),
        None => 0,
    };
    if encrypted & 1 != 0 {
        return Err(bad("it needs a registration code"));
    }
    let encoding = match attr("Encoding").unwrap_or_default().to_uppercase().as_str() {
        "UTF-16" | "UTF16" => Encoding::Utf16,
        "GBK" | "GB2312" | "GB18030" => Encoding::Gb18030,
        "BIG5" | "BIG-5" => Encoding::Big5,
        _ => Encoding::Utf8,
    };

    // The keyword section.
    let num_key_blocks = r.number(wide)?;
    let _num_entries = r.number(wide)?;
    if wide {
        r.number(wide)?; // the block index's size unpacked
    }
    let info_size = r.number(wide)? as usize;
    let key_blocks_size = r.number(wide)? as usize;
    if wide {
        r.take(4)?;
    }
    let mut info = r.take(info_size)?.to_vec();
    let key_blocks = r.take(key_blocks_size)?;
    if wide {
        if encrypted & 2 != 0 {
            info = unscramble(&info);
        }
        info = unpack(&info, None)?;
    }
    let sizes = key_block_sizes(&info, num_key_blocks, wide, encoding)?;

    let mut keys: Vec<(u64, String)> = Vec::new();
    let mut at = 0usize;
    for (packed, unpacked) in sizes {
        let block = key_blocks.get(at..at + packed).ok_or_else(|| bad("a key block runs past the end"))?;
        at += packed;
        let raw = unpack(block, Some(unpacked))?;
        let mut k = Reader { data: &raw, at: 0 };
        while k.at < raw.len() {
            let offset = k.number(wide)?;
            let text = read_terminated(&mut k, encoding)?;
            keys.push((offset, text));
        }
    }

    // The record section.
    let num_record_blocks = r.number(wide)?;
    let _ = r.number(wide)?;
    let _ = r.number(wide)?;
    let _ = r.number(wide)?;
    let mut blocks = Vec::with_capacity(num_record_blocks as usize);
    for _ in 0..num_record_blocks {
        blocks.push((r.number(wide)? as usize, r.number(wide)? as usize));
    }
    // The entries' text is one stream across the blocks: walk the keys in order through it.
    let mut key_i = 0usize;
    let mut stream_start = 0u64;
    let mut carry: Vec<u8> = Vec::new();
    for (packed, unpacked) in blocks {
        let raw = unpack(r.take(packed)?, Some(unpacked))?;
        let mut buf = std::mem::take(&mut carry);
        let buf_start = stream_start - buf.len() as u64;
        buf.extend_from_slice(&raw);
        stream_start += raw.len() as u64;
        while key_i < keys.len() {
            let (offset, ref word) = keys[key_i];
            let end = keys.get(key_i + 1).map(|k| k.0).unwrap_or(stream_start);
            if end > stream_start {
                break;
            }
            let (s, e) = ((offset.saturating_sub(buf_start)) as usize, (end.saturating_sub(buf_start)) as usize);
            if let Some(bytes) = buf.get(s..e.max(s)) {
                let body = decode(bytes, encoding);
                each(word, body.trim_end_matches('\0').trim_end())?;
            }
            key_i += 1;
        }
        // What the next entry has begun in this block goes on into the next.
        if let Some(&(offset, _)) = keys.get(key_i) {
            let from = (offset.saturating_sub(buf_start)) as usize;
            carry = buf.get(from..).map(|b| b.to_vec()).unwrap_or_default();
        }
    }
    Ok(Header { title: attr("Title") })
}

/// Each key block's packed and unpacked size, from the block index.
fn key_block_sizes(info: &[u8], count: u64, wide: bool, encoding: Encoding) -> Result<Vec<(usize, usize)>> {
    let mut r = Reader { data: info, at: 0 };
    let unit = if encoding == Encoding::Utf16 { 2 } else { 1 };
    let term = if wide { 1 } else { 0 };
    let mut out = Vec::with_capacity(count as usize);
    for _ in 0..count {
        r.number(wide)?; // entries in the block
        for _ in 0..2 {
            // its first and last headword
            let len = if wide { u16::from_be_bytes(r.take(2)?.try_into().unwrap()) as usize } else { r.take(1)?[0] as usize };
            r.take((len + term) * unit)?;
        }
        let packed = r.number(wide)? as usize;
        let unpacked = r.number(wide)? as usize;
        out.push((packed, unpacked));
    }
    Ok(out)
}

/// A block: four bytes for how it is packed, four of checksum, then the data.
fn unpack(block: &[u8], unpacked: Option<usize>) -> Result<Vec<u8>> {
    if block.len() < 8 {
        return Err(bad("a block is too short"));
    }
    let body = &block[8..];
    match block[0] {
        0 => Ok(body.to_vec()),
        1 => lzo1x::decompress(body, unpacked.unwrap_or(body.len() * 8)).map_err(|_| bad("an LZO block didn't unpack")),
        2 => {
            let mut out = Vec::with_capacity(unpacked.unwrap_or(body.len() * 4));
            flate2::read::ZlibDecoder::new(body).read_to_end(&mut out).map_err(|_| bad("a zlib block didn't unpack"))?;
            Ok(out)
        }
        _ => Err(bad("a block is packed in a way this app doesn't know")),
    }
}

/// `Encrypted="2"`: the key block index after its first eight bytes, unscrambled with
/// RIPEMD-128(its checksum + 0x3695).
fn unscramble(block: &[u8]) -> Vec<u8> {
    if block.len() < 8 {
        return block.to_vec();
    }
    let mut hasher = Ripemd128::new();
    hasher.update(&block[4..8]);
    hasher.update(0x3695u32.to_le_bytes());
    let key = hasher.finalize();
    let mut out = block[..8].to_vec();
    let mut previous = 0x36u8;
    for (i, &b) in block[8..].iter().enumerate() {
        let t = b.rotate_left(4) ^ previous ^ (i as u8) ^ key[i % key.len()];
        previous = b;
        out.push(t);
    }
    out
}

fn read_terminated(r: &mut Reader, encoding: Encoding) -> Result<String> {
    let start = r.at;
    if encoding == Encoding::Utf16 {
        while r.at + 1 < r.data.len() && !(r.data[r.at] == 0 && r.data[r.at + 1] == 0) {
            r.at += 2;
        }
        let text = decode(&r.data[start..r.at], encoding);
        r.at = (r.at + 2).min(r.data.len());
        Ok(text)
    } else {
        while r.at < r.data.len() && r.data[r.at] != 0 {
            r.at += 1;
        }
        let text = decode(&r.data[start..r.at], encoding);
        r.at = (r.at + 1).min(r.data.len());
        Ok(text)
    }
}

fn decode(bytes: &[u8], encoding: Encoding) -> String {
    match encoding {
        Encoding::Utf8 => String::from_utf8_lossy(bytes).into_owned(),
        Encoding::Utf16 => encoding_rs::UTF_16LE.decode(bytes).0.into_owned(),
        Encoding::Gb18030 => encoding_rs::GB18030.decode(bytes).0.into_owned(),
        Encoding::Big5 => encoding_rs::BIG5.decode(bytes).0.into_owned(),
    }
}

fn unescape_xml(s: &str) -> String {
    s.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'").replace("&amp;", "&")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    /// A small engine-2.0 file, built the way MdxBuilder writes one: zlib blocks, the key block
    /// index scrambled (Encrypted="2"), the entries split over two record blocks.
    fn write_mdx(path: &Path, entries: &[(&str, &str)]) {
        fn zlib(data: &[u8]) -> Vec<u8> {
            let mut e = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
            e.write_all(data).unwrap();
            let body = e.finish().unwrap();
            let mut out = vec![2, 0, 0, 0];
            out.extend_from_slice(&adler(data).to_be_bytes());
            out.extend(body);
            out
        }
        fn adler(data: &[u8]) -> u32 {
            let (mut a, mut b) = (1u32, 0u32);
            for &x in data {
                a = (a + x as u32) % 65521;
                b = (b + a) % 65521;
            }
            (b << 16) | a
        }
        fn scramble(block: &[u8]) -> Vec<u8> {
            let mut hasher = Ripemd128::new();
            hasher.update(&block[4..8]);
            hasher.update(0x3695u32.to_le_bytes());
            let key = hasher.finalize();
            let mut out = block[..8].to_vec();
            let mut previous = 0x36u8;
            for (i, &plain) in block[8..].iter().enumerate() {
                let b = (plain ^ previous ^ (i as u8) ^ key[i % key.len()]).rotate_right(4);
                previous = b;
                out.push(b);
            }
            out
        }
        let header = r#"<Dictionary GeneratedByEngineVersion="2.0" RequiredEngineVersion="2.0" Encrypted="2" Encoding="UTF-8" Format="Html" Title="Test Dict" />"#;
        let header16: Vec<u8> = header.encode_utf16().flat_map(|u| u.to_le_bytes()).chain([0, 0]).collect();
        // Records and keys.
        let mut records = Vec::new();
        let mut keys = Vec::new();
        for (word, body) in entries {
            keys.extend_from_slice(&(records.len() as u64).to_be_bytes());
            keys.extend_from_slice(word.as_bytes());
            keys.push(0);
            records.extend_from_slice(body.as_bytes());
            records.push(0);
        }
        let key_block = zlib(&keys);
        let mut info = Vec::new();
        info.extend_from_slice(&(entries.len() as u64).to_be_bytes());
        for w in [entries[0].0, entries[entries.len() - 1].0] {
            info.extend_from_slice(&(w.len() as u16).to_be_bytes());
            info.extend_from_slice(w.as_bytes());
            info.push(0);
        }
        info.extend_from_slice(&(key_block.len() as u64).to_be_bytes());
        info.extend_from_slice(&(keys.len() as u64).to_be_bytes());
        let info_packed = scramble(&zlib(&info));
        let split = records.len() / 2;
        let (r1, r2) = (zlib(&records[..split]), zlib(&records[split..]));

        let mut f = Vec::new();
        f.extend_from_slice(&(header16.len() as u32).to_be_bytes());
        f.extend_from_slice(&header16);
        f.extend_from_slice(&adler(&header16).to_le_bytes());
        for n in [1u64, entries.len() as u64, info.len() as u64, info_packed.len() as u64, key_block.len() as u64] {
            f.extend_from_slice(&n.to_be_bytes());
        }
        f.extend_from_slice(&[0, 0, 0, 0]);
        f.extend_from_slice(&info_packed);
        f.extend_from_slice(&key_block);
        for n in [2u64, entries.len() as u64, 32, (r1.len() + r2.len()) as u64] {
            f.extend_from_slice(&n.to_be_bytes());
        }
        for (packed, unpacked) in [(r1.len(), split), (r2.len(), records.len() - split)] {
            f.extend_from_slice(&(packed as u64).to_be_bytes());
            f.extend_from_slice(&(unpacked as u64).to_be_bytes());
        }
        f.extend_from_slice(&r1);
        f.extend_from_slice(&r2);
        std::fs::write(path, f).unwrap();
    }

    /// `YUYUE_WRITE_MDX=path cargo test -p yuyue-core write_sample_mdx -- --ignored` writes the
    /// test dictionary to `path`, to try 导入 MDict 词典 in the apps.
    #[test]
    #[ignore]
    fn write_sample_mdx() {
        let path = std::env::var("YUYUE_WRITE_MDX").expect("YUYUE_WRITE_MDX");
        write_mdx(Path::new(&path), &[("fortune", "<div><b>fortune</b> n. 财富，大笔的钱；运气</div><p>Example: <i>a man of good fortune</i></p>"), ("fortunes", "@@@LINK=fortune"), ("possession", "<b>possession</b> n. 拥有；财产")]);
    }

    #[test]
    fn reads_an_mdx_and_looks_words_up() {
        let dir = std::env::temp_dir().join(format!("yuyue-mdict-{}", now_ms()));
        std::fs::create_dir_all(&dir).unwrap();
        let mdx = dir.join("test.mdx");
        write_mdx(
            &mdx,
            &[
                ("carry", "<b>carry</b> /ˈkæri/ <i>v.</i> 携带；运送"),
                ("fortune", "<div><b>fortune</b> n. 财富，大笔的钱；运气</div>"),
                ("fortunes", "@@@LINK=fortune"),
                ("zebra", "<style>.x{}</style>n. 斑马"),
            ],
        );
        let mut seen = Vec::new();
        let header = read_mdx(&mdx, |w, b| {
            seen.push((w.to_string(), b.to_string()));
            Ok(())
        })
        .unwrap();
        assert_eq!(header.title.as_deref(), Some("Test Dict"));
        assert_eq!(seen.len(), 4);
        assert_eq!(seen[3], ("zebra".into(), "<style>.x{}</style>n. 斑马".into()));

        let core = YuyueCore::open(dir.join("lib").to_string_lossy().into(), "test".into(), "test".into()).unwrap();
        let info = core.import_dictionary(mdx.to_string_lossy().into()).unwrap();
        assert_eq!((info.title.as_str(), info.entries), ("Test Dict", 4));
        let e = core.look_up("Fortunes".into()).unwrap().unwrap();
        assert_eq!((e.headword.as_str(), e.summary.as_str()), ("fortune", "n. 财富，大笔的钱；运气"));
        assert_eq!(core.look_up("carried".into()).unwrap().unwrap().summary, "/ˈkæri/ v. 携带；运送");
        assert_eq!(core.look_up("zebra".into()).unwrap().unwrap().summary, "n. 斑马");
        assert!(core.look_up("unknown".into()).unwrap().is_none());
        core.set_dictionary(info.id.clone(), false).unwrap();
        assert!(core.look_up("zebra".into()).unwrap().is_none());
        core.remove_dictionary(info.id).unwrap();
        assert!(core.dictionaries().unwrap().is_empty());
    }
}
