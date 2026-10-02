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
| Phase 5 | Sound engine | Complete | `ee9a924` + test fix |
| Phase 6 | Real-agent integration | Complete | this commit |
| Phase 7 | Hardening | Not started | - |

## Phase 5 — Complete

Five synthesized keyboard sound packs, bounded four-voice playback, one-event-ahead scheduler, volume/mute persistence, and cadence tests are green in App CI.

## Phase 6 — Complete

Implemented passive real-agent observation in the Rust core:

- default Claude root: `~/.claude/projects`
- default Codex root: `~/.codex/sessions`
- recursive native filesystem observation
- create and modify events distinguished
- startup scans metadata only and baselines recent existing JSONL files at EOF
- historical transcript bodies are never replayed at startup
- new JSONL files are observed from byte zero
- existing files are tailed only from their stored baseline
- unknown pre-existing files are baselined at current EOF rather than replayed
- maximum 256 baseline cursors and 64 active sessions
- maximum 4096 discovery entries per rescan
- existing 512 KiB per-file scan budget retained
- dirty sessions continue scanning across timer ticks without requiring another filesystem event
- Claude/Codex parsers feed the common Activity Engine
- ephemeral `u32` session handles only
- `session_opened`, `session_closed`, `observer_status`, and `activity` IPC messages
- activity emitted at the existing 100 ms core cadence
- shell/read/search tool execution naturally emits no typing audio
- idle sessions can be evicted when the 64-session active bound is reached
- monitor is a child-owned thread and shuts down when Core shuts down
- normal `claude` / `codex` commands are unchanged
- no alias, wrapper, shell rc, Claude settings, or Codex settings modifications

### Known Phase 6 boundary

If a very old pre-existing session is outside the bounded startup baseline set and is resumed later, the first append is deliberately skipped and establishes an EOF baseline. Subsequent appends are observed. This preserves the no-history-replay and bounded-memory guarantees.

### Validation

Phase 6 is complete after Core CI passes:

- `cargo fmt --check`
- `cargo test`
- `cargo clippy --all-targets -- -D warnings`

Real installed-agent smoke testing and resource/failure stress testing remain Phase 7.

## Next: Phase 7

Hardening:

- large JSONL/RSS stress tests
- many-session stress
- watcher failure/recovery
- app/core kill behavior
- sleep/wake and rescan
- packaging the Rust auxiliary executable into the macOS app
- on-device smoke tests with current Claude Code and Codex
- Start at Login
