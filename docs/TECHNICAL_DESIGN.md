# I'm Thinking — Technical Design v1

> Status: Implementation-ready design  
> Target: macOS menu bar application  
> Primary agents: Claude Code / Codex  
> Repository: `den0206/I-m-Thinking`

## 1. Product goal

**I'm Thinking** is a macOS menu bar application that passively detects when local AI coding agents are thinking, writing, or executing tools, and turns that activity into keyboard-like audio.

The user should continue using each agent normally:

```bash
claude
```

```bash
codex
```

No command prefix such as `im-thinking claude` is required.

The perceived typing speed is driven by an internal **Activity Velocity** signal. The application must not claim that this value is always an exact real-time reasoning-token rate. When direct token signals are available they can contribute to the score; otherwise the score is estimated from observable lifecycle and transcript events.

## 2. Non-negotiable constraints

### Agent isolation

I'm Thinking must not modify:

- `~/.claude/settings.json`
- project-level `.claude/*` settings
- `CLAUDE.md`
- `~/.codex/config.toml`
- project-level Codex configuration
- `AGENTS.md`
- `~/.zshrc`, `~/.zprofile`, or other shell startup files
- aliases or PATH entries used to replace `claude` / `codex`

The default mode is fully passive and read-only.

### Fail-open behavior

If I'm Thinking crashes, is force-quit, loses audio output, or its Rust core fails:

- Claude Code continues normally.
- Codex continues normally.
- Only activity visualization/audio stops.

### Privacy

I'm Thinking must never persist:

- prompts
- assistant responses
- reasoning text
- source code
- file contents
- tool input
- tool output
- complete session transcripts
- Claude/Codex session identifiers

The parser should extract only metadata required for classification and counters, then discard content immediately.

### Resource discipline

- Disk logs: off by default.
- Historical transcripts: never replayed automatically on application launch.
- Event queues: bounded.
- Audio queues: bounded.
- Active sessions: bounded.
- Large JSONL records must not cause memory usage proportional to record size.
- No busy polling loop.

## 3. User experience

### Normal operation

1. User launches **I'm Thinking.app**.
2. The app remains in the macOS menu bar.
3. The user starts `claude` or `codex` normally in any terminal.
4. I'm Thinking detects new/updated session data.
5. The app classifies the current state:
   - IDLE
   - THINKING
   - WRITING
   - TOOL
6. Activity is converted to a normalized intensity in `0.0...1.0`.
7. The selected sound pack produces keyboard-like audio.

### Menu bar

Initial menu bar scope:

- Claude Code state + activity bar
- Codex state + activity bar
- Sound Pack selector
- Volume
- Mute
- Auto Detect
- Start at Login
- Core/observer health status
- Quit

The displayed percentage, if any, must be labeled **Activity**, not token usage.

## 4. Architecture

```text
┌──────────────────────────────────────────┐
│              I'm Thinking.app            │
│                    Swift                 │
│                                          │
│  NSStatusItem / settings                 │
│  AVAudioEngine                           │
│  SoundPackManager                        │
│  CoreBridge                              │
└───────────────────┬──────────────────────┘
                    │ NDJSON over stdin/stdout
                    ▼
┌──────────────────────────────────────────┐
│              im-thinking-core            │
│                    Rust                  │
│                                          │
│  File/session observers                  │
│  JSONL framing                           │
│  Claude parser                           │
│  Codex parser                            │
│  State reducer                           │
│  Activity engine                         │
└───────────────┬──────────────────┬───────┘
                │ READ ONLY        │ READ ONLY
                ▼                  ▼
       Claude transcript      Codex rollout
```

### Responsibility split

Swift owns:

- menu bar UI
- distribution mode selection
- direct root discovery or sandbox user-consent/bookmark management
- user settings
- Login Item state
- sound pack selection
- audio scheduling
- audio device lifecycle
- launching/restarting the Rust core

Rust owns:

- filesystem/event monitoring
- bounded configured root resolution
- App Store transfer-bookmark resolution/security-scope lifetime
- transcript/rollout tailing
- JSONL framing
- selective parsing
- state reduction
- activity/confidence calculation
- bounded session/event bookkeeping

Rust does not play audio. Swift does not parse agent transcripts.

## 5. Observation strategy

### Claude Code

Default root:

```text
~/.claude/projects/
```

The passive observer tails only newly appended bytes after I'm Thinking begins monitoring.

Relevant record semantics:

| Claude record | Normalized event |
|---|---|
| real user message | `TurnStart` |
| assistant content `thinking` | `ThinkingPulse` |
| assistant content `text` | `WritingPulse` |
| assistant content `tool_use` | `ToolStart` |
| user content `tool_result` | `ToolEnd` |
| system `turn_duration` | `TurnEnd` |
| unknown record | ignore |

Claude's transcript format is treated as an implementation detail rather than a stable public schema. Parsing must therefore be permissive:

- deserialize only required fields
- ignore unknown fields
- ignore unknown record types
- never assume one assistant JSONL row equals one turn
- never interpret absence of a text row as proof that the model is idle

### Codex

Default root:

```text
~/.codex/sessions/
```

The observer supports both legacy and paginated rollout shapes.

Relevant semantics:

| Codex record | Normalized event |
|---|---|
| `task_started` / equivalent turn start | `TurnStart` |
| reasoning response/event | `ThinkingPulse` |
| assistant message response/event | `WritingPulse` |
| function/custom/local-shell/tool call | `ToolStart` |
| corresponding output/item completion | `ToolEnd` |
| token-count update | `UsagePulse` |
| task/turn completion or abort | `TurnEnd` |
| unknown record | ignore |

Do not rely on rollout `ordinal` for correctness. Physical append order is the authoritative ordering for the passive tailer.

## 6. Normalized event contract

```rust
enum NormalizedEvent {
    TurnStart,

    ThinkingPulse {
        units: u32,
        confidence: Confidence,
    },

    WritingPulse {
        units: u32,
        confidence: Confidence,
    },

    ToolStart {
        id: ToolKey,
        class: ToolClass,
    },

    ToolEnd {
        id: Option<ToolKey>,
    },

    UsagePulse {
        output_tokens: u32,
        reasoning_tokens: u32,
    },

    TurnEnd,
}

enum AgentState {
    Idle,
    Thinking,
    Writing,
    Tool,
}

enum Confidence {
    High,
    Medium,
    Low,
}

enum ToolClass {
    Mutation,
    Shell,
    Read,
    Search,
    SubAgent,
    Mcp,
    Generic,
}
```

No normalized event may contain prompt text, reasoning text, generated text, code, file contents, or tool output.

## 7. State reducer

State transitions:

| Event | New state |
|---|---|
| `TurnStart` | THINKING |
| `ThinkingPulse` | THINKING, unless tools remain active |
| `WritingPulse` | WRITING, unless tools remain active |
| `ToolStart` | TOOL |
| `ToolEnd`, no active tools remain | THINKING |
| `ToolEnd`, another tool remains | TOOL |
| `TurnEnd` | IDLE |
| observed agent/session termination | IDLE |

Parallel tools are tracked in a bounded map/set. A single boolean is not sufficient.

```rust
struct SessionState {
    turn_open: bool,
    phase: AgentState,
    active_tools: HashMap<ToolKey, ToolClass>,
}
```

State and sound intensity are deliberately separate. A session may remain logically THINKING while its audio intensity decays to zero because no fresh signal has arrived.

## 8. Activity Velocity

Activity Velocity is a normalized `0.0...1.0` value.

It is not universally equal to tokens per second.

Potential signals:

- direct reasoning-token delta
- output-token delta
- reasoning record arrival
- text record arrival
- mutation-tool activity
- turn-state baseline

### Token score

When token updates arrive frequently enough to be considered real-time:

```text
reasoning_score = 1 - exp(-reasoning_tokens_per_sec / 35)
```

A similar capped score can be used for output tokens.

### Usage cadence

```rust
enum UsageCadence {
    Realtime,
    Sparse,
    Unknown,
}
```

Usage deltas may drive real-time sound only when update cadence is sufficiently frequent. Sparse turn-end usage must never cause a sudden high-speed burst.

Initial heuristic:

```text
median usage interval <= 1.5s => Realtime
otherwise                    => Sparse
```

### Event impulses

Transcript-based signals create bounded impulses that decay exponentially.

Examples:

```text
ThinkingPulse -> thinking impulse
WritingPulse  -> writing impulse
Mutation tool -> short mutation impulse
```

A large transcript block does not linearly create a large score.

### Confidence multiplier

Initial values:

```text
HIGH   1.00
MEDIUM 0.80
LOW    0.55
```

### Smoothing

Use asymmetric smoothing:

```text
activity increase: fast response, ~120 ms
activity decrease: slower decay, ~550 ms
```

This makes sound accelerate quickly and settle naturally.

## 9. Sound scheduling

Sound speed is derived from intensity rather than directly from event count.

Initial mapping:

```text
keys_per_second = 1.2 + 13.8 * intensity^1.8
```

Rules:

- intensity below a small threshold: silence
- hard maximum: 15 keys/sec
- interval jitter: approximately ±18%
- no multi-second pre-scheduling
- schedule only the next one or two keystrokes
- activity reduction must take effect quickly

State-dependent patterns:

| State | Pattern |
|---|---|
| THINKING | short irregular bursts |
| WRITING | longer, steadier bursts |
| TOOL / Mutation | short strong burst |
| TOOL / Shell | normally silent |
| TOOL / Read | normally silent |
| TOOL / Search | normally silent |
| IDLE | silent |

## 10. Sound packs

Initial built-in packs:

- Mechanical Clicky
- Mechanical Thock
- Laptop
- Typewriter
- Soft

Each pack should remain small:

```text
regular key × ~6
space       × ~2
enter       × ~2
```

Variation is created using sample choice, pitch, gain, pan, and interval jitter rather than hundreds of files.

Only the active pack needs decoded PCM in memory.

Initial audio bounds:

```text
max audio queue: 32
max simultaneous voices: 4
max typing rate: 15/sec
```

Mute is a separate setting rather than a "Silent" sound pack.

## 11. JSONL framing and memory safety

Do not use an unbounded `read_line()` strategy.

A single JSONL row can contain very large tool output, source text, or encoded binary/image content.

### Framing algorithm

```text
file
  ↓
seek(committed/scan offset)
  ↓
read fixed-size chunks
  ↓
scan only for newline
  ↓
obtain [record_start, record_end]
  ↓
selective streaming parser
```

Initial scan chunk:

```text
64 KiB
```

Initial per-file scan budget per scheduling cycle:

```text
512 KiB
```

Yield between budgets so one huge Codex record cannot block Claude activity processing.

### Cursor

```rust
struct FileCursor {
    record_start: u64,
    scan_offset: u64,
    committed_offset: u64,
}
```

Only advance `committed_offset` after a complete JSON record has been safely processed.

Partial writes remain pending until the next file-change notification.

### Truncate / replace

If:

```text
file_size < committed_offset
```

or file identity changes, do not reread the entire historical file.

Instead:

1. mark session confidence low/degraded
2. reset cursor to current EOF
3. continue with future appended records

The observer must prioritize agent safety and bounded resource use over perfect historical reconstruction.

## 12. Startup behavior

I'm Thinking must not parse historical sessions on launch.

For existing files:

```text
baseline offset = current EOF
```

Only bytes appended after monitoring starts are processed.

A session file created after monitoring starts is observed from its beginning.

This prevents first-launch CPU/RAM spikes caused by years of existing agent history.

## 13. Multiple sessions

Initial maximum:

```text
MAX_ACTIVE_SESSIONS = 64
```

MVP global audio intensity:

```text
global_intensity = max(active_session_intensities)
```

Do not sum session intensity; opening more terminals must not automatically make audio faster.

If the active-session limit is exceeded, evict the least-recent inactive bookkeeping first. If all slots are active, leave the new session unobserved and report a recoverable watcher warning.

## 14. Swift ↔ Rust IPC v1

Transport:

- Rust core is a child process of the Swift app.
- Swift writes commands to child stdin.
- Rust writes NDJSON events to child stdout.
- stderr is reserved for development/debug builds and must not contain transcript contents.

No socket, localhost port, shared IPC file, or daemon is required.

### Envelope

```json
{
  "v": 1,
  "seq": 42,
  "type": "activity"
}
```

Rules:

- `v`: protocol major version
- `seq`: monotonically increasing per core process for core → app messages
- unknown fields: ignore
- unknown type with supported major version: ignore + metric
- unsupported major version: fatal handshake failure
- maximum IPC record: 32 KiB

### Handshake

Core → App:

```json
{
  "v": 1,
  "seq": 1,
  "type": "hello",
  "core_version": "0.1.0",
  "protocol_min": 1,
  "protocol_max": 1,
  "capabilities": [
    "claude-passive",
    "codex-legacy",
    "codex-paginated"
  ]
}
```

App → Core:

```json
{
  "v": 1,
  "type": "configure",
  "agents": {
    "claude": true,
    "codex": true
  },
  "roots": {
    "claude": [
      {"path": "/Users/example/.claude/projects", "bookmark": null}
    ],
    "codex": [
      {"path": null, "bookmark": "BASE64_BOOKMARK_DATA"}
    ]
  }
}
```

Core → App:

```json
{
  "v": 1,
  "seq": 2,
  "type": "ready"
}
```

### App → Core messages

MVP:

- `configure`
- `set_agent_enabled`
- `rescan`
- `ping`
- `shutdown`

### Core → App activity

```json
{
  "v": 1,
  "seq": 126,
  "type": "activity",
  "session": 4,
  "agent": "codex",
  "phase": "thinking",
  "intensity": 0.63,
  "confidence": "high",
  "tool_class": null,
  "basis": "reasoning_usage",
  "at_ms": 48392
}
```

The `session` field is an ephemeral `u32` handle generated by the core. Real agent session IDs are never sent to Swift.

Activity updates are capped at approximately 10 Hz per session, except important phase transitions which may be emitted immediately.

Other core → app messages:

- `observer_status`
- `session_opened`
- `session_closed`
- `metrics`
- `error`
- `pong`

## 15. Settings schema

Swift owns application settings.

```swift
struct AppSettings: Codable {
    var schemaVersion: Int = 1

    var soundPack: SoundPackID = .laptop
    var volume: Double = 0.55
    var muted: Bool = false

    var claudeEnabled: Bool = true
    var codexEnabled: Bool = true
    var autoDetect: Bool = true
}
```

Persist normal settings with `UserDefaults`.

Start-at-login state should come from the macOS Login Item API as the source of truth rather than duplicating it in app configuration.

Optional advanced roots may be supported later:

```swift
struct AdvancedSettings {
    var additionalClaudeRoots: [URL]
    var additionalCodexRoots: [URL]
}
```

The application must never search all of `~/`, `/Users`, or Spotlight for transcripts.

## 16. Error model

Errors are divided into:

- info
- warning
- fatal

Most observer/parser errors are recoverable and must not terminate the core.

### IPC

```text
IPC1001 ProtocolVersionMismatch
IPC1002 MalformedCommand
IPC1003 MessageTooLarge
IPC1004 BrokenPipe
```

### Watcher

```text
WATCH2001 RootNotFound
WATCH2002 PermissionDenied
WATCH2003 FSEventsUnavailable
WATCH2004 FileReplaced
WATCH2005 FileTruncated
WATCH2006 TooManyActiveSessions
```

### Parser

```text
PARSE3001 MalformedRecord
PARSE3002 UnsupportedRecord
PARSE3003 PartialRecord
PARSE3004 RecordTooComplex
PARSE3005 CounterReset
```

### Activity

```text
ACT4001 InvalidUsageDelta
ACT4002 SessionStateConflict
ACT4003 ToolEndWithoutStart
ACT4004 ActivityQueueFull
```

### Audio

```text
AUD5001 AudioEngineUnavailable
AUD5002 SoundPackMissing
AUD5003 SoundDecodeFailed
AUD5004 AudioQueueFull
```

### Configuration

```text
CFG6001 InvalidSetting
CFG6002 UnsupportedSchema
CFG6003 InvalidAdditionalRoot
```

Error IPC must not contain transcript paths, prompt content, response content, reasoning, source code, or raw payloads.

## 17. Resource bounds

Initial core constants:

```rust
const MAX_ACTIVE_SESSIONS: usize = 64;
const MAX_ACTIVITY_QUEUE: usize = 256;
const MAX_RECENT_FINGERPRINTS: usize = 128;

const FILE_SCAN_CHUNK: usize = 64 * 1024;
const FILE_SCAN_BUDGET: usize = 512 * 1024;

const ACTIVITY_INTERVAL_MS: u64 = 100;
const MAX_IPC_RECORD_BYTES: usize = 32 * 1024;
```

Initial Swift audio bounds:

```swift
let maxAudioQueue = 32
let maxAudioVoices = 4
let maxKeysPerSecond = 15.0
```

All queues must define and test overflow behavior. Audio should be dropped rather than backpressuring an agent observer.

## 18. Testing contract

All transcript fixtures must be synthetic/sanitized. Never commit a real user's Claude/Codex transcript.

### Claude fixtures

- `01_basic_thinking_writing.jsonl`
- `02_single_tool.jsonl`
- `03_parallel_tools.jsonl`
- `04_tool_result_as_user.jsonl`
- `05_missing_text.jsonl`
- `06_duplicate_usage.jsonl`
- `07_unknown_fields.jsonl`
- `08_unknown_record_type.jsonl`
- `09_subagent.jsonl`

### Codex fixtures

- `01_legacy_basic.jsonl`
- `02_paginated_basic.jsonl`
- `03_function_call.jsonl`
- `04_parallel_function_calls.jsonl`
- `05_item_completed_duplicate.jsonl`
- `06_missing_call_id.jsonl`
- `07_reasoning_usage.jsonl`
- `08_usage_reset.jsonl`
- `09_duplicate_ordinal.jsonl`
- `10_missing_ordinal.jsonl`
- `11_unknown_response_item.jsonl`

### Framing tests

- partial record across multiple appends
- multiple records in one append
- file truncation
- file replacement
- very large ignored field
- no trailing newline yet
- malformed record followed by valid record
- simultaneous changes in multiple sessions

Large fixtures are generated during tests rather than committed.

### Activity tests

Use a fake monotonic clock.

Test:

- thinking impulse decay
- writing impulse decay
- fast reasoning usage
- sparse usage rejection
- usage counter reset
- asymmetric smoothing
- tool silence
- transition immediacy
- bounded event queue

### Audio tests

Test:

- zero intensity = silence
- maximum typing rate never exceeds configured limit
- jitter remains within range
- maximum queue length
- maximum voice count
- mute
- volume
- sound-pack switching
- old PCM release
- no long tail of pre-scheduled sounds after activity stops

## 19. Implementation phases and Definition of Done

### Phase 0 — Contracts

Deliver:

- this technical design
- protocol contract
- normalized-event contract
- parser rules
- resource/privacy constraints

DoD:

- IPC v1 fixed
- enums fixed
- error namespaces fixed
- fixture list fixed
- no-write-to-agent-settings rule documented
- privacy contract documented

### Phase 1 — JSONL infrastructure

Deliver:

- filesystem observer
- cursor handling
- bounded JSONL framer
- selective parser plumbing

DoD:

- only appended bytes processed
- existing history not replayed
- partial write support
- truncate support
- file replace support
- no unbounded `read_line()`
- large ignored field does not create proportional RSS growth
- read-only access to agent data
- idle CPU approximately zero/event-driven

### Phase 2 — Claude/Codex parsers

DoD:

- all Claude fixtures pass
- Codex legacy and paginated fixtures pass
- unknown records do not crash
- missing IDs do not crash
- duplicate semantic events do not double count
- parser fuzz test does not panic

### Phase 3 — State + Activity Engine

DoD:

- deterministic IDLE/THINKING/WRITING/TOOL reducer
- parallel tool handling
- usage reset handling
- sparse usage detection
- confidence calculation
- deterministic fake-clock tests
- monotonic time only

### Phase 4 — IPC + menu bar

No audio yet.

DoD:

- core launch + handshake
- protocol mismatch handling
- activity/state display
- core crash detection and restart
- Quit terminates child core
- no orphan core process
- no real session IDs/paths sent to Swift

### Phase 5 — Sound engine

DoD:

- all five sound packs selectable
- immediate pack switching
- volume/mute
- bounded voices and queue
- maximum typing rate enforced
- audio failure does not affect observer/core
- unnecessary decoded PCM released

### Phase 6 — Real agent integration

User must only need:

```bash
claude
```

or:

```bash
codex
```

DoD:

- no wrapper command
- no alias
- no shell rc modification
- no Claude/Codex configuration modification
- thinking/writing/tool/idle transitions observed in real sessions
- multiple sessions supported

### Phase 7 — Hardening

Exercise:

- many simultaneous Claude/Codex sessions
- large tool output
- high-frequency token events
- partial writes
- truncation/replacement
- core kill
- app kill
- audio device changes
- sleep/wake
- agent version updates

DoD:

- agent processes remain unaffected by all I'm Thinking failures
- no orphan core process
- no unintended temporary files
- bounded memory/queues remain within limits
- monitoring degrades gracefully when an agent format changes

## 20. Repository / development / distribution layout

The v1 implementation uses a deliberately small Swift + Rust split:

```text
I-m-Thinking/
├── app/
│   ├── Package.swift
│   ├── Resources/
│   │   └── ImThinking.debug.entitlements
│   ├── Sources/ImThinking/
│   │   ├── ImThinkingApp.swift
│   │   ├── AppModel.swift
│   │   ├── MenuContent.swift
│   │   ├── CoreBridge.swift
│   │   ├── CoreMessage.swift
│   │   ├── KeyboardAudioEngine.swift
│   │   ├── SoundPack.swift
│   │   ├── SoundSynthesizer.swift
│   │   ├── TypingScheduler.swift
│   │   └── LoginItemManager.swift
│   └── Tests/ImThinkingTests/
├── core/
│   ├── Cargo.toml
│   ├── src/
│   │   ├── activity/
│   │   ├── jsonl/
│   │   ├── observer/
│   │   ├── parsers/
│   │   ├── runtime/
│   │   ├── events.rs
│   │   ├── ipc.rs
│   │   ├── lib.rs
│   │   └── main.rs
│   └── tests/
│       └── fixtures/
├── scripts/
│   ├── build-app.sh
│   └── make-dmg.sh
├── .vscode/
│   ├── launch.json
│   ├── tasks.json
│   └── extensions.json
├── .github/workflows/
│   ├── core.yml
│   ├── app.yml
│   └── release.yml
├── docs/
│   ├── DEVELOPMENT.md
│   ├── RELEASE.md
│   ├── TECHNICAL_DESIGN.md
│   ├── PROTOCOL.md
│   ├── PARSER_RULES.md
│   ├── NORMALIZED_EVENTS.md
│   ├── RESOURCE_LIMITS.md
│   ├── PROGRESS.md
│   └── checklists/manual-verification.md
├── CHANGELOG.md
└── README.md
```

### Debug build

VS Code and Cursor use the same checked-in CodeLLDB configuration.

```text
I'm Thinking Debug.app
bundle id: com.den0206.ImThinking.debug
output: .build/debug/
```

The real app bundle is built before LLDB launches the Swift executable. This keeps `Info.plist`, bundled Rust Core lookup, MenuBarExtra, and SMAppService behavior close to release behavior.

The debug app alone receives `com.apple.security.get-task-allow`. The release app never receives this entitlement.

### Release build

```text
I'm Thinking.app
bundle id: com.den0206.ImThinking
output: .build/release/
```

The release pipeline is intentionally same-repository:

```text
vX.Y.Z tag
  -> tests
  -> Developer ID signing
  -> app notarize + staple
  -> DMG creation
  -> DMG signing
  -> DMG notarize + staple
  -> GitHub Release in den0206/I-m-Thinking
```

No dedicated release repository, self-update mechanism, or release-specific runtime service is part of v1.

Development and release operational details are normative in:

- `docs/DEVELOPMENT.md`
- `docs/RELEASE.md`
- `docs/checklists/manual-verification.md`

## 21. v1 completion criteria

Version 1 is complete when all of the following are true:

1. Users launch Claude Code and Codex with their normal commands.
2. No agent or shell configuration is modified.
3. Agent session files are accessed read-only.
4. THINKING / WRITING / TOOL / IDLE are automatically classified.
5. Activity intensity is calculated in `0...1`.
6. Uncertainty is explicitly represented as confidence.
7. Reasoning-token deltas are used only when sufficiently real-time.
8. Sparse usage updates cannot create false high-speed bursts.
9. At least five sound packs are selectable.
10. Volume, mute, and Start at Login are supported.
11. RAM use does not scale linearly with JSONL record size.
12. Historical transcripts are not replayed at startup.
13. Monitoring is event-driven rather than busy-polled.
14. Session/event/audio bounds are enforced.
15. Disk logging is off by default.
16. I'm Thinking failure cannot break Claude Code or Codex.
17. User content is never persisted by I'm Thinking.
18. Legacy and paginated Codex rollouts are supported.
19. Unknown future records degrade gracefully.
20. Real-agent, large-record, crash, and sleep/wake tests pass.

---

This document is the implementation contract for v1. Changes that weaken agent isolation, privacy, fail-open behavior, or bounded-resource guarantees require explicit design review before implementation.
