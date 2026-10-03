# Changelog

All notable changes to I'm Thinking are documented here.

The format follows Keep a Changelog conventions and releases use semantic version tags (`vX.Y.Z`).

## [Unreleased]

### Added

- A first-launch window points to the menu-bar icon and offers Start at Login. In the App Store build it also asks for the Claude Code / Codex session folders and cannot be dismissed until at least one is allowed (Quit stays available).
- Choosing a folder that is not the agent's session folder (for example the Codex folder for Claude Code, or `~/.claude` instead of `~/.claude/projects`) shows a red error under that agent and is not saved.
- The DMG window has a background that guides dragging the app to Applications.
- Agents whose transcripts stop producing recognizable records (for example after a Claude Code / Codex update changes the format) are flagged as "Unsupported format" in the menu, and the diagnostic log records each session's agent CLI version.
- Copy Diagnostic Log shares bounded, in-memory monitoring metadata without transcript content or file paths.
- In Random mode the Sound Pack tile shows the pack currently playing.
- A Hermes Precisa 305 typewriter sound pack recorded from a real machine, with its own space bar sound.
- The menu links to the privacy policy.
- Recorded keyboard sounds, random sound selection per turn, a speed slider, and an animated menu-bar keycap.
- Passive Claude Code / Codex activity monitoring without wrapper commands.
- Keyboard sound packs with activity-sensitive cadence.
- macOS menu-bar UI, Start at Login, and sleep/wake rescan.
- VS Code / Cursor debug configuration.
- Signed/notarized DMG release workflow for same-repository GitHub Releases.

### Changed

- Minimum deployment target is macOS 26.0.
- Swift toolchain is pinned to Swift 6.4.
- The typing speed slider spans 0.3–2.1× and the cap is 30 keys/s, so the fast end is audibly faster.
- Volume at the slider's left end is mute: the fill disappears, the mute tile follows, and unmuting from zero restores the default volume.

### Fixed

- Metadata reconciliation recovers Codex updates when macOS file notifications do not arrive, without replaying startup history.
- Old core process callbacks cannot disconnect a restarted monitor; replacing or truncating a transcript clears its previous activity and parser state.
- Silent sessions no longer leave Thinking displayed in the agent tile.
- Claude idle status cannot be undone by queued transcript records across scan budgets or by a partial row completed later.
- Codex long model-output waits remain audible up to the bounded stale-turn deadline; paginated reasoning/messages and terminal answer phases are recognized.
- Late records cannot reopen explicitly ended turns, and silent/idle sessions and monitor shutdown no longer leave the keycap animating.
- Audio stays within four voices and 30 keys/s, drops queued overlap, releases inactive pack PCM, and cancels pending previews on stop.
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
- Activity updates are capped at 10 Hz per session, the monitor sleeps between events and bounded metadata reconciliation, and the core event queue is bounded.

## [0.1.0] - Unreleased

- Initial public release preparation.
