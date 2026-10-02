#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Confidence { High, Medium, Low }

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToolClass { Mutation, Shell, Read, Search, SubAgent, Mcp, Generic }

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ToolKey(Box<str>);

impl ToolKey {
    pub fn new(value: impl Into<Box<str>>) -> Self { Self(value.into()) }
    pub fn as_str(&self) -> &str { &self.0 }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NormalizedEvent {
    TurnStart,
    ThinkingPulse { units: u32, confidence: Confidence },
    WritingPulse { units: u32, confidence: Confidence },
    ToolStart { id: ToolKey, class: ToolClass },
    ToolEnd { id: Option<ToolKey> },
    UsagePulse { output_tokens: u32, reasoning_tokens: u32 },
    TurnEnd,
}

pub fn classify_tool(name: &str) -> ToolClass {
    let n = name.to_ascii_lowercase();
    if n.starts_with("mcp__") || n.contains("mcp_tool") { return ToolClass::Mcp; }
    match n.as_str() {
        "edit" | "write" | "notebookedit" | "notebook_edit" => ToolClass::Mutation,
        "bash" | "exec_command" | "local_shell" | "local_shell_call" => ToolClass::Shell,
        "read" | "glob" | "grep" => ToolClass::Read,
        "websearch" | "webfetch" | "web_search" | "web_search_call" => ToolClass::Search,
        "agent" | "task" | "subagent" => ToolClass::SubAgent,
        _ => ToolClass::Generic,
    }
}
