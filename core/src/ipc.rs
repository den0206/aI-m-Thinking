use std::io::{self, Read, Write};

use serde::{Deserialize, Serialize};

use crate::activity::ActivitySample;
use crate::events::ToolClass;

pub const PROTOCOL_VERSION: u8 = 1;
pub const MAX_IPC_RECORD_BYTES: usize = 32 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum AgentKind {
    Claude,
    Codex,
}

impl AgentKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize)]
pub struct AgentFlags {
    pub claude: bool,
    pub codex: bool,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientCommand {
    Configure {
        v: u8,
        agents: AgentFlags,
        #[serde(default)]
        extra_roots: Vec<String>,
    },
    SetAgentEnabled {
        v: u8,
        agent: AgentKind,
        enabled: bool,
    },
    Rescan {
        v: u8,
    },
    Ping {
        v: u8,
        id: u64,
    },
    Shutdown {
        v: u8,
    },
}

impl ClientCommand {
    pub fn version(&self) -> u8 {
        match self {
            Self::Configure { v, .. }
            | Self::SetAgentEnabled { v, .. }
            | Self::Rescan { v }
            | Self::Ping { v, .. }
            | Self::Shutdown { v } => *v,
        }
    }
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ServerMessage<'a> {
    Hello {
        v: u8,
        seq: u64,
        core_version: &'static str,
        protocol_min: u8,
        protocol_max: u8,
        capabilities: [&'static str; 3],
    },
    Ready {
        v: u8,
        seq: u64,
    },
    Pong {
        v: u8,
        seq: u64,
        id: u64,
    },
    ObserverStatus {
        v: u8,
        seq: u64,
        agent: &'static str,
        status: &'static str,
    },
    SessionOpened {
        v: u8,
        seq: u64,
        session: u32,
        agent: &'static str,
    },
    SessionClosed {
        v: u8,
        seq: u64,
        session: u32,
        agent: &'static str,
    },
    Activity {
        v: u8,
        seq: u64,
        session: u32,
        agent: &'static str,
        phase: &'static str,
        intensity: f32,
        confidence: &'static str,
        tool_class: Option<&'static str>,
        basis: &'static str,
        at_ms: u64,
    },
    Error {
        v: u8,
        seq: u64,
        severity: &'static str,
        code: &'static str,
        component: &'a str,
        recoverable: bool,
    },
}

pub struct ServerWriter<W> {
    writer: W,
    seq: u64,
}

impl<W: Write> ServerWriter<W> {
    pub fn new(writer: W) -> Self {
        Self { writer, seq: 0 }
    }

    pub fn hello(&mut self) -> io::Result<()> {
        let seq = self.next_seq();
        self.write(ServerMessage::Hello {
            v: PROTOCOL_VERSION,
            seq,
            core_version: env!("CARGO_PKG_VERSION"),
            protocol_min: PROTOCOL_VERSION,
            protocol_max: PROTOCOL_VERSION,
            capabilities: ["claude-passive", "codex-legacy", "codex-paginated"],
        })
    }

    pub fn ready(&mut self) -> io::Result<()> {
        let seq = self.next_seq();
        self.write(ServerMessage::Ready {
            v: PROTOCOL_VERSION,
            seq,
        })
    }

    pub fn pong(&mut self, id: u64) -> io::Result<()> {
        let seq = self.next_seq();
        self.write(ServerMessage::Pong {
            v: PROTOCOL_VERSION,
            seq,
            id,
        })
    }

    pub fn observer_status(&mut self, agent: AgentKind, status: &'static str) -> io::Result<()> {
        let seq = self.next_seq();
        self.write(ServerMessage::ObserverStatus {
            v: PROTOCOL_VERSION,
            seq,
            agent: agent.as_str(),
            status,
        })
    }

    pub fn session_opened(&mut self, session: u32, agent: AgentKind) -> io::Result<()> {
        let seq = self.next_seq();
        self.write(ServerMessage::SessionOpened {
            v: PROTOCOL_VERSION,
            seq,
            session,
            agent: agent.as_str(),
        })
    }

    pub fn session_closed(&mut self, session: u32, agent: AgentKind) -> io::Result<()> {
        let seq = self.next_seq();
        self.write(ServerMessage::SessionClosed {
            v: PROTOCOL_VERSION,
            seq,
            session,
            agent: agent.as_str(),
        })
    }

    pub fn activity(
        &mut self,
        session: u32,
        agent: AgentKind,
        sample: ActivitySample,
        tool_class: Option<ToolClass>,
        at_ms: u64,
    ) -> io::Result<()> {
        let seq = self.next_seq();
        self.write(ServerMessage::Activity {
            v: PROTOCOL_VERSION,
            seq,
            session,
            agent: agent.as_str(),
            phase: sample.phase.as_str(),
            intensity: sample.intensity,
            confidence: sample.confidence.as_str(),
            tool_class: tool_class.map(ToolClass::as_str),
            basis: sample.basis.as_str(),
            at_ms,
        })
    }

    pub fn error(
        &mut self,
        severity: &'static str,
        code: &'static str,
        component: &str,
        recoverable: bool,
    ) -> io::Result<()> {
        let seq = self.next_seq();
        self.write(ServerMessage::Error {
            v: PROTOCOL_VERSION,
            seq,
            severity,
            code,
            component,
            recoverable,
        })
    }

    fn next_seq(&mut self) -> u64 {
        self.seq = self.seq.saturating_add(1);
        self.seq
    }

    fn write(&mut self, message: ServerMessage<'_>) -> io::Result<()> {
        serde_json::to_writer(&mut self.writer, &message).map_err(io::Error::other)?;
        self.writer.write_all(b"\n")?;
        self.writer.flush()
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum LineRead {
    Eof,
    Data(Vec<u8>),
    Oversized,
}

pub fn read_bounded_line<R: Read>(reader: &mut R) -> io::Result<LineRead> {
    let mut line = Vec::with_capacity(256);
    let mut byte = [0_u8; 1];
    let mut oversized = false;

    loop {
        match reader.read(&mut byte)? {
            0 if line.is_empty() && !oversized => return Ok(LineRead::Eof),
            0 => {
                return Ok(if oversized {
                    LineRead::Oversized
                } else {
                    LineRead::Data(line)
                });
            }
            _ if byte[0] == b'\n' => {
                return Ok(if oversized {
                    LineRead::Oversized
                } else {
                    LineRead::Data(line)
                });
            }
            _ if oversized => {}
            _ if line.len() < MAX_IPC_RECORD_BYTES => line.push(byte[0]),
            _ => oversized = true,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bounded_reader_rejects_oversized_lines_and_recovers() {
        let mut input = vec![b'x'; MAX_IPC_RECORD_BYTES + 1];
        input.extend_from_slice(b"\n{}\n");
        let mut cursor = io::Cursor::new(input);

        assert_eq!(read_bounded_line(&mut cursor).unwrap(), LineRead::Oversized);
        assert_eq!(
            read_bounded_line(&mut cursor).unwrap(),
            LineRead::Data(b"{}".to_vec())
        );
    }

    #[test]
    fn command_version_is_explicit() {
        let command: ClientCommand =
            serde_json::from_slice(br#"{"v":1,"type":"ping","id":7}"#).unwrap();
        assert_eq!(command.version(), PROTOCOL_VERSION);
    }

    #[test]
    fn activity_message_contains_only_metadata() {
        let mut output = Vec::new();
        let mut writer = ServerWriter::new(&mut output);
        writer
            .activity(
                7,
                AgentKind::Codex,
                ActivitySample {
                    phase: crate::events::AgentState::Thinking,
                    intensity: 0.5,
                    confidence: crate::events::Confidence::High,
                    basis: crate::activity::ActivityBasis::ReasoningUsage,
                },
                None,
                120,
            )
            .unwrap();

        let text = String::from_utf8(output).unwrap();
        assert!(text.contains("\"session\":7"));
        assert!(text.contains("\"agent\":\"codex\""));
        assert!(!text.contains("path"));
        assert!(!text.contains("prompt"));
        assert!(!text.contains("reasoning_text"));
    }
}
