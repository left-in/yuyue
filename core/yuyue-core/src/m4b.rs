//! An M4B's (or M4A's) chapter marks, read from the file itself, for platforms whose player
//! doesn't give them (Android). Two places hold them:
//!
//! - `moov/udta/chpl`, Nero's list: each mark's start (100 ns units) and title;
//! - a text track the audio track points to through `tref/chap` (QuickTime, iTunes, Audible):
//!   each sample is a chapter, its title in the sample's text, its start from the track's
//!   sample times.
//!
//! Only the boxes on the way are read; the audio isn't.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use crate::audio::AudioMark;
use crate::error::Result;

/// The chapter marks in the file, in seconds from its start; empty when it has none.
pub fn chapter_marks(path: &Path) -> Result<Vec<AudioMark>> {
    let mut f = File::open(path)?;
    let len = f.metadata()?.len();
    let Some(moov) = find(&mut f, 0, len, b"moov")? else { return Ok(Vec::new()) };
    let moov = read_body(&mut f, moov)?;
    let mut marks = quicktime(&mut f, &moov)?;
    if marks.is_empty() {
        marks = nero(&moov);
    }
    marks.sort_by(|a, b| a.start.total_cmp(&b.start));
    Ok(marks)
}

#[derive(Clone, Copy)]
struct Span {
    /// Where the body starts and how long it is.
    at: u64,
    len: u64,
}

/// The first box called `name` among the boxes in `[at, at + len)` of the file.
fn find(f: &mut File, at: u64, len: u64, name: &[u8; 4]) -> Result<Option<Span>> {
    let end = at + len;
    let mut pos = at;
    while pos + 8 <= end {
        f.seek(SeekFrom::Start(pos))?;
        let mut head = [0u8; 8];
        f.read_exact(&mut head)?;
        let mut size = u32::from_be_bytes(head[..4].try_into().unwrap()) as u64;
        let mut header = 8;
        if size == 1 {
            let mut big = [0u8; 8];
            f.read_exact(&mut big)?;
            size = u64::from_be_bytes(big);
            header = 16;
        } else if size == 0 {
            size = end - pos;
        }
        if size < header || pos + size > end {
            break;
        }
        if &head[4..] == name {
            return Ok(Some(Span { at: pos + header, len: size - header }));
        }
        pos += size;
    }
    Ok(None)
}

/// `moov` is small (the index, not the audio): read it whole. Capped so a broken size can't
/// ask for gigabytes.
fn read_body(f: &mut File, s: Span) -> Result<Vec<u8>> {
    let mut buf = vec![0; s.len.min(64 << 20) as usize];
    f.seek(SeekFrom::Start(s.at))?;
    f.read_exact(&mut buf)?;
    Ok(buf)
}

/// The boxes directly inside `data`, as (name, body).
fn boxes(data: &[u8]) -> Vec<([u8; 4], &[u8])> {
    let mut out = Vec::new();
    let mut pos = 0;
    while pos + 8 <= data.len() {
        let mut size = u32::from_be_bytes(data[pos..pos + 4].try_into().unwrap()) as usize;
        let name: [u8; 4] = data[pos + 4..pos + 8].try_into().unwrap();
        let mut header = 8;
        if size == 1 && pos + 16 <= data.len() {
            size = u64::from_be_bytes(data[pos + 8..pos + 16].try_into().unwrap()) as usize;
            header = 16;
        } else if size == 0 {
            size = data.len() - pos;
        }
        if size < header || pos + size > data.len() {
            break;
        }
        out.push((name, &data[pos + header..pos + size]));
        pos += size;
    }
    out
}

fn child<'a>(data: &'a [u8], name: &[u8; 4]) -> Option<&'a [u8]> {
    boxes(data).into_iter().find(|(n, _)| n == name).map(|(_, b)| b)
}

fn path<'a>(data: &'a [u8], names: &[&[u8; 4]]) -> Option<&'a [u8]> {
    names.iter().try_fold(data, |d, n| child(d, n))
}

fn be32(d: &[u8], at: usize) -> Option<u32> {
    d.get(at..at + 4).map(|b| u32::from_be_bytes(b.try_into().unwrap()))
}

fn be64(d: &[u8], at: usize) -> Option<u64> {
    d.get(at..at + 8).map(|b| u64::from_be_bytes(b.try_into().unwrap()))
}

/// Nero's `chpl`: version, flags, (a reserved byte in version 1), a count, then each mark's
/// start in 100 ns and a length-prefixed title.
fn nero(moov: &[u8]) -> Vec<AudioMark> {
    let Some(c) = boxes(moov).into_iter().filter(|(n, _)| n == b"udta").find_map(|(_, u)| child(u, b"chpl")) else { return Vec::new() };
    let mut at = if c.first() == Some(&1) { 5 } else { 4 };
    // Some writers put the count in four bytes, some in one.
    let count = if c.first() == Some(&1) { c.get(at).copied().unwrap_or(0) as usize } else { be32(c, at).unwrap_or(0) as usize };
    at += if c.first() == Some(&1) { 1 } else { 4 };
    let mut out = Vec::new();
    for _ in 0..count {
        let (Some(start), Some(&n)) = (be64(c, at), c.get(at + 8)) else { break };
        let Some(title) = c.get(at + 9..at + 9 + n as usize) else { break };
        out.push(AudioMark { title: text(title), start: start as f64 / 1e7 });
        at += 9 + n as usize;
    }
    out
}

/// The chapter track the audio points to: its sample times say where each chapter starts, its
/// samples (in the file, outside `moov`) carry the titles.
fn quicktime(f: &mut File, moov: &[u8]) -> Result<Vec<AudioMark>> {
    let traks: Vec<&[u8]> = boxes(moov).into_iter().filter(|(n, _)| n == b"trak").map(|(_, b)| b).collect();
    let id = |t: &[u8]| {
        let h = child(t, b"tkhd")?;
        be32(h, if h.first() == Some(&1) { 20 } else { 12 })
    };
    let Some(chap) = traks.iter().find_map(|t| path(t, &[b"tref", b"chap"]).and_then(|c| be32(c, 0))) else { return Ok(Vec::new()) };
    let Some(track) = traks.iter().find(|t| id(t) == Some(chap)) else { return Ok(Vec::new()) };
    let Some(mdia) = child(track, b"mdia") else { return Ok(Vec::new()) };
    let Some(mdhd) = child(mdia, b"mdhd") else { return Ok(Vec::new()) };
    let scale = be32(mdhd, if mdhd.first() == Some(&1) { 20 } else { 12 }).unwrap_or(0);
    let Some(stbl) = path(mdia, &[b"minf", b"stbl"]) else { return Ok(Vec::new()) };
    if scale == 0 {
        return Ok(Vec::new());
    }
    // Each sample's start, from the run lengths of durations.
    let mut starts = Vec::new();
    if let Some(stts) = child(stbl, b"stts") {
        let mut t = 0u64;
        for i in 0..be32(stts, 4).unwrap_or(0) as usize {
            let (Some(n), Some(d)) = (be32(stts, 8 + i * 8), be32(stts, 12 + i * 8)) else { break };
            for _ in 0..n.min(10_000) {
                starts.push(t);
                t += d as u64;
            }
        }
    }
    // Each sample's place in the file: chunks from stco/co64, samples per chunk from stsc,
    // sizes from stsz.
    let chunks: Vec<u64> = if let Some(c) = child(stbl, b"stco") {
        (0..be32(c, 4).unwrap_or(0) as usize).filter_map(|i| be32(c, 8 + i * 4).map(u64::from)).collect()
    } else if let Some(c) = child(stbl, b"co64") {
        (0..be32(c, 4).unwrap_or(0) as usize).filter_map(|i| be64(c, 8 + i * 8)).collect()
    } else {
        Vec::new()
    };
    let sizes: Vec<u32> = match child(stbl, b"stsz") {
        Some(s) => {
            let fixed = be32(s, 4).unwrap_or(0);
            let n = be32(s, 8).unwrap_or(0) as usize;
            if fixed > 0 { vec![fixed; n] } else { (0..n).filter_map(|i| be32(s, 12 + i * 4)).collect() }
        }
        None => Vec::new(),
    };
    let runs: Vec<(u32, u32)> = child(stbl, b"stsc")
        .map(|s| (0..be32(s, 4).unwrap_or(0) as usize).filter_map(|i| Some((be32(s, 8 + i * 12)?, be32(s, 12 + i * 12)?))).collect())
        .unwrap_or_default();
    let mut offsets = Vec::new();
    for (ci, &chunk) in chunks.iter().enumerate() {
        let per = runs.iter().rev().find(|(first, _)| *first as usize <= ci + 1).map(|r| r.1).unwrap_or(1);
        let mut at = chunk;
        for _ in 0..per {
            let Some(&size) = sizes.get(offsets.len()) else { break };
            offsets.push((at, size));
            at += size as u64;
        }
    }
    let mut out = Vec::new();
    for (i, &t) in starts.iter().enumerate() {
        // A text sample: two bytes of length, then the title.
        let title = offsets.get(i).and_then(|&(at, size)| {
            let mut buf = vec![0; (size as usize).min(1024)];
            f.seek(SeekFrom::Start(at)).ok()?;
            f.read_exact(&mut buf).ok()?;
            let n = u16::from_be_bytes(buf.get(..2)?.try_into().ok()?) as usize;
            text(buf.get(2..2 + n)?)
        });
        out.push(AudioMark { title, start: t as f64 / scale as f64 });
    }
    Ok(out)
}

/// UTF-8, or UTF-16 with a byte-order mark.
fn text(b: &[u8]) -> Option<String> {
    let s = if b.starts_with(&[0xFE, 0xFF]) || b.starts_with(&[0xFF, 0xFE]) {
        let be = b[0] == 0xFE;
        let units: Vec<u16> = b[2..].as_chunks::<2>().0.iter().map(|c| if be { u16::from_be_bytes([c[0], c[1]]) } else { u16::from_le_bytes([c[0], c[1]]) }).collect();
        String::from_utf16_lossy(&units)
    } else {
        String::from_utf8_lossy(b).into_owned()
    };
    let s = s.trim_matches(|c: char| c == '\0' || c.is_whitespace()).to_string();
    (!s.is_empty()).then_some(s)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bx(name: &[u8; 4], body: &[u8]) -> Vec<u8> {
        let mut v = ((body.len() + 8) as u32).to_be_bytes().to_vec();
        v.extend_from_slice(name);
        v.extend_from_slice(body);
        v
    }

    fn temp(bytes: &[u8]) -> std::path::PathBuf {
        let p = std::env::temp_dir().join(format!("yuyue-m4b-{}.m4b", getrandom::u64().unwrap()));
        std::fs::write(&p, bytes).unwrap();
        p
    }

    #[test]
    fn nero_marks() {
        let mut chpl = vec![1, 0, 0, 0, 0, 2];
        for (t, name) in [(0u64, "序"), (125_000_000u64, "第一章")] {
            chpl.extend_from_slice(&t.to_be_bytes());
            chpl.push(name.len() as u8);
            chpl.extend_from_slice(name.as_bytes());
        }
        let file = [bx(b"ftyp", b"M4B \0\0\0\0"), bx(b"moov", &bx(b"udta", &bx(b"chpl", &chpl)))].concat();
        let p = temp(&file);
        let marks = chapter_marks(&p).unwrap();
        std::fs::remove_file(p).ok();
        assert_eq!(marks.iter().map(|m| (m.title.clone().unwrap(), m.start)).collect::<Vec<_>>(), [("序".into(), 0.0), ("第一章".into(), 12.5)]);
    }

    #[test]
    fn quicktime_chapter_track() {
        // Two titles in an mdat, then a moov whose audio track points to a text track holding them.
        let titles = ["开头", "Chapter 2"];
        let samples: Vec<Vec<u8>> = titles.iter().map(|t| [(t.len() as u16).to_be_bytes().to_vec(), t.as_bytes().to_vec()].concat()).collect();
        let ftyp = bx(b"ftyp", b"M4B \0\0\0\0");
        let mdat = bx(b"mdat", &samples.concat());
        let first = (ftyp.len() + 8) as u32;
        let tkhd = |id: u32| bx(b"tkhd", &[vec![0; 12], id.to_be_bytes().to_vec(), vec![0; 4]].concat());
        let audio = bx(b"trak", &[tkhd(1), bx(b"tref", &bx(b"chap", &2u32.to_be_bytes()))].concat());
        let mdhd = bx(b"mdhd", &[vec![0; 12], 1000u32.to_be_bytes().to_vec(), vec![0; 8]].concat());
        let stts = bx(b"stts", &[vec![0; 4], 2u32.to_be_bytes().to_vec(), 1u32.to_be_bytes().to_vec(), 3000u32.to_be_bytes().to_vec(), 1u32.to_be_bytes().to_vec(), 5000u32.to_be_bytes().to_vec()].concat());
        let stsc = bx(b"stsc", &[vec![0; 4], 1u32.to_be_bytes().to_vec(), 1u32.to_be_bytes().to_vec(), 2u32.to_be_bytes().to_vec(), 1u32.to_be_bytes().to_vec()].concat());
        let stsz = bx(b"stsz", &[vec![0; 4], 0u32.to_be_bytes().to_vec(), 2u32.to_be_bytes().to_vec(), (samples[0].len() as u32).to_be_bytes().to_vec(), (samples[1].len() as u32).to_be_bytes().to_vec()].concat());
        let stco = bx(b"stco", &[vec![0; 4], 1u32.to_be_bytes().to_vec(), first.to_be_bytes().to_vec()].concat());
        let stbl = bx(b"stbl", &[stts, stsc, stsz, stco].concat());
        let text = bx(b"trak", &[tkhd(2), bx(b"mdia", &[mdhd, bx(b"minf", &stbl)].concat())].concat());
        let file = [ftyp, mdat, bx(b"moov", &[audio, text].concat())].concat();
        let p = temp(&file);
        let marks = chapter_marks(&p).unwrap();
        std::fs::remove_file(p).ok();
        assert_eq!(marks.iter().map(|m| (m.title.clone().unwrap(), m.start)).collect::<Vec<_>>(), [("开头".into(), 0.0), ("Chapter 2".into(), 3.0)]);
    }

    #[test]
    fn no_marks_in_a_plain_file() {
        let p = temp(&bx(b"ftyp", b"M4A \0\0\0\0"));
        assert!(chapter_marks(&p).unwrap().is_empty());
        std::fs::remove_file(p).ok();
    }
}
