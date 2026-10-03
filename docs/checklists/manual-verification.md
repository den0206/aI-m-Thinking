# Manual Verification Checklist

自動テストでは保証できない macOS / Claude Code / Codex / audio / distribution の実機確認項目です。

## A. Debug bundle

- [ ] `CONFIG=debug ./scripts/build-app.sh` が成功する
- [ ] `.build/debug/aI'm Thinking Debug.app` が生成される
- [ ] bundle id が `com.den0206.AImThinking.debug`
- [ ] VS Code / Cursorで `Run aI'm Thinking Debug.app` をF5起動できる
- [ ] MenuBarExtraだけが表示され、通常のDock appとして常駐しない
- [ ] Debug版とRelease版を同時に識別できる

## B. Claude Code

- [ ] aI'm Thinking起動後、通常の `claude` だけで監視される
- [ ] wrapper / alias / hook追加が不要
- [ ] turn開始でTHINKINGへ遷移する
- [ ] text生成でWRITINGへ遷移する
- [ ] tool実行でTOOLへ遷移する
- [ ] turn終了後IDLEへ戻る
- [ ] read/search/shell待機中に高頻度音が鳴り続けない
- [ ] edit/write系toolで短いtyping burstが鳴る

## C. Codex

- [ ] aI'm Thinking起動後、通常の `codex` だけで監視される
- [ ] wrapper / alias / hook追加が不要
- [ ] reasoning/activity eventでTHINKINGへ遷移する
- [ ] outputでWRITINGへ遷移する
- [ ] function/tool callでTOOLへ遷移する
- [ ] turn完了後IDLEへ戻る
- [ ] usage snapshotだけで不自然なburstが発生しない

## D. Audio

- [ ] 6種類のsound packを切り替えられる
- [ ] sound packを選ぶとpreviewが鳴り、Mute中は鳴らない
- [ ] Randomではturnごとにsound packが変わる
- [ ] Speedを上げても再生が30 keys/sを超えない
- [ ] volume sliderが反映される
- [ ] Muteで即座に停止する
- [ ] intensityが低いと遅く、高いと速くなる
- [ ] THINKINGとWRITINGで過剰な連打にならない
- [ ] 長時間idleでAVAudioEngineが不要に動き続けない
- [ ] Agentが待機中の試聴は、最後の音が終わるとAVAudioEngineも停止する
- [ ] 試聴中にAgentの活動が始まっても、試聴の終了処理で活動音が止まらない

## E. Multiple sessions

- [ ] ClaudeとCodexを同時起動してもクラッシュしない
- [ ] 複数sessionのうち強いactivityがsound schedulerへ反映される
- [ ] session終了時にstateが解放される
- [ ] agent tileの停止ボタンでそのagentの動作中sessionの音が止まり、tileがPausedになる
- [ ] 一時停止中に進んだ分は、再開しても再生されない（再開後の新しいactivityだけで鳴る）
- [ ] 一時停止中も他agent・一時停止後に始まったsessionは鳴り続け、停止ボタンで止められる
- [ ] 同じagentに一時停止中・動作中のsessionが混在するとき、再開・停止ボタンが両方表示され、動作中のsessionを止めずに再開できる
- [ ] 長時間利用してmemoryが継続増加しない

## F. Sleep / wake

- [ ] Macをsleepする
- [ ] wake後にobserver rescanが走る
- [ ] Agentを再起動せず監視が継続する
- [ ] wake後に重複監視や二重音が発生しない

## G. Start at Login

- [ ] Start at LoginをONにできる
- [ ] 再ログイン後にaI'm Thinkingが起動する
- [ ] OFFにすると登録解除される
- [ ] shell rc / LaunchAgent plistをaI'm Thinkingが生成しない
- [ ] Debug版の操作がRelease版の登録を意図せず変更しない
- [ ] 登録失敗・承認待ちの説明が表示され、Login Items設定を開ける

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
- [ ] prompt / response / reasoning / source codeをaI'm Thinkingが保存しない
- [ ] aI'm Thinkingをforce quitしてもClaude/Codexが継続動作する

## I. Release bundle

- [ ] `.build/release/aI'm Thinking.app` が生成される
- [ ] `LSMinimumSystemVersion = 26.0`
- [ ] bundle id = `com.den0206.AImThinking`
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
- [ ] Release titleが `aI'm Thinking X.Y.Z`
- [ ] 過去Releaseを上書きしない

## L. Resource inspection

長時間smoke test中にActivity Monitor / Instrumentsで確認:

- [ ] idle CPUが継続的に高くない
- [ ] Codexの長い生成待ち（3分以上）でも途中で音が消えず、完了・中断でキーが止まる
- [ ] 強度ゼロの古いsessionが残っていてもキーが動き続けない
- [ ] monitor停止・故障後に音とキーが止まる
- [ ] session終了後にfile descriptorが増え続けない
- [ ] memory footprintが時間に比例して増え続けない
- [ ] audio node / taskが停止後に増殖しない
- [ ] 監視フォルダの削除・アクセス失敗がAgent欄に表示され、復旧後に監視中へ戻る
- [ ] 直接配布版のAgent Foldersで保存先を変更でき、再起動後も保持され、Resetで既定値へ戻る
- [ ] Coreの異常終了から自動復旧し、連続失敗では3回の再試行後に停止する
- [ ] 4,096エントリを超える履歴でも探索が進み、直近のファイルへの通知なしの追記が検知され、古い履歴が繰り返し開き直されない

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
- [ ] first App Store-mode launch opens the welcome window; Done and the close button stay disabled until a folder is allowed
- [ ] choosing `~/.codex/sessions` or `~/.claude` for Claude Code shows a red error and saves nothing
- [ ] the welcome window does not reappear after Done
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
