use im_thinking_core::events::{Confidence, NormalizedEvent, ToolClass};
use im_thinking_core::parsers::{ClaudeParser, CodexParser};
use std::io::Cursor;

fn claude(s: &str) -> Vec<NormalizedEvent> {
    let mut p = ClaudeParser::default();
    s.lines()
        .flat_map(|line| p.parse(Cursor::new(line.as_bytes())).unwrap())
        .collect()
}

fn codex(s: &str) -> Vec<NormalizedEvent> {
    let mut p = CodexParser::default();
    s.lines()
        .flat_map(|line| p.parse(Cursor::new(line.as_bytes())).unwrap())
        .collect()
}

#[test]
fn claude_basic() {
    let events = claude(include_str!(
        "fixtures/claude/01_basic_thinking_writing.jsonl"
    ));
    assert_eq!(
        events,
        vec![
            NormalizedEvent::TurnStart,
            NormalizedEvent::ThinkingPulse {
                units: 1,
                confidence: Confidence::Medium,
            },
            NormalizedEvent::WritingPulse {
                units: 1,
                confidence: Confidence::Medium,
            },
            NormalizedEvent::TurnEnd,
        ]
    );
}

#[test]
fn claude_tool_result_not_turn() {
    let events = claude(include_str!("fixtures/claude/02_single_tool.jsonl"));
    assert!(matches!(events[2], NormalizedEvent::ToolStart { .. }));
    assert!(matches!(events[3], NormalizedEvent::ToolEnd { .. }));
    assert_eq!(
        events
            .iter()
            .filter(|event| matches!(event, NormalizedEvent::TurnStart))
            .count(),
        1
    );
}

#[test]
fn claude_parallel_ids() {
    let events = claude(include_str!("fixtures/claude/03_parallel_tools.jsonl"));
    let ids: Vec<_> = events
        .iter()
        .filter_map(|event| {
            if let NormalizedEvent::ToolStart { id, .. } = event {
                Some(id.as_str())
            } else {
                None
            }
        })
        .collect();
    assert_eq!(ids, vec!["a", "b"]);
}

#[test]
fn claude_unknown_tolerated() {
    assert!(claude(include_str!("fixtures/claude/07_unknown_fields.jsonl")).len() >= 2);
    assert!(claude(include_str!("fixtures/claude/08_unknown_record_type.jsonl")).is_empty());
}

#[test]
fn codex_legacy_paginated() {
    for events in [
        codex(include_str!("fixtures/codex/01_legacy_basic.jsonl")),
        codex(include_str!("fixtures/codex/02_paginated_basic.jsonl")),
    ] {
        assert!(matches!(events.first(), Some(NormalizedEvent::TurnStart)));
        assert!(
            events
                .iter()
                .any(|event| matches!(event, NormalizedEvent::ThinkingPulse { .. }))
        );
        assert!(
            events
                .iter()
                .any(|event| matches!(event, NormalizedEvent::WritingPulse { .. }))
        );
        assert!(matches!(events.last(), Some(NormalizedEvent::TurnEnd)));
    }
}

#[test]
fn codex_tool() {
    let events = codex(include_str!("fixtures/codex/03_function_call.jsonl"));
    assert!(matches!(
        events[0],
        NormalizedEvent::ToolStart {
            class: ToolClass::Shell,
            ..
        }
    ));
    assert!(matches!(events[1], NormalizedEvent::ToolEnd { .. }));
}

#[test]
fn codex_dedup() {
    let events = codex(include_str!(
        "fixtures/codex/05_item_completed_duplicate.jsonl"
    ));
    assert_eq!(
        events
            .iter()
            .filter(|event| matches!(event, NormalizedEvent::ToolEnd { .. }))
            .count(),
        1
    );
}

#[test]
fn codex_missing_id() {
    let events = codex(include_str!("fixtures/codex/06_missing_call_id.jsonl"));
    assert!(matches!(events[0], NormalizedEvent::ToolStart { .. }));
    assert!(matches!(events[1], NormalizedEvent::ToolEnd { id: None }));
}

#[test]
fn codex_usage() {
    let events = codex(include_str!("fixtures/codex/07_reasoning_usage.jsonl"));
    assert_eq!(
        events,
        vec![
            NormalizedEvent::UsagePulse {
                output_tokens: 12,
                reasoning_tokens: 17,
            },
            NormalizedEvent::UsagePulse {
                output_tokens: 33,
                reasoning_tokens: 28,
            },
        ]
    );
}

#[test]
fn codex_reset() {
    let events = codex(include_str!("fixtures/codex/08_usage_reset.jsonl"));
    assert_eq!(
        events,
        vec![NormalizedEvent::UsagePulse {
            output_tokens: 50,
            reasoning_tokens: 50,
        }]
    );
}

#[test]
fn ordinal_irrelevant() {
    assert_eq!(
        codex(include_str!("fixtures/codex/09_duplicate_ordinal.jsonl")).len(),
        2
    );
    assert_eq!(
        codex(include_str!("fixtures/codex/10_missing_ordinal.jsonl")).len(),
        2
    );
}

#[test]
fn unknown_codex() {
    assert!(
        codex(include_str!(
            "fixtures/codex/11_unknown_response_item.jsonl"
        ))
        .is_empty()
    );
}

#[test]
fn malformed_never_panics() {
    let mut claude = ClaudeParser::default();
    let mut codex = CodexParser::default();

    for i in 0..10_000_u32 {
        let input = format!("{{\"type\":\"{}\",", i.wrapping_mul(2_654_435_761));
        let _ = claude.parse(Cursor::new(input.as_bytes()));
        let _ = codex.parse(Cursor::new(input.as_bytes()));
    }
}
