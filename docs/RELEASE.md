# Release Guide

aI'm Thinking は専用Releaseリポジトリを使わず、このソースリポジトリ自身の GitHub Releases から配布します。

## 1. Release artifact

公開物:

```text
aIm-Thinking-X.Y.Z.dmg
```

DMG内:

```text
aI'm Thinking.app
Applications -> /Applications
```

現在のRelease CIはApple Silicon runnerでビルドするため、配布対象もApple Siliconです。

## 2. Trigger

`release/Ver_X.Y.Z` ブランチのpushで `.github/workflows/release.yml` が起動します。

```bash
git switch -c release/Ver_0.1.0
git push origin release/Ver_0.1.0
```

ブランチ名が厳密な `release/Ver_<major>.<minor>.<patch>` でない場合と、既存の最新Releaseより古いバージョンの場合はworkflowを停止します。

GitHub Release（tag `vX.Y.Z`）は**このリポジトリ**に作成されます。別repository用PATは不要です。

App Storeへの提出を伴うので、通常はClaude Code / Codexの `appstore-submit` スキル（Claude Codeでは `/appstore-submit X.Y.Z`）から行います。`scripts/appstore-preflight.sh X.Y.Z` で提出要件を確かめ、掲載内容を実装と照合し、承認を得てからこのブランチをpushします。

リリースノートは `CHANGELOG.md` の `[Unreleased]` です。push前に英語で書いておきます（`scripts/release-changelog.sh --check` が日本語の混入と未知の節見出しを止めます）。

## 3. Release pipeline

1. Swift 6.4 toolchain確認
2. Rust tests / Clippy
3. Swift tests
4. `scripts/appstore-release.sh --check` でApp Storeがこのバージョンの新しいビルドを受け付けるか確認（承認済み・公開済み、または別バージョンが審査中・公開待ちなら停止）
5. Developer ID certificateを一時Keychainへimport
6. release `.app` build
7. Rust helperを署名
8. `.app` bundleをDeveloper ID + Hardened Runtime + timestampで署名
9. `.app` をzip化してApple Notaryへ提出
10. 元の `.app` へnotarization ticketをstaple
11. `.app` + `/Applications` link入りDMG生成
12. DMG自体をDeveloper ID署名
13. DMGをnotarize + staple
14. codesign / stapler / Gatekeeper確認
15. GitHub Release作成 + DMG添付（ノートはCHANGELOGの切り出した節。同じコミットのReleaseがあれば作らない）
16. Mac App Store用 `.pkg` をビルドし、API keyでApp Store Connectへアップロード
17. `scripts/appstore-release.sh` でApp Storeバージョンを作成・審査待ち/審査中なら取り消し・ビルドを紐付け・「新機能」を入力し、審査へ提出
18. 切り出したCHANGELOGを `main` へコミット

App Storeの初回バージョンは「新機能」を入力できないため飛ばします。スクリーンショットや審査情報などの掲載情報が未入力だと、審査への提出で失敗します。

`.app` を先にnotarize/stapleしてからDMGへ入れます。DMGだけをnotarizeする構成にはしません。

## 4. Required GitHub Secrets

| Secret | Purpose |
|---|---|
| `MACOS_CERT_P12` | Developer ID Application証明書 + private keyを含む `.p12` のbase64 |
| `MACOS_CERT_PASSWORD` | `.p12` password |
| `MACOS_SIGN_IDENTITY` | `Developer ID Application: Name (TEAMID)` |
| `KEYCHAIN_PASSWORD` | CI一時Keychain password |
| `NOTARY_APPLE_ID` | Apple ID |
| `NOTARY_TEAM_ID` | Apple Developer Team ID |
| `NOTARY_PASSWORD` | Apple app-specific password |
| `MAS_CERT_P12` | Apple Distribution と Mac Installer Distribution の証明書 + private keyをまとめた `.p12` のbase64 |
| `MAS_CERT_PASSWORD` | 上記 `.p12` password |
| `MAS_PROVISIONING_PROFILE` | Mac App Store Connect provisioning profileのbase64（2027-10-03 期限切れ） |
| `ASC_KEY_ID` | App Store Connect API key ID（App Manager権限） |
| `ASC_ISSUER_ID` | App Store Connect API issuer ID |
| `ASC_KEY_P8` | API key `.p8` ファイルの中身 |

Release workflowはこれらが欠けた状態では公開しません。未署名DMGを誤ってReleaseしないためです。

## 5. Developer ID setup

### Certificate

Apple Developer portalで `Developer ID Application` certificateを発行します。

Keychain Accessの「自分の証明書」からprivate key込みで `.p12` をexportします。

base64:

```bash
base64 -i DeveloperID.p12 | pbcopy
```

これを `MACOS_CERT_P12` に設定します。

### Intermediate certificate

`security find-identity -v -p codesigning` で `0 valid identities found` になる場合、Developer ID G2 intermediate certificateが不足していないか確認します。

確認:

```bash
security find-identity -v -p codesigning
```

Apple Certificate Authorityから `Developer ID Certification Authority (G2)` を取得してKeychainへimportします。

## 6. Notarization credentials

Apple Accountでapp-specific passwordを発行し、`NOTARY_PASSWORD` に設定します。

ローカル確認ではkeychain profileも使用できます。

```bash
xcrun notarytool store-credentials im-thinking-notary \
  --apple-id '<APPLE_ID>' \
  --team-id '<TEAM_ID>' \
  --password '<APP_SPECIFIC_PASSWORD>'
```

## 7. Local signed build

```bash
SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
MARKETING_VERSION=0.1.0 \
BUILD_NUMBER=1 \
./scripts/build-app.sh
```

生成物:

```text
.build/release/aI'm Thinking.app
```

DMG:

```bash
bash scripts/make-dmg.sh \
  ".build/release/aI'm Thinking.app" \
  aIm-Thinking-0.1.0.dmg \
  "aI'm Thinking 0.1.0"
```

DMG ウィンドウの背景は `app/Resources/DmgBackground.svg` から生成します。アイコン位置を記録する `.DS_Store` は Finder に書かせるため、初回実行時に Finder の自動操作の許可を求められます。

## 8. Verification

App signature:

```bash
codesign --verify --strict --verbose=2 ".build/release/aI'm Thinking.app"
codesign -dv --verbose=4 ".build/release/aI'm Thinking.app"
```

Notarization:

```bash
xcrun stapler validate ".build/release/aI'm Thinking.app"
xcrun stapler validate aIm-Thinking-0.1.0.dmg
```

Gatekeeper:

```bash
spctl -a -vv ".build/release/aI'm Thinking.app"
spctl -a -t open --context context:primary-signature -vv aIm-Thinking-0.1.0.dmg
```

## 9. Versioning

- Release branch: `release/Ver_X.Y.Z`
- Git tag: `vX.Y.Z`（同じバージョンの出し直しは `vX.Y.Z+N`）
- `CFBundleShortVersionString`: `X.Y.Z`
- `CFBundleVersion`: DMGはGitHub Actions `run_number`、App Storeは `(100 + run_number).run_attempt`（再実行でも番号が重複せず、CI導入前に手元からアップロードしたビルド2より大きくなる）

### 同じバージョンで出し直す

修正コミットを同じ `release/Ver_X.Y.Z` ブランチへpushすると、そのバージョンで出し直します。

- GitHub Releaseは既存の `vX.Y.Z` を残し、`vX.Y.Z+1`、`+2` … と採番して新しく作る（DMG名とアプリのバージョンは `X.Y.Z` のまま）
- 失敗したworkflowのRe-runなど、同じコミットのReleaseがすでにある場合は採番せずそのReleaseを使い、App Storeへの提出だけをやり直す
- ノートと「新機能」はreleaseブランチの `[Unreleased]` 全体（初回分を含む）。修正項目をそこへ追記した場合、`main` の `[X.Y.Z]` 節には自動反映されないので手で追記する
- `--check` の後、ビルド中に審査が承認されると提出で失敗する（GitHub Releaseは作成済み）。この場合も次のpatch versionで公開する
- App Storeは審査待ち・審査中なら審査を取り消し、新しいビルドに差し替えて再提出する
- App Storeのバージョンが承認済み・公開済みなど新しいビルドを受け付けない状態なら、ビルド前の `Check App Store version can take a new build` で停止する（GitHub Releaseも変更しない）。この場合は次のpatch versionで公開する

## 10. Repository visibility

GitHub Releasesの公開範囲はrepository visibilityに従います。

- Public repository: Releaseも一般ユーザーが取得可能
- Private repository: Releaseもrepositoryアクセス権を持つユーザーのみ取得可能

ソースをprivateのまま一般公開ダウンロードだけ提供する必要が出た場合は、別配布経路を改めて設計します。現時点では専用Release repositoryは作りません。

## 11. Deliberately not included

Rebornを参考にしつつ、aI'm Thinkingでは次を入れていません。

- self-update
- release専用repository

構成を小さく保ち、release branch -> signed/notarized DMG + App Store提出 -> same-repo GitHub Releaseに限定します。
