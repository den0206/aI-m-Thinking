use crate::events::{Confidence, NormalizedEvent, ParsedRecord, ToolClass, ToolKey, classify_tool};
use crate::timestamp::parse_utc_ms;
use serde::Deserialize;
use std::{collections::VecDeque, io::Read};

const MAX_RECENT_TOOL_ENDS: usize = 128;

#[derive(Debug, Default)]
pub struct CodexParser {
    anonymous_tool: u64,
    last_usage: Option<TokenUsage>,
    recent_tool_ends: VecDeque<ToolKey>,
}

impl CodexParser {
    pub fn parse<R: Read>(&mut self, reader: R) -> serde_json::Result<Vec<NormalizedEvent>> {
        self.parse_record(reader).map(|record| record.events)
    }

    pub fn parse_record<R: Read>(&mut self, reader: R) -> serde_json::Result<ParsedRecord> {
        let record: CodexRecord = serde_json::from_reader(reader)?;
        let mut out = Vec::new();
        let quiet = match record.kind.as_deref() {
            Some("session_meta" | "turn_context" | "token_usage_record" | "compacted") => true,
            Some("event_msg") => record.payload.kind.as_deref() == Some("token_count"),
            _ => false,
        };

        match record.kind.as_deref() {
            Some("response_item") => self.response(&record.payload, &mut out),
            Some("event_msg") => self.event(&record.payload, &mut out),
            Some("token_usage_record") => {}
            _ => {}
        }

        Ok(ParsedRecord {
            events: out,
            timestamp_ms: record.timestamp.as_deref().and_then(parse_utc_ms),
            agent_version: record.payload.cli_version,
            quiet,
        })
    }

    fn response(&mut self, p: &CodexPayload, out: &mut Vec<NormalizedEvent>) {
        match p.kind.as_deref() {
            Some("reasoning") => out.push(NormalizedEvent::ThinkingPulse {
                units: 1,
                confidence: Confidence::High,
            }),
            Some("message") if p.role.as_deref() == Some("assistant") => {
                self.assistant_message(p, out)
            }
            Some("agent_message") => self.assistant_message(p, out),
            Some(k) if is_call(k) => out.push(self.tool_start(p, k)),
            Some(k) if is_output(k) => self.tool_end(p.tool_id(), out),
            _ => {}
        }
    }

    fn event(&mut self, p: &CodexPayload, out: &mut Vec<NormalizedEvent>) {
        match p.kind.as_deref() {
            Some("task_started" | "turn_started") => {
                self.recent_tool_ends.clear();
                out.push(NormalizedEvent::TurnStart);
            }
            Some("task_complete" | "turn_complete" | "turn_aborted") => {
                out.push(NormalizedEvent::TurnEnd)
            }
            Some("agent_reasoning" | "agent_reasoning_raw_content") => {
                out.push(NormalizedEvent::ThinkingPulse {
                    units: 1,
                    confidence: Confidence::High,
                })
            }
            Some("agent_message") => self.assistant_message(p, out),
            Some("exec_command_begin") => out.push(self.named_start(p, ToolClass::Shell)),
            Some("exec_command_end") => self.tool_end(p.tool_id(), out),
            Some("mcp_tool_call_begin") => out.push(self.named_start(p, ToolClass::Mcp)),
            Some("mcp_tool_call_end") => self.tool_end(p.tool_id(), out),
            Some("web_search_begin") => out.push(self.named_start(p, ToolClass::Search)),
            Some("web_search_end") => self.tool_end(p.tool_id(), out),
            Some("item_started") => {
                if let Some(item) = p.item.as_deref() {
                    if let Some(k) = item.kind.as_deref() {
                        if is_call(k) {
                            out.push(self.tool_start(item, k));
                        }
                    }
                }
            }
            Some("item_completed") => {
                if let Some(item) = p.item.as_deref() {
                    if let Some(k) = item.kind.as_deref() {
                        match k {
                            "Reasoning" => out.push(NormalizedEvent::ThinkingPulse {
                                units: 1,
                                confidence: Confidence::High,
                            }),
                            "AgentMessage" => self.assistant_message(item, out),
                            "FunctionCallOutput" => self.tool_end(item.tool_id(), out),
                            "CommandExecution"
                            | "DynamicToolCall"
                            | "CollabAgentToolCall"
                            | "McpToolCall"
                                if item.status.as_deref() != Some("in_progress") =>
                            {
                                self.tool_end(item.tool_id(), out);
                            }
                            _ if is_output(k) || is_call(k) => self.tool_end(item.tool_id(), out),
                            _ => {}
                        }
                    }
                }
            }
            Some("token_count") => self.usage(p, out),
            _ => {}
        }
    }

    fn assistant_message(&self, p: &CodexPayload, out: &mut Vec<NormalizedEvent>) {
        // Async delivery is mid-turn even when the message has a final phase.
        if p.phase.as_deref() == Some("final_answer") && p.delivery.as_deref() != Some("async") {
            out.push(NormalizedEvent::TurnEnd);
        } else {
            out.push(NormalizedEvent::WritingPulse {
                units: 1,
                confidence: Confidence::High,
            });
        }
    }

    fn tool_start(&mut self, p: &CodexPayload, kind: &str) -> NormalizedEvent {
        let name = p.name.as_deref().unwrap_or(kind);
        let class = match kind {
            "local_shell_call" => ToolClass::Shell,
            _ => classify_tool(name),
        };
        let id = p
            .tool_id()
            .map(Into::into)
            .unwrap_or_else(|| self.anonymous());
        NormalizedEvent::ToolStart { id, class }
    }

    fn named_start(&mut self, p: &CodexPayload, class: ToolClass) -> NormalizedEvent {
        let id = p
            .tool_id()
            .map(Into::into)
            .unwrap_or_else(|| self.anonymous());
        NormalizedEvent::ToolStart { id, class }
    }

    fn anonymous(&mut self) -> ToolKey {
        self.anonymous_tool = self.anonymous_tool.wrapping_add(1);
        ToolKey::from(format!("codex-anon-{}", self.anonymous_tool))
    }

    fn tool_end(&mut self, raw: Option<&str>, out: &mut Vec<NormalizedEvent>) {
        let id = raw.map(Into::into);
        if let Some(ref key) = id {
            if self.recent_tool_ends.contains(key) {
                return;
            }
            self.recent_tool_ends.push_back(key.clone());
            while self.recent_tool_ends.len() > MAX_RECENT_TOOL_ENDS {
                self.recent_tool_ends.pop_front();
            }
        }
        out.push(NormalizedEvent::ToolEnd { id });
    }

    fn usage(&mut self, p: &CodexPayload, out: &mut Vec<NormalizedEvent>) {
        let Some(current) = p.info.as_ref().and_then(|i| i.total_token_usage) else {
            return;
        };
        let Some(previous) = self.last_usage.replace(current) else {
            return;
        };

        if current.output_tokens < previous.output_tokens
            || current.reasoning_output_tokens < previous.reasoning_output_tokens
        {
            return;
        }

        let output = current.output_tokens - previous.output_tokens;
        let reasoning = current.reasoning_output_tokens - previous.reasoning_output_tokens;
        if output == 0 && reasoning == 0 {
            return;
        }

        out.push(NormalizedEvent::UsagePulse {
            output_tokens: output.min(u32::MAX as u64) as u32,
            reasoning_tokens: reasoning.min(u32::MAX as u64) as u32,
        });
    }
}

/// Response items that start a tool which later reports an output item.
///
/// `web_search_call` and `image_generation_call` are excluded: Codex persists
/// them only once the hosted tool has completed and no output item follows,
/// so treating them as starts would leave the session stuck in TOOL.
fn is_call(k: &str) -> bool {
    matches!(
        k,
        "function_call"
            | "custom_tool_call"
            | "local_shell_call"
            | "tool_search_call"
            | "mcp_tool_call"
    )
}

fn is_output(k: &str) -> bool {
    matches!(
        k,
        "function_call_output"
            | "custom_tool_call_output"
            | "tool_search_output"
            | "local_shell_call_output"
            | "web_search_call_output"
            | "image_generation_call_output"
            | "mcp_tool_call_output"
    )
}

#[derive(Debug, Deserialize)]
struct CodexRecord {
    timestamp: Option<String>,
    #[serde(rename = "type")]
    kind: Option<String>,
    #[serde(default)]
    payload: CodexPayload,
}

#[derive(Debug, Default, Deserialize)]
struct CodexPayload {
    #[serde(rename = "type")]
    kind: Option<String>,
    role: Option<String>,
    name: Option<String>,
    phase: Option<String>,
    delivery: Option<String>,
    status: Option<String>,
    /// Present on `session_meta` records.
    cli_version: Option<String>,
    call_id: Option<String>,
    id: Option<String>,
    item: Option<Box<CodexPayload>>,
    info: Option<TokenInfo>,
}

impl CodexPayload {
    fn tool_id(&self) -> Option<&str> {
        self.call_id.as_deref().or(self.id.as_deref())
    }
}

#[derive(Debug, Deserialize)]
struct TokenInfo {
    total_token_usage: Option<TokenUsage>,
}

#[derive(Debug, Clone, Copy, Deserialize)]
struct TokenUsage {
    #[serde(default, alias = "outputTokens")]
    output_tokens: u64,
    #[serde(default, alias = "reasoningOutputTokens")]
    reasoning_output_tokens: u64,
}
