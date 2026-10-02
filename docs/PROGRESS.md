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

## Platform modernization — Complete

The macOS app intentionally targets the current modern platform baseline:

- minimum deployment target: macOS 26.0
- Swift tools version: 6.4
- Swift language mode: Swift 6 via `swiftLanguageModes: [.v6]`
- repository toolchain pin: `.swift-version` = `6.4.0`
- App CI runner: Xcode 27
- CI explicitly verifies Apple Swift 6.4
- tests use Swift Testing instead of XCTest
- `CoreBridge` is MainActor-isolated
- `KeyboardAudioEngine` is MainActor-isolated
- delayed UI/audio work uses Swift Concurrency instead of DispatchQueue callbacks
- wake handling uses async NotificationCenter sequences
- duplicate bundled Core executable lookup was removed
- packaged `Info.plist` requires macOS 26.0
- CI verifies the packaged deployment target is exactly 26.0

Latest modernization App CI: `37015100779` — build, tests, app bundle construction, and bundle verification all passed.

## Distribution / developer workflow modernization — Complete

Reborn was reviewed as a reference and only the pieces appropriate for I'm Thinking were adopted:

- same-repository GitHub Releases; no dedicated release repository
- tag-based release trigger: `vX.Y.Z`
- Developer ID signing for the bundled Rust helper and macOS app
- app notarization + staple before DMG creation
- DMG creation with an `/Applications` shortcut
- DMG signing + notarization + staple
- GitHub Release publication with the repository's own `GITHUB_TOKEN`
- VS Code / Cursor F5 workflow using CodeLLDB
- real `.app` bundle debugging rather than launching the raw Swift executable
- separate debug identity: `I'm Thinking Debug` / `com.den0206.ImThinking.debug`
- debug `get-task-allow` entitlement for LLDB
- separate CodeLLDB entry for the Rust Core
- expanded README, development guide, release guide, manual verification checklist, and CHANGELOG

Deliberately not adopted from Reborn:

- dedicated public release repository
- self-update
- custom `+N` re-release numbering
- Accessibility/TCC-specific development infrastructure
- Reborn-specific application/system abstraction layers

Release secrets are intentionally mandatory for the public release workflow so an unsigned or unnotarized DMG is not accidentally published.

The release workflow is implemented but has not been exercised with a real `vX.Y.Z` tag and Apple signing/notarization secrets. That remains a release-candidate verification item rather than an implementation gap.

Latest distribution/development CI: `37017158952` — Swift build/tests, Debug app bundle, Release app bundle, bundle validation, and test DMG packaging all passed.

## Mac App Store readiness — Architecture implemented

The Mac App Store path is now separated from direct distribution without changing the zero-setup direct UX.

Implemented:

- Rust Core no longer derives Claude/Codex roots from `HOME`
- IPC `configure.roots` accepts bounded path or bookmark grants
- maximum configured roots: 4 per agent
- Direct distribution supplies explicit path grants from Swift
- App Store mode uses `SandboxAgentRootProvider`
- Claude/Codex folders are selected explicitly with `NSOpenPanel`
- persistent read-only security-scoped bookmarks are stored in the app container
- stale persistent bookmarks are refreshed
- a transfer bookmark is handed to the Rust child instead of relying on dynamic sandbox inheritance
- Rust resolves the transfer bookmark with Core Foundation and keeps the security scope for the monitor lifetime
- main App Store entitlement set is App Sandbox + user-selected read-only + app-scoped bookmarks
- Rust helper entitlement set is App Sandbox + inherit only
- PrivacyInfo.xcprivacy declares no tracking/data collection and the UserDefaults required-reason API usage
- `appstore-smoke` CI bundle validates packaging, Privacy Manifest presence, and the signed entitlement split
- Review Notes draft, risk register, and submission checklist are documented in `docs/APP_STORE.md`

Validated Core CI:

- run `37022393931`: format, tests, and Clippy passed with the explicit root-grant IPC schema.

Validated App Store smoke steps:

- run `37022875951`: Swift build/tests, Debug bundle, App Store smoke build, sandbox entitlement verification, Privacy Manifest verification, and Direct release bundle verification passed. The same run's final DMG smoke is independent of the App Store sandbox path.

Remaining before an actual App Store submission:

1. Real sandboxed device test for Swift -> Rust bookmark handoff and recursive session monitoring.
2. Add a real Xcode macOS App target / Product Archive path; the hand-built `appstore-smoke` bundle is intentionally not a submission artifact.
3. Configure the final registered App ID and App Store distribution signing.
4. Validate/upload an Archive to App Store Connect / TestFlight.
5. Reconcile final Xcode privacy report with App Store Connect privacy answers.
6. Provide a deterministic reviewer demo path if Apple reviewers cannot authenticate to Claude Code/Codex.
7. Submit with the Review Notes in `docs/APP_STORE.md`.

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
