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
  "core_version": "0.1.0"
}
```

### App -> Core configure

```json
{
  "v": 1,
  "type": "configure",
  "agents": {"claude": true, "codex": true},
  "roots": {
    "claude": [{"path": "/Users/example/.claude/projects", "bookmark": null}],
    "codex": [{"path": "/Users/example/.codex/sessions", "bookmark": null}]
  }
}
```

### Root grants

Each configured root is one of:

```json
{"path":"/absolute/read-only/root","bookmark":null}
```

or:

```json
{"path":null,"bookmark":"BASE64_BOOKMARK_DATA"}
```

Direct distribution uses explicit path grants supplied by Swift. App Store mode uses a transfer bookmark created from a user-approved security-scoped URL.

Rules:

- Rust Core never derives agent roots from `HOME`.
- At most 4 configured roots per agent are accepted.
- A bookmark grant takes precedence if both fields are present.
- Invalid/empty grants are ignored.
- The entire configure record remains subject to the 32 KiB IPC limit.
- Real session identifiers and transcript contents never cross IPC.
- An agent whose `agents` flag is false gets no roots; there is no runtime toggle.
- Sole exception to reading only granted roots: for a Claude root named `projects`, Core also watches the sibling `sessions` directory read-only (one watcher per root, released with the root). Only `sessionId` and `status` are parsed from files of at most 16 KiB and never cross IPC. Where the sandbox does not allow it, the watcher is skipped.

## App -> Core messages

- `configure`
- `rescan`
- `set_session_paused`: `{"v":1,"type":"set_session_paused","session":4,"paused":true}`. Pauses only the specified ephemeral session. Send `paused:false` to resume manually; only records beginning after the resume command contribute activity. Paused records are consumed silently, and other sessions remain monitored. Paused sessions are never evicted at the session cap, so they stay paused until resumed or their file is removed. Unknown/closed handles are ignored.
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
  "tool_class": null
}
```

`session` is an ephemeral core-generated `u32`. Real Claude/Codex session identifiers must never cross IPC.

### phase
- `idle`
- `thinking`
- `writing`
- `tool`

### tool_class
- `mutation`
- `shell`
- `read`
- `search`
- `subagent`
- `mcp`
- `generic`

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

`PARSE3006` (unrecognized transcript format) uses the agent name, `claude` or `codex`, as `component`. See `docs/PARSER_RULES.md`.

Error payloads must not contain transcript paths, raw records, prompts, reasoning, source code, tool arguments, or tool output.

## Shutdown

The app sends `shutdown`; the core releases observers and exits with status 0. EOF on stdin is also treated as shutdown so an orphan core is not left behind.
