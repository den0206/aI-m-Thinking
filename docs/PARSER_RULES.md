# Parser Rules v1

The parser is intentionally tolerant because Claude and Codex persistence formats are external implementation details.

## Shared rules

1. Read session data read-only.
2. Parse only bytes appended after monitoring starts.
3. Never replay existing history on application launch.
4. Deserialize only fields needed for classification/counters.
5. Ignore unknown fields and unknown record types.
6. Do not retain prompt/reasoning/tool payload strings.
7. Absence of an event never proves the agent is idle.
8. File append order is authoritative; do not depend on Codex ordinal values.
9. Partial records do not advance the committed offset.
10. Malformed/unsupported records do not terminate the observer.

## Claude

Default root:

```text
~/.claude/projects/
```

| Input semantic | Normalized event |
|---|---|
| typed prompt: other string content, `origin.kind = "human"`, or image/document block | TurnStart |
| user row with text-only block list (interruption, injected context) | TurnEnd |
| user row with `isMeta: true` | ignore |
| string content starting `<command-`, `<local-command-`, `<bash-` (local command echo/output) | ignore |
| `<command-message>` row with `origin.kind = "human"` (slash command or skill the model runs) | TurnStart |
| string content starting `[Request interrupted by user` | TurnEnd |
| assistant content: thinking / redacted_thinking | ThinkingPulse |
| assistant content: text | WritingPulse |
| assistant content: tool_use / server_tool_use | ToolStart |
| user content: tool_result | ToolEnd |
| assistant `message.stop_reason`: end_turn / stop_sequence / refusal | TurnEnd |
| system subtype: turn_duration (older versions) | TurnEnd |

A `type=user` row containing `tool_result` is not a new user turn.

Observed on Claude Code 2.1.x:

- Esc pressed before the model writes any row leaves no transcript record at all. The only signal is `~/.claude/sessions/<pid>.json` (`{"sessionId", "status": "busy" | "shell" | "idle" | "waiting"}`), which flips to `idle` within about a second, or to `shell` instead while background tasks of that process are still running. When that directory sits next to the configured `projects` root, the runtime watches it and closes the turn of the matching session and its subagents on `idle` or `shell`. `waiting` (a permission or input prompt) keeps the turn open. With only `projects` granted (App Store sandbox), such turns fall back to the pending-output timeout.
- `system/turn_duration` is not written. The terminal `stop_reason` of the last API message is the turn-end signal.
- Every content block of one API message is written when that message completes, and each row already carries the final `stop_reason`. Rows are therefore completion signals that lag the work by the generation time (prompt or tool result to next row: median 5 s, p90 33 s, max 59 s in a measured session).
- Because of that lag, the state reducer tracks "awaiting model output" after a prompt and after all tools return. Activity holds while output is pending and fades between 60 s and 120 s without a new record.

Claude text rows can be delayed or absent. While a turn remains open, no fresh row lowers activity/confidence; it does not force IDLE.

## Codex

Default root:

```text
~/.codex/sessions/
```

Support legacy and paginated rollout representations.

| Input semantic | Normalized event |
|---|---|
| task/turn start | TurnStart |
| reasoning item/event | ThinkingPulse |
| assistant message item/event | WritingPulse |
| function/custom/local-shell/tool call | ToolStart |
| call output or completed tool item | ToolEnd |
| token-count update | UsagePulse |
| task/turn complete or abort | TurnEnd |

Semantic duplicates such as call output plus `item_completed` must be deduplicated.

From the Codex rollout persistence policy (`codex-rs/rollout/src/policy.rs`):

- `exec_command_begin/end`, `mcp_tool_call_begin`, `web_search_begin` and `item_started` are transient and never written to rollouts. Tool lifecycles come from `response_item` calls and outputs.
- `web_search_call` and `image_generation_call` response items are written only after the hosted tool completes and have no output item. They do not open a tool.
- Built-in tool names: `apply_patch` (mutation); `exec_command`, `shell`, `shell_command`, `write_stdin` (shell); `read_file`, `list_dir`, `grep_files`, `view_image` (read); `web_search`, `tool_search` (search); `spawn_agent`, `wait_agent` (sub-agent).
- Cold rollouts are compressed to `.jsonl.zst`. Resuming one writes the full history back to a new `.jsonl` file, so a newly created file is not necessarily new activity.

- Paginated `item_completed` records use the case-sensitive TurnItem names `Reasoning`, `AgentMessage`, and `FunctionCallOutput`. Reasoning and assistant messages refresh activity; completed tool items close the corresponding tool instead of opening one.
- Assistant `phase: "final_answer"` ends the turn unless `delivery: "async"` marks a mid-turn message. Commentary and messages without phase remain activity signals; `task_complete` / `turn_complete` / `turn_aborted` are explicit end signals.
- Codex model-output waits hold activity for 540 seconds and fade over the final 60 seconds of the existing 600-second stale-turn limit. Claude keeps its 60-second hold and 120-second fade deadline. Waiting on read/search/shell tools remains silent.
- Once an explicit turn end is observed, late content, tool, and usage records cannot reopen it; the next turn-start event is required. Both agents report zero intensity immediately on turn end.

Upstream definitions: [rollout persistence policy](https://github.com/openai/codex/blob/main/codex-rs/rollout/src/policy.rs), [TurnItem](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/items.rs), and [MessagePhase](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/models.rs).

Claude's external idle status records capture the transcript EOF as an interruption cutoff. Already-written records, including partial rows completed later, cannot reopen the turn. The normal byte and record scan budgets remain in effect.

Missing tool IDs use a bounded fallback key. Missing IDs must never panic the parser.

Usage counter decreases are treated as reset/rebaseline, never as a negative activity delta.

## History guard

Every record's own `timestamp` is compared with the wall clock. Records written more than 10 minutes before they are observed (a restored rollout, a creation event for an old file) update session state but never produce sound or "awaiting model" activity.

## Unrecognized format

A session that writes 100 records without any of them producing an event is reported once with the warning `PARSE3006` (`component` = `claude` / `codex`). Records older than the history guard and quiet kinds are not counted: Claude `progress`, `file-history-snapshot`, `summary`, `queue-operation`, `system`, and `isMeta` rows; Codex `session_meta`, `turn_context`, `token_usage_record`, `compacted`, and `event_msg` `token_count`. Malformed records always count. The app marks the agent "Unsupported format" until that agent reports activity again or monitoring restarts.

## Measuring accuracy

`cargo run --example replay_eval -- <claude transcript.jsonl>` replays a real Claude Code transcript on its own clock and prints, per ground-truth interval (model generating / tool running / idle), how much time was audible and how often the reported phase matched. Only aggregate numbers are printed.

## Framing

Do not use an unbounded `read_line()`.

Scan fixed-size chunks for newline boundaries, then selectively deserialize the bounded file range. Large ignored fields must not be copied into memory.

Partial rows stay pending until the next append notification.
