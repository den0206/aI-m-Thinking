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
| real user message | TurnStart |
| assistant content: thinking | ThinkingPulse |
| assistant content: text | WritingPulse |
| assistant content: tool_use | ToolStart |
| user content: tool_result | ToolEnd |
| system subtype: turn_duration | TurnEnd |

A `type=user` row containing `tool_result` is not a new user turn.

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

Missing tool IDs use a bounded fallback key. Missing IDs must never panic the parser.

Usage counter decreases are treated as reset/rebaseline, never as a negative activity delta.

## Framing

Do not use an unbounded `read_line()`.

Scan fixed-size chunks for newline boundaries, then selectively deserialize the bounded file range. Large ignored fields must not be copied into memory.

Partial rows stay pending until the next append notification.
