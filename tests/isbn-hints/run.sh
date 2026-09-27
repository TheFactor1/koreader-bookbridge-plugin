#!/bin/bash
# The Anna's Archive ISBN-hints file drops entries for deleted books when a new
# hint is added (it only ever grew before, found 2026-09-23) -- but never an
# entry whose FOLDER is missing (unmounted storage), which may still be needed.
# Runs the REAL load/save/addDownloadIsbnHint from main.lua on temp files.
# Also: a {"isbn13": null} answer from annas-archive-api is no ISBN, and a null
# already saved in the file (earlier builds) is dropped on load -- JSON null
# decodes to KOReader's truthy null sentinel, which crashed the download
# follow-up (found on the Scribe 2026-09-27). Offline; KOReader's luajit.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
M=${1:-$REPO/bookbridge.koplugin/main.lua}
KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
[ -x "${KDIR:-/nonexistent}/luajit" ] || { echo "SKIP  no local KOReader (set KOREADER_DIR)"; exit 3; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
{ echo "local DOWNLOAD_ISBN_HINTS_PATH = os.getenv('HINTS')"
  cat <<'STUBS'
socketurl = { escape = function(x) return x end }
socketutil = { set_timeout = function() end, reset_timeout = function() end,
  table_sink = function() local t = {}; return function(c) if c then t[#t + 1] = c end return 1 end, t end }
http = { request = function(req) req.sink(ANNAS_BODY); return 1, 200 end }
socket = { skip = function(n, ...) return select(n + 1, ...) end }
debugLog = function() end
STUBS
  for f in loadDownloadIsbnHints saveDownloadIsbnHints addDownloadIsbnHint doAnnasFetchIsbn; do
    awk -v a="local function $f(" 'index($0, a) == 1 {f=1} f{print} f&&/^end$/{exit}' "$M"; done
  echo "HINT_ADD = addDownloadIsbnHint; HINT_LOAD = loadDownloadIsbnHints; FETCH_ISBN = doAnnasFetchIsbn"; } > "$W/fns.lua"
mkdir -p "$W/books"; touch "$W/books/kept.epub" "$W/books/new.epub"
printf '{"%s":"9780000000001","%s":"9780000000002","%s":"9780000000003","%s":null}' \
  "$W/books/kept.epub" "$W/books/deleted.epub" "$W/unmounted/elsewhere.epub" "$W/books/kept2.epub" > "$W/hints.json"
touch "$W/books/kept2.epub"
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
local h0 = HINT_LOAD()
ck(h0[B .. "/kept2.epub"] == nil, "a saved JSON null is dropped on load (not a truthy sentinel)")
local h = HINT_LOAD()
ck(h[B .. "/new.epub"] == "9780000000009", "the new hint is recorded")
ck(h[B .. "/kept.epub"] == "9780000000001", "a book still on the device keeps its hint")
ck(h[B .. "/deleted.epub"] == nil, "a deleted book's hint is dropped (the file only grew before)")
ck(h[U .. "/elsewhere.epub"] == "9780000000003", "a book whose folder is missing (unmounted) is left alone")
ANNAS_BODY = '{"isbn13":null}'
local ok_n, r_n = pcall(FETCH_ISBN, "http://x", "k", "gd", "abc")
ck(ok_n and r_n == nil, "an {\"isbn13\": null} answer means no ISBN (it crashed before)")
ANNAS_BODY = '{"isbn13":"9781234567897"}'
local ok_s, r_s = pcall(FETCH_ISBN, "http://x", "k", "gd", "abc")
ck(ok_s and r_s == "9781234567897", "a real ISBN is still returned")
print(string.format("=== %d passed, %d failure(s)", pass, fail))
os.exit(fail == 0 and 0 or 1)
LUA
