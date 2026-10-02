# Implementation Progress

This file is updated at each phase boundary so another agent can quickly understand the current implementation state.

## Branching / commit policy

During initial development, work is committed directly to `main`.

Commits are grouped by implementation phase. Avoid both giant multi-phase commits and tiny per-file commits.

## Status

| Phase | Scope | Status | Commit |
|---|---|---|---|
| Phase 0 | Contracts and implementation rules | Complete | pending this commit |
| Phase 1 | JSONL infrastructure | Not started | - |
| Phase 2 | Claude/Codex parsers | Not started | - |
| Phase 3 | State + Activity Engine | Not started | - |
| Phase 4 | IPC + macOS menu bar | Not started | - |
| Phase 5 | Sound engine | Not started | - |
| Phase 6 | Real-agent integration | Not started | - |
| Phase 7 | Hardening | Not started | - |

## Phase 0 — Complete

Added explicit contracts for:

- Swift/Rust IPC v1
- normalized event/state model
- Claude/Codex parser behavior
- privacy and fail-open guarantees
- memory/storage/resource bounds
- phase-based implementation workflow

### Key decisions

- Users continue to launch `claude` and `codex` normally.
- Default integration is passive/read-only.
- Agent and shell configuration must not be modified.
- Existing transcript history is not replayed at app startup.
- Rust parses agent persistence; Swift owns UI/audio.
- No user content crosses the Rust/Swift IPC boundary.
- Resource limits are explicit and testable.

## Next: Phase 1

Implement only the shared JSONL infrastructure:

- Rust crate skeleton
- file cursor
- bounded newline framing
- append-only processing
- partial record handling
- truncate/replace detection
- selective parsing plumbing
- tests for framing and bounded behavior

Do not implement Claude/Codex semantic parsers in Phase 1.
Do not add Swift UI/audio code in Phase 1.
