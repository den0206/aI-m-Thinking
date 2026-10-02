# Implementation Progress

This file is updated at each phase boundary so another agent can quickly understand the current implementation state.

## Branching / commit policy

During initial development, work is committed directly to `main`. Commits are grouped by implementation phase.

## Status

| Phase | Scope | Status | Commit |
|---|---|---|---|
| Phase 0 | Contracts and implementation rules | Complete | `fd938fa` |
| Phase 1 | JSONL infrastructure | Complete | `82da5fc` + CI fixes |
| Phase 2 | Claude/Codex parsers | Complete | `0c3655d` + CI fixes |
| Phase 3 | State + Activity Engine | Complete | `92c0eb4` + CI fixes |
| Phase 4 | IPC + macOS menu bar | Complete | `6d01945` |
| Phase 5 | Sound engine | Complete | this commit |
| Phase 6 | Real-agent integration | Not started | - |
| Phase 7 | Hardening | Not started | - |

## Phase 4 — Complete

Rust protocol executable and Swift menu-bar shell both pass their macOS CI workflows.

## Phase 5 — Complete

Implemented audio without adding external sound assets:

- five selectable sound packs
- short PCM sounds synthesized from per-pack profiles
- only the selected pack is retained as decoded buffers
- four AVAudioPlayerNode voices
- no unbounded audio request queue
- at most one future typing event scheduled by the cadence scheduler
- Activity Velocity mapping capped at 15 keys/sec
- THINKING uses slower irregular cadence
- WRITING uses normal cadence
- TOOL is silent unless it is a mutation tool
- volume and mute persisted in UserDefaults
- sound selection persisted in UserDefaults
- preview control
- multiple agent sessions are combined using max intensity, never summed
- Swift unit coverage for sound-pack count and cadence bounds

No Claude/Codex observation logic changes are included in this phase.

### Validation

Phase 5 is complete after App CI passes both:

- `swift build --package-path app`
- `swift test --package-path app`

## Next: Phase 6

Wire real passive observation to IPC:

- discover/tail Claude and Codex session files
- create ephemeral session handles
- parse only appended records
- reduce state + activity
- emit bounded `activity/session_opened/session_closed/observer_status`
- preserve normal `claude` / `codex` launch behavior
- no wrapper, alias, shell modification, or agent configuration changes
