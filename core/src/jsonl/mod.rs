mod cursor;
mod framer;
mod record;

pub use cursor::{FileCursor, FileIdentity, RefreshOutcome};
pub use framer::{ScanResult, scan_records};
pub use record::{RecordRange, record_reader};

pub const FILE_SCAN_CHUNK: usize = 64 * 1024;
pub const FILE_SCAN_BUDGET: usize = 512 * 1024;
pub const MAX_RECORDS_PER_SCAN: usize = 1024;
