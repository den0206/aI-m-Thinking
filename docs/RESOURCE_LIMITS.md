# Resource, Privacy, and Fail-Open Limits v1

These limits are product requirements, not optional optimizations.

## Core limits

```rust
const MAX_ACTIVE_SESSIONS: usize = 64;
const MAX_CONFIGURED_ROOTS_PER_AGENT: usize = 4;
const MAX_ACTIVITY_QUEUE: usize = 256;
const MAX_RECENT_FINGERPRINTS: usize = 128;

const FILE_SCAN_CHUNK: usize = 64 * 1024;
const FILE_SCAN_BUDGET: usize = 512 * 1024;

const ACTIVITY_INTERVAL_MS: u64 = 100;
const MAX_IPC_RECORD_BYTES: usize = 32 * 1024;
```

## Audio limits

```swift
let maxAudioQueue = 32
let maxAudioVoices = 4
let maxKeysPerSecond = 15.0
```

Overflow must drop non-critical observer/audio work rather than backpressure Claude or Codex.

## Startup

For files that already exist when monitoring begins:

```text
baseline offset = current EOF
```

Historical transcript replay is forbidden by default.

## Disk

- Disk logging is off by default.
- No transcript copies.
- No cache of prompts/responses/reasoning/tool output.
- Sound assets are application resources.
- No temporary session database.

## Memory

- Queues are bounded.
- Session bookkeeping is bounded.
- Only the active sound pack needs decoded PCM.
- JSONL record size must not cause proportional retained-memory growth.
- Large ignored fields are streamed/skipped.

## Agent isolation

I'm Thinking must not modify Claude, Codex, project, or shell configuration.

The observer opens agent session data read-only.

## Fail-open

If any I'm Thinking component fails:

- Claude Code remains unaffected.
- Codex remains unaffected.
- Monitoring/audio may degrade or stop.
- A watcher/parser/audio error alone does not terminate the agent.

## Privacy

I'm Thinking must never persist:

- prompts
- assistant responses
- reasoning text
- source code
- file contents
- tool input
- tool output
- complete transcripts
- real Claude/Codex session IDs

Only ephemeral classification metadata/counters may cross from Rust to Swift.


## Sandbox grants

- Direct mode sends absolute root paths over the existing bounded IPC channel.
- App Store mode persists only security-scoped bookmark data in the app container.
- The Rust helper receives transfer bookmark data, resolves it locally, and holds the resulting scope only for the monitor lifetime.
- Root grants are capped at 4 per agent.
- Configure messages remain capped at 32 KiB.
- The helper receives App Sandbox + inherit entitlements only; it does not receive broad user-selected file entitlements.
- Full Disk Access is not a supported fallback.
