# I'm Thinking

Requires macOS 26.0+ and Swift 6.4 for development.

A macOS menu-bar app that turns Claude Code / Codex activity into keyboard-like sound.

## Current behavior

1. Launch **I'm Thinking**.
2. Continue to use the normal commands:

```bash
claude
codex
```

No wrapper command, alias, shell hook, Claude setting, or Codex setting is required.

The app passively observes newly appended local session JSONL metadata and maps detected activity to synthesized keyboard sounds.

## Safety / privacy defaults

- Claude/Codex configuration is never modified.
- Shell startup files are never modified.
- Agent JSONL files are opened read-only.
- Existing transcript history is not replayed at startup.
- Prompt, response, reasoning, source code, and tool output are not persisted by I'm Thinking.
- Disk logging is off by default.
- Session/event/audio state is bounded.
- If I'm Thinking stops, Claude Code and Codex continue normally.

See [docs/TECHNICAL_DESIGN.md](docs/TECHNICAL_DESIGN.md) for the implementation contract.

## Development

Rust Core:

```bash
cargo test --manifest-path core/Cargo.toml
cargo clippy --manifest-path core/Cargo.toml --all-targets -- -D warnings
```

Swift app:

```bash
swift build --package-path app
swift test --package-path app
```

For development, point the Swift process at a locally built Core:

```bash
IM_THINKING_CORE_PATH="$PWD/core/target/debug/im-thinking-core" \
  swift run --package-path app ImThinking
```

## Build the macOS app bundle

```bash
bash scripts/build-app.sh
```

Output:

```text
dist/I'm Thinking.app
```

The bundle contains both the Swift menu-bar executable and the Rust `im-thinking-core` auxiliary executable.

To sign locally or in release automation:

```bash
SIGN_IDENTITY="Developer ID Application: ..." bash scripts/build-app.sh
```

## Status

Implementation progress and phase boundaries are recorded in [docs/PROGRESS.md](docs/PROGRESS.md).
