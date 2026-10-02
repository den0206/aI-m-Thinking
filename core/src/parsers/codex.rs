use std::{collections::VecDeque, io::Read};
use serde::Deserialize;
use crate::events::{classify_tool, Confidence, NormalizedEvent, ToolClass, ToolKey};

const MAX_RECENT_TOOL_ENDS: usize = 128;

#[derive(Debug, Default)]
pub struct CodexParser {
    anonymous_tool: u64,
    last_usage: Option<TokenUsage>,
    recent_tool_ends: VecDeque<ToolKey>,
}

impl CodexParser {
    pub fn parse<R: Read>(&mut self, reader: R) -> serde_json::Result<Vec<NormalizedEvent>> {
        let record: CodexRecord = serde_json::from_reader(reader)?;
        let mut out = Vec::new();
        match record.kind.as_deref() {
            Some("response_item") => self.response(&record.payload, &mut out),
            Some("event_msg") => self.event(&record.payload, &mut out),
            Some("token_usage_record") => {}
            _ => {}
        }
        Ok(out)
    }

    fn response(&mut self, p: &CodexPayload, out: &mut Vec<NormalizedEvent>) {
        match p.kind.as_deref() {
            Some("reasoning") => out.push(NormalizedEvent::ThinkingPulse { units: 1, confidence: Confidence::High }),
            Some("message") if p.role.as_deref() == Some("assistant") => out.push(NormalizedEvent::WritingPulse { units: 1, confidence: Confidence::High }),
            Some(k) if is_call(k) => out.push(self.tool_start(p, k)),
            Some(k) if is_output(k) => self.tool_end(p.tool_id(), out),
            _ => {}
        }
    }

    fn event(&mut self, p: &CodexPayload, out: &mut Vec<NormalizedEvent>) {
        match p.kind.as_deref() {
            Some("task_started" | "turn_started") => out.push(NormalizedEvent::TurnStart),
            Some("task_complete" | "turn_complete" | "turn_aborted") => out.push(NormalizedEvent::TurnEnd),
            Some("agent_reasoning" | "agent_reasoning_raw_content") => out.push(NormalizedEvent::ThinkingPulse { units: 1, confidence: Confidence::High }),
            Some("agent_message") => out.push(NormalizedEvent::WritingPulse { units: 1, confidence: Confidence::High }),
            Some("exec_command_begin") => out.push(self.named_start(p, ToolClass::Shell)),
            Some("exec_command_end") => self.tool_end(p.tool_id(), out),
            Some("mcp_tool_call_begin") => out.push(self.named_start(p, ToolClass::Mcp)),
            Some("mcp_tool_call_end") => self.tool_end(p.tool_id(), out),
            Some("web_search_begin") => out.push(self.named_start(p, ToolClass::Search)),
            Some("web_search_end") => self.tool_end(p.tool_id(), out),
            Some("item_started") => {
                if let Some(item) = p.item.as_deref() {
                    if let Some(k) = item.kind.as_deref() {
                        if is_call(k) { out.push(self.tool_start(item, k)); }
                    }
                }
            }
            Some("item_completed") => {
                if let Some(item) = p.item.as_deref() {
                    if let Some(k) = item.kind.as_deref() {
                        if is_output(k) || is_call(k) { self.tool_end(item.tool_id(), out); }
                    }
                }
            }
            Some("token_count") => self.usage(p, out),
            _ => {}
        }
    }

    fn tool_start(&mut self, p: &CodexPayload, kind: &str) -> NormalizedEvent {
        let name = p.name.as_deref().unwrap_or(kind);
        let class = match kind {
            "web_search_call" => ToolClass::Search,
            "local_shell_call" => ToolClass::Shell,
            _ => classify_tool(name),
        };
        let id = p.tool_id().map(ToolKey::new).unwrap_or_else(|| self.anonymous());
        NormalizedEvent::ToolStart { id, class }
    }

    fn named_start(&mut self, p: &CodexPayload, class: ToolClass) -> NormalizedEvent {
        let id = p.tool_id().map(ToolKey::new).unwrap_or_else(|| self.anonymous());
        NormalizedEvent::ToolStart { id, class }
    }

    fn anonymous(&mut self) -> ToolKey {
        self.anonymous_tool = self.anonymous_tool.wrapping_add(1);
        ToolKey::new(format!("codex-anon-{}", self.anonymous_tool))
    }

    fn tool_end(&mut self, raw: Option<&str>, out: &mut Vec<NormalizedEvent>) {
        let id = raw.map(ToolKey::new);
        if let Some(ref key) = id {
            if self.recent_tool_ends.contains(key) { return; }
            self.recent_tool_ends.push_back(key.clone());
            while self.recent_tool_ends.len() > MAX_RECENT_TOOL_ENDS { self.recent_tool_ends.pop_front(); }
        }
        out.push(NormalizedEvent::ToolEnd { id });
    }

    fn usage(&mut self, p: &CodexPayload, out: &mut Vec<NormalizedEvent>) {
        let Some(current) = p.info.as_ref().and_then(|i| i.total_token_usage) else { return; };
        let Some(previous) = self.last_usage.replace(current) else { return; };
        if current.output_tokens < previous.output_tokens || current.reasoning_output_tokens < previous.reasoning_output_tokens { return; }
        let output = current.output_tokens - previous.output_tokens;
        let reasoning = current.reasoning_output_tokens - previous.reasoning_output_tokens;
        if output == 0 && reasoning == 0 { return; }
        out.push(NormalizedEvent::UsagePulse {
            output_tokens: output.min(u32::MAX as u64) as u32,
            reasoning_tokens: reasoning.min(u32::MAX as u64) as u32,
        });
    }
}

fn is_call(k: &str) -> bool { matches!(k, "function_call"|"custom_tool_call"|"local_shell_call"|"tool_search_call"|"web_search_call"|"image_generation_call"|"mcp_tool_call") }
fn is_output(k: &str) -> bool { matches!(k, "function_call_output"|"custom_tool_call_output"|"tool_search_output"|"local_shell_call_output"|"web_search_call_output"|"image_generation_call_output"|"mcp_tool_call_output") }

#[derive(Debug, Deserialize)]
struct CodexRecord {
    #[serde(rename="type")] kind: Option<String>,
    #[serde(default)] payload: CodexPayload,
}

#[derive(Debug, Default, Deserialize)]
struct CodexPayload {
    #[serde(rename="type")] kind: Option<String>,
    role: Option<String>,
    name: Option<String>,
    call_id: Option<String>,
    id: Option<String>,
    item: Option<Box<CodexPayload>>,
    info: Option<TokenInfo>,
}
impl CodexPayload { fn tool_id(&self) -> Option<&str> { self.call_id.as_deref().or(self.id.as_deref()) } }

#[derive(Debug, Deserialize)]
struct TokenInfo { total_token_usage: Option<TokenUsage> }

#[derive(Debug, Clone, Copy, Deserialize)]
struct TokenUsage {
    #[serde(default, alias="outputTokens")] output_tokens: u64,
    #[serde(default, alias="reasoningOutputTokens")] reasoning_output_tokens: u64,
}
