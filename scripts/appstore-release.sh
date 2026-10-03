#!/bin/bash
#
# appstore-release.sh — アップロード済みのビルドを App Store の審査へ提出する
#
#   scripts/appstore-release.sh <version> <build-number> <whats-new-file>
#
# App Store Connect API で次を行う。何度呼んでも安全（済んでいる手順は飛ばす）。
#   1. そのバージョンの macOS App Store バージョンを探す（なければ作る）
#   2. ビルドを紐付ける
#   3. 各言語の「新機能」を whats-new-file の内容にする（初回バージョンは入力できないので飛ばす）
#   4. 審査へ提出する
#
# 必要な環境変数: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8（.p8 ファイルのパス）
set -euo pipefail

VERSION="$1"
BUILD_NUMBER="$2"
WHATS_NEW_FILE="$3"
APP_ID="${ASC_APP_ID:-6818721943}"
API="https://api.appstoreconnect.apple.com/v1"

# ES256 の JWT。有効期限は API 上限の 20 分。
TOKEN="$(swift - "$ASC_KEY_ID" "$ASC_ISSUER_ID" "$ASC_KEY_P8" <<'SWIFT'
import CryptoKit
import Foundation

let args = CommandLine.arguments
let key = try P256.Signing.PrivateKey(pemRepresentation: String(contentsOfFile: args[3], encoding: .utf8))
func b64(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
let now = Int(Date().timeIntervalSince1970)
let header = b64(try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": args[1], "typ": "JWT"]))
let claims = b64(try JSONSerialization.data(withJSONObject: [
    "iss": args[2], "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1",
]))
let signature = try key.signature(for: Data("\(header).\(claims)".utf8))
print("\(header).\(claims).\(b64(signature.rawRepresentation))")
SWIFT
)"

asc() {
  local method="$1" path="$2" body="${3:-}"
  local args=(--fail-with-body --silent --show-error -X "$method" -H "Authorization: Bearer $TOKEN")
  [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" -d "$body")
  curl "${args[@]}" "$API$path"
}

# altool --wait の直後は API にまだビルドが見えないことがある。
BUILD_ID=""
for _ in $(seq 30); do
  BUILD_ID="$(asc GET "/builds?filter%5Bapp%5D=$APP_ID&filter%5Bversion%5D=$BUILD_NUMBER&filter%5BpreReleaseVersion.version%5D=$VERSION&filter%5BprocessingState%5D=VALID" | jq -r '.data[0].id // empty')"
  [[ -n "$BUILD_ID" ]] && break
  sleep 20
done
[[ -n "$BUILD_ID" ]] || { echo "build $VERSION ($BUILD_NUMBER) is not VALID on App Store Connect" >&2; exit 1; }

VERSIONS="$(asc GET "/apps/$APP_ID/appStoreVersions?filter%5Bplatform%5D=MAC_OS&limit=200")"
VERSION_ID="$(jq -r --arg v "$VERSION" '.data[] | select(.attributes.versionString == $v) | .id' <<<"$VERSIONS")"
# Only one editable version can exist (a new app starts with "1.0"), so renumber it instead of creating another.
EDITABLE_ID="$(jq -r '[.data[] | select(.attributes.appStoreState | IN("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED")) | .id][0] // empty' <<<"$VERSIONS")"
if [[ -z "$VERSION_ID" && -n "$EDITABLE_ID" ]]; then
  VERSION_ID="$EDITABLE_ID"
  asc PATCH "/appStoreVersions/$VERSION_ID" "$(jq -n --arg id "$VERSION_ID" --arg v "$VERSION" \
    '{data: {type: "appStoreVersions", id: $id, attributes: {versionString: $v}}}')" >/dev/null
elif [[ -z "$VERSION_ID" ]]; then
  VERSION_ID="$(asc POST /appStoreVersions "$(jq -n --arg v "$VERSION" --arg app "$APP_ID" '{data: {type: "appStoreVersions",
    attributes: {platform: "MAC_OS", versionString: $v},
    relationships: {app: {data: {type: "apps", id: $app}}}}}')" | jq -r .data.id)"
fi
echo "App Store version $VERSION: $VERSION_ID"

asc PATCH "/appStoreVersions/$VERSION_ID/relationships/build" \
  "$(jq -n --arg b "$BUILD_ID" '{data: {type: "builds", id: $b}}')" >/dev/null
echo "attached build $BUILD_NUMBER"

# 「新機能」は公開済みのバージョンがあるアプリでしか入力できない。
if jq -e --arg v "$VERSION" 'any(.data[]; .attributes.versionString != $v)' <<<"$VERSIONS" >/dev/null; then
  # App Store の表示はプレーンテキストなので、Markdown の強調とコード記号を外す。
  WHATS_NEW="$(sed -e 's/\*\*//g' -e 's/`//g' "$WHATS_NEW_FILE")"
  for LOC_ID in $(asc GET "/appStoreVersions/$VERSION_ID/appStoreVersionLocalizations" | jq -r '.data[].id'); do
    asc PATCH "/appStoreVersionLocalizations/$LOC_ID" "$(jq -n --arg id "$LOC_ID" --arg w "${WHATS_NEW:0:4000}" \
      '{data: {type: "appStoreVersionLocalizations", id: $id, attributes: {whatsNew: $w}}}')" >/dev/null
  done
  echo "updated What's New"
fi

STATE="$(asc GET "/appStoreVersions/$VERSION_ID" | jq -r .data.attributes.appStoreState)"
case "$STATE" in
  PREPARE_FOR_SUBMISSION|DEVELOPER_REJECTED|REJECTED|METADATA_REJECTED) ;;
  *) echo "version is already $STATE; not submitting again"; exit 0 ;;
esac

SUBMISSION_ID="$(asc GET "/reviewSubmissions?filter%5Bapp%5D=$APP_ID&filter%5Bplatform%5D=MAC_OS&filter%5Bstate%5D=READY_FOR_REVIEW" | jq -r '.data[0].id // empty')"
if [[ -z "$SUBMISSION_ID" ]]; then
  SUBMISSION_ID="$(asc POST /reviewSubmissions "$(jq -n --arg app "$APP_ID" '{data: {type: "reviewSubmissions",
    attributes: {platform: "MAC_OS"}, relationships: {app: {data: {type: "apps", id: $app}}}}}')" | jq -r .data.id)"
fi
asc POST /reviewSubmissionItems "$(jq -n --arg s "$SUBMISSION_ID" --arg v "$VERSION_ID" '{data: {type: "reviewSubmissionItems",
  relationships: {reviewSubmission: {data: {type: "reviewSubmissions", id: $s}},
                  appStoreVersion: {data: {type: "appStoreVersions", id: $v}}}}}')" >/dev/null || true
asc PATCH "/reviewSubmissions/$SUBMISSION_ID" "$(jq -n --arg s "$SUBMISSION_ID" \
  '{data: {type: "reviewSubmissions", id: $s, attributes: {submitted: true}}}')" >/dev/null
echo "submitted $VERSION ($BUILD_NUMBER) for review"
