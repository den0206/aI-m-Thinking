---
name: review-for-merge
description: aI'm Thinking の作業中の変更やブランチ差分をマージ前にレビューする。修正やコミットは行わない。
---

# マージ前レビュー

1. リポジトリルートで `git status --short`、`git diff`、`git diff --cached` を確認し、関連する未追跡ファイルも読む。比較元指定があれば `git diff <base>...HEAD` も確認する。指定がなければ main との差分も確認し、main が存在しない場合はその制限を報告する。レビュー範囲を明記する。
2. `README.md`、`docs/DEVELOPMENT.md`、`docs/RESOURCE_LIMITS.md` と変更に関連する仕様を読み、変更した処理の呼び出し元・終了処理・対応テストまで確認する。
3. 特に以下を確認する。
   - Agent設定・shell設定をアプリが変更せず、JSONLをread-onlyで監視する。アプリの故障・終了がClaude/Codexに影響しない。
   - 起動前の履歴や復元された古いrecordで音を鳴らさない。途中行・巨大行・不正JSON・未知record・truncate/rotateに耐える。
   - prompt・response・reasoning・source code・tool input/output・実session IDを保存せず、IPCやdiagnosticにも流さない。
   - queue・session・fingerprint・baseline・root・audio voiceに上限と解放条件がある。overflowでAgentを待たせず、idle時の不要な処理を止める。
   - 並列tool・重複event・欠損ID・usage reset・中断・subagentを扱う。無更新だけでIDLEと断定せず、古いturnは解放する。
   - Rust/SwiftのNDJSON、version、seq、handshake、32 KiB上限が一致する。stdin EOF/shutdownでCoreとwatcherを終了する。
   - UIのactor境界、Mute、音量、sound pack切替、sleep/wake、音声resourceの解放を保つ。
   - 明示的なroot grant、各Agent最大4件、bookmark失効・取消時のscope解放、Sandboxのread-only権限を保つ。CoreがHOMEからrootを導出しない。
   - Debug/Release/App Storeのbundle ID・entitlements、Rust helper・Sounds・PrivacyInfoの同梱、helper→appの署名順を保つ。
4. 関連する検証を既存CIと同じコマンドで実行する。Rust/Swift境界の変更は両方を検証する。

```bash
cargo fmt --manifest-path core/Cargo.toml --check
cargo test --manifest-path core/Cargo.toml
cargo clippy --manifest-path core/Cargo.toml --all-targets -- -D warnings
swift build --package-path app
swift test --package-path app
```

bundle・resource・entitlements・build script変更では必要な構成をビルドし、該当CIのbundle検査も行う。

```bash
CONFIG=debug bash scripts/build-app.sh
CONFIG=appstore-smoke bash scripts/build-app.sh
bash scripts/build-app.sh
```

文書・コマンド・スキルのみなら参照先・形式・手順の整合性と `git diff --check` を確認し、製品ビルドを省略できる。不足toolchainや環境制約による失敗・未実行を成功扱いにしない。

関連仕様: parser/activityは `docs/PARSER_RULES.md` と `docs/NORMALIZED_EVENTS.md`、IPC/root grantは `docs/PROTOCOL.md`、構成は `docs/TECHNICAL_DESIGN.md`、配布は `docs/RELEASE.md` と `docs/APP_STORE.md`。必要な実機確認は `docs/checklists/manual-verification.md` を参照する。

仕様変更時は関連docs・README・CHANGELOGとの整合性を確認する。不要な依存・重複実装も確認するが、入力検証・エラー処理・上限・アクセシビリティを削らない。テストはfixtureや一時ディレクトリを使い、実ユーザーの設定やsessionデータを変更しない。実sessionを使うreplayはユーザー指定がある場合だけ行う。

重大度順に根拠のある指摘を `ファイル:行`・影響・修正案とともに報告し、検証結果と「取り込み可 / 要修正 / 検証未完了」を示す。指摘がなくても検証漏れは明記する。
レビューだけではファイル編集、stage、commit、pushを行わない。
