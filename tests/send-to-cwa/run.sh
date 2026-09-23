#!/bin/bash
# "Send to Calibre-Web" on a book already uploaded (and never matched back)
# asks before sending again, instead of refusing forever.
#
# Syncs deliberately never re-upload such a book: if CWA did import it under
# metadata that disagrees with the filename, re-sending makes a duplicate every
# run. But if CWA really dropped the upload the book was stuck -- this action
# refused too. Found 2026-09-23. Runs the REAL sendBookToCwa from main.lua.
# Offline; KOReader's luajit.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
M=${1:-$REPO/bookbridge.koplugin/main.lua}
KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
[ -x "${KDIR:-/nonexistent}/luajit" ] || { echo "SKIP  no local KOReader (set KOREADER_DIR)"; exit 3; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
awk '/^function Bookbridge:sendBookToCwa/{f=1} f{print} f&&/^end$/{exit}' "$M" > "$W/fns.lua"
grep -q "sendBookToCwa" "$W/fns.lua" || { echo "FAIL  extraction failed"; exit 1; }
cd "$KDIR" || exit 1
SRC="$W/fns.lua" ./luajit - <<'LUA'
_ = function(s) return s end
T = function(s, ...) local a = {...}; return (s:gsub("%%(%d+)", function(n) return tostring(a[tonumber(n)]) end)) end
debugLog = function() end
local PU, shown, SYNCS = {}, {}, 0
loadPendingUploads = function() local c = {}; for k, v in pairs(PU) do c[k] = v end; return c end
savePendingUploads = function(t) PU = t end
runSyncWithProgress = function() SYNCS = SYNCS + 1; return true, { "Done." }, {} end
logSyncReport = function() end
invalidateBookInfoCache = function() end
UIManager = { show = function(_s, w) shown[#shown + 1] = w end, setDirty = function() end }
package.loaded["ui/widget/confirmbox"] = { new = function(_s, t) t.kind = "confirm"; return t end }
package.loaded["ui/widget/textviewer"] = { new = function(_s, t) t.kind = "report"; return t end }
package.loaded["ui/trapper"] = { wrap = function(_s, f) return f() end }
Bookbridge = {}
assert(load(io.open(os.getenv("SRC")):read("*a")))()
local k = setmetatable({ cwa_url = "http://cwa", download_dir = "/books", defaultDownloadDir = function() return "/books" end }, { __index = Bookbridge })
local pass, fail = 0, 0
local function ck(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end
-- 1. a book never uploaded: sent straight away, as before
k:sendBookToCwa("/books/New Book.epub")
ck(SYNCS == 1 and shown[1] and shown[1].kind == "report", "a book never uploaded is sent straight away (no question)")
-- 2. already uploaded, not matched back: ask first, send nothing yet
PU = { ["/books/Stuck Book.epub"] = { title = "Stuck Book.epub", at = os.time() - 86400 * 9 } }; shown = {}; SYNCS = 0
k:sendBookToCwa("/books/Stuck Book.epub")
ck(SYNCS == 0 and shown[1] and shown[1].kind == "confirm", "an already-uploaded book asks before sending again")
ck(shown[1] and tostring(shown[1].text):find("duplicate", 1, true) ~= nil, "...and explains the duplicate risk")
-- 3. answering no (never calling ok_callback) changes nothing
ck(PU["/books/Stuck Book.epub"] ~= nil, "saying no keeps the mark (no silent duplicate)")
-- 4. answering yes: the mark is cleared and the book is sent, once
shown[1].ok_callback()
ck(PU["/books/Stuck Book.epub"] == nil and SYNCS == 1, "saying yes clears the mark and sends it once")
print(string.format("=== %d passed, %d failure(s)", pass, fail))
os.exit(fail == 0 and 0 or 1)
LUA
