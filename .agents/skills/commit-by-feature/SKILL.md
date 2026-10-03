---
name: commit-by-feature
description: I'm Thinking の未コミット変更をレビューし、機能ごとのコミットに分割する。コミット依頼時に使い、レビューのみでは実行しない。
---

# 機能ごとのコミット

1. リポジトリルートで `git status --short`、staged/unstagedのdiff、関連する未追跡ファイル、`git log --oneline -5` を確認する。対象指定があればその範囲に限り、無関係なユーザーの変更を含めない。変更がなければ終了する。
2. 機能の実装・テスト・関連仕様を同じグループにまとめる。scopeの例は core / app / build / ci / docs / agents。Rust/Swift双方のIPC変更など独立すると壊れる変更は一緒にする。分離できなければ無理に分割しない。
3. グループと日本語のコミット件名案を示す。Conventional Commitsを使う（例: `feat(core): 活動推定を改善`）。提案だけの依頼ならここで終了する。コマンド・スキルの作成依頼だけではコミットしない。
4. `.agents/skills/review-for-merge/SKILL.md` を全文読み、対象の未コミット変更をレビューし、関連チェックを実行する。問題や必須チェックの失敗・未実行があれば、そのグループはコミットせず理由を報告する。
5. グループのファイル・hunkだけをstageし、`git diff --cached` と `git diff --cached --check` で内容を確認してcommitする。各コミットが独立してビルド・テストできる単位にする。後続変更がないとチェックが通らないなら同じグループにまとめる。
6. commit hash・件名・分割理由・検証結果と、残った `git status --short` を報告する。

既存のstaged変更を勝手に含めない。対象外のindex内容を保持して分離できなければ停止して理由を伝える。秘密情報、実sessionデータ、生成されたapp・DMG・cacheを含めない。
`git add .`、`git add -A`、空commit、amend、reset、clean、変更破棄は行わない。hook失敗を `--no-verify` で回避しない。push・tag・公開は別途明示的に依頼された場合だけ行う。権限が必要なら環境の承認機構を使い、拒否を迂回しない。
