# Normalized Events v1

Agent-specific persistence formats are normalized before state or activity logic sees them.

## Types

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

## Reducer contract

| Event | Result |
|---|---|
| TurnStart | THINKING |
| ThinkingPulse | THINKING unless tools remain active |
| WritingPulse | WRITING unless tools remain active |
| ToolStart | TOOL |
| ToolEnd with active tools remaining | TOOL |
| ToolEnd with no tools remaining | THINKING |
| TurnEnd | IDLE |

Parallel tools are tracked by key; a single boolean is not sufficient.

State and intensity are independent. A session can remain logically THINKING while sound intensity decays to zero.

## Privacy rule

Normalized events may contain classification metadata and counters only. They must not contain prompts, reasoning text, assistant text, source code, file contents, tool arguments, or tool output.
