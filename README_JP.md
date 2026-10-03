<p align="center">
  <img src="docs/images/icon.png" width="128" alt="aI'm Thinking">
</p>

# aI'm Thinking

[![Core](https://github.com/den0206/aI-m-Thinking/actions/workflows/core.yml/badge.svg)](https://github.com/den0206/aI-m-Thinking/actions/workflows/core.yml)
[![App](https://github.com/den0206/aI-m-Thinking/actions/workflows/app.yml/badge.svg)](https://github.com/den0206/aI-m-Thinking/actions/workflows/app.yml)
[![Release](https://github.com/den0206/aI-m-Thinking/actions/workflows/release.yml/badge.svg)](https://github.com/den0206/aI-m-Thinking/actions/workflows/release.yml)

[English](README.md) | **日本語**

Claude Code / Codex の活動を検知し、思考・生成・編集の強さに合わせてキーボード音を鳴らす macOS メニューバーアプリです。

通常どおり次のコマンドで Agent を起動できます。

```bash
claude
codex
```

`agent-sound claude` のようなラッパーコマンド、alias、shell hook、Claude/Codex設定変更は不要です。

## Requirements

- macOS 26.0 以降
- Apple Silicon
- 開発時: Xcode 27 / Swift 6.4 / Rust toolchain

Swift toolchain はリポジトリ直下の `.swift-version` で `6.4.0` に固定しています。

## Install

GitHub Releases から最新の `aIm-Thinking-X.Y.Z.dmg` を取得し、`aI'm Thinking.app` を `/Applications` へ移動します。

配布は**このリポジトリ自身のGitHub Releases**を使用します。Release専用リポジトリは使いません。

> 現在のRelease CIはApple Silicon runnerでビルドするため、配布対象もApple Siliconです。

## Features

- Claude Code / Codex の通常起動をpassive監視
- THINKING / WRITING / TOOL / IDLE の状態推定
- 活動強度に応じたキーボード音の速度変化
- 5種類のキーボードサウンド
- turnごとのランダムサウンド / typing速度調整
- 活動に合わせたメニューバーのキーアニメーション
- 音量 / Mute
- Start at Login
- sleep / wake 後の自動rescan
- Agent設定ファイルを書き換えないfail-open設計

## Privacy / resource policy

- `~/.claude/settings.json`、`~/.codex/config.toml`、shell rcを変更しません
- Claude/Codex JSONLはread-onlyで開きます
- 起動前の履歴を再生しません
- prompt / response / reasoning / source code / tool outputをaI'm Thinking側へ永続保存しません
- JSONL全文をメモリへ保持しません
- session / event / audio stateには上限があります
- aI'm Thinkingが停止してもClaude Code / Codexはそのまま動作します

詳細: [Technical Design](docs/TECHNICAL_DESIGN.md)

## Development

### VS Code / Cursor

`.vscode/launch.json` と `.vscode/tasks.json` を同梱しています。

1. CodeLLDB (`vadimcn.vscode-lldb`) をインストール
2. リポジトリルートを VS Code / Cursor で開く
3. Run and Debug で **Run aI'm Thinking Debug.app** を選択
4. **F5**

F5実行時は自動で次を生成します。

```text
.build/debug/aI'm Thinking Debug.app
```

Debug版は本番版と分離されています。

| | Release | Debug |
|---|---|---|
| App name | aI'm Thinking | aI'm Thinking Debug |
| Bundle ID | `com.den0206.AImThinking` | `com.den0206.AImThinking.debug` |
| Build | release | debug |

Rust Coreを単体で追う場合は **Run Rust Core** を選択してF5します。

詳細: [Development Guide](docs/DEVELOPMENT.md)

### CLI

```bash
cargo test --manifest-path core/Cargo.toml
cargo clippy --manifest-path core/Cargo.toml --all-targets -- -D warnings

swift build --package-path app
swift test --package-path app

CONFIG=debug ./scripts/build-app.sh
open ".build/debug/aI'm Thinking Debug.app"
```

### App icon

アイコンは `app/Resources/AppIcon/generate_icon.py` から生成します。キーの文字・色・大きさなどはファイル先頭の `CONFIG` を編集し、次で `AppIcon.svg`、`app/Resources/AppIcon.icns`、`docs/images/icon.png` を再生成します。

```bash
./scripts/make-icon.sh
```

## Release build

ローカルのrelease bundle:

```bash
./scripts/build-app.sh
```

出力:

```text
.build/release/aI'm Thinking.app
```

Developer IDで署名する場合:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  ./scripts/build-app.sh
```

### GitHub Release

`vX.Y.Z` タグをpushすると、Release workflowが次を行います。

1. Rust / Swift tests
2. Developer ID署名
3. `.app` notarization + staple
4. DMG生成
5. DMG署名
6. DMG notarization + staple
7. このリポジトリのGitHub ReleaseへDMGを添付

```bash
git tag v0.1.0
git push origin v0.1.0
```

必要なSecretsや証明書準備は [Release Guide](docs/RELEASE.md) を参照してください。

## Documentation

- [Development Guide](docs/DEVELOPMENT.md)
- [Release Guide](docs/RELEASE.md)
- [Mac App Store Readiness](docs/APP_STORE.md)
- [Manual Verification Checklist](docs/checklists/manual-verification.md)
- [Technical Design](docs/TECHNICAL_DESIGN.md)
- [Parser Rules](docs/PARSER_RULES.md)
- [IPC Protocol](docs/PROTOCOL.md)
- [Resource Limits](docs/RESOURCE_LIMITS.md)
- [Implementation Progress](docs/PROGRESS.md)
- [CHANGELOG](CHANGELOG.md)

## Project layout

```text
app/                    Swift / SwiftUI menu-bar app
core/                   Rust observer/parser/activity engine
scripts/build-app.sh    Debug/Release .app assembly + codesign
scripts/make-dmg.sh     DMG packaging
scripts/make-icon.sh    App icon (.icns) generation
.vscode/                VS Code / Cursor debug configuration
.github/workflows/      CI / Release workflows
docs/                   Design / development / release documents
```

## Status

実装進捗と未完了の実機確認項目は [docs/PROGRESS.md](docs/PROGRESS.md) に記録しています。
