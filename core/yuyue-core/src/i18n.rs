//! The few words the core says to people itself (errors, the 常用规则, a chapter's 读/听 line),
//! in the interface's language. The apps set it once at launch from the system's.

use std::sync::atomic::{AtomicBool, Ordering};

static ENGLISH: AtomicBool = AtomicBool::new(false);

/// "zh…" keeps Chinese; anything else is English.
#[uniffi::export]
pub fn set_ui_language(language: String) {
    ENGLISH.store(!language.to_ascii_lowercase().starts_with("zh"), Ordering::Relaxed);
}

pub fn english() -> bool {
    ENGLISH.load(Ordering::Relaxed)
}

/// The Chinese or the English, whichever the interface speaks.
pub fn tr(zh: &str, en: &str) -> String {
    if english() { en.to_string() } else { zh.to_string() }
}
