#!/bin/bash
# The Anna's Archive ISBN-hints file drops entries for deleted books when a new
# hint is added (it only ever grew before, found 2026-09-23) -- but never an
# entry whose FOLDER is missing (unmounted storage), which may still be needed.
# Runs the REAL load/save/addDownloadIsbnHint from main.lua on temp files.
# Offline; KOReader's luajit.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
M=${1:-$REPO/bookbridge.koplugin/main.lua}
KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
[ -x "${KDIR:-/nonexistent}/luajit" ] || { echo "SKIP  no local KOReader (set KOREADER_DIR)"; exit 3; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
{ echo "local DOWNLOAD_ISBN_HINTS_PATH = os.getenv('HINTS')"
  for f in loadDownloadIsbnHints saveDownloadIsbnHints addDownloadIsbnHint; do
    awk -v a="local function $f(" 'index($0, a) == 1 {f=1} f{print} f&&/^end$/{exit}' "$M"; done
  echo "HINT_ADD = addDownloadIsbnHint; HINT_LOAD = loadDownloadIsbnHints"; } > "$W/fns.lua"
mkdir -p "$W/books"; touch "$W/books/kept.epub" "$W/books/new.epub"
printf '{"%s":"9780000000001","%s":"9780000000002","%s":"9780000000003"}' \
  "$W/books/kept.epub" "$W/books/deleted.epub" "$W/unmounted/elsewhere.epub" > "$W/hints.json"
cd "$KDIR" || exit 1
SRC="$W/fns.lua" HINTS="$W/hints.json" BOOKS="$W/books" UNM="$W/unmounted" ./luajit - <<'LUA'
package.path = "common/?.lua;frontend/?.lua;" .. package.path
package.cpath = "common/?.so;libs/?.so;" .. package.cpath
JSON = require("json")
lfs = require("libs/libkoreader-lfs")
assert(load(io.open(os.getenv("SRC")):read("*a")))()
local B, U = os.getenv("BOOKS"), os.getenv("UNM")
local pass, fail = 0, 0
local function ck(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end
HINT_ADD(B .. "/new.epub", "9780000000009")
local h = HINT_LOAD()
ck(h[B .. "/new.epub"] == "9780000000009", "the new hint is recorded")
ck(h[B .. "/kept.epub"] == "9780000000001", "a book still on the device keeps its hint")
ck(h[B .. "/deleted.epub"] == nil, "a deleted book's hint is dropped (the file only grew before)")
ck(h[U .. "/elsewhere.epub"] == "9780000000003", "a book whose folder is missing (unmounted) is left alone")
print(string.format("=== %d passed, %d failure(s)", pass, fail))
os.exit(fail == 0 and 0 or 1)
LUA
