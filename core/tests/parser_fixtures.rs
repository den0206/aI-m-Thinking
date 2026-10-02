use std::io::Cursor;
use im_thinking_core::events::{Confidence, NormalizedEvent, ToolClass};
use im_thinking_core::parsers::{ClaudeParser, CodexParser};

fn claude(s:&str)->Vec<NormalizedEvent>{let mut p=ClaudeParser::default();s.lines().flat_map(|l|p.parse(Cursor::new(l.as_bytes())).unwrap()).collect()}
fn codex(s:&str)->Vec<NormalizedEvent>{let mut p=CodexParser::default();s.lines().flat_map(|l|p.parse(Cursor::new(l.as_bytes())).unwrap()).collect()}

#[test] fn claude_basic(){
 let e=claude(include_str!("fixtures/claude/01_basic_thinking_writing.jsonl"));
 assert_eq!(e,vec![NormalizedEvent::TurnStart,NormalizedEvent::ThinkingPulse{units:1,confidence:Confidence::Medium},NormalizedEvent::WritingPulse{units:1,confidence:Confidence::Medium},NormalizedEvent::TurnEnd]);
}
#[test] fn claude_tool_result_not_turn(){
 let e=claude(include_str!("fixtures/claude/02_single_tool.jsonl"));
 assert!(matches!(e[2],NormalizedEvent::ToolStart{..})); assert!(matches!(e[3],NormalizedEvent::ToolEnd{..}));
 assert_eq!(e.iter().filter(|x|matches!(x,NormalizedEvent::TurnStart)).count(),1);
}
#[test] fn claude_parallel_ids(){
 let e=claude(include_str!("fixtures/claude/03_parallel_tools.jsonl"));
 let ids:Vec<_>=e.iter().filter_map(|x|if let NormalizedEvent::ToolStart{id,..}=x{Some(id.as_str())}else{None}).collect();
 assert_eq!(ids,vec!["a","b"]);
}
#[test] fn claude_unknown_tolerated(){
 assert!(claude(include_str!("fixtures/claude/07_unknown_fields.jsonl")).len()>=2);
 assert!(claude(include_str!("fixtures/claude/08_unknown_record_type.jsonl")).is_empty());
}
#[test] fn codex_legacy_paginated(){
 for e in [codex(include_str!("fixtures/codex/01_legacy_basic.jsonl")),codex(include_str!("fixtures/codex/02_paginated_basic.jsonl"))]{
  assert!(matches!(e.first(),Some(NormalizedEvent::TurnStart)));
  assert!(e.iter().any(|x|matches!(x,NormalizedEvent::ThinkingPulse{..})));
  assert!(e.iter().any(|x|matches!(x,NormalizedEvent::WritingPulse{..})));
  assert!(matches!(e.last(),Some(NormalizedEvent::TurnEnd)));
 }
}
#[test] fn codex_tool(){
 let e=codex(include_str!("fixtures/codex/03_function_call.jsonl"));
 assert!(matches!(e[0],NormalizedEvent::ToolStart{class:ToolClass::Shell,..}));
 assert!(matches!(e[1],NormalizedEvent::ToolEnd{..}));
}
#[test] fn codex_dedup(){
 let e=codex(include_str!("fixtures/codex/05_item_completed_duplicate.jsonl"));
 assert_eq!(e.iter().filter(|x|matches!(x,NormalizedEvent::ToolEnd{..})).count(),1);
}
#[test] fn codex_missing_id(){
 let e=codex(include_str!("fixtures/codex/06_missing_call_id.jsonl"));
 assert!(matches!(e[0],NormalizedEvent::ToolStart{..})); assert!(matches!(e[1],NormalizedEvent::ToolEnd{id:None}));
}
#[test] fn codex_usage(){
 let e=codex(include_str!("fixtures/codex/07_reasoning_usage.jsonl"));
 assert_eq!(e,vec![NormalizedEvent::UsagePulse{output_tokens:12,reasoning_tokens:17},NormalizedEvent::UsagePulse{output_tokens:33,reasoning_tokens:28}]);
}
#[test] fn codex_reset(){
 let e=codex(include_str!("fixtures/codex/08_usage_reset.jsonl"));
 assert_eq!(e,vec![NormalizedEvent::UsagePulse{output_tokens:50,reasoning_tokens:50}]);
}
#[test] fn ordinal_irrelevant(){
 assert_eq!(codex(include_str!("fixtures/codex/09_duplicate_ordinal.jsonl")).len(),2);
 assert_eq!(codex(include_str!("fixtures/codex/10_missing_ordinal.jsonl")).len(),2);
}
#[test] fn unknown_codex(){assert!(codex(include_str!("fixtures/codex/11_unknown_response_item.jsonl")).is_empty());}
#[test] fn malformed_never_panics(){
 let mut c=ClaudeParser::default(); let mut x=CodexParser::default();
 for i in 0..10_000u32{let s=format!("{{\"type\":\"{}\",",i.wrapping_mul(2654435761));let _=c.parse(Cursor::new(s.as_bytes()));let _=x.parse(Cursor::new(s.as_bytes()));}
}
