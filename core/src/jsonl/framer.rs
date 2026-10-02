use std::cmp::min;
use std::io::{self, Read, Seek, SeekFrom};

use super::{FILE_SCAN_CHUNK, FileCursor, MAX_RECORDS_PER_SCAN, RecordRange};

#[derive(Debug, Default, PartialEq, Eq)]
pub struct ScanResult {
    pub records: Vec<RecordRange>,
    pub bytes_scanned: usize,
    pub pending_partial: bool,
}

/// Scans at most `budget` bytes for newline-delimited records.
///
/// Record contents are never accumulated. Memory is bounded by a fixed scan
/// buffer plus at most `MAX_RECORDS_PER_SCAN` byte ranges.
pub fn scan_records<R: Read + Seek>(
    reader: &mut R,
    cursor: &mut FileCursor,
    budget: usize,
) -> io::Result<ScanResult> {
    if budget == 0 {
        return Ok(ScanResult::default());
    }

    let mut result = ScanResult::default();
    let mut buffer = [0_u8; FILE_SCAN_CHUNK];
    reader.seek(SeekFrom::Start(cursor.scan_offset()))?;

    while result.bytes_scanned < budget && result.records.len() < MAX_RECORDS_PER_SCAN {
        let remaining = budget - result.bytes_scanned;
        let requested = min(buffer.len(), remaining);
        let read = reader.read(&mut buffer[..requested])?;
        if read == 0 {
            break;
        }

        let chunk_start = cursor.scan_offset();
        for (index, byte) in buffer[..read].iter().enumerate() {
            if *byte != b'\n' {
                continue;
            }

            let newline_offset = chunk_start + index as u64;
            let next_offset = newline_offset + 1;
            result.records.push(RecordRange {
                start: cursor.record_start(),
                end: newline_offset,
                next_offset,
            });
            cursor.advance_record_start(next_offset);

            if result.records.len() == MAX_RECORDS_PER_SCAN {
                let consumed = index + 1;
                cursor.set_scan_offset(chunk_start + consumed as u64);
                result.bytes_scanned += consumed;
                result.pending_partial = cursor.record_start() < cursor.scan_offset();
                return Ok(result);
            }
        }

        cursor.set_scan_offset(chunk_start + read as u64);
        result.bytes_scanned += read;
    }

    result.pending_partial = cursor.record_start() < cursor.scan_offset();
    Ok(result)
}
