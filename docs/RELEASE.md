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

`vX.Y.Z` 形式のtag pushで `.github/workflows/release.yml` が起動します。

```bash
git tag v0.1.0
git push origin v0.1.0
```

tag名が厳密な `v<major>.<minor>.<patch>` でない場合はworkflowを停止します。

GitHub Releaseはtagが属する**このリポジトリ**に作成されます。別repository用PATは不要です。

## 3. Release pipeline

1. Swift 6.4 toolchain確認
2. Rust tests / Clippy
3. Swift tests
4. Developer ID certificateを一時Keychainへimport
5. release `.app` build
6. Rust helperを署名
7. `.app` bundleをDeveloper ID + Hardened Runtime + timestampで署名
8. `.app` をzip化してApple Notaryへ提出
9. 元の `.app` へnotarization ticketをstaple
10. `.app` + `/Applications` link入りDMG生成
11. DMG自体をDeveloper ID署名
12. DMGをnotarize + staple
13. codesign / stapler / Gatekeeper確認
14. GitHub Release作成 + DMG添付

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

- Git tag: `vX.Y.Z`
- `CFBundleShortVersionString`: `X.Y.Z`
- `CFBundleVersion`: GitHub Actions `run_number`

Release済みtagは上書きしません。修正は新しいpatch versionで公開します。

## 10. Repository visibility

GitHub Releasesの公開範囲はrepository visibilityに従います。

- Public repository: Releaseも一般ユーザーが取得可能
- Private repository: Releaseもrepositoryアクセス権を持つユーザーのみ取得可能

ソースをprivateのまま一般公開ダウンロードだけ提供する必要が出た場合は、別配布経路を改めて設計します。現時点では専用Release repositoryは作りません。

## 11. Deliberately not included

Rebornを参考にしつつ、aI'm Thinkingでは次を入れていません。

- self-update
- release専用repository
- `+N` 独自再リリース採番
- release branchからのCHANGELOG自動書換え
- App Store配布

構成を小さく保ち、タグ -> signed/notarized DMG -> same-repo GitHub Releaseに限定します。
