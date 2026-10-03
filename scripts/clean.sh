#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Build outputs only (all gitignored); rebuilt by build-app.sh / swift build.
for dir in app/.build .build core/target dist; do
  if [ -e "$ROOT/$dir" ]; then
    du -sh "$ROOT/$dir"
    rm -rf "$ROOT/$dir"
  fi
done

# UserDefaults suites left behind by tests (empty plists cfprefsd keeps on disk).
shopt -s nullglob
for plist in "$HOME"/Library/Preferences/im-thinking-test-*.plist; do
  defaults delete "$(basename "$plist" .plist)" 2>/dev/null || true
  rm -f "$plist"
done

# Temp directories left behind by Swift / Rust tests.
rm -rf "${TMPDIR:-/tmp}"/im-thinking-*
