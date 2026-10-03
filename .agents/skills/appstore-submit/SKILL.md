---
name: appstore-submit
description: aI'm Thinking の指定バージョンを、掲載内容を確認したうえで App Store の審査へ提出する。リリースブランチの push と GitHub Release の公開を伴う。
---

# App Store への審査提出

引数はバージョン `X.Y.Z`。なければ聞く。審査への提出と DMG の公開は外部に出る操作なので、手順 5 の承認なしに手順 6 へ進まない。

1. **前提を確かめる。** リポジトリルートで `git status --short`、`git fetch origin`、`git status -sb` を確認する。作業ツリーが汚れている、または `main` と `origin/main` がずれていれば止めて報告する（リリースは `origin/main` から切る）。`X.Y.Z` が既存の最新Releaseより古ければ止める（`git ls-remote --tags origin`）。同じ `X.Y.Z` のReleaseがあれば、`vX.Y.Z+N` での出し直しになることを伝える。

2. **APIで提出要件を確かめる。** `scripts/appstore-preflight.sh X.Y.Z` を実行する。認証情報は `.secret` と `~/Downloads`・`~/.appstoreconnect/private_keys` の `.p8` から自動で読む。値を表示しない。FAIL は手順 5 の報告に含め、解消するまで提出しない。App Store Connect で直す項目（価格・配信地域・連絡先など）は利用者に依頼し、掲載文の修正は手順 3 の結果と合わせて提案する。

3. **掲載内容を実装と照合する。** `scripts/appstore-preflight.sh --dump X.Y.Z` の出力を読み、次と食い違いがないか確かめる。
   - 機能・数値: `app/Sources/AImThinking/SoundPack.swift` のパック数、`app/Package.swift` の最低OS、README の Features と Requirements、対応エージェント
   - 「新機能」とGitHub Releaseのノートになる CHANGELOG `[Unreleased]`（同じバージョンの出し直しでは切り出し済みの `[X.Y.Z]` 節）: 英語で、今回の変更を過不足なく説明しているか（`git log v<前回>..origin/main` と照合）。初回バージョンは「新機能」を使わない
   - 審査ガイドライン: キーワードに他社の製品名・商標がない（2.3.7）、説明文に他社との提携を思わせる表現がない、価格・他プラットフォーム・「beta」・仮の文言・個人情報がない、App Review notes の手順が現在のUI（ボタン名・フォルダ名）と一致する
   掲載文の修正が必要なら、修正案を手順 5 で示す。承認を得てから App Store Connect API（`scripts/asc-lib.sh` の `asc`）で更新する。

4. **画面で確かめる（使える場合）。** Claude Code では `claude-in-chrome` スキル、Codex ではブラウザ操作ツールで https://appstoreconnect.apple.com/apps/6818721943 を開き、次を確認する。サインインやパスワード入力は代行せず、未ログインなら利用者に頼む。
   - App Privacy が公開済みで、内容が「Data Not Collected」
   - 配信予定のmacOSバージョンのページに、警告や未入力の項目がない
   - 価格が Free、配信地域が意図どおり
   ブラウザ操作が使えなければ、これらを利用者が確認する項目として手順 5 に載せる。

5. **報告して承認を得る。** チェック結果（FAIL / WARN / 内容の指摘 / 画面確認の結果または未確認項目）を一覧で示し、次を明記して提出してよいか聞く。
   - `vX.Y.Z`（または `+N`）のGitHub ReleaseでDMGが一般公開される
   - App Storeへ新しいビルドがアップロードされ、審査へ提出される。審査待ち・審査中の同じバージョンがあれば取り消して差し替える
   FAIL が残っている場合は提出しない。

6. **リリースする。** 承認後、`git push origin origin/main:refs/heads/release/Ver_X.Y.Z` でリリースブランチを作る。既にある場合は、`origin/main` がその先にある（fast-forward できる）ときだけ同じコマンドで更新し、そうでなければ止めて聞く。

7. **workflowを見届ける。** `gh run list --workflow release.yml --branch release/Ver_X.Y.Z --limit 1` で実行を特定し、`gh run watch <id> --exit-status` で待つ。失敗したら `gh run view <id> --log-failed` から原因の手順と行を示し、修正案を出して止める（同じコミットの Re-run は既存Releaseを使い、App Storeの提出だけやり直す）。

8. **結果を報告する。** GitHub Release のURL、アップロードしたビルド番号、`scripts/appstore-release.sh --check X.Y.Z` で得たApp Storeの状態（`WAITING_FOR_REVIEW` を期待）、main へ反映されたCHANGELOGのコミットを示す。

`.secret` と `.p8` は読み取るだけで、削除・移動・表示しない。証明書・プロファイル・API keyを会話やログに出さない。`--force` の push、タグの削除、審査の取り消しを単独で行わない（手順 6 のworkflowが行うものを除く）。
