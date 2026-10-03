use std::collections::HashMap;

use crate::events::{AgentState, NormalizedEvent, ToolClass, ToolKey};

const MAX_ACTIVE_TOOLS: usize = 64;

#[derive(Debug)]
pub struct SessionState {
    turn_open: bool,
    awaiting_model: bool,
    phase: AgentState,
    active_tools: HashMap<ToolKey, ToolClass>,
    ended: bool,
}

impl Default for SessionState {
    fn default() -> Self {
        Self {
            turn_open: false,
            awaiting_model: false,
            phase: AgentState::Idle,
            active_tools: HashMap::new(),
            ended: false,
        }
    }
}

impl SessionState {
    pub fn phase(&self) -> AgentState {
        self.phase
    }

    pub fn turn_open(&self) -> bool {
        self.turn_open
    }

    /// True while the model is producing output that has not reached the
    /// transcript yet: after a prompt, and after every tool has returned.
    /// Transcripts record content blocks only once they are complete.
    pub fn awaiting_model(&self) -> bool {
        self.awaiting_model
    }

    pub fn active_tool_count(&self) -> usize {
        self.active_tools.len()
    }

    pub fn has_mutation_tool(&self) -> bool {
        self.active_tools
            .values()
            .any(|class| *class == ToolClass::Mutation)
    }

    pub fn accepts(&self, event: &NormalizedEvent) -> bool {
        !self.ended || matches!(event, NormalizedEvent::TurnStart | NormalizedEvent::TurnEnd)
    }

    /// A timeout is not an authoritative completion signal. Fresh evidence
    /// from the same turn must still be accepted when the agent resumes.
    pub(super) fn mark_stale(&mut self) {
        self.ended = false;
    }

    pub fn apply(&mut self, event: &NormalizedEvent) {
        if !self.accepts(event) {
            return;
        }
        match event {
            NormalizedEvent::TurnStart => {
                self.ended = false;
                self.turn_open = true;
                self.awaiting_model = true;
                self.active_tools.clear();
                self.phase = AgentState::Thinking;
            }
            NormalizedEvent::ThinkingPulse { .. } => {
                if self.active_tools.is_empty() {
                    self.phase = AgentState::Thinking;
                }
            }
            NormalizedEvent::WritingPulse { .. } => {
                if self.active_tools.is_empty() {
                    self.phase = AgentState::Writing;
                }
            }
            NormalizedEvent::ToolStart { id, class } => {
                if self.active_tools.len() < MAX_ACTIVE_TOOLS || self.active_tools.contains_key(id)
                {
                    self.active_tools.insert(id.clone(), *class);
                }
                self.awaiting_model = false;
                self.phase = AgentState::Tool;
            }
            NormalizedEvent::ToolEnd { id } => {
                match id {
                    Some(key) => {
                        self.active_tools.remove(key);
                    }
                    None => {
                        if let Some(key) = self.active_tools.keys().next().cloned() {
                            self.active_tools.remove(&key);
                        }
                    }
                }

                self.awaiting_model = self.active_tools.is_empty();
                self.phase = if self.awaiting_model {
                    AgentState::Thinking
                } else {
                    AgentState::Tool
                };
            }
            NormalizedEvent::TurnEnd => {
                self.ended = true;
                self.turn_open = false;
                self.awaiting_model = false;
                self.active_tools.clear();
                self.phase = AgentState::Idle;
            }
            NormalizedEvent::UsagePulse { .. } => {}
        }
    }

    /// Applies an event replayed from history: state is reconstructed, but
    /// the model is not assumed to be working now.
    pub fn apply_history(&mut self, event: &NormalizedEvent) {
        self.apply(event);
        self.awaiting_model = false;
    }
}
