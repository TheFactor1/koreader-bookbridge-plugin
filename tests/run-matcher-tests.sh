#!/bin/bash
# Standalone regression test for the pure-logic half of doSyncLibrary's
# matcher: word normalization, the subset matcher, and the search-query
# derivation (the "Spider-Man" hyphen / underscore-for-colon truncation).
#
# Pulls the relevant blocks straight out of main.lua by anchor text (not
# line numbers) so it keeps testing the real code as it moves, wraps the
# inline query-derivation block into a callable function, and runs the cases
# in matcher_cases.lua under LuaJIT (same runtime as KOReader) via docker --
# nothing on the host needs Lua installed.
#
#   bash tests/run-matcher-tests.sh          # exit 0 = all cases pass
set -euo pipefail
cd "$(dirname "$0")/.."
MAIN=bookbridge.koplugin/main.lua
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

ln() { grep -n "$1" "$MAIN" | head -1 | cut -d: -f1; }
H_START=$(ln '^local SYNC_STOPWORDS = ')
H_END=$(awk -v s="$(ln '^local function titleWordsSubsetOf')" 'NR>s && /^end$/ {print NR; exit}' "$MAIN")
Q_START=$(ln 'local cleaned_fname = stripTrailingParenGroups(fname)')
Q_END=$(ln 'local query = search_title:match(')
[ -n "$H_START$H_END$Q_START$Q_END" ] || { echo "anchor not found in $MAIN"; exit 2; }

{
  echo 'local _ = function(s) return s end'
  sed -n "${H_START},${H_END}p" "$MAIN"
  echo 'local function deriveQuery(fname, catalog)'
  sed -n "${Q_START},${Q_END}p" "$MAIN"
  echo 'return query, search_title, series_side end'
  cat tests/matcher_cases.lua
} > "$OUT/test.lua"

docker run --rm -v "$OUT":/t:ro openresty/openresty:alpine \
  /usr/local/openresty/luajit/bin/luajit /t/test.lua
