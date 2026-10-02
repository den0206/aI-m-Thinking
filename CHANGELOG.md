# Changelog

All notable changes to I'm Thinking are documented here.

The format follows Keep a Changelog conventions and releases use semantic version tags (`vX.Y.Z`).

## [Unreleased]

### Added

- Passive Claude Code / Codex activity monitoring without wrapper commands.
- Keyboard sound packs with activity-sensitive cadence.
- macOS menu-bar UI, Start at Login, and sleep/wake rescan.
- VS Code / Cursor debug configuration.
- Signed/notarized DMG release workflow for same-repository GitHub Releases.

### Changed

- Minimum deployment target is macOS 26.0.
- Swift toolchain is pinned to Swift 6.4.

### Fixed

- Claude Code turns end on the final message's `stop_reason`; current versions no longer write `turn_duration`, so sessions previously never returned to IDLE.
- Activity holds while the model is generating output that has not reached the transcript yet, instead of falling silent after 5 seconds.
- Claude interruption and meta rows no longer start a new turn.
- Codex hosted `web_search_call` / `image_generation_call` items no longer leave the session stuck in TOOL; `apply_patch`, `shell_command`, `spawn_agent` and other built-in tool names are classified.
- Records written more than 10 minutes before they are observed (for example a Codex rollout restored from `.jsonl.zst`) update state without producing sound.

- Realtime token activity now decays when usage updates stop instead of holding typing speed indefinitely.
- Turns that never write a turn-end record stop emitting activity once silent and close after 10 minutes without signal.
- JSONL records are parsed through a buffered reader instead of one `read()` per byte.
- Session files older than the startup baseline budget are tracked once they are appended to.
- A creation event for a file that existed before monitoring no longer replays its history.
- Activity updates are capped at 10 Hz per session, the monitor sleeps when nothing is active, and the core event queue is bounded.

## [0.1.0] - Unreleased

- Initial public release preparation.
