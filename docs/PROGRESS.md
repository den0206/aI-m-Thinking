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
| Phase 4 | IPC + macOS menu bar | Complete | this commit |
| Phase 5 | Sound engine | Not started | - |
| Phase 6 | Real-agent integration | Not started | - |
| Phase 7 | Hardening | Not started | - |

## Phase 3 — Complete

State reducer and Activity Velocity are implemented and validated by macOS CI. The phase also removed a flaky temp-fixture collision discovered by parallel CI.

## Phase 4 — Complete

Implemented the process boundary and minimal macOS shell without audio:

### Rust core IPC

- executable `im-thinking-core`
- protocol v1 `hello -> configure -> ready` handshake
- `ping/pong`, `set_agent_enabled`, `rescan`, and graceful `shutdown`
- bounded 32 KiB stdin command records
- oversized-command recovery
- malformed-command recovery
- explicit protocol-version failure
- stdout reserved for NDJSON protocol
- stdin EOF exits the core, preventing an orphan child
- no transcript path/session/user content in IPC messages

### Swift menu-bar app

- SwiftUI `MenuBarExtra` for macOS 13+
- `CoreBridge` owns a Rust child `Process`
- bundled auxiliary executable lookup with `IM_THINKING_CORE_PATH` development override
- handshake/configure handling
- bounded stdout buffer
- unexpected core termination detection
- manual monitor restart
- minimal Claude/Codex state rows
- no audio code yet

### Validation

Phase 4 is complete after both workflows are green:

- Core: format, tests, Clippy
- App: `swift build --package-path app`

## Next: Phase 5

Implement audio only:

- Sound Pack model
- AVAudioEngine voice pool
- bounded queue / maximum four voices
- Activity Velocity -> typing cadence
- volume / mute
- selectable Mechanical Clicky, Mechanical Thock, Laptop, Typewriter, Soft
- no agent-observation changes in Phase 5
