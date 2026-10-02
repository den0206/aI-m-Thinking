# Manual Verification Checklist

自動テストでは保証できない macOS / Claude Code / Codex / audio / distribution の実機確認項目です。

## A. Debug bundle

- [ ] `CONFIG=debug ./scripts/build-app.sh` が成功する
- [ ] `.build/debug/I'm Thinking Debug.app` が生成される
- [ ] bundle id が `com.den0206.ImThinking.debug`
- [ ] VS Code / Cursorで `Run I'm Thinking Debug.app` をF5起動できる
- [ ] MenuBarExtraだけが表示され、通常のDock appとして常駐しない
- [ ] Debug版とRelease版を同時に識別できる

## B. Claude Code

- [ ] I’m Thinking起動後、通常の `claude` だけで監視される
- [ ] wrapper / alias / hook追加が不要
- [ ] turn開始でTHINKINGへ遷移する
- [ ] text生成でWRITINGへ遷移する
- [ ] tool実行でTOOLへ遷移する
- [ ] turn終了後IDLEへ戻る
- [ ] read/search/shell待機中に高頻度音が鳴り続けない
- [ ] edit/write系toolで短いtyping burstが鳴る

## C. Codex

- [ ] I’m Thinking起動後、通常の `codex` だけで監視される
- [ ] wrapper / alias / hook追加が不要
- [ ] reasoning/activity eventでTHINKINGへ遷移する
- [ ] outputでWRITINGへ遷移する
- [ ] function/tool callでTOOLへ遷移する
- [ ] turn完了後IDLEへ戻る
- [ ] usage snapshotだけで不自然なburstが発生しない

## D. Audio

- [ ] 5種類のsound packを切り替えられる
- [ ] Preview Soundが鳴る
- [ ] volume sliderが反映される
- [ ] Muteで即座に停止する
- [ ] intensityが低いと遅く、高いと速くなる
- [ ] THINKINGとWRITINGで過剰な連打にならない
- [ ] 長時間idleでAVAudioEngineが不要に動き続けない

## E. Multiple sessions

- [ ] ClaudeとCodexを同時起動してもクラッシュしない
- [ ] 複数sessionのうち強いactivityがsound schedulerへ反映される
- [ ] session終了時にstateが解放される
- [ ] 長時間利用してmemoryが継続増加しない

## F. Sleep / wake

- [ ] Macをsleepする
- [ ] wake後にobserver rescanが走る
- [ ] Agentを再起動せず監視が継続する
- [ ] wake後に重複監視や二重音が発生しない

## G. Start at Login

- [ ] Start at LoginをONにできる
- [ ] 再ログイン後にI’m Thinkingが起動する
- [ ] OFFにすると登録解除される
- [ ] shell rc / LaunchAgent plistをI’m Thinkingが生成しない
- [ ] Debug版の操作がRelease版の登録を意図せず変更しない

## H. Privacy / fail-open

実行前後で差分を確認:

```bash
shasum ~/.claude/settings.json 2>/dev/null || true
shasum ~/.codex/config.toml 2>/dev/null || true
```

- [ ] Claude settingsが変更されない
- [ ] Codex configが変更されない
- [ ] `.claude/` / `.codex/` project設定を追加しない
- [ ] `.zshrc` / `.bashrc` を変更しない
- [ ] prompt / response / reasoning / source codeをI’m Thinkingが保存しない
- [ ] I’m Thinkingをforce quitしてもClaude/Codexが継続動作する

## I. Release bundle

- [ ] `.build/release/I'm Thinking.app` が生成される
- [ ] `LSMinimumSystemVersion = 26.0`
- [ ] bundle id = `com.den0206.ImThinking`
- [ ] Rust Coreが `Contents/MacOS/im-thinking-core` に同梱される
- [ ] `codesign --verify --strict` が成功する

## J. Notarized DMG

署名・公証済みRelease candidateで確認:

- [ ] `.app` にnotarization ticketがstapleされている
- [ ] DMGにDeveloper ID signatureがある
- [ ] DMGにnotarization ticketがstapleされている
- [ ] DMGをmountできる
- [ ] `Applications` shortcutが存在する
- [ ] `/Applications`へコピー後、通常起動できる
- [ ] Gatekeeper warningなしで起動できる
- [ ] オフライン状態でもstapled appを起動できる

## K. Release workflow

- [ ] `vX.Y.Z`以外のtagはversion validationで停止する
- [ ] 必須Secrets不足時にReleaseを公開しない
- [ ] test failure時にReleaseを公開しない
- [ ] same repositoryのGitHub ReleasesへDMGが添付される
- [ ] Release titleが `I'm Thinking X.Y.Z`
- [ ] 過去Releaseを上書きしない

## L. Resource inspection

長時間smoke test中にActivity Monitor / Instrumentsで確認:

- [ ] idle CPUが継続的に高くない
- [ ] session終了後にfile descriptorが増え続けない
- [ ] memory footprintが時間に比例して増え続けない
- [ ] audio node / taskが停止後に増殖しない

数値上限の正本: [RESOURCE_LIMITS.md](../RESOURCE_LIMITS.md)


## M. Mac App Store sandbox

Build the smoke bundle:

```bash
CONFIG=appstore-smoke ./scripts/build-app.sh
```

- [ ] App bundle contains `PrivacyInfo.xcprivacy`
- [ ] main app has `com.apple.security.app-sandbox`
- [ ] main app has `com.apple.security.files.user-selected.read-only`
- [ ] Rust helper has `com.apple.security.app-sandbox`
- [ ] Rust helper has `com.apple.security.inherit`
- [ ] Rust helper does not have broad user-selected file entitlement
- [ ] Claude folder shows unauthorized on first App Store-mode launch
- [ ] selecting `~/.claude/projects` enables monitoring
- [ ] Codex folder shows unauthorized on first App Store-mode launch
- [ ] selecting `~/.codex/sessions` enables monitoring
- [ ] authorization survives app relaunch via bookmark
- [ ] stale bookmark recovery is tested
- [ ] Revoke stops future monitoring and removes stored authorization
- [ ] helper cannot read an unselected neighboring folder
- [ ] no Full Disk Access prompt is shown
- [ ] no Accessibility / Input Monitoring / Screen Recording prompt is shown
- [ ] force-quitting the app terminates the helper without affecting Claude/Codex

Full submission checklist: [APP_STORE.md](../APP_STORE.md)
