#!/bin/bash
#
# appstore-preflight.sh — App Store の審査へ出す前に、提出に必要なものが揃っているかを確かめる
#
#   scripts/appstore-preflight.sh <version>          # チェック結果を PASS / WARN / FAIL で表示する
#   scripts/appstore-preflight.sh --dump <version>   # 内容確認用に掲載文と CHANGELOG を表示する
#
# 何も変更しない。FAIL が1つでもあれば終了コード 1。
# App Privacy（データの収集）は API で読めないので対象外。画面で確認する。
#
# 認証情報は環境変数 ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_P8 を使う。
# なければ .secret（KEY=値）から ID を読み、.p8 は ~/.appstoreconnect/private_keys と ~/Downloads から探す。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DUMP=false
if [[ "${1:-}" == --dump ]]; then DUMP=true; shift; fi
VERSION="${1:?usage: appstore-preflight.sh [--dump] <X.Y.Z>}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be X.Y.Z (received: $VERSION)" >&2; exit 2; }

secret() { [[ -f "$ROOT/.secret" ]] && grep -m1 "^$1=" "$ROOT/.secret" | cut -d= -f2- || true; }
export ASC_KEY_ID="${ASC_KEY_ID:-$(secret ASC_KEY_ID)}"
export ASC_ISSUER_ID="${ASC_ISSUER_ID:-$(secret ASC_ISSUER_ID)}"
if [[ -z "${ASC_KEY_P8:-}" ]]; then
  ASC_KEY_P8="$(find "$HOME/.appstoreconnect/private_keys" "$HOME/Downloads" -maxdepth 3 \
    -name "AuthKey_$ASC_KEY_ID.p8" 2>/dev/null | head -1 || true)"
fi
export ASC_KEY_P8
[[ -n "$ASC_KEY_ID" && -n "$ASC_ISSUER_ID" && -f "$ASC_KEY_P8" ]] \
  || { echo "App Store Connect API key not found. Set ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8." >&2; exit 2; }
source "$ROOT/scripts/asc-lib.sh"

# 対象バージョンがまだなければ、CI が作るときに掲載情報を引き継ぐ最新のバージョンを見る。
VERSIONS="$(asc GET "/apps/$APP_ID/appStoreVersions?filter%5Bplatform%5D=MAC_OS&limit=200")"
VERSION_ID="$(jq -r --arg v "$VERSION" '[.data[] | select(.attributes.versionString == $v) | .id][0] // empty' <<<"$VERSIONS")"
# この一覧は sort を受け付けないので、作成日時で最新を選ぶ。
SOURCE_ID="${VERSION_ID:-$(jq -r '.data | max_by(.attributes.createdDate) | .id // empty' <<<"$VERSIONS")}"
SOURCE_NAME="$(jq -r --arg id "$SOURCE_ID" '.data[] | select(.id == $id) | .attributes.versionString' <<<"$VERSIONS")"
APP_INFO="$(asc GET "/apps/$APP_ID/appInfos?include=primaryCategory,appInfoLocalizations,ageRatingDeclaration")"
LOCALIZATIONS="$(asc GET "/appStoreVersions/$SOURCE_ID/appStoreVersionLocalizations")"

unreleased() {
  awk '/^## \[Unreleased\]/ { on = 1; next } on && /^## / { exit } on' "$ROOT/CHANGELOG.md"
}

if $DUMP; then
  echo "### App Store metadata (version $SOURCE_NAME)"
  jq -r '.included[]? | select(.type == "appInfoLocalizations") | .attributes
    | "[\(.locale)] name: \(.name)\nsubtitle: \(.subtitle)\nprivacy policy: \(.privacyPolicyUrl)"' <<<"$APP_INFO"
  jq -r '.data[].attributes | "\n[\(.locale)]\nkeywords: \(.keywords)\nsupport: \(.supportUrl)\nmarketing: \(.marketingUrl)\npromotional text: \(.promotionalText)\n\ndescription:\n\(.description)"' <<<"$LOCALIZATIONS"
  echo; echo "### App Review notes"
  asc_get "/appStoreVersions/$SOURCE_ID/appStoreReviewDetail" | jq -r '.data.attributes.notes // "(none)"'
  if "$ROOT/scripts/release-changelog.sh" --section "$VERSION" >/dev/null 2>&1; then
    echo; echo "### CHANGELOG [$VERSION] (re-release: becomes What's New and the GitHub Release notes)"
    "$ROOT/scripts/release-changelog.sh" --section "$VERSION"
  else
    echo; echo "### CHANGELOG [Unreleased] (becomes What's New and the GitHub Release notes)"
    unreleased
  fi
  exit 0
fi

FAILS=0
pass() { printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
check() { if [[ "$1" == true ]]; then pass "$2"; else fail "$2${3:+: $3}"; fi; }

echo "Checking App Store submission of $VERSION (metadata from version $SOURCE_NAME)"

# Version state and other versions in review.
if out="$("$ROOT/scripts/appstore-release.sh" --check "$VERSION" 2>&1)"; then
  pass "version state: ${out#App Store version }"
else
  fail "version state: $(sed 's/^::error:://' <<<"$out")"
fi

# App information.
CATEGORY="$(jq -r '.data[0].relationships.primaryCategory.data.id // empty' <<<"$APP_INFO")"
check "$([[ -n "$CATEGORY" ]] && echo true)" "primary category ${CATEGORY:-not set}"
while IFS=$'\t' read -r locale name subtitle privacy; do
  check "$([[ -n "$name" && "$name" != null ]] && echo true)" "[$locale] name"
  if [[ "$subtitle" == null ]]; then warn "[$locale] subtitle not set (optional)"
  else check "$([[ ${#subtitle} -le 30 ]] && echo true)" "[$locale] subtitle (${#subtitle}/30)" "too long"; fi
  check "$([[ "$privacy" == https://* ]] && echo true)" "[$locale] privacy policy URL"
done < <(jq -r '.included[]? | select(.type == "appInfoLocalizations") | .attributes
  | [.locale, (.name // "null"), (.subtitle // "null"), (.privacyPolicyUrl // "null")] | @tsv' <<<"$APP_INFO")
AGE="$(jq -r '.included[]? | select(.type == "ageRatingDeclarations") | .attributes.violenceRealistic // empty' <<<"$APP_INFO")"
check "$([[ -n "$AGE" ]] && echo true)" "age rating questionnaire answered"
RIGHTS="$(asc GET "/apps/$APP_ID?fields%5Bapps%5D=contentRightsDeclaration" | jq -r '.data.attributes.contentRightsDeclaration // empty')"
check "$([[ -n "$RIGHTS" ]] && echo true)" "content rights ${RIGHTS:-not declared}"

# Pricing and availability.
PRICES="$(asc_get "/apps/$APP_ID/appPriceSchedule?include=manualPrices" | jq -r '[.included[]? | select(.type == "appPrices")] | length')"
check "$([[ "$PRICES" -gt 0 ]] && echo true)" "price set" "set a price (Free) in Pricing and Availability"
TERRITORIES="$(asc_get "/apps/$APP_ID/appAvailabilityV2" | jq -r '.data.id // empty')"
check "$([[ -n "$TERRITORIES" ]] && echo true)" "availability (territories) set" "choose territories in Pricing and Availability"

# Version metadata per locale.
URLS=()
while IFS=$'\t' read -r id locale desc keywords support marketing; do
  check "$([[ "$desc" != null && ${#desc} -le 4000 ]] && echo true)" "[$locale] description (${#desc}/4000)" "missing or too long"
  KW_BYTES="$(printf '%s' "$keywords" | wc -c | tr -d ' ')"
  check "$([[ "$keywords" != null && $KW_BYTES -le 100 ]] && echo true)" "[$locale] keywords ($KW_BYTES/100 bytes)" "missing or too long"
  check "$([[ "$support" == https://* ]] && echo true)" "[$locale] support URL"
  URLS+=("$support")
  [[ "$marketing" == https://* ]] && URLS+=("$marketing")
  SETS="$(asc GET "/appStoreVersionLocalizations/$id/appScreenshotSets?include=appScreenshots")"
  SHOTS="$(jq '[.included[]? | select(.type == "appScreenshots" and .attributes.assetDeliveryState.state == "COMPLETE")] | length' <<<"$SETS")"
  check "$([[ "$SHOTS" -gt 0 ]] && echo true)" "[$locale] Mac screenshots ($SHOTS processed)" "upload at least one 16:10 screenshot"
done < <(jq -r '.data[] | [.id, .attributes.locale, (.attributes.description // "null"), (.attributes.keywords // "null"),
  (.attributes.supportUrl // "null"), (.attributes.marketingUrl // "null")] | @tsv' <<<"$LOCALIZATIONS")
URLS+=("$(jq -r '[.included[]? | select(.type == "appInfoLocalizations") | .attributes.privacyPolicyUrl // empty][0] // empty' <<<"$APP_INFO")")

COPYRIGHT="$(asc GET "/appStoreVersions/$SOURCE_ID" | jq -r '.data.attributes.copyright // empty')"
check "$([[ -n "$COPYRIGHT" ]] && echo true)" "copyright ${COPYRIGHT:-not set}"

# App Review information.
REVIEW="$(asc_get "/appStoreVersions/$SOURCE_ID/appStoreReviewDetail" | jq '.data.attributes // {}')"
for field in contactFirstName contactLastName contactPhone contactEmail notes; do
  check "$(jq -r --arg f "$field" '(.[$f] // "") != ""' <<<"$REVIEW")" "App Review $field"
done

# Public pages must open without signing in.
for url in "${URLS[@]}"; do
  [[ -n "$url" ]] || continue
  code="$(curl -s -o /dev/null -L --max-time 15 -w '%{http_code}' "$url" || true)"
  check "$([[ "$code" == 200 ]] && echo true)" "$url opens" "HTTP $code"
done

# Release notes.
if "$ROOT/scripts/release-changelog.sh" --check >/dev/null 2>&1; then pass "CHANGELOG format"; else fail "CHANGELOG format: run scripts/release-changelog.sh --check"; fi
# 同じバージョンの出し直しでは [Unreleased] が空で、切り出し済みの節がそのまま使われる。
if "$ROOT/scripts/release-changelog.sh" --section "$VERSION" >/dev/null 2>&1; then
  pass "CHANGELOG [$VERSION] already cut (re-release; it becomes What's New and the release notes)"
else
  check "$(unreleased | grep -q '[^[:space:]]' && echo true)" "CHANGELOG [Unreleased] has entries" "nothing to release"
fi

# Release workflow inputs.
REQUIRED="MACOS_CERT_P12 MACOS_CERT_PASSWORD MACOS_SIGN_IDENTITY KEYCHAIN_PASSWORD NOTARY_APPLE_ID NOTARY_TEAM_ID NOTARY_PASSWORD MAS_CERT_P12 MAS_CERT_PASSWORD MAS_PROVISIONING_PROFILE ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8"
if SECRETS="$(gh secret list --json name -q '.[].name' 2>/dev/null)"; then
  MISSING="$(for s in $REQUIRED; do grep -qx "$s" <<<"$SECRETS" || printf '%s ' "$s"; done)"
  check "$([[ -z "$MISSING" ]] && echo true)" "GitHub Secrets for the release workflow" "missing $MISSING"
else
  warn "could not list GitHub Secrets (gh not signed in?)"
fi

echo
if [[ $FAILS -gt 0 ]]; then echo "$FAILS check(s) failed."; exit 1; fi
echo "All API checks passed. App Privacy must still be checked in App Store Connect."
