# IPC Protocol v1

This document defines the executable contract between the Swift menu-bar app and `im-thinking-core`.

## Transport

- Swift owns the Rust child process.
- App -> Core: NDJSON over stdin.
- Core -> App: NDJSON over stdout.
- stderr is diagnostic-only and must never contain transcript content.
- No socket, local port, daemon, or shared IPC file is required.

## Envelope

Every Core -> App message contains:

```json
{"v":1,"seq":1,"type":"hello"}
```

- `v`: protocol major version.
- `seq`: monotonically increasing for one core-process lifetime.
- `type`: message discriminator.
- Unknown fields are ignored.
- Unknown message types on a supported major version are ignored and counted.
- Unsupported major versions fail the handshake.
- Maximum IPC record size: 32 KiB.

## Handshake

1. Core emits `hello`.
2. App emits `configure`.
3. Core emits `ready`.
4. Monitoring begins only after `ready`.

### Core -> App hello

```json
{
  "v": 1,
  "seq": 1,
  "type": "hello",
  "core_version": "0.1.0",
  "protocol_min": 1,
  "protocol_max": 1,
  "capabilities": ["claude-passive","codex-legacy","codex-paginated"]
}
```

### App -> Core configure

```json
{
  "v": 1,
  "type": "configure",
  "agents": {"claude": true, "codex": true},
  "extra_roots": []
}
```

## App -> Core messages

- `configure`
- `set_agent_enabled`
- `rescan`
- `ping`
- `shutdown`

## Core -> App messages

- `hello`
- `ready`
- `activity`
- `observer_status`
- `session_opened`
- `session_closed`
- `metrics`
- `error`
- `pong`

## Activity

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

`session` is an ephemeral core-generated `u32`. Real Claude/Codex session identifiers must never cross IPC.

### phase
- `idle`
- `thinking`
- `writing`
- `tool`

### confidence
- `high`
- `medium`
- `low`

### tool_class
- `mutation`
- `shell`
- `read`
- `search`
- `subagent`
- `mcp`
- `generic`

### basis
- `reasoning_usage`
- `reasoning_record`
- `text_record`
- `tool_event`
- `state_baseline`
- `mixed`

Activity updates are capped at about 10 Hz per session. Phase transitions may be emitted immediately.

## Error payload

```json
{
  "v": 1,
  "seq": 188,
  "type": "error",
  "severity": "warning",
  "code": "WATCH2002",
  "component": "claude_observer",
  "recoverable": true
}
```

Error payloads must not contain transcript paths, raw records, prompts, reasoning, source code, tool arguments, or tool output.

## Shutdown

The app sends `shutdown`; the core releases observers and exits with status 0. EOF on stdin is also treated as shutdown so an orphan core is not left behind.
