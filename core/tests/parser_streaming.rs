use std::io::{Cursor, Read};

use im_thinking_core::parsers::ClaudeParser;

#[test]
fn large_ignored_payload_can_be_streamed_without_input_buffer() {
    const PAYLOAD_BYTES: u64 = 8 * 1024 * 1024;

    let prefix = Cursor::new(br#"{"type":"future_record","payload":""#);
    let payload = std::io::repeat(b'x').take(PAYLOAD_BYTES);
    let suffix = Cursor::new(br#""}"#);
    let reader = prefix.chain(payload).chain(suffix);

    let mut parser = ClaudeParser::default();
    let events = parser.parse(reader).unwrap();
    assert!(events.is_empty());
}
