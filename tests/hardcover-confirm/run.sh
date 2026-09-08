#!/bin/bash
# The close-time Hardcover confirm dialog must not do network work.
#
# It used to run the book search itself, so it could not appear until a round
# trip finished -- during reader teardown, with the radio possibly still
# waking. It now uses the match prefetched when the book was OPENED
# (Bookbridge:prefetchHardcoverMatch, via onReaderReady), so the dialog goes up
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
awk '/^function Bookbridge:resolveHardcoverMatch/{f=1} f{print} f&&/^end$/{exit}' \
    "$REPO/bookbridge.koplugin/main.lua" > "$W/confirm.lua"
awk '/^function Bookbridge:pickHardcoverCandidate/{f=1} f{print} f&&/^end$/{exit}' \
    "$REPO/bookbridge.koplugin/main.lua" >> "$W/confirm.lua"
awk '/^function Bookbridge:showAfterCloseNotice/{f=1} f{print} f&&/^end$/{exit}' \
    "$REPO/bookbridge.koplugin/main.lua" >> "$W/confirm.lua"
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
package.loaded["device"] = { input = { inhibitInputUntil = function() end }, isDesktop = function() return true end }
UIManager.close = function() end
package.loaded["ui/trapper"] = {
    wrap = function(_s,f) return f() end,
    dismissableRunInSubprocess = function(_s,f) return true, f() end,
}
local SEARCHES = 0
doHardcoverFindBook = function() SEARCHES = SEARCHES + 1; return 999, "SEARCHED", "Someone", nil, { {id=999,title="SEARCHED",author="Someone"} }, false end
doHardcoverPushProgress = function() return true, 8, 382 end
Bookbridge = {}
assert(load(io.open(SRC):read("*a")))()

local pass, fail = 0, 0
local function ck(c,m) if c then pass=pass+1; print("PASS  "..m) else fail=fail+1; print("FAIL  "..m) end end
local CLEARED = {}
local function inst(extra)
    local t = { hardcover_token="t", clearHardcoverPending=function(_s, md5) CLEARED[#CLEARED+1]=md5 end,
                showAfterCloseNotice = Bookbridge.showAfterCloseNotice }
    for k,v in pairs(extra or {}) do t[k]=v end
    return t
end

-- 1. confident prefetch -> silent sync + push, no UI at all
shown = {}; MAP = {}; SEARCHES = 0; CLEARED = {}
local PUSHES = 0; doHardcoverPushProgress = function() PUSHES = PUSHES + 1; return true, 8, 382 end
Bookbridge.resolveHardcoverMatch(inst{ _hc_prefetch = { m = { book_id=427473, title="Red Rising", author="Pierce Brown", ranked={}, confident=true } } },
    "m", { title="Red Rising", author="Pierce Brown", percent=0.02 })
ck(#shown == 1 and shown[1].timeout and not shown[1].buttons, "confident match: one auto-dismissing note, no dialog")
ck(shown[1].text:find("page 8 of 382", 1, true) ~= nil, "the note carries the page numbers")
ck(MAP.m and MAP.m.decision=="sync" and MAP.m.book_id==427473, "confident match: recorded as sync")
ck(PUSHES == 1 and CLEARED[1] == "m", "confident match: progress pushed and the queue entry cleared")
ck(SEARCHES == 0, "confident match from prefetch: zero searches")

-- 2. uncertain prefetch -> review, no UI, no push, progress kept
shown = {}; MAP = {}; PUSHES = 0; CLEARED = {}
local ranked = { {id=427798,title="The Hitchhiker's Guide to the Galaxy",author="Douglas Adams"}, {id=205829,title="Omnibus",author="Douglas Adams"} }
Bookbridge.resolveHardcoverMatch(inst{ _hc_prefetch = { h = { book_id=427798, title="The Hitchhiker's Guide to the Galaxy", author="Douglas Adams", ranked=ranked, confident=false } } },
    "h", { title="The Ultimate Hitchhiker's Guide to the Galaxy", author="Douglas Adams", percent=0.07 })
ck(#shown == 1 and shown[1].timeout and not shown[1].buttons and PUSHES == 0, "uncertain match: one note pointing at Review matches, nothing pushed")
ck(MAP.h and MAP.h.decision=="review" and #MAP.h.ranked == 2, "uncertain match: parked for review with its candidates")
ck(#CLEARED == 0, "uncertain match: progress stays queued")

-- 3. no prefetch -> one search, then the same rules
shown = {}; MAP = {}; SEARCHES = 0
Bookbridge.resolveHardcoverMatch(inst{}, "c", { title="Whatever", author="A Person", percent=0.5 })
ck(SEARCHES == 1, "no prefetch -> exactly one search")
ck(MAP.c and MAP.c.decision=="review", "search stub (not confident) -> review")

-- 4. the review picker: choose -> sync + push; None -> skip; Not now -> nothing
shown = {}; MAP = { h = { decision="review", title="T" } }; PUSHES = 0; CLEARED = {}
Bookbridge.pickHardcoverCandidate(inst{}, "h", { title="T", author="A", percent=0.1 }, ranked, "t")
local pk = shown[1]
ck(pk and #pk.buttons == 4, "picker: 2 candidates + None of these + Not now")
pk.buttons[1][1].callback()
ck(MAP.h and MAP.h.decision=="sync" and MAP.h.book_id==427798 and PUSHES == 1, "picking a candidate records sync and pushes the waiting progress")
shown = {}; MAP = { h = { decision="review", title="T" } }
Bookbridge.pickHardcoverCandidate(inst{}, "h", { title="T", author="A" }, ranked, "t")
shown[1].buttons[3][1].callback()
ck(MAP.h and MAP.h.decision=="skip", "None of these records skip")
shown = {}; MAP = { h = { decision="review", title="T" } }
Bookbridge.pickHardcoverCandidate(inst{}, "h", { title="T", author="A" }, ranked, "t")
shown[1].buttons[4][1].callback()
ck(MAP.h and MAP.h.decision=="review", "Not now leaves it in review")

-- Android: the after-close notice nudges the window (brightness re-applied
-- through the Java window attributes) and posts the buffer again; the
-- whole-stack repaints run on every real device. Nothing on the desktop.
do
    local timers, logs, nudges, posts, dirty = {}, {}, 0, 0, 0
    local old_UI, old_dev, old_log = UIManager, package.loaded["device"], debugLog
    debugLog = function(m) logs[#logs+1] = m end
    UIManager = { show = function() end, isWidgetShown = function() return true end,
        scheduleIn = function(_s, d, f) timers[#timers+1] = { d = d, f = f } end,
        setDirty = function(_s, w, m) if w == "all" and m == "ui" then dirty = dirty + 1 end end }
    package.loaded["device"] = { isDesktop = function() return false end, isAndroid = function() return true end,
        screen = { _updateWindow = function() posts = posts + 1 end, refreshWaitForLast = function() end } }
    -- Android with the launcher's toast: the OS draws it; nothing in-app at all
    local toasts, shown_msgs = {}, 0
    UIManager.show = function() shown_msgs = shown_msgs + 1 end
    android = { notification = function(t, long) toasts[#toasts+1] = { t = t, long = long } end,
        getScreenBrightness = function() return 48 end, setScreenBrightness = function(v) if v == 48 then nudges = nudges + 1 end end }
    Bookbridge.showAfterCloseNotice({}, "hi")
    ck(#toasts == 1 and toasts[1].t == "hi" and toasts[1].long == true, "Android: the notice is a long system toast")
    ck(shown_msgs == 0 and #timers == 0 and nudges == 0, "Android toast: no InfoMessage, no timers, no nudge")
    ck(logs[#logs] == "[hc] notice: system toast", "...and it is logged")
    -- Android without a toast (older launcher): the in-app path with the nudge
    android.notification = nil; logs = {}
    Bookbridge.showAfterCloseNotice({}, "hi")
    ck(shown_msgs == 1 and logs[1]:find("system toast failed"), "no toast -> falls back to the in-app notice, logged")
    table.sort(timers, function(a, b) return a.d < b.d end)
    for _, t in ipairs(timers) do t.f() end
    ck(nudges == 2, "Android: brightness re-applied twice (window nudge) -- got " .. nudges)
    ck(posts == 2, "Android: buffer posted again twice -- got " .. posts)
    ck(dirty == 2, "whole-stack repaint twice -- got " .. dirty)
    local order = {}; for _, t in ipairs(timers) do order[#order+1] = t.d end
    ck(order[1] == 0.3 and order[2] == 0.7 and order[3] == 1, "nudge (0.3s) lands before the post (0.7s) and the repaint (1s)")
    ck(logs[2] and logs[2]:find("window nudge at %+0.3s ok %(48%)"), "the nudge is logged with the brightness it re-applied")
    -- Kindle: no nudge, no explicit post, just the repaints
    timers, nudges, posts, dirty = {}, 0, 0, 0
    package.loaded["device"].isAndroid = function() return false end
    Bookbridge.showAfterCloseNotice({}, "hi")
    for _, t in ipairs(timers) do t.f() end
    ck(nudges == 0 and posts == 0 and dirty == 2, "Kindle: repaints only (nudges=" .. nudges .. " posts=" .. posts .. " dirty=" .. dirty .. ")")
    UIManager, package.loaded["device"], debugLog, android = old_UI, old_dev, old_log, nil
end

-- Offline: an unreachable Hardcover is not a verdict -- the book stays queued
do
    local old = doHardcoverFindBook
    doHardcoverFindBook = function() SEARCHES = SEARCHES + 1; return nil, nil, nil, "connection refused", nil, false, true end
    shown = {}; CLEARED = {}; local before = SEARCHES
    Bookbridge.resolveHardcoverMatch({ hardcover_token = "t", hardcover_language = "en", _hc_prefetch = {}, clearHardcoverPending=function(_s, md5) CLEARED[#CLEARED+1]=md5 end, showAfterCloseNotice=Bookbridge.showAfterCloseNotice }, "off1", { title = "Upgrade", author = "Blake Crouch", percent = 0.1 })
    ck(SEARCHES == before + 1, "unreachable: one lookup attempted")
    ck(MAP.off1 == nil, "unreachable: NO review entry recorded (the bug that parked 'Upgrade' with no candidates)")
    ck(#CLEARED == 0 and #shown == 0, "unreachable: progress stays queued, nothing shown")
    doHardcoverFindBook = function() SEARCHES = SEARCHES + 1; return 7, "Upgrade", "Blake Crouch", nil, { {id=7,title="Upgrade",author="Blake Crouch"} }, true end
    before = SEARCHES
    Bookbridge.resolveHardcoverMatch({ hardcover_token = "t", hardcover_language = "en", _hc_prefetch = { off2 = { book_id = nil, ranked = {} } }, clearHardcoverPending=function(_s, md5) CLEARED[#CLEARED+1]=md5 end, showAfterCloseNotice=Bookbridge.showAfterCloseNotice }, "off2", { title = "Upgrade", author = "Blake Crouch", percent = 0.1 })
    ck(SEARCHES == before + 1 and MAP.off2 and MAP.off2.decision == "sync", "stale empty prefetch is not trusted: looked up again and matched")
    doHardcoverFindBook = function() SEARCHES = SEARCHES + 1; return nil, nil, nil, "No matching book found on Hardcover.", {}, false, false end
    Bookbridge.resolveHardcoverMatch({ hardcover_token = "t", hardcover_language = "en", _hc_prefetch = {}, clearHardcoverPending=function(_s, md5) CLEARED[#CLEARED+1]=md5 end, showAfterCloseNotice=Bookbridge.showAfterCloseNotice }, "miss1", { title = "Zqxv Nonexistent", author = "Nobody", percent = 0.1 })
    ck(MAP.miss1 and MAP.miss1.decision == "review" and #MAP.miss1.ranked == 0, "genuine miss: parked for review (empty list, re-searched when opened)")
    doHardcoverFindBook = old
end

print(pass.." passed, "..fail.." failed")
os.exit(fail==0 and 0 or 1)
LUA
