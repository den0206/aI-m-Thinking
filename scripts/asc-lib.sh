#!/bin/bash
#
# asc-lib.sh — App Store Connect API の共通処理。source して使う。
#
# 必要な環境変数: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8（.p8 ファイルのパス）
# 定義するもの: APP_ID, TOKEN, asc（失敗で終了する）, asc_get（失敗しても本文を返す）

APP_ID="${ASC_APP_ID:-6818721943}"
ASC_API="https://api.appstoreconnect.apple.com/v1"

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
[[ -n "$TOKEN" ]] || { echo "could not create an App Store Connect token from $ASC_KEY_P8" >&2; exit 1; }

asc() {
  local method="$1" path="$2" body="${3:-}"
  local args=(--fail-with-body --silent --show-error -X "$method" -H "Authorization: Bearer $TOKEN")
  [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" -d "$body")
  curl "${args[@]}" "$ASC_API$path"
}

# 404 などを「ない」として扱いたい読み取り用。
asc_get() {
  curl --silent --show-error -H "Authorization: Bearer $TOKEN" "$ASC_API$1"
}
