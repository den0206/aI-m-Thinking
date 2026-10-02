use crate::events::{Confidence, NormalizedEvent, ToolKey, classify_tool};
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
        let record: ClaudeRecord = serde_json::from_reader(reader)?;
        let mut out = Vec::new();

        match record.kind.as_deref() {
            Some("assistant") => {
                if let Some(message) = record.message {
                    for block in message.content.0 {
                        match block.kind.as_deref() {
                            Some("thinking") => out.push(NormalizedEvent::ThinkingPulse {
                                units: 1,
                                confidence: Confidence::Medium,
                            }),
                            Some("text") => out.push(NormalizedEvent::WritingPulse {
                                units: 1,
                                confidence: Confidence::Medium,
                            }),
                            Some("tool_use") => {
                                let id = block.id.map(ToolKey::new).unwrap_or_else(|| {
                                    self.anonymous_tool = self.anonymous_tool.wrapping_add(1);
                                    ToolKey::new(format!("claude-anon-{}", self.anonymous_tool))
                                });
                                out.push(NormalizedEvent::ToolStart {
                                    id,
                                    class: classify_tool(block.name.as_deref().unwrap_or("")),
                                });
                            }
                            _ => {}
                        }
                    }
                }
            }
            Some("user") => {
                let mut results = 0;
                if let Some(message) = record.message {
                    for block in message.content.0 {
                        if block.kind.as_deref() == Some("tool_result") {
                            results += 1;
                            out.push(NormalizedEvent::ToolEnd {
                                id: block.tool_use_id.map(ToolKey::new),
                            });
                        }
                    }
                }

                if results == 0 {
                    if record.tool_use_result.is_some()
                        || record.source_tool_assistant_uuid.is_some()
                    {
                        out.push(NormalizedEvent::ToolEnd { id: None });
                    } else {
                        out.push(NormalizedEvent::TurnStart);
                    }
                }
            }
            Some("system") if record.subtype.as_deref() == Some("turn_duration") => {
                out.push(NormalizedEvent::TurnEnd)
            }
            _ => {}
        }

        Ok(out)
    }
}

#[derive(Deserialize)]
struct ClaudeRecord {
    #[serde(rename = "type")]
    kind: Option<String>,
    subtype: Option<String>,
    message: Option<ClaudeMessage>,
    #[serde(rename = "toolUseResult")]
    tool_use_result: Option<IgnoredAny>,
    #[serde(rename = "sourceToolAssistantUUID")]
    source_tool_assistant_uuid: Option<IgnoredAny>,
}

#[derive(Deserialize)]
struct ClaudeMessage {
    #[serde(default, deserialize_with = "deserialize_content")]
    content: ClaudeContent,
}

#[derive(Debug, Default)]
struct ClaudeContent(Vec<ClaudeBlock>);

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
                    None => return Ok(ClaudeContent(blocks)),
                }
            }

            while seq.next_element::<IgnoredAny>()?.is_some() {}
            Ok(ClaudeContent(blocks))
        }

        fn visit_str<E>(self, _: &str) -> Result<Self::Value, E> {
            Ok(ClaudeContent::default())
        }

        fn visit_string<E>(self, _: String) -> Result<Self::Value, E> {
            Ok(ClaudeContent::default())
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
