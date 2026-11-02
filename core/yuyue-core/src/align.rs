//! 听读对齐's results: where each sentence of a book is in a recording of it (an audiobook), so
//! the voice can be the narrator's and the ink line still knows where it is. `forced` makes them
//! (强制对齐); one the recording skips has no stretch, and the app reads it with a system voice
//! instead (录音里没有); one heard only in part is marked, so the app can ask for a look (对得不准).

/// Where a sentence of the book was read, in seconds from the start of the whole recording.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct SentenceTime {
    pub section: u32,
    pub sentence: u32,
    /// Negative when the recording doesn't have it.
    pub start: f64,
    pub end: f64,
    /// How much of it was heard, 0–1; a sentence with nothing to say counts as heard.
    pub heard: f32,
}

/// How well a chapter came out.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct SectionFit {
    pub section: u32,
    pub sentences: u32,
    /// Share of its words found in the recording, 0–1.
    pub heard: f32,
    /// Sentences the recording doesn't have.
    pub missing: u32,
    /// Sentences only partly heard, whose times are partly guessed.
    pub unsure: u32,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct Alignment {
    pub sentences: Vec<SentenceTime>,
    pub sections: Vec<SectionFit>,
    /// Seconds of recording before the book's first words: an announcer, music (片头).
    pub intro: f64,
    /// Seconds a unit (a character, a word) takes to say, on average.
    pub unit_seconds: f64,
}

/// A sentence that counts as only partly heard.
pub const UNSURE_BELOW: f32 = 0.5;
