#!/bin/bash
#
# appstore-release.sh — アップロード済みのビルドを App Store の審査へ提出する
#
#   scripts/appstore-release.sh <version> <build-number> <whats-new-file>
#   scripts/appstore-release.sh --check <version>
#
# App Store Connect API で次を行う。同じバージョンで何度呼んでも、最新のビルドで出し直す。
#   1. そのバージョンの macOS App Store バージョンを探す（なければ作る）
#   2. 審査待ち・審査中なら審査を取り消す
#   3. ビルドを紐付ける
#   4. 各言語の「新機能」を whats-new-file の内容にする（初回バージョンは入力できないので飛ばす）
#   5. 審査へ提出する
#
# --check は何も変えず、そのバージョンへビルドを出し直せない状態（承認済み・公開済みなど）や、
# 別バージョンが審査中・公開待ちなら失敗する。
# ビルドやアップロードの前に呼び、DMG だけが作り直される事態を防ぐ。
#
# 必要な環境変数: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8（.p8 ファイルのパス）
set -euo pipefail

CHECK_ONLY=false
if [[ "$1" == --check ]]; then CHECK_ONLY=true; shift; fi
VERSION="$1"
BUILD_NUMBER="${2:-}"
WHATS_NEW_FILE="${3:-}"
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

# 状態がこの中なら、そのバージョンへビルドを出し直せる。
REPLACEABLE='PREPARE_FOR_SUBMISSION|DEVELOPER_REJECTED|REJECTED|METADATA_REJECTED|INVALID_BINARY|WAITING_FOR_REVIEW|IN_REVIEW'
EDITABLE='PREPARE_FOR_SUBMISSION|DEVELOPER_REJECTED|REJECTED|METADATA_REJECTED|INVALID_BINARY'
version_state() { asc GET "/appStoreVersions/$1" | jq -r .data.attributes.appStoreState; }

VERSIONS="$(asc GET "/apps/$APP_ID/appStoreVersions?filter%5Bplatform%5D=MAC_OS&limit=200")"
VERSION_ID="$(jq -r --arg v "$VERSION" '.data[] | select(.attributes.versionString == $v) | .id' <<<"$VERSIONS")"

if [[ -n "$VERSION_ID" ]]; then
  STATE="$(version_state "$VERSION_ID")"
  if ! [[ "$STATE" =~ ^($REPLACEABLE)$ ]]; then
    echo "::error::App Store version $VERSION is $STATE and cannot take a new build. Release a new version (for example the next patch) instead." >&2
    exit 1
  fi
fi
# 審査中・公開待ちの別バージョンがある間は、新しいバージョンを作れない。
BUSY="$(jq -r --arg v "$VERSION" '[.data[] | select(.attributes.versionString != $v
  and (.attributes.appStoreState | IN("WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_DEVELOPER_RELEASE", "PENDING_APPLE_RELEASE", "PROCESSING_FOR_APP_STORE")))
  | "\(.attributes.versionString) (\(.attributes.appStoreState))"] | join(", ")' <<<"$VERSIONS")"
if [[ -n "$BUSY" ]]; then
  echo "::error::App Store version $BUSY is still in progress. Release or remove it before submitting $VERSION." >&2
  exit 1
fi
if $CHECK_ONLY; then
  echo "App Store version $VERSION: ${STATE:-not created yet}; a new build can be submitted"
  exit 0
fi

# altool --wait の直後は API にまだビルドが見えないことがある。
BUILD_ID=""
for _ in $(seq 30); do
  BUILD_ID="$(asc GET "/builds?filter%5Bapp%5D=$APP_ID&filter%5Bversion%5D=$BUILD_NUMBER&filter%5BpreReleaseVersion.version%5D=$VERSION&filter%5BprocessingState%5D=VALID" | jq -r '.data[0].id // empty')"
  [[ -n "$BUILD_ID" ]] && break
  sleep 20
done
[[ -n "$BUILD_ID" ]] || { echo "build $VERSION ($BUILD_NUMBER) is not VALID on App Store Connect" >&2; exit 1; }

# Only one editable version can exist (a new app starts with "1.0"), so renumber it instead of creating another.
EDITABLE_ID="$(jq -r --arg re "^($EDITABLE)$" '[.data[] | select(.attributes.appStoreState | test($re)) | .id][0] // empty' <<<"$VERSIONS")"
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

# 審査待ち・審査中のビルドは差し替えられないので、審査を取り消して編集できる状態に戻す。
if [[ "$(version_state "$VERSION_ID")" =~ ^(WAITING_FOR_REVIEW|IN_REVIEW)$ ]]; then
  for SUB in $(asc GET "/reviewSubmissions?filter%5Bapp%5D=$APP_ID&filter%5Bplatform%5D=MAC_OS&filter%5Bstate%5D=WAITING_FOR_REVIEW,IN_REVIEW" | jq -r '.data[].id'); do
    asc PATCH "/reviewSubmissions/$SUB" "$(jq -n --arg s "$SUB" \
      '{data: {type: "reviewSubmissions", id: $s, attributes: {canceled: true}}}')" >/dev/null
  done
  echo "canceled the review in progress"
  for _ in $(seq 60); do
    [[ "$(version_state "$VERSION_ID")" =~ ^($EDITABLE)$ ]] && break
    sleep 10
  done
  STATE="$(version_state "$VERSION_ID")"
  [[ "$STATE" =~ ^($EDITABLE)$ ]] || { echo "review cancellation did not finish (state: $STATE)" >&2; exit 1; }
fi

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

# 却下後は UNRESOLVED_ISSUES の提出を出し直す。なければ新しく作る。
SUBMISSION_ID="$(asc GET "/reviewSubmissions?filter%5Bapp%5D=$APP_ID&filter%5Bplatform%5D=MAC_OS&filter%5Bstate%5D=READY_FOR_REVIEW,UNRESOLVED_ISSUES" | jq -r '.data[0].id // empty')"
if [[ -z "$SUBMISSION_ID" ]]; then
  SUBMISSION_ID="$(asc POST /reviewSubmissions "$(jq -n --arg app "$APP_ID" '{data: {type: "reviewSubmissions",
    attributes: {platform: "MAC_OS"}, relationships: {app: {data: {type: "apps", id: $app}}}}}')" | jq -r .data.id)"
fi
asc POST /reviewSubmissionItems "$(jq -n --arg s "$SUBMISSION_ID" --arg v "$VERSION_ID" '{data: {type: "reviewSubmissionItems",
  relationships: {reviewSubmission: {data: {type: "reviewSubmissions", id: $s}},
                  appStoreVersion: {data: {type: "appStoreVersions", id: $v}}}}}')" >/dev/null \
  || echo "version is already an item of this submission"  # 再提出では追加済みのことがある。本当の失敗は次の提出で出る。
asc PATCH "/reviewSubmissions/$SUBMISSION_ID" "$(jq -n --arg s "$SUBMISSION_ID" \
  '{data: {type: "reviewSubmissions", id: $s, attributes: {submitted: true}}}')" >/dev/null
echo "submitted $VERSION ($BUILD_NUMBER) for review"
