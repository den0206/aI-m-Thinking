#!/bin/bash
#
# asc-lib.sh — App Store Connect API の共通処理。source して使う。
#
# 必要な環境変数: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8（.p8 ファイルのパス）
# 定義するもの: APP_ID, TOKEN, asc（失敗で終了する）, asc_get（失敗しても本文を返す）

APP_ID="${ASC_APP_ID:-6818721943}"
ASC_API="https://api.appstoreconnect.apple.com/v1"

ASC_TOKEN_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/asc-token.py"
ASC_TOKEN_CREATED=0
refresh_token() {
  local now
  now="$(date +%s)"
  if (( now - ASC_TOKEN_CREATED >= 900 )); then
    TOKEN="$(python3 "$ASC_TOKEN_SCRIPT" "$ASC_KEY_ID" "$ASC_ISSUER_ID" "$ASC_KEY_P8")" || return 1
    [[ -n "$TOKEN" ]] || return 1
    ASC_TOKEN_CREATED="$now"
  fi
}
refresh_token || { echo "could not create an App Store Connect token" >&2; exit 1; }

asc() {
  refresh_token || return 1
  local method="$1" path="$2" body="${3:-}"
  local args=(--fail-with-body --silent --show-error -X "$method" -H "Authorization: Bearer $TOKEN")
  [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" -d "$body")
  curl "${args[@]}" "$ASC_API$path"
}

# 404 などを「ない」として扱いたい読み取り用。
asc_get() {
  refresh_token || return 1
  curl --silent --show-error -H "Authorization: Bearer $TOKEN" "$ASC_API$1"
}
