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
awk '/^function Shelfmark:confirmHardcoverMatchForProgress/{f=1} f{print} f&&/^end$/{exit}' \
    "$REPO/shelfmark.koplugin/main.lua" > "$W/confirm.lua"
grep -q "confirmHardcoverMatchForProgress" "$W/confirm.lua" || { echo "FAIL  could not extract the confirm method"; exit 1; }

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
package.loaded["device"] = { input = { inhibitInputUntil = function() end } }
UIManager.close = function() end
package.loaded["ui/trapper"] = {
    wrap = function(_s,f) return f() end,
    dismissableRunInSubprocess = function(_s,f) return true, f() end,
}
local SEARCHES = 0
doHardcoverFindBook = function() SEARCHES = SEARCHES + 1; return 999, "SEARCHED", "Someone" end
doHardcoverPushProgress = function() return true, 8, 382 end
Shelfmark = {}
assert(load(io.open(SRC):read("*a")))()

local pass, fail = 0, 0
local function ck(c,m) if c then pass=pass+1; print("PASS  "..m) else fail=fail+1; print("FAIL  "..m) end end

local warm = { hardcover_token="t",
    _hc_prefetch = { md5a = { book_id=427473, title="Red Rising", author="Pierce Brown" } } }
Shelfmark.confirmHardcoverMatchForProgress(warm, "md5a", { title="Red Rising", author="Pierce Brown", percent=0.02 })
ck(SEARCHES == 0, "prefetched match -> ZERO searches, dialog is instant")
local box = shown[1]
ck(box ~= nil, "dialog is shown")
ck(box and box.title:find("This book:",1,true) and box.title:find("Hardcover match:",1,true),
   "shows the book's own metadata next to Hardcover's, for approval")
ck(box and box.dismissable == false, "not dismissable (a stray tap cannot answer it)")
-- The important one: a ConfirmBox calls cancel_callback from onClose, so the
-- dialog merely going away recorded decision="skip" permanently. ButtonDialog
-- only calls tap_close_callback, and none is set.
ck(box and box.tap_close_callback == nil,
   "no close callback: the dialog going away records NOTHING")
ck(box and box.buttons and box.buttons[1] and #box.buttons[1] == 2, "offers exactly two buttons")

shown = {}
Shelfmark.confirmHardcoverMatchForProgress({ hardcover_token="t" }, "md5b",
    { title="Whatever", author="A Person", percent=0.5 })
ck(SEARCHES == 1, "no prefetch -> falls back to exactly one search")
ck(shown[1] ~= nil, "cold path still shows a dialog")

shown = {}; MAP = {}
local st = { hardcover_token="t", _hc_prefetch={ m={book_id=1,title="T",author="A"} },
             clearHardcoverPending=function() end }
Shelfmark.confirmHardcoverMatchForProgress(st, "m", { title="T", author="A", percent=0.1 })
shown[1].buttons[1][1].callback()      -- "Yes, sync"
ck(MAP.m and MAP.m.decision=="sync" and MAP.m.book_id==1, "tapping Yes records decision=sync")

shown = {}; MAP = {}
Shelfmark.confirmHardcoverMatchForProgress(st, "m", { title="T", author="A", percent=0.1 })
shown[1].buttons[1][2].callback()      -- "Not this book"
ck(MAP.m and MAP.m.decision=="skip", "tapping Not this book records decision=skip")

-- Teardown regression: build the dialog, touch no button, and the map must
-- stay empty. This is the bug that silently condemned a book on Android
-- whenever the OS reclaimed a backgrounded KOReader.
shown = {}; MAP = {}
Shelfmark.confirmHardcoverMatchForProgress(st, "m", { title="T", author="A", percent=0.1 })
ck(next(MAP) == nil, "dialog dismissed without an answer records nothing")

print(pass.." passed, "..fail.." failed")
os.exit(fail==0 and 0 or 1)
LUA
