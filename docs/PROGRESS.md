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
| Phase 6 | Real-agent integration | Complete | `e4e7196` + CI fixes |
| Phase 7 | Hardening / packaging | CI complete; device smoke pending | `092aeba` + CI fixes |

## Phase 6 — Complete

Normal `claude` and `codex` usage passively feeds the observer/parser/activity/IPC/audio pipeline without altering agent or shell configuration.

## Phase 7 — Implementation complete

Hardening and packaging added:

- protocol handshake emits `ready` before monitor events can begin
- per-agent baseline budgets prevent one agent from starving the other
- re-enabling an observer performs a rescan
- parallel tool state is tested at its 64-entry bound
- an 8 MiB ignored JSON payload is streamed directly into the parser test
- subprocess integration test covers Core hello/configure/ready/ping/shutdown lifecycle
- wake-from-sleep triggers an agent rescan
- Start at Login uses `SMAppService.mainApp`, not shell or LaunchAgent modifications
- macOS app bundle script packages Swift UI and Rust Core together
- App CI builds and validates the resulting `.app`
- optional code signing is supported through `SIGN_IDENTITY`
- top-level README documents development, packaging, privacy, and fail-open behavior

### Remaining device smoke tests

These cannot be fully validated in GitHub CI and should be completed on a developer Mac before calling v1 release-ready:

1. Launch the packaged `I'm Thinking.app`.
2. Confirm menu-bar-only behavior.
3. Start current Claude Code with normal `claude`.
4. Confirm THINKING / WRITING / TOOL / IDLE changes and sound.
5. Start current Codex with normal `codex` and repeat.
6. Confirm shell/read/search waits become quiet.
7. Confirm mutation/edit work produces a short typing burst.
8. Change all five sound packs, volume, and mute.
9. Enable/disable Start at Login.
10. Sleep/wake the Mac and confirm monitoring resumes.
11. Force-quit I'm Thinking while Claude/Codex are active and confirm both agents are unaffected.
12. Inspect Claude/Codex settings before/after and confirm no changes were made.

### CI validation

Latest validation on `main`:

- Core: `cargo fmt --check` — passed
- Core: `cargo test` — passed
- Core: `cargo clippy --all-targets -- -D warnings` — passed
- App: `swift build` — passed
- App: `swift test` — passed
- App bundle construction — passed
- Bundled Swift/Rust executables — verified
- `Info.plist` validation — passed

Until the device tests above pass, the implementation is complete but v1 is intentionally not marked release-ready.
