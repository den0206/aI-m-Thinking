#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Confidence {
    High,
    Medium,
    Low,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentState {
    Idle,
    Thinking,
    Writing,
    Tool,
}

impl AgentState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Thinking => "thinking",
            Self::Writing => "writing",
            Self::Tool => "tool",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToolClass {
    Mutation,
    Shell,
    Read,
    Search,
    SubAgent,
    Mcp,
    Generic,
}

impl ToolClass {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Mutation => "mutation",
            Self::Shell => "shell",
            Self::Read => "read",
            Self::Search => "search",
            Self::SubAgent => "subagent",
            Self::Mcp => "mcp",
            Self::Generic => "generic",
        }
    }
}

pub type ToolKey = Box<str>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NormalizedEvent {
    TurnStart,
    ThinkingPulse {
        units: u32,
        confidence: Confidence,
    },
    WritingPulse {
        units: u32,
        confidence: Confidence,
    },
    ToolStart {
        id: ToolKey,
        class: ToolClass,
    },
    ToolEnd {
        id: Option<ToolKey>,
    },
    UsagePulse {
        output_tokens: u32,
        reasoning_tokens: u32,
    },
    TurnEnd,
}

/// Events from one transcript record plus the record's own write time, which
/// lets the observer tell live activity from replayed history.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ParsedRecord {
    pub events: Vec<NormalizedEvent>,
    pub timestamp_ms: Option<i64>,
}

/// Classifies Claude Code and Codex tool names. Unknown names are `Generic`.
pub fn classify_tool(name: &str) -> ToolClass {
    let n = name.to_ascii_lowercase();
    if n.starts_with("mcp__") || n.contains("mcp_tool") {
        return ToolClass::Mcp;
    }

    match n.as_str() {
        "edit" | "multiedit" | "write" | "notebookedit" | "notebook_edit" | "apply_patch" => {
            ToolClass::Mutation
        }
        "bash" | "bashoutput" | "exec_command" | "shell" | "shell_command" | "write_stdin"
        | "local_shell" | "local_shell_call" => ToolClass::Shell,
        "read" | "glob" | "grep" | "ls" | "read_file" | "list_dir" | "grep_files"
        | "view_image" => ToolClass::Read,
        "websearch" | "webfetch" | "web_search" | "tool_search" | "toolsearch" => ToolClass::Search,
        "agent" | "task" | "subagent" | "spawn_agent" | "wait_agent" => ToolClass::SubAgent,
        _ => ToolClass::Generic,
    }
}
