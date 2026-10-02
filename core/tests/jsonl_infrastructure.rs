use std::fs::{self, OpenOptions};
use std::io::{Cursor, Read, Seek, SeekFrom, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

use im_thinking_core::jsonl::{
    FILE_SCAN_BUDGET, FileCursor, RefreshOutcome, record_reader, scan_records,
};

#[test]
fn scans_multiple_complete_records_without_loading_contents() {
    let bytes = b"{\"a\":1}\n{\"b\":2}\n";
    let mut reader = Cursor::new(bytes.as_slice());
    let file = temp_file(bytes);
    let mut cursor = FileCursor::from_start(&file).unwrap();

    let result = scan_records(&mut reader, &mut cursor, FILE_SCAN_BUDGET).unwrap();
    assert_eq!(result.records.len(), 2);
    assert!(!result.pending_partial);

    let mut record = record_reader(&mut reader, result.records[0]).unwrap();
    let mut text = String::new();
    record.read_to_string(&mut text).unwrap();
    assert_eq!(text, "{\"a\":1}");
}

#[test]
fn partial_record_is_completed_by_a_later_append() {
    let mut bytes = b"{\"a\":1".to_vec();
    let file = temp_file(&bytes);
    let mut cursor = FileCursor::from_start(&file).unwrap();
    let mut reader = Cursor::new(bytes.clone());

    let first = scan_records(&mut reader, &mut cursor, FILE_SCAN_BUDGET).unwrap();
    assert!(first.records.is_empty());
    assert!(first.pending_partial);
    assert_eq!(cursor.committed_offset(), 0);

    bytes.extend_from_slice(b"}\n");
    reader = Cursor::new(bytes);
    let second = scan_records(&mut reader, &mut cursor, FILE_SCAN_BUDGET).unwrap();
    assert_eq!(second.records.len(), 1);
    assert!(!second.pending_partial);
    assert_eq!(second.records[0].start, 0);
}

#[test]
fn scan_budget_bounds_large_unterminated_record_work() {
    let bytes = vec![b'x'; FILE_SCAN_BUDGET * 2];
    let file = temp_file(&bytes);
    let mut cursor = FileCursor::from_start(&file).unwrap();
    let mut reader = Cursor::new(bytes);

    let result = scan_records(&mut reader, &mut cursor, FILE_SCAN_BUDGET).unwrap();
    assert!(result.records.is_empty());
    assert_eq!(result.bytes_scanned, FILE_SCAN_BUDGET);
    assert_eq!(cursor.scan_offset(), FILE_SCAN_BUDGET as u64);
    assert!(result.pending_partial);
}

#[test]
fn baseline_starts_at_existing_eof() {
    let path = temp_path();
    fs::write(&path, b"historical\ncontent\n").unwrap();

    let (_file, cursor) = FileCursor::baseline(&path).unwrap();
    assert_eq!(cursor.committed_offset(), 19);
    assert_eq!(cursor.scan_offset(), 19);

    let _ = fs::remove_file(path);
}

#[test]
fn baseline_file_is_opened_read_only() {
    let path = temp_path();
    fs::write(&path, b"existing\n").unwrap();
    let (mut file, _cursor) = FileCursor::baseline(&path).unwrap();

    file.seek(SeekFrom::End(0)).unwrap();
    assert!(file.write_all(b"must fail").is_err());

    let _ = fs::remove_file(path);
}

#[test]
fn truncation_resyncs_to_current_eof() {
    let path = temp_path();
    fs::write(&path, b"one\ntwo\nthree\n").unwrap();
    let (_file, mut cursor) = FileCursor::baseline(&path).unwrap();

    let mut writable = OpenOptions::new()
        .write(true)
        .truncate(true)
        .open(&path)
        .unwrap();
    writable.write_all(b"x\n").unwrap();
    drop(writable);

    let reopened = OpenOptions::new().read(true).open(&path).unwrap();
    assert_eq!(
        cursor.refresh(&reopened).unwrap(),
        RefreshOutcome::Truncated
    );
    assert_eq!(cursor.committed_offset(), 2);

    let _ = fs::remove_file(path);
}

#[test]
fn replacement_resyncs_without_replaying_history() {
    let path = temp_path();
    fs::write(&path, b"old\n").unwrap();
    let (_file, mut cursor) = FileCursor::baseline(&path).unwrap();

    let replacement = path.with_extension("replacement");
    fs::write(&replacement, b"new history\n").unwrap();
    fs::rename(&replacement, &path).unwrap();

    let reopened = OpenOptions::new().read(true).open(&path).unwrap();
    assert_eq!(cursor.refresh(&reopened).unwrap(), RefreshOutcome::Replaced);
    assert_eq!(cursor.committed_offset(), 12);

    let _ = fs::remove_file(path);
}

fn temp_file(contents: &[u8]) -> std::fs::File {
    let path = temp_path();
    fs::write(&path, contents).unwrap();
    let file = OpenOptions::new().read(true).open(&path).unwrap();
    let _ = fs::remove_file(path);
    file
}

fn temp_path() -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let sequence = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!(
        "im-thinking-test-{}-{nonce}-{sequence}",
        std::process::id()
    ))
}
