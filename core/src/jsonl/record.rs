use std::io::{self, Read, Seek, SeekFrom, Take};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RecordRange {
    pub start: u64,
    pub end: u64,
    pub next_offset: u64,
}

impl RecordRange {
    pub fn len(self) -> u64 {
        self.end.saturating_sub(self.start)
    }

    pub fn is_empty(self) -> bool {
        self.start == self.end
    }
}

/// Returns a reader limited to one JSONL record without allocating a buffer for
/// the complete record. The trailing newline is excluded.
pub fn record_reader<'a, R: Read + Seek>(
    reader: &'a mut R,
    range: RecordRange,
) -> io::Result<Take<&'a mut R>> {
    reader.seek(SeekFrom::Start(range.start))?;
    Ok(reader.take(range.len()))
}
