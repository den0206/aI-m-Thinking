# Development Guide

I’m Thinking のローカル開発、VS Code / Cursor デバッグ、Swift/Rust Coreの確認手順をまとめます。

## 1. Required toolchain

- macOS 26.0+
- Xcode 27
- Swift 6.4
- Rust toolchain
- VS Code または Cursor
- CodeLLDB extension: `vadimcn.vscode-lldb`

確認:

```bash
swift --version
cargo --version
```

リポジトリ直下の `.swift-version` は `6.4.0` です。

## 2. F5: macOS app debug

VS Code / Cursor でリポジトリルートを開きます。

Run and Debug で `Run I'm Thinking Debug.app` を選び、F5 を実行します。

preLaunchTask:

```bash
CONFIG=debug ./scripts/build-app.sh
```

生成物:

```text
.build/debug/I'm Thinking Debug.app
```

CodeLLDB は `.app` 内の実行ファイルを直接起動します。

```text
.build/debug/I'm Thinking Debug.app/Contents/MacOS/ImThinking
```

SwiftUIだけを `swift run` するのではなくApp bundleを組み立てる理由:

- `Info.plist` を本番と同じ条件で使える
- Rust Coreを `Contents/MacOS/im-thinking-core` に同梱できる
- `Bundle.main` ベースのCore探索を本番と同じ経路で検証できる
- MenuBarExtra / SMAppServiceをApp bundleとして確認できる

## 3. Debug app isolation

| | Release | Debug |
|---|---|---|
| Display name | I'm Thinking | I'm Thinking Debug |
| Bundle ID | `com.den0206.ImThinking` | `com.den0206.ImThinking.debug` |
| Bundle | `.build/release/I'm Thinking.app` | `.build/debug/I'm Thinking Debug.app` |

Debug版を別bundle idにすることで、開発中のStart at LoginやLaunchServices上の同一性を本番版と分離します。

## 4. Build without debugger

Cmd+Shift+B のdefault taskは `Build & Run I'm Thinking Debug.app` です。

Terminalから実行する場合:

```bash
CONFIG=debug ./scripts/build-app.sh
open ".build/debug/I'm Thinking Debug.app"
```

## 5. Debug the Rust Core

Run and Debugで `Run Rust Core` を選んでF5します。

preLaunchTask:

```bash
cargo build --manifest-path core/Cargo.toml
```

binary:

```text
core/target/debug/im-thinking-core
```

Core単体起動時はstdin/stdoutのnewline JSON IPCで動きます。最初に `hello` が出力されます。

configure例:

```json
{"v":1,"type":"configure","agents":{"claude":true,"codex":true},"extra_roots":[]}
```

Parser / Activity Engineのロジック確認ではRust testsを優先します。

## 6. Tests

Rust:

```bash
cargo fmt --manifest-path core/Cargo.toml -- --check
cargo test --manifest-path core/Cargo.toml
cargo clippy --manifest-path core/Cargo.toml --all-targets -- -D warnings
```

Swift:

```bash
swift build --package-path app
swift test --package-path app
```

App bundle:

```bash
CONFIG=debug ./scripts/build-app.sh
./scripts/build-app.sh
```

### Accuracy replay

実際の Claude Code トランスクリプトを時刻どおりに再生し、生成中・ツール実行中・待機中の各区間で「音が鳴った割合」と「phase の一致率」を集計します。出力は集計値のみで、トランスクリプトの内容は表示しません。

```bash
cargo run --manifest-path core/Cargo.toml --example replay_eval -- ~/.claude/projects/<project>/<session>.jsonl
```

パーサーや Activity Engine を変更したときは、手元の複数セッションで前後の数値を比較してください。

## 7. Real agent smoke test

I’m Thinking Debugを起動した状態で、別Terminalから通常どおり `claude` または `codex` を起動します。

確認ポイント:

- Agent側にaliasやprefixが不要
- THINKING / WRITING / TOOL / IDLE が変化する
- activity intensityに応じて音の間隔が変化する
- read/search/shell待機中に不要な連打が続かない
- edit/write系toolでは短い入力音が鳴る
- I’m Thinkingを終了してもAgent側は影響を受けない

詳細: [Manual Verification Checklist](checklists/manual-verification.md)

## 8. Important development rules

### Do not modify agent configuration

開発やデバッグのために次を変更しません。

```text
~/.claude/settings.json
~/.codex/config.toml
project/.claude/*
project/.codex/*
CLAUDE.md
AGENTS.md
~/.zshrc
~/.bashrc
```

### Do not persist transcript content

I’m Thinking側のdebug loggingへprompt、response、reasoning、source code、tool input/output、full JSONL recordを出しません。

diagnosticsはevent type / state / intensity / timestamp / error code等のmetadataに限定します。

### Keep memory bounded

新しいqueue/cache/session mapを追加するときは必ず上限と破棄条件を定義します。

既存制約: [RESOURCE_LIMITS.md](RESOURCE_LIMITS.md)

## 9. Rebornから参考にした点

- `.vscode/launch.json` / `.vscode/tasks.json`
- `.app` を組み立ててからF5で起動
- Debug版を本番版と分離
- build scriptをdebug/release共通化
- GitHub Actionsとローカル手順を揃える
- 実機確認をchecklistとして別管理

I’m Thinkingでは不要なため、Accessibility/TCC向けの複雑な処理、自己更新、独立Release repositoryは採用していません。
