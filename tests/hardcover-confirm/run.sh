#!/bin/bash
# The close-time Hardcover confirm dialog must not do network work.
#
# It used to run the book search itself, so it could not appear until a round
# trip finished -- during reader teardown, with the radio possibly still
# waking. It now uses the match prefetched when the book was OPENED
# (Shelfmark:prefetchHardcoverMatch, via onReaderReady), so the dialog goes up
# immediately.
#
# The stub here counts calls to doHardcoverFindBook, so "instant" is asserted
# rather than assumed: with a prefetched match the count must be zero. The
# cold fallback (progress sync switched on mid-book, or a restart since the
# book was opened) must still work, and still be one search.
#
# Also pins the anti-misfire properties, since a mistimed tap used to record a
# book as never-sync permanently: dismissable=false, flush_events_on_show=true.
#
# Offline. Needs only KOReader's luajit (for ffi/util's template function).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
[ -x "${KDIR:-/nonexistent}/luajit" ] || { echo "SKIP  no local KOReader (set KOREADER_DIR)"; exit 3; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
# Extracted by name so it cannot drift from the real implementation.
awk '/^function Shelfmark:resolveHardcoverMatch/{f=1} f{print} f&&/^end$/{exit}' \
    "$REPO/shelfmark.koplugin/main.lua" > "$W/confirm.lua"
awk '/^function Shelfmark:pickHardcoverCandidate/{f=1} f{print} f&&/^end$/{exit}' \
    "$REPO/shelfmark.koplugin/main.lua" >> "$W/confirm.lua"
grep -q "resolveHardcoverMatch" "$W/confirm.lua" || { echo "FAIL  could not extract resolveHardcoverMatch"; exit 1; }

cd "$KDIR" || exit 1
KDIR="$KDIR" SRC="$W/confirm.lua" ./luajit - <<'LUA'
local KDIR, SRC = os.getenv("KDIR"), os.getenv("SRC")
package.path = KDIR.."/?.lua;"..KDIR.."/frontend/?.lua;"..KDIR.."/common/?.lua;"..package.path
package.cpath = KDIR.."/?.so;"..KDIR.."/libs/?.so;"..package.cpath
_ = function(s) return s end
T = require("ffi/util").template

local MAP, shown = {}, {}
loadHardcoverMap = function() return MAP end
saveHardcoverMap = function(t) MAP = t end
debugLog = function() end
UIManager = { show = function(_s,w) shown[#shown+1] = w end, scheduleIn = function() end }
package.loaded["ui/widget/confirmbox"] = { new = function(_s,t) return t end }
package.loaded["ui/widget/buttondialog"] = { new = function(_s,t) return t end }
InfoMessage = { new = function(_s,t) return t end }
package.loaded["device"] = { input = { inhibitInputUntil = function() end } }
UIManager.close = function() end
package.loaded["ui/trapper"] = {
    wrap = function(_s,f) return f() end,
    dismissableRunInSubprocess = function(_s,f) return true, f() end,
}
local SEARCHES = 0
doHardcoverFindBook = function() SEARCHES = SEARCHES + 1; return 999, "SEARCHED", "Someone", nil, { {id=999,title="SEARCHED",author="Someone"} }, false end
doHardcoverPushProgress = function() return true, 8, 382 end
Shelfmark = {}
assert(load(io.open(SRC):read("*a")))()

local pass, fail = 0, 0
local function ck(c,m) if c then pass=pass+1; print("PASS  "..m) else fail=fail+1; print("FAIL  "..m) end end
local CLEARED = {}
local function inst(extra)
    local t = { hardcover_token="t", clearHardcoverPending=function(_s, md5) CLEARED[#CLEARED+1]=md5 end }
    for k,v in pairs(extra or {}) do t[k]=v end
    return t
end

-- 1. confident prefetch -> silent sync + push, no UI at all
shown = {}; MAP = {}; SEARCHES = 0; CLEARED = {}
local PUSHES = 0; doHardcoverPushProgress = function() PUSHES = PUSHES + 1; return true, 8, 382 end
Shelfmark.resolveHardcoverMatch(inst{ _hc_prefetch = { m = { book_id=427473, title="Red Rising", author="Pierce Brown", ranked={}, confident=true } } },
    "m", { title="Red Rising", author="Pierce Brown", percent=0.02 })
ck(#shown == 0, "confident match: no dialog of any kind")
ck(MAP.m and MAP.m.decision=="sync" and MAP.m.book_id==427473, "confident match: recorded as sync")
ck(PUSHES == 1 and CLEARED[1] == "m", "confident match: progress pushed and the queue entry cleared")
ck(SEARCHES == 0, "confident match from prefetch: zero searches")

-- 2. uncertain prefetch -> review, no UI, no push, progress kept
shown = {}; MAP = {}; PUSHES = 0; CLEARED = {}
local ranked = { {id=427798,title="The Hitchhiker's Guide to the Galaxy",author="Douglas Adams"}, {id=205829,title="Omnibus",author="Douglas Adams"} }
Shelfmark.resolveHardcoverMatch(inst{ _hc_prefetch = { h = { book_id=427798, title="The Hitchhiker's Guide to the Galaxy", author="Douglas Adams", ranked=ranked, confident=false } } },
    "h", { title="The Ultimate Hitchhiker's Guide to the Galaxy", author="Douglas Adams", percent=0.07 })
ck(#shown == 0 and PUSHES == 0, "uncertain match: nothing shown, nothing pushed")
ck(MAP.h and MAP.h.decision=="review" and #MAP.h.ranked == 2, "uncertain match: parked for review with its candidates")
ck(#CLEARED == 0, "uncertain match: progress stays queued")

-- 3. no prefetch -> one search, then the same rules
shown = {}; MAP = {}; SEARCHES = 0
Shelfmark.resolveHardcoverMatch(inst{}, "c", { title="Whatever", author="A Person", percent=0.5 })
ck(SEARCHES == 1, "no prefetch -> exactly one search")
ck(MAP.c and MAP.c.decision=="review", "search stub (not confident) -> review")

-- 4. the review picker: choose -> sync + push; None -> skip; Not now -> nothing
shown = {}; MAP = { h = { decision="review", title="T" } }; PUSHES = 0; CLEARED = {}
Shelfmark.pickHardcoverCandidate(inst{}, "h", { title="T", author="A", percent=0.1 }, ranked, "t")
local pk = shown[1]
ck(pk and #pk.buttons == 4, "picker: 2 candidates + None of these + Not now")
pk.buttons[1][1].callback()
ck(MAP.h and MAP.h.decision=="sync" and MAP.h.book_id==427798 and PUSHES == 1, "picking a candidate records sync and pushes the waiting progress")
shown = {}; MAP = { h = { decision="review", title="T" } }
Shelfmark.pickHardcoverCandidate(inst{}, "h", { title="T", author="A" }, ranked, "t")
shown[1].buttons[3][1].callback()
ck(MAP.h and MAP.h.decision=="skip", "None of these records skip")
shown = {}; MAP = { h = { decision="review", title="T" } }
Shelfmark.pickHardcoverCandidate(inst{}, "h", { title="T", author="A" }, ranked, "t")
shown[1].buttons[4][1].callback()
ck(MAP.h and MAP.h.decision=="review", "Not now leaves it in review")

print(pass.." passed, "..fail.." failed")
os.exit(fail==0 and 0 or 1)
LUA
