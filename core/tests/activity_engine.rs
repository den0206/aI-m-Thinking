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
fn reducer_bounds_parallel_tool_state() {
    let mut state = SessionState::default();
    state.apply(&NormalizedEvent::TurnStart);

    for index in 0..100 {
        state.apply(&NormalizedEvent::ToolStart {
            id: ToolKey::new(format!("tool-{index}")),
            class: ToolClass::Read,
        });
    }

    assert_eq!(state.phase(), AgentState::Tool);
    assert_eq!(state.active_tool_count(), 64);
}

#[test]
fn thinking_impulse_decays() {
    let mut engine = ActivityEngine::new(ms(0));
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

#[test]
fn realtime_usage_score_decays_after_updates_stop() {
    let mut engine = ActivityEngine::new(ms(0));
    engine.apply(&NormalizedEvent::TurnStart, ms(0));
    for step in 1..6 {
        engine.apply(
            &NormalizedEvent::UsagePulse {
                output_tokens: 30,
                reasoning_tokens: 30,
            },
            ms(500 * step),
        );
    }
    assert_eq!(engine.usage_cadence(), UsageCadence::Realtime);
    assert!(engine.sample(ms(2600)).intensity > 0.3);

    // A long shell command runs; no further usage arrives.
    engine.apply(
        &NormalizedEvent::ToolStart {
            id: ToolKey::new("build"),
            class: ToolClass::Shell,
        },
        ms(2600),
    );

    let mut intensity = 1.0;
    for now in (2700..10_000).step_by(100) {
        intensity = engine.sample(ms(now)).intensity;
    }
    assert!(intensity < 0.005, "intensity stayed at {intensity}");
}

#[test]
fn stale_turn_expires_to_idle() {
    let mut engine = ActivityEngine::new(ms(0));
    engine.apply(&NormalizedEvent::TurnStart, ms(0));
    engine.apply(
        &NormalizedEvent::ToolStart {
            id: ToolKey::new("long"),
            class: ToolClass::Shell,
        },
        ms(100),
    );

    assert!(!engine.expire_stale_turn(ms(59_000), ms(60_000)));
    assert_eq!(engine.state().phase(), AgentState::Tool);

    assert!(engine.expire_stale_turn(ms(60_100), ms(60_000)));
    assert_eq!(engine.state().phase(), AgentState::Idle);
    assert_eq!(engine.state().active_tool_count(), 0);
    assert!(!engine.expire_stale_turn(ms(200_000), ms(60_000)));
}

#[test]
fn pending_model_output_sustains_activity_until_the_next_record() {
    let mut engine = ActivityEngine::new(ms(0));
    engine.apply(&NormalizedEvent::TurnStart, ms(0));

    // No record arrives for 30 s while the model thinks.
    let mut quiet = f32::MAX;
    for now in (500..30_000).step_by(100) {
        quiet = quiet.min(engine.sample(ms(now)).intensity);
    }
    assert!(quiet >= 0.2, "pending activity dropped to {quiet}");
    assert_eq!(engine.sample(ms(30_000)).phase, AgentState::Thinking);
}

#[test]
fn pending_activity_resumes_after_tools_return_and_stops_at_turn_end() {
    let mut engine = ActivityEngine::new(ms(0));
    engine.apply(&NormalizedEvent::TurnStart, ms(0));
    engine.apply(
        &NormalizedEvent::ToolStart {
            id: ToolKey::new("a"),
            class: ToolClass::Shell,
        },
        ms(1_000),
    );
    assert!(!engine.state().awaiting_model());

    engine.apply(
        &NormalizedEvent::ToolEnd {
            id: Some(ToolKey::new("a")),
        },
        ms(20_000),
    );
    assert!(engine.state().awaiting_model());
    let mut intensity = 0.0;
    for now in (20_000..30_000).step_by(100) {
        intensity = engine.sample(ms(now)).intensity;
    }
    assert!(intensity >= 0.2);

    engine.apply(&NormalizedEvent::TurnEnd, ms(30_000));
    for now in (30_000..35_000).step_by(100) {
        intensity = engine.sample(ms(now)).intensity;
    }
    assert!(intensity < 0.005);
    assert_eq!(engine.state().phase(), AgentState::Idle);
}

#[test]
fn pending_activity_fades_when_no_record_ever_arrives() {
    let mut engine = ActivityEngine::new(ms(0));
    engine.apply(&NormalizedEvent::TurnStart, ms(0));

    let mut intensity = 1.0;
    for now in (0..125_000).step_by(100) {
        intensity = engine.sample(ms(now)).intensity;
    }
    assert!(intensity < 0.005, "intensity stayed at {intensity}");
}

#[test]
fn history_updates_state_without_sound() {
    let mut engine = ActivityEngine::new(ms(0));
    engine.apply_history(&NormalizedEvent::TurnStart);
    engine.apply_history(&NormalizedEvent::ThinkingPulse {
        units: 1,
        confidence: Confidence::High,
    });

    assert_eq!(engine.state().phase(), AgentState::Thinking);
    assert!(!engine.state().awaiting_model());
    assert_eq!(engine.sample(ms(100)).intensity, 0.0);
}
