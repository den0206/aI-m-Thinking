use std::time::Duration;

use im_thinking_core::activity::{ActivityEngine, SessionState, UsageCadence};
use im_thinking_core::events::{AgentState, Confidence, NormalizedEvent, ToolClass, ToolKey};

fn ms(value: u64) -> Duration {
    Duration::from_millis(value)
}

#[test]
fn reducer_handles_parallel_tools() {
    let mut state = SessionState::default();
    state.apply(&NormalizedEvent::TurnStart);
    state.apply(&NormalizedEvent::ToolStart {
        id: ToolKey::new("a"),
        class: ToolClass::Read,
    });
    state.apply(&NormalizedEvent::ToolStart {
        id: ToolKey::new("b"),
        class: ToolClass::Shell,
    });

    assert_eq!(state.phase(), AgentState::Tool);
    assert_eq!(state.active_tool_count(), 2);

    state.apply(&NormalizedEvent::ToolEnd {
        id: Some(ToolKey::new("a")),
    });
    assert_eq!(state.phase(), AgentState::Tool);

    state.apply(&NormalizedEvent::ToolEnd {
        id: Some(ToolKey::new("b")),
    });
    assert_eq!(state.phase(), AgentState::Thinking);
}

#[test]
fn thinking_impulse_decays() {
    let mut engine = ActivityEngine::new(ms(0));
    engine.apply(&NormalizedEvent::TurnStart, ms(0));
    engine.apply(
        &NormalizedEvent::ThinkingPulse {
            units: 1,
            confidence: Confidence::Medium,
        },
        ms(100),
    );

    let early = engine.sample(ms(250)).intensity;
    let later = engine.sample(ms(2000)).intensity;
    assert!(early > 0.0);
    assert!(later < early);
}

#[test]
fn usage_requires_realtime_cadence_before_driving_activity() {
    let mut engine = ActivityEngine::new(ms(0));
    engine.apply(
        &NormalizedEvent::UsagePulse {
            output_tokens: 20,
            reasoning_tokens: 20,
        },
        ms(100),
    );
    engine.apply(
        &NormalizedEvent::UsagePulse {
            output_tokens: 20,
            reasoning_tokens: 20,
        },
        ms(700),
    );
    assert_eq!(engine.usage_cadence(), UsageCadence::Unknown);

    engine.apply(
        &NormalizedEvent::UsagePulse {
            output_tokens: 30,
            reasoning_tokens: 30,
        },
        ms(1300),
    );
    assert_eq!(engine.usage_cadence(), UsageCadence::Realtime);
    assert!(engine.sample(ms(1400)).intensity > 0.0);
}

#[test]
fn sparse_usage_does_not_create_token_burst() {
    let mut engine = ActivityEngine::new(ms(0));
    engine.apply(
        &NormalizedEvent::UsagePulse {
            output_tokens: 500,
            reasoning_tokens: 500,
        },
        ms(100),
    );
    engine.apply(
        &NormalizedEvent::UsagePulse {
            output_tokens: 500,
            reasoning_tokens: 500,
        },
        ms(30_100),
    );
    engine.apply(
        &NormalizedEvent::UsagePulse {
            output_tokens: 500,
            reasoning_tokens: 500,
        },
        ms(60_100),
    );

    assert_eq!(engine.usage_cadence(), UsageCadence::Sparse);
    assert_eq!(engine.sample(ms(60_200)).intensity, 0.0);
}

#[test]
fn shell_tool_decays_to_silence() {
    let mut engine = ActivityEngine::new(ms(0));
    engine.apply(&NormalizedEvent::TurnStart, ms(0));
    engine.apply(
        &NormalizedEvent::ToolStart {
            id: ToolKey::new("shell"),
            class: ToolClass::Shell,
        },
        ms(100),
    );

    let _ = engine.sample(ms(200));
    let late = engine.sample(ms(6000));
    assert_eq!(late.phase, AgentState::Tool);
    assert!(late.intensity < 0.01);
}

#[test]
fn mutation_tool_gets_a_short_impulse() {
    let mut engine = ActivityEngine::new(ms(0));
    engine.apply(
        &NormalizedEvent::ToolStart {
            id: ToolKey::new("edit"),
            class: ToolClass::Mutation,
        },
        ms(100),
    );

    let sample = engine.sample(ms(200));
    assert_eq!(sample.phase, AgentState::Tool);
    assert!(sample.intensity > 0.0);
}

#[test]
fn smoothing_rises_faster_than_it_falls() {
    let mut engine = ActivityEngine::new(ms(0));
    engine.apply(
        &NormalizedEvent::WritingPulse {
            units: 8,
            confidence: Confidence::High,
        },
        ms(0),
    );

    let risen = engine.sample(ms(120)).intensity;
    let after_fall_window = engine.sample(ms(670)).intensity;

    assert!(risen > 0.2);
    assert!(after_fall_window > 0.0);
}

#[test]
fn turn_end_returns_to_idle() {
    let mut engine = ActivityEngine::new(ms(0));
    engine.apply(&NormalizedEvent::TurnStart, ms(0));
    engine.apply(&NormalizedEvent::TurnEnd, ms(100));
    assert_eq!(engine.sample(ms(200)).phase, AgentState::Idle);
}
