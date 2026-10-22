//! 语阅 core: everything that is a rule rather than a pixel.
//!
//! Imports books and normalizes them into per-section HTML with sentence spans, keeps the
//! library, progress and settings in an operation log that syncs between devices, and plans
//! what to speak next. The apps (SwiftUI, Compose) call it through UniFFI; see `api`.

pub mod align;
pub mod api;
pub mod book;
pub mod comic;
pub mod conflicts;
pub mod document;
pub mod dom;
pub mod epub;
pub mod error;
pub mod export;
pub mod footnote;
pub mod hard;
pub mod i18n;
pub mod mobi;
pub mod normalize;
pub mod notes;
pub mod punct;
pub mod records;
pub mod rules;
pub mod mdict;
pub mod segment;
pub mod shelf;
pub mod snapshot;
pub mod store;
pub mod text;
pub mod txt;
pub mod txtlayout;
pub mod words;

pub use api::*;
pub use align::*;
pub use shelf::*;
pub use notes::*;
pub use rules::*;
pub use mdict::*;
pub use footnote::*;
pub use txtlayout::*;
pub use error::CoreError;

uniffi::setup_scaffolding!();
