# Implementation Progress

This file is updated at each phase boundary so another agent can quickly understand the current implementation state.

## Branching / commit policy

During initial development, work is committed directly to `main`.

Commits are grouped by implementation phase. Avoid both giant multi-phase commits and tiny per-file commits.

## Status

| Phase | Scope | Status | Commit |
|---|---|---|---|
| Phase 0 | Contracts and implementation rules | Complete | `fd938fa` |
| Phase 1 | JSONL infrastructure | Complete | this commit |
| Phase 2 | Claude/Codex parsers | Not started | - |
| Phase 3 | State + Activity Engine | Not started | - |
| Phase 4 | IPC + macOS menu bar | Not started | - |
| Phase 5 | Sound engine | Not started | - |
| Phase 6 | Real-agent integration | Not started | - |
| Phase 7 | Hardening | Not started | - |

## Phase 0 — Complete

Added explicit contracts for IPC, normalized events, parser behavior, privacy/fail-open requirements, resource limits, and the phase workflow.

## Phase 1 — Complete

Implemented the shared Rust JSONL infrastructure without adding agent-specific parsing:

- `im-thinking-core` crate skeleton
- recursive event-driven filesystem observer via `notify`
- read-only baseline opening at current EOF
- inode/device-based replacement detection
- truncation detection and EOF resync
- fixed 64 KiB scan buffer
- 512 KiB per-scan budget
- maximum 1024 framed records per scan
- partial-record continuation across appends
- range-based record reader so later parsers can stream a record without first copying it into one large buffer
- infrastructure tests
- macOS CI for `cargo fmt`, `cargo test`, and `cargo clippy -D warnings`

### Resource/safety behavior

- Existing history is not replayed.
- Agent data is opened read-only by the observer baseline API.
- The framer stores byte ranges, not record bodies.
- Large unterminated records consume a fixed scan buffer and advance incrementally.
- Replace/truncate recovery skips historical reconstruction and resumes from the new EOF.
- No Claude/Codex semantic assumptions exist in this phase.

### Validation

CI is the authoritative build/test environment because the implementation environment used to create this phase does not provide a local Rust toolchain. Phase 1 is considered complete only after the macOS Core workflow is green.

## Next: Phase 2

Implement Claude and Codex semantic parsers on top of the range-based reader:

- normalized event types
- Claude minimal selective schema
- Codex legacy + paginated minimal selective schema
- tool classification
- usage-delta handling
- semantic deduplication
- synthetic/sanitized fixtures

Do not implement Activity Velocity or Swift UI/audio in Phase 2.
