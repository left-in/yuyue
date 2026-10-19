#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("file error: {message}")]
    Io { message: String },
    #[error("database error: {message}")]
    Db { message: String },
    #[error("this file type isn't supported")]
    Unsupported,
    #[error("the book couldn't be read: {message}")]
    BadBook { message: String },
    #[error("the book is DRM-protected")]
    Protected,
    #[error("not found: {what}")]
    NotFound { what: String },
    #[error("invalid input: {message}")]
    Invalid { message: String },
}

impl CoreError {
    pub fn bad_book(message: impl Into<String>) -> Self {
        CoreError::BadBook { message: message.into() }
    }

    pub fn not_found(what: impl Into<String>) -> Self {
        CoreError::NotFound { what: what.into() }
    }
}

impl From<std::io::Error> for CoreError {
    fn from(e: std::io::Error) -> Self {
        CoreError::Io { message: e.to_string() }
    }
}

impl From<rusqlite::Error> for CoreError {
    fn from(e: rusqlite::Error) -> Self {
        CoreError::Db { message: e.to_string() }
    }
}

impl From<serde_json::Error> for CoreError {
    fn from(e: serde_json::Error) -> Self {
        CoreError::Invalid { message: e.to_string() }
    }
}

impl From<zip::result::ZipError> for CoreError {
    fn from(e: zip::result::ZipError) -> Self {
        CoreError::BadBook { message: e.to_string() }
    }
}

pub type Result<T> = std::result::Result<T, CoreError>;
