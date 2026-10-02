use std::collections::VecDeque;
use std::time::Duration;

use super::SessionState;
use crate::events::{AgentState, Confidence, NormalizedEvent, ToolClass};

const MAX_USAGE_INTERVALS: usize = 4;
const REALTIME_USAGE_MAX_INTERVAL: Duration = Duration::from_millis(1500);
const RISE_TAU_MS: f32 = 120.0;
const FALL_TAU_MS: f32 = 550.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UsageCadence {
    Realtime,
    Sparse,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActivityBasis {
    ReasoningUsage,
    ReasoningRecord,
    TextRecord,
    ToolEvent,
    StateBaseline,
    Mixed,
}

impl ActivityBasis {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::ReasoningUsage => "reasoning_usage",
            Self::ReasoningRecord => "reasoning_record",
            Self::TextRecord => "text_record",
            Self::ToolEvent => "tool_event",
            Self::StateBaseline => "state_baseline",
            Self::Mixed => "mixed",
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub struct ActivitySample {
    pub phase: AgentState,
    pub intensity: f32,
    pub confidence: Confidence,
    pub basis: ActivityBasis,
}

#[derive(Debug, Clone, Copy)]
struct Impulse {
    value: f32,
    at: Duration,
    tau_ms: f32,
}

impl Impulse {
    fn value_at(self, now: Duration) -> f32 {
        let elapsed_ms = now.saturating_sub(self.at).as_secs_f32() * 1000.0;
        self.value * (-elapsed_ms / self.tau_ms).exp()
    }
}

#[derive(Debug)]
pub struct ActivityEngine {
    state: SessionState,
    thinking: Option<Impulse>,
    writing: Option<Impulse>,
    mutation: Option<Impulse>,
    usage_intervals: VecDeque<Duration>,
    last_usage_at: Option<Duration>,
    token_score: f32,
    last_signal_at: Duration,
    confidence: Confidence,
    basis: ActivityBasis,
    smoothed: f32,
    last_sample_at: Duration,
}

impl ActivityEngine {
    pub fn new(now: Duration) -> Self {
        Self {
            state: SessionState::default(),
            thinking: None,
            writing: None,
            mutation: None,
            usage_intervals: VecDeque::with_capacity(MAX_USAGE_INTERVALS),
            last_usage_at: None,
            token_score: 0.0,
            last_signal_at: now,
            confidence: Confidence::Low,
            basis: ActivityBasis::StateBaseline,
            smoothed: 0.0,
            last_sample_at: now,
        }
    }

    pub fn state(&self) -> &SessionState {
        &self.state
    }

    pub fn usage_cadence(&self) -> UsageCadence {
        if self.usage_intervals.len() < 2 {
            return UsageCadence::Unknown;
        }

        let mut values: Vec<_> = self.usage_intervals.iter().copied().collect();
        values.sort_unstable();
        let median = values[values.len() / 2];

        if median <= REALTIME_USAGE_MAX_INTERVAL {
            UsageCadence::Realtime
        } else {
            UsageCadence::Sparse
        }
    }

    pub fn apply(&mut self, event: &NormalizedEvent, now: Duration) {
        self.state.apply(event);

        match event {
            NormalizedEvent::TurnStart => {
                self.last_signal_at = now;
                self.confidence = Confidence::Low;
                self.basis = ActivityBasis::StateBaseline;
            }
            NormalizedEvent::ThinkingPulse { units, confidence } => {
                self.thinking = Some(Impulse {
                    value: impulse_value(*units, 0.35, 0.56),
                    at: now,
                    tau_ms: 700.0,
                });
                self.last_signal_at = now;
                self.confidence = *confidence;
                self.basis = ActivityBasis::ReasoningRecord;
            }
            NormalizedEvent::WritingPulse { units, confidence } => {
                self.writing = Some(Impulse {
                    value: impulse_value(*units, 0.45, 0.68),
                    at: now,
                    tau_ms: 600.0,
                });
                self.last_signal_at = now;
                self.confidence = *confidence;
                self.basis = ActivityBasis::TextRecord;
            }
            NormalizedEvent::ToolStart { class, .. } => {
                if *class == ToolClass::Mutation {
                    self.mutation = Some(Impulse {
                        value: 0.55,
                        at: now,
                        tau_ms: 450.0,
                    });
                }
                self.last_signal_at = now;
                self.confidence = Confidence::Medium;
                self.basis = ActivityBasis::ToolEvent;
            }
            NormalizedEvent::ToolEnd { .. } => {
                self.last_signal_at = now;
                self.confidence = Confidence::Medium;
                self.basis = ActivityBasis::ToolEvent;
            }
            NormalizedEvent::UsagePulse {
                output_tokens,
                reasoning_tokens,
            } => self.apply_usage(*output_tokens, *reasoning_tokens, now),
            NormalizedEvent::TurnEnd => {
                self.last_signal_at = now;
                self.token_score = 0.0;
                self.confidence = Confidence::Low;
                self.basis = ActivityBasis::StateBaseline;
            }
        }
    }

    pub fn sample(&mut self, now: Duration) -> ActivitySample {
        let thinking = self.thinking.map_or(0.0, |value| value.value_at(now));
        let writing = self.writing.map_or(0.0, |value| value.value_at(now));
        let mutation = self.mutation.map_or(0.0, |value| value.value_at(now));

        if self.usage_cadence() != UsageCadence::Realtime {
            self.token_score = 0.0;
        }

        let baseline = self.state_baseline(now);
        let target = thinking
            .max(writing)
            .max(mutation)
            .max(self.token_score)
            .max(baseline)
            * confidence_multiplier(self.effective_confidence(now));

        let dt_ms = now.saturating_sub(self.last_sample_at).as_secs_f32() * 1000.0;
        let tau = if target > self.smoothed {
            RISE_TAU_MS
        } else {
            FALL_TAU_MS
        };
        let alpha = if dt_ms <= 0.0 {
            0.0
        } else {
            1.0 - (-dt_ms / tau).exp()
        };

        self.smoothed += alpha * (target - self.smoothed);
        self.smoothed = self.smoothed.clamp(0.0, 1.0);
        self.last_sample_at = now;

        ActivitySample {
            phase: self.state.phase(),
            intensity: self.smoothed,
            confidence: self.effective_confidence(now),
            basis: if count_nonzero([thinking, writing, mutation, self.token_score, baseline]) > 1 {
                ActivityBasis::Mixed
            } else {
                self.basis
            },
        }
    }

    fn apply_usage(&mut self, output: u32, reasoning: u32, now: Duration) {
        let Some(previous_at) = self.last_usage_at.replace(now) else {
            self.last_signal_at = now;
            return;
        };

        let interval = now.saturating_sub(previous_at);
        self.usage_intervals.push_back(interval);
        while self.usage_intervals.len() > MAX_USAGE_INTERVALS {
            self.usage_intervals.pop_front();
        }

        if self.usage_cadence() == UsageCadence::Realtime && !interval.is_zero() {
            let seconds = interval.as_secs_f32();
            let reasoning_per_second = reasoning as f32 / seconds;
            let output_per_second = output as f32 / seconds;
            let reasoning_score = 1.0 - (-reasoning_per_second / 35.0).exp();
            let output_score = 1.0 - (-output_per_second / 45.0).exp();
            self.token_score = reasoning_score.max(output_score).clamp(0.0, 1.0);
            self.confidence = Confidence::High;
            self.basis = ActivityBasis::ReasoningUsage;
        }

        self.last_signal_at = now;
    }

    fn state_baseline(&self, now: Duration) -> f32 {
        let base = match self.state.phase() {
            AgentState::Idle => 0.0,
            AgentState::Thinking => 0.18,
            AgentState::Writing => 0.25,
            AgentState::Tool => {
                if self.state.has_mutation_tool() {
                    0.05
                } else {
                    0.0
                }
            }
        };

        base * freshness(now.saturating_sub(self.last_signal_at))
    }

    fn effective_confidence(&self, now: Duration) -> Confidence {
        if now.saturating_sub(self.last_signal_at) > Duration::from_secs(3) {
            Confidence::Low
        } else {
            self.confidence
        }
    }
}

fn impulse_value(units: u32, base: f32, cap: f32) -> f32 {
    if units == 0 {
        return 0.0;
    }

    (base + (units.saturating_sub(1).min(8) as f32 * 0.03)).min(cap)
}

fn freshness(age: Duration) -> f32 {
    let ms = age.as_millis() as f32;
    if ms <= 1500.0 {
        1.0
    } else if ms <= 3000.0 {
        1.0 - 0.95 * ((ms - 1500.0) / 1500.0)
    } else if ms <= 5000.0 {
        0.05 * (1.0 - ((ms - 3000.0) / 2000.0))
    } else {
        0.0
    }
}

fn confidence_multiplier(confidence: Confidence) -> f32 {
    match confidence {
        Confidence::High => 1.0,
        Confidence::Medium => 0.8,
        Confidence::Low => 0.55,
    }
}

fn count_nonzero(values: [f32; 5]) -> usize {
    values.into_iter().filter(|value| *value > 0.001).count()
}
