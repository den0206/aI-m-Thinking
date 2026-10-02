use std::collections::HashMap;

use crate::events::{AgentState, NormalizedEvent, ToolClass, ToolKey};

const MAX_ACTIVE_TOOLS: usize = 64;

#[derive(Debug)]
pub struct SessionState {
    turn_open: bool,
    phase: AgentState,
    active_tools: HashMap<ToolKey, ToolClass>,
}

impl Default for SessionState {
    fn default() -> Self {
        Self {
            turn_open: false,
            phase: AgentState::Idle,
            active_tools: HashMap::new(),
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

    pub fn active_tool_count(&self) -> usize {
        self.active_tools.len()
    }

    pub fn has_mutation_tool(&self) -> bool {
        self.active_tools
            .values()
            .any(|class| *class == ToolClass::Mutation)
    }

    pub fn apply(&mut self, event: &NormalizedEvent) {
        match event {
            NormalizedEvent::TurnStart => {
                self.turn_open = true;
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
                if self.active_tools.len() < MAX_ACTIVE_TOOLS || self.active_tools.contains_key(id) {
                    self.active_tools.insert(id.clone(), *class);
                }
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

                self.phase = if self.active_tools.is_empty() {
                    AgentState::Thinking
                } else {
                    AgentState::Tool
                };
            }
            NormalizedEvent::TurnEnd => {
                self.turn_open = false;
                self.active_tools.clear();
                self.phase = AgentState::Idle;
            }
            NormalizedEvent::UsagePulse { .. } => {}
        }
    }
}
