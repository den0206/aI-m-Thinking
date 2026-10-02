//! Replays a Claude Code transcript through the parser and activity engine on
//! the transcript's own clock and reports how well the produced phase and
//! audibility match what the agent was actually doing.
//!
//! Only aggregate numbers are printed; transcript content is never output.
//!
//! ```text
//! cargo run --example replay_eval -- ~/.claude/projects/<project>/<session>.jsonl
//! ```

use std::collections::BTreeMap;
use std::time::Duration;

use im_thinking_core::activity::ActivityEngine;
use im_thinking_core::events::AgentState;
use im_thinking_core::parsers::ClaudeParser;
use im_thinking_core::timestamp::parse_utc_ms;
use serde_json::Value;

/// Lowest intensity the app scheduler (`TypingScheduler.keysPerSecond`) turns
/// into sound.
const AUDIBLE: f32 = 0.06;
const STEP_MS: u64 = 100;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Truth {
    /// The model is producing output that is not yet in the transcript.
    Generating,
    /// A tool requested by the model is running.
    Tool,
    /// The turn has ended and the agent waits for the user.
    Idle,
}

struct Arrival {
    at_ms: u64,
    lines: Vec<String>,
    truth_after: Truth,
}

fn main() {
    let path = std::env::args()
        .nth(1)
        .expect("usage: replay_eval <claude.jsonl>");
    let text = std::fs::read_to_string(&path).expect("read transcript");
    let arrivals = arrivals(&text);
    if arrivals.is_empty() {
        eprintln!("no timestamped user/assistant/system records");
        return;
    }

    let origin = arrivals[0].at_ms;
    let mut parser = ClaudeParser::default();
    let mut engine = ActivityEngine::new(Duration::ZERO);
    let mut stats: BTreeMap<Truth, Stat> = BTreeMap::new();
    let mut truth = Truth::Idle;
    let mut next = 0;
    let end = arrivals.last().unwrap().at_ms - origin;

    let mut now = 0;
    while now <= end {
        while next < arrivals.len() && arrivals[next].at_ms - origin <= now {
            for line in &arrivals[next].lines {
                if let Ok(events) = parser.parse(line.as_bytes()) {
                    for event in events {
                        engine.apply(&event, Duration::from_millis(now));
                    }
                }
            }
            truth = arrivals[next].truth_after;
            next += 1;
        }

        let sample = engine.sample(Duration::from_millis(now));
        let stat = stats.entry(truth).or_default();
        stat.total += 1;
        let typing_phase = match sample.phase {
            AgentState::Thinking | AgentState::Writing => true,
            AgentState::Tool => engine.state().has_mutation_tool(),
            AgentState::Idle => false,
        };
        stat.audible += u64::from(typing_phase && sample.intensity >= AUDIBLE);
        stat.phase_ok += u64::from(phase_matches(truth, sample.phase));
        now += STEP_MS;
    }

    println!("truth        seconds  audible  phase-match");
    for (truth, stat) in &stats {
        println!(
            "{:<11} {:>8.1} {:>7.1}% {:>11.1}%",
            format!("{truth:?}"),
            stat.total as f64 * STEP_MS as f64 / 1000.0,
            percent(stat.audible, stat.total),
            percent(stat.phase_ok, stat.total),
        );
    }
}

#[derive(Default)]
struct Stat {
    total: u64,
    audible: u64,
    phase_ok: u64,
}

fn percent(part: u64, total: u64) -> f64 {
    if total == 0 {
        0.0
    } else {
        part as f64 * 100.0 / total as f64
    }
}

fn phase_matches(truth: Truth, phase: AgentState) -> bool {
    match truth {
        Truth::Generating => matches!(phase, AgentState::Thinking | AgentState::Writing),
        Truth::Tool => phase == AgentState::Tool,
        Truth::Idle => phase == AgentState::Idle,
    }
}

/// Groups records into observer arrivals. Claude writes every content block of
/// one API message when that message completes, so a message arrives at the
/// latest timestamp among its blocks.
fn arrivals(text: &str) -> Vec<Arrival> {
    let mut out: Vec<Arrival> = Vec::new();
    let mut open_message: Option<String> = None;

    for line in text.lines() {
        let Ok(record) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        let kind = record["type"].as_str().unwrap_or_default();
        if !matches!(kind, "user" | "assistant" | "system") {
            continue;
        }
        let Some(at_ms) = record["timestamp"]
            .as_str()
            .and_then(parse_utc_ms)
            .and_then(|ms| u64::try_from(ms).ok())
        else {
            continue;
        };

        let message_id = record["message"]["id"].as_str().map(str::to_owned);
        let truth_after = truth_after(&record);
        if kind == "assistant" && message_id.is_some() && message_id == open_message {
            let last = out.last_mut().unwrap();
            last.at_ms = last.at_ms.max(at_ms);
            last.lines.push(line.to_owned());
            last.truth_after = truth_after;
            continue;
        }

        open_message = if kind == "assistant" {
            message_id
        } else {
            None
        };
        out.push(Arrival {
            at_ms,
            lines: vec![line.to_owned()],
            truth_after,
        });
    }

    out.sort_by_key(|arrival| arrival.at_ms);
    out
}

fn truth_after(record: &Value) -> Truth {
    match record["type"].as_str() {
        Some("assistant") => match record["message"]["stop_reason"].as_str() {
            Some("tool_use") => Truth::Tool,
            Some("end_turn" | "stop_sequence" | "refusal") => Truth::Idle,
            _ => Truth::Generating,
        },
        Some("user") => Truth::Generating,
        _ => Truth::Idle,
    }
}
