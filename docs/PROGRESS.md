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
| Phase 3 | State + Activity Engine | Complete | this commit |
| Phase 4 | IPC + macOS menu bar | Not started | - |
| Phase 5 | Sound engine | Not started | - |
| Phase 6 | Real-agent integration | Not started | - |
| Phase 7 | Hardening | Not started | - |

## Phase 1 — Complete

Bounded, read-only JSONL framing and event-driven filesystem observation.

## Phase 2 — Complete

Content-free normalized events and tolerant Claude/Codex semantic parsers. macOS CI is green through commit `7c979cc`.

## Phase 3 — Complete

Implemented the pure Rust state/activity layer:

- deterministic IDLE / THINKING / WRITING / TOOL reducer
- bounded parallel tool tracking
- anonymous ToolEnd fallback
- reasoning/writing/mutation impulses
- usage interval tracking capped at four samples
- realtime vs sparse token cadence classification
- first usage interval treated as unknown rather than a false token-rate sample
- reasoning/output token-rate normalization
- state freshness decay
- confidence weighting
- 120 ms rise / 550 ms fall asymmetric smoothing
- shell/read/search tool states naturally decay to silence
- mutation tools receive only a short bounded impulse
- deterministic tests use caller-supplied monotonic `Duration` values

No Swift, UI, or audio code is included in this phase.

### Validation

Phase 3 is complete after the macOS Core workflow passes format, tests, and Clippy.

## Next: Phase 4

Implement IPC v1 plus the minimal macOS menu-bar shell:

- Rust child-process protocol messages
- handshake / configure / shutdown
- Swift CoreBridge
- menu-bar state display only
- core crash detection / restart
- no audio yet

The Swift side must never receive real transcript paths or real Claude/Codex session identifiers.
