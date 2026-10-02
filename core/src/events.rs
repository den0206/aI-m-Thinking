#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Confidence {
    High,
    Medium,
    Low,
}

impl Confidence {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::High => "high",
            Self::Medium => "medium",
            Self::Low => "low",
        }
    }
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

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ToolKey(Box<str>);

impl ToolKey {
    pub fn new(value: impl Into<Box<str>>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

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

pub fn classify_tool(name: &str) -> ToolClass {
    let n = name.to_ascii_lowercase();
    if n.starts_with("mcp__") || n.contains("mcp_tool") {
        return ToolClass::Mcp;
    }

    match n.as_str() {
        "edit" | "write" | "notebookedit" | "notebook_edit" => ToolClass::Mutation,
        "bash" | "exec_command" | "local_shell" | "local_shell_call" => ToolClass::Shell,
        "read" | "glob" | "grep" => ToolClass::Read,
        "websearch" | "webfetch" | "web_search" | "web_search_call" => ToolClass::Search,
        "agent" | "task" | "subagent" => ToolClass::SubAgent,
        _ => ToolClass::Generic,
    }
}
