# Implementation Progress

This file is updated at each phase boundary so another agent can quickly understand the current implementation state.

## Branching / commit policy

During initial development, work is committed directly to `main`. Commits are grouped by implementation phase.

## Status

| Phase | Scope | Status | Commit |
|---|---|---|---|
| Phase 0 | Contracts and implementation rules | Complete | `fd938fa` |
| Phase 1 | JSONL infrastructure | Complete | `82da5fc` + CI fixes |
| Phase 2 | Claude/Codex parsers | Complete | this commit |
| Phase 3 | State + Activity Engine | Not started | - |
| Phase 4 | IPC + macOS menu bar | Not started | - |
| Phase 5 | Sound engine | Not started | - |
| Phase 6 | Real-agent integration | Not started | - |
| Phase 7 | Hardening | Not started | - |

## Phase 1 — Complete

Bounded, read-only JSONL framing and event-driven filesystem observation. macOS CI is green through commit `8a1af2b`.

## Phase 2 — Complete

Implemented only semantic parsing:

- content-free normalized event types
- Claude user/assistant/system parser
- Claude content list capped at 128 blocks
- tool-result rows never become user turns
- Codex legacy + paginated semantic parsing
- bounded recent ToolEnd deduplication
- missing tool-ID fallback
- cumulative usage baseline/delta/reset handling
- no ordinal dependency
- synthetic fixtures and malformed-input no-panic test

User prompt, reasoning, assistant text, tool input, and tool output are absent from parser data structures and are skipped by Serde.

### Validation

Phase 2 is complete after the macOS Core workflow passes format, tests, and Clippy.

## Next: Phase 3

Implement state reduction and Activity Velocity only: parallel tool state, token cadence, impulses, confidence weighting, asymmetric smoothing, and fake-clock tests. No Swift UI/audio yet.
