#!/bin/bash
# A book replaced by CWA's copy must get a fresh KOReader fingerprint.
#
# KOReader stamps partial_md5_checksum into the sidecar on first open and never
# recomputes it. When a CWA download replaced an already-opened book, the
# sidecar kept the old file's fingerprint, so Readest saw a different book from
# the one every other device downloaded. Uses KOReader's REAL DocSettings and
# util.partialMD5 against a throwaway book and sidecar. Offline.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
[ -x "${KDIR:-/nonexistent}/luajit" ] || { echo "SKIP  no local KOReader (set KOREADER_DIR)"; exit 3; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
awk '/^local function refreshBookFingerprint/{f=1} f{print} f&&/^end$/{exit}' "$REPO/bookbridge.koplugin/main.lua" > "$W/fn.lua"
echo 'return refreshBookFingerprint' >> "$W/fn.lua"
grep -q "partial_md5_checksum" "$W/fn.lua" || { echo "FAIL  could not extract refreshBookFingerprint"; exit 1; }
cd "$KDIR" || exit 1
W="$W" SRC="$W/fn.lua" ./luajit - <<'LUA'
package.path = "frontend/?.lua;common/?.lua;" .. package.path
package.cpath = "common/?.so;libs/?.so;" .. package.cpath
local W = os.getenv("W")
require("setupkoenv")
G_reader_settings = require("luasettings"):open(W .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open(W .. "/defaults.custom.lua")
local DocSettings = require("docsettings")
local util = require("util")
local MAP, PEND, logs = {}, {}, {}
loadHardcoverMap = function() return MAP end
saveHardcoverMap = function(t) MAP = t end
loadHardcoverPending = function() return PEND end
saveHardcoverPending = function(t) PEND = t end
debugLog = function(m) logs[#logs + 1] = m end
local refresh = assert(load(io.open(os.getenv("SRC")):read("*a")))()
local pass, fail = 0, 0
local function ck(c, m) if c then pass = pass + 1; print("PASS  " .. m) else fail = fail + 1; print("FAIL  " .. m) end end
local function write(path, seed)
    local f = assert(io.open(path, "wb"))
    for i = 1, 300 do f:write(string.rep(string.char((seed * 7 + i) % 256), 1024)) end
    f:close()
end
local book = W .. "/Probe Author - Probe.epub"
write(book, 1)
local old = util.partialMD5(book)
local ds = DocSettings:open(book); ds:saveSetting("partial_md5_checksum", old); ds:saveSetting("percent_finished", 0.42); ds:flush()
MAP[old] = { decision = "sync", book_id = 7, title = "Probe" }
PEND[old] = { title = "Probe", percent = 0.42 }
write(book, 2)                           -- CWA's copy replaces the file
local new = util.partialMD5(book)
ck(new ~= old, "the replacement really is a different file")
refresh(book)
local after = DocSettings:open(book)
ck(after:readSetting("partial_md5_checksum") == new, "sidecar now carries the new file's fingerprint")
ck(after:readSetting("percent_finished") == 0.42, "...and keeps the reading position and everything else")
ck(MAP[new] and MAP[new].book_id == 7 and MAP[old] == nil, "Hardcover match moved to the new fingerprint (no re-match)")
ck(PEND[new] and PEND[new].percent == 0.42 and PEND[old] == nil, "queued Hardcover progress moved with it")
-- the book open in the reader is left alone
write(book, 3); local third = util.partialMD5(book)
package.loaded["apps/reader/readerui"] = { instance = { document = { file = book } } }
refresh(book)
ck(DocSettings:open(book):readSetting("partial_md5_checksum") == new, "open book: left as is (the reader would write the old value back)")
package.loaded["apps/reader/readerui"] = nil
-- a never-opened book has no sidecar: nothing created
local fresh = W .. "/Never Opened.epub"; write(fresh, 4)
refresh(fresh)
ck(not DocSettings:hasSidecarFile(fresh), "never-opened book: no sidecar created")
-- same bytes again: nothing to do
refresh(book)
ck(DocSettings:open(book):readSetting("partial_md5_checksum") == third, "a later replace is picked up too")
print(pass .. " passed, " .. fail .. " failed")
os.exit(fail == 0 and 0 or 1)
LUA
