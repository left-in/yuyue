//! 导出阅读记录: the shelf as a CSV that Goodreads or StoryGraph takes in through its own
//! "import" page — 想读, 在读, 读完 and when. Neither offers an interface to write to directly, so
//! a file is the whole of it. Comics stay out: neither site lists them.

use crate::api::{YuyueCore, lock};
use crate::error::Result;
use crate::shelf::ReadingStatus;

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum ReadingSite {
    Goodreads,
    StoryGraph,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct ReadingExport {
    pub want: u32,
    pub reading: u32,
    pub finished: u32,
    /// Matched by title and author on the site, so worth checking there.
    pub without_isbn: u32,
    pub csv: String,
}

fn field(text: &str) -> String {
    if text.contains([',', '"', '\n', '\r']) { format!("\"{}\"", text.replace('"', "\"\"")) } else { text.to_string() }
}

/// `2026/10/03`, the way both sites write dates, in the reader's own time zone.
fn date(ms: i64, utc_offset_minutes: i32) -> String {
    let days = (ms + utc_offset_minutes as i64 * 60_000).div_euclid(86_400_000);
    // Civil from days (Howard Hinnant's algorithm).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}/{m:02}/{d:02}")
}

#[uniffi::export]
impl YuyueCore {
    /// The shelf as a CSV for `site`, newest first.
    pub fn reading_export(&self, site: ReadingSite, utc_offset_minutes: i32) -> Result<ReadingExport> {
        let books = self.books()?;
        let mut out = ReadingExport { want: 0, reading: 0, finished: 0, without_isbn: 0, csv: String::new() };
        out.csv = match site {
            ReadingSite::Goodreads => "Title,Author,ISBN13,Exclusive Shelf,Date Read,Date Added\n",
            ReadingSite::StoryGraph => "Title,Authors,ISBN/UID,Read Status,Last Date Read,Date Added\n",
        }
        .to_string();
        for b in books.iter().filter(|b| b.format != crate::api::BookFormat::Comic) {
            let isbn = if b.available { self.manifest(&b.id).ok().and_then(|m| m.isbn.clone()) } else { None };
            let isbn = isbn.or_else(|| self.stored_isbn(&b.id));
            let shelf = match b.status {
                ReadingStatus::Want => {
                    out.want += 1;
                    "to-read"
                }
                ReadingStatus::Reading => {
                    out.reading += 1;
                    "currently-reading"
                }
                ReadingStatus::Finished => {
                    out.finished += 1;
                    "read"
                }
            };
            if isbn.is_none() {
                out.without_isbn += 1;
            }
            let read = b.finished_at.filter(|_| b.status == ReadingStatus::Finished).map(|t| date(t, utc_offset_minutes));
            let authors = match site {
                // Goodreads takes one author; the others would be read as part of the name.
                ReadingSite::Goodreads => b.authors.first().cloned().unwrap_or_default(),
                ReadingSite::StoryGraph => b.authors.join(", "),
            };
            let row = [
                field(&b.title),
                field(&authors),
                isbn.unwrap_or_default(),
                shelf.to_string(),
                read.unwrap_or_default(),
                date(b.added_at, utc_offset_minutes),
            ];
            out.csv.push_str(&row.join(","));
            out.csv.push('\n');
        }
        Ok(out)
    }
}

impl YuyueCore {
    /// The ISBN the shelf remembers for a book whose files are elsewhere.
    fn stored_isbn(&self, id: &str) -> Option<String> {
        lock(&self.store).get(&format!("book/{id}"), "isbn").ok().flatten()?.as_str().map(str::to_string)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dates_and_quoting() {
        assert_eq!(date(0, 0), "1970/01/01");
        // 2026-10-02 21:40 in Beijing; three hours on it's the 3rd there, still the 2nd in UTC.
        assert_eq!(date(1_790_948_400_000, 480), "2026/10/02");
        assert_eq!(date(1_790_948_400_000 + 3 * 3_600_000, 480), "2026/10/03");
        assert_eq!(date(1_790_948_400_000 + 3 * 3_600_000, 0), "2026/10/02");
        assert_eq!(field("三体"), "三体");
        assert_eq!(field("Hello, \"World\""), "\"Hello, \"\"World\"\"\"");
    }
}
