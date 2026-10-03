use crate::events::{Confidence, NormalizedEvent, ParsedRecord, ToolKey, classify_tool};
use crate::timestamp::parse_utc_ms;
use serde::de::{IgnoredAny, SeqAccess, Visitor};
use serde::{Deserialize, Deserializer};
use std::{fmt, io::Read};

const MAX_CONTENT_BLOCKS: usize = 128;

#[derive(Debug, Default)]
pub struct ClaudeParser {
    anonymous_tool: u64,
}

impl ClaudeParser {
    pub fn parse<R: Read>(&mut self, reader: R) -> serde_json::Result<Vec<NormalizedEvent>> {
        self.parse_record(reader).map(|record| record.events)
    }

    pub fn parse_record<R: Read>(&mut self, reader: R) -> serde_json::Result<ParsedRecord> {
        let record: ClaudeRecord = serde_json::from_reader(reader)?;
        let mut out = Vec::new();
        // Subagents and long commands write runs of `progress` rows mid-turn.
        let quiet = matches!(
            record.kind.as_deref(),
            Some("progress" | "file-history-snapshot" | "summary" | "queue-operation" | "system")
        ) || record.is_meta == Some(true);

        match record.kind.as_deref() {
            Some("assistant") => {
                if let Some(message) = &record.message {
                    self.assistant(message, &mut out);
                }
            }
            Some("user") if record.is_meta != Some(true) => self.user(&record, &mut out),
            Some("system") if record.subtype.as_deref() == Some("turn_duration") => {
                out.push(NormalizedEvent::TurnEnd)
            }
            _ => {}
        }

        Ok(ParsedRecord {
            events: out,
            timestamp_ms: record.timestamp.as_deref().and_then(parse_utc_ms),
            agent_version: record.version,
            quiet,
        })
    }

    fn assistant(&mut self, message: &ClaudeMessage, out: &mut Vec<NormalizedEvent>) {
        for block in &message.content.blocks {
            match block.kind.as_deref() {
                Some("thinking" | "redacted_thinking") => {
                    out.push(NormalizedEvent::ThinkingPulse {
                        units: 1,
                        confidence: Confidence::Medium,
                    })
                }
                Some("text") => out.push(NormalizedEvent::WritingPulse {
                    units: 1,
                    confidence: Confidence::Medium,
                }),
                Some("tool_use" | "server_tool_use") => {
                    let id = block.id.clone().map(Into::into).unwrap_or_else(|| {
                        self.anonymous_tool = self.anonymous_tool.wrapping_add(1);
                        ToolKey::from(format!("claude-anon-{}", self.anonymous_tool))
                    });
                    out.push(NormalizedEvent::ToolStart {
                        id,
                        class: classify_tool(block.name.as_deref().unwrap_or("")),
                    });
                }
                _ => {}
            }
        }

        // Current Claude Code versions do not write `turn_duration`; the final
        // API message of a turn carries a terminal stop reason instead.
        if matches!(
            message.stop_reason.as_deref(),
            Some("end_turn" | "stop_sequence" | "refusal")
        ) {
            out.push(NormalizedEvent::TurnEnd);
        }
    }

    fn user(&mut self, record: &ClaudeRecord, out: &mut Vec<NormalizedEvent>) {
        let Some(message) = &record.message else {
            return;
        };

        let mut results = 0;
        for block in &message.content.blocks {
            if block.kind.as_deref() == Some("tool_result") {
                results += 1;
                out.push(NormalizedEvent::ToolEnd {
                    id: block.tool_use_id.clone().map(Into::into),
                });
            }
        }
        if results > 0 {
            return;
        }

        if record.tool_use_result.is_some() || record.source_tool_assistant_uuid.is_some() {
            out.push(NormalizedEvent::ToolEnd { id: None });
            return;
        }

        let human = record
            .origin
            .as_ref()
            .is_some_and(|origin| origin.kind.as_deref() == Some("human"));
        let attachment = message
            .content
            .blocks
            .iter()
            .any(|block| matches!(block.kind.as_deref(), Some("image" | "document")));

        match message.content.text {
            // Local command echoes and their output never reach the model.
            // A human-origin `<command-message>` row is a slash command or
            // skill the model runs, so it starts a turn.
            Some(TextKind::LocalCommand) if !human => return,
            Some(TextKind::Interrupt) => {
                out.push(NormalizedEvent::TurnEnd);
                return;
            }
            Some(TextKind::Prompt | TextKind::LocalCommand) | None => {}
        }

        if human || message.content.text.is_some() || attachment {
            out.push(NormalizedEvent::TurnStart);
        } else if !message.content.blocks.is_empty() {
            // Text-only block lists are written for interruptions and injected
            // context, not typed prompts. The model is not known to be working,
            // so close the turn rather than keep typing.
            out.push(NormalizedEvent::TurnEnd);
        }
    }
}

#[derive(Deserialize)]
struct ClaudeRecord {
    #[serde(rename = "type")]
    kind: Option<String>,
    timestamp: Option<String>,
    version: Option<String>,
    #[serde(rename = "isMeta")]
    is_meta: Option<bool>,
    origin: Option<ClaudeOrigin>,
    subtype: Option<String>,
    message: Option<ClaudeMessage>,
    #[serde(rename = "toolUseResult")]
    tool_use_result: Option<IgnoredAny>,
    #[serde(rename = "sourceToolAssistantUUID")]
    source_tool_assistant_uuid: Option<IgnoredAny>,
}

#[derive(Deserialize)]
struct ClaudeOrigin {
    kind: Option<String>,
}

#[derive(Deserialize)]
struct ClaudeMessage {
    #[serde(default, deserialize_with = "deserialize_content")]
    content: ClaudeContent,
    stop_reason: Option<String>,
}

/// Content is either a plain string or a list of blocks.
#[derive(Debug, Default)]
struct ClaudeContent {
    blocks: Vec<ClaudeBlock>,
    /// Set for string content. Only a prefix is inspected; the text itself is
    /// never retained.
    text: Option<TextKind>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TextKind {
    Prompt,
    /// `<command-name>`, `<local-command-stdout>`, `<bash-input>` and similar
    /// echoes of commands the user ran locally.
    LocalCommand,
    /// `[Request interrupted by user]` markers.
    Interrupt,
}

impl TextKind {
    fn classify(text: &str) -> Self {
        let text = text.trim_start();
        if text.starts_with("[Request interrupted by user") {
            Self::Interrupt
        } else if ["<command-", "<local-command-", "<bash-"]
            .iter()
            .any(|prefix| text.starts_with(prefix))
        {
            Self::LocalCommand
        } else {
            Self::Prompt
        }
    }
}

#[derive(Debug, Deserialize)]
struct ClaudeBlock {
    #[serde(rename = "type")]
    kind: Option<String>,
    id: Option<String>,
    name: Option<String>,
    tool_use_id: Option<String>,
}

fn deserialize_content<'de, D: Deserializer<'de>>(d: D) -> Result<ClaudeContent, D::Error> {
    struct V;

    impl<'de> Visitor<'de> for V {
        type Value = ClaudeContent;

        fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            f.write_str("Claude content")
        }

        fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Self::Value, A::Error> {
            let mut blocks = Vec::with_capacity(8);
            while blocks.len() < MAX_CONTENT_BLOCKS {
                match seq.next_element::<ClaudeBlock>()? {
                    Some(value) => blocks.push(value),
                    None => return Ok(ClaudeContent { blocks, text: None }),
                }
            }

            while seq.next_element::<IgnoredAny>()?.is_some() {}
            Ok(ClaudeContent { blocks, text: None })
        }

        fn visit_str<E>(self, value: &str) -> Result<Self::Value, E> {
            Ok(ClaudeContent {
                blocks: Vec::new(),
                text: Some(TextKind::classify(value)),
            })
        }

        fn visit_string<E>(self, value: String) -> Result<Self::Value, E> {
            Ok(ClaudeContent {
                blocks: Vec::new(),
                text: Some(TextKind::classify(&value)),
            })
        }

        fn visit_none<E>(self) -> Result<Self::Value, E> {
            Ok(ClaudeContent::default())
        }

        fn visit_unit<E>(self) -> Result<Self::Value, E> {
            Ok(ClaudeContent::default())
        }
    }

    d.deserialize_any(V)
}
