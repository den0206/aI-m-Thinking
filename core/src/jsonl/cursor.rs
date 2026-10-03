use std::fs::{File, Metadata};
use std::io;
use std::path::Path;

#[cfg(unix)]
use std::os::unix::fs::MetadataExt;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FileIdentity {
    #[cfg(unix)]
    dev: u64,
    #[cfg(unix)]
    ino: u64,
}

impl FileIdentity {
    fn from_metadata(metadata: &Metadata) -> Self {
        Self {
            #[cfg(unix)]
            dev: metadata.dev(),
            #[cfg(unix)]
            ino: metadata.ino(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RefreshOutcome {
    Unchanged,
    Replaced,
    Truncated,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FileCursor {
    identity: FileIdentity,
    record_start: u64,
    scan_offset: u64,
    committed_offset: u64,
}

impl FileCursor {
    /// Opens an existing file read-only and starts at its current EOF.
    /// Historical content is intentionally not replayed.
    pub fn baseline(path: &Path) -> io::Result<(File, Self)> {
        let file = File::open(path)?;
        let metadata = file.metadata()?;
        let eof = metadata.len();

        Ok((
            file,
            Self {
                identity: FileIdentity::from_metadata(&metadata),
                record_start: eof,
                scan_offset: eof,
                committed_offset: eof,
            },
        ))
    }

    /// Starts at the EOF described by already-fetched metadata, avoiding an
    /// extra open when many existing files are baselined at once.
    pub fn baseline_from_metadata(metadata: &Metadata) -> Self {
        let eof = metadata.len();
        Self {
            identity: FileIdentity::from_metadata(metadata),
            record_start: eof,
            scan_offset: eof,
            committed_offset: eof,
        }
    }

    /// Creates a cursor for a newly-created file that should be observed from byte zero.
    pub fn from_start(file: &File) -> io::Result<Self> {
        let metadata = file.metadata()?;
        Ok(Self {
            identity: FileIdentity::from_metadata(&metadata),
            record_start: 0,
            scan_offset: 0,
            committed_offset: 0,
        })
    }

    pub fn record_start(&self) -> u64 {
        self.record_start
    }

    pub fn scan_offset(&self) -> u64 {
        self.scan_offset
    }

    pub fn metadata_changed(&self, metadata: &Metadata) -> bool {
        FileIdentity::from_metadata(metadata) != self.identity || metadata.len() != self.scan_offset
    }

    pub fn committed_offset(&self) -> u64 {
        self.committed_offset
    }

    pub(crate) fn set_scan_offset(&mut self, offset: u64) {
        self.scan_offset = offset;
    }

    pub(crate) fn advance_record_start(&mut self, offset: u64) {
        self.record_start = offset;
    }

    pub fn commit_through(&mut self, offset: u64) {
        if offset > self.committed_offset {
            self.committed_offset = offset;
        }
    }

    /// Detects replacement or truncation. The caller must pass a freshly-opened
    /// file after a path-level change notification to detect replacement.
    pub fn refresh(&mut self, file: &File) -> io::Result<RefreshOutcome> {
        let metadata = file.metadata()?;
        let identity = FileIdentity::from_metadata(&metadata);
        let eof = metadata.len();

        if identity != self.identity {
            self.identity = identity;
            self.reset_to_eof(eof);
            return Ok(RefreshOutcome::Replaced);
        }

        if eof < self.committed_offset || eof < self.scan_offset {
            self.reset_to_eof(eof);
            return Ok(RefreshOutcome::Truncated);
        }

        Ok(RefreshOutcome::Unchanged)
    }

    fn reset_to_eof(&mut self, eof: u64) {
        self.record_start = eof;
        self.scan_offset = eof;
        self.committed_offset = eof;
    }
}
