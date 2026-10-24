//! The song catalog the desktop app exports (contract section 5), indexed
//! into artists, albums and search. Owned by unit L1b.

use std::path::Path;

/// An indexed catalog snapshot. Immutable once loaded.
#[derive(Debug, Default)]
pub struct Catalog {}

impl Catalog {
    /// A catalog with no songs, used before the first export.
    pub fn empty() -> Self {
        Self::default()
    }

    /// Reads and indexes the NDJSON export at `path`.
    pub fn load(path: &Path) -> Result<Self, String> {
        let _ = path;
        Err("catalog loading is not implemented yet".to_owned())
    }

    pub fn song_count(&self) -> usize {
        0
    }
}
