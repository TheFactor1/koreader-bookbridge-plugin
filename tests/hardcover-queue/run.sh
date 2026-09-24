#!/bin/bash
# The pending-progress queue: who runs it, and what it refuses to do twice.
#
# Two behaviours worth pinning, both found by testing on desktop KOReader:
#
# 1. Never race the open-time lookup. Hardcover throttles rapid queries by
#    HANGING the connection rather than answering 429 -- measured: two quick
#    searches answer in ~0.2s, a third can hang past 30s. Closing a book before
#    the prefetch landed used to fire a second, competing search, so the
#    confirm dialog took tens of seconds to appear. It must wait instead.
# 2. Wi-Fi coming back flushes the queue. Reading offline writes progress to
#    the pending file locally and a failed push leaves the record in place, so
#    the queue always existed -- it just had no trigger until the next close.
#
# Offline. Needs KOReader's luajit only.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
[ -x "${KDIR:-/nonexistent}/luajit" ] || { echo "SKIP  no local KOReader (set KOREADER_DIR)"; exit 3; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
M="$REPO/bookbridge.koplugin/main.lua"
awk '/^local function hardcoverErrorIsTransient/{f=1}   f{print} f&&/^end$/{exit}' "$M" >  "$W/fns.lua"
grep -E '^local HC_PROCESS_STALE = ' "$M" >> "$W/fns.lua"
grep -E '^local HC_TOKEN_REJECTED = ' "$M" >> "$W/fns.lua"
awk '/^function Bookbridge:processHardcoverPending/{f=1} f{print} f&&/^end$/{exit}' "$M" >> "$W/fns.lua"
awk '/^function Bookbridge:drainHardcoverPending/{f=1}   f{print} f&&/^end$/{exit}' "$M" >> "$W/fns.lua"
awk '/^function Bookbridge:checkHardcoverFinishedBook/{f=1} f{print} f&&/^end$/{exit}' "$M" >> "$W/fns.lua"
echo 'HC_TRANSIENT = hardcoverErrorIsTransient   -- export the chunk-local classifier to the test' >> "$W/fns.lua"
awk '/^function Bookbridge:onNetworkConnected/{f=1}     f{print} f&&/^end$/{exit}' "$M" >> "$W/fns.lua"
awk '/^function Bookbridge:showAfterCloseNotice/{f=1}    f{print} f&&/^end$/{exit}' "$M" >> "$W/fns.lua"
awk '/^function Bookbridge:captureReadingProgress/{f=1}   f{print} f&&/^end$/{exit}' "$M" >> "$W/fns.lua"
awk '/^local function bookshelfPark/{f=1}                 f{print} f&&/^end$/{exit}' "$M" >> "$W/fns.lua"
awk '/^function Bookbridge:hookBookshelfPark/{f=1}         f{print} f&&/^end$/{exit}' "$M" >> "$W/fns.lua"
awk '/^function Bookbridge:onCloseConfigMenu/{f=1}         f{print} f&&/^end$/{exit}' "$M" >> "$W/fns.lua"
awk '/^function Bookbridge:onBookshelfParked/{f=1}         f{print} f&&/^end$/{exit}' "$M" >> "$W/fns.lua"
grep -q "processHardcoverPending" "$W/fns.lua" || { echo "FAIL  extraction failed"; exit 1; }
grep -q "onNetworkConnected"      "$W/fns.lua" || { echo "FAIL  onNetworkConnected not extracted"; exit 1; }

cd "$KDIR" || exit 1
KDIR="$KDIR" SRC="$W/fns.lua" ./luajit - <<'LUA'
local KDIR, SRC = os.getenv("KDIR"), os.getenv("SRC")
package.path = KDIR.."/?.lua;"..KDIR.."/frontend/?.lua;"..KDIR.."/common/?.lua;"..package.path
package.cpath = KDIR.."/?.so;"..KDIR.."/libs/?.so;"..package.cpath
_ = function(s) return s end
T = require("ffi/util").template

local PENDING, MAP, scheduled = {}, {}, {}
loadHardcoverPending = function() local c={} for k,v in pairs(PENDING) do c[k]=v end return c end
saveHardcoverPending = function(t) PENDING=t end
loadHardcoverMap = function() return MAP end
saveHardcoverMap = function(t) MAP = t end
debugLog = function() end
local shown = {}
UIManager = { scheduleIn = function(_s,d,f) scheduled[#scheduled+1]={delay=d,fn=f} end, show=function(_s,w) shown[#shown+1]=w end }
InfoMessage = { new = function(_s,t) return t end }
package.loaded["device"] = { isDesktop = function() return true end }
package.loaded["ui/trapper"] = {
    wrap = function(_s,f) return f() end,
    dismissableRunInSubprocess = function(_s,f) return true, f() end,
}
local PUSHES = 0
doHardcoverPushProgress = function() PUSHES = PUSHES + 1; return true, 8, 382 end
Bookbridge = {}
assert(load(io.open(SRC):read("*a")))()
-- processHardcoverPending checks finished books first (added 2026-09-18). None
-- of the cases here finish a book, so "nothing finished" is the faithful stub.
-- The cases pass plain tables as self, so inject it per call.
do
  local orig = Bookbridge.processHardcoverPending
  Bookbridge.processHardcoverPending = function(self, ...)
    if self.checkHardcoverFinishedBook == nil then self.checkHardcoverFinishedBook = function() return false end end
    return orig(self, ...)
  end
end
doHardcoverGetBookSlug = function() return "test-slug" end   -- slug backfill piggybacks on a successful push
-- (hardcoverErrorIsTransient is the REAL one, extracted from main.lua)

local pass, fail = 0, 0
local function ck(c,m) if c then pass=pass+1; print("PASS  "..m) else fail=fail+1; print("FAIL  "..m) end end

-- 1. lookup still running -> wait, do NOT confirm
local confirms = 0
local s1 = { hardcover_progress_sync=true, hardcover_token="t",
             _hc_prefetch_inflight = { md5a = true },
             resolveHardcoverMatch = function() confirms = confirms + 1 end }
PENDING = { md5a = { title="Red Rising", percent=0.5 } }; MAP = {}; scheduled = {}
Bookbridge.processHardcoverPending(s1)
ck(confirms == 0, "open-time lookup in flight -> does NOT start a competing search")
ck(#scheduled == 1, "instead it schedules a retry")

ck(scheduled[1] and scheduled[1].delay == 1, "retry is one second out")

-- ...and gives up eventually rather than waiting forever
s1._hc_wait_tries = 20
scheduled = {}
Bookbridge.processHardcoverPending(s1)
ck(confirms == 1, "after 20 tries it stops waiting and searches")
-- a book parked for review is neither pushed nor resolved again
local resolves = 0
local sr = { hardcover_progress_sync=true, hardcover_token="t", resolveHardcoverMatch=function() resolves = resolves + 1 end }
PENDING = { r = { title="R", percent=0.3 } }; MAP = { r = { decision="review", title="R" } }; PUSHES = 0
Bookbridge.processHardcoverPending(sr)
ck(resolves == 0 and PUSHES == 0 and PENDING.r ~= nil, "review entry: not pushed, not re-resolved, progress kept")

-- 2. no lookup in flight -> confirm immediately
local confirms2 = 0
local s2 = { hardcover_progress_sync=true, hardcover_token="t",
             resolveHardcoverMatch = function() confirms2 = confirms2 + 1 end }
PENDING = { m = { title="X", percent=0.2 } }; MAP = {}; scheduled = {}
Bookbridge.processHardcoverPending(s2)
ck(confirms2 == 1, "nothing in flight -> confirms straight away")

-- 3. a book already mapped pushes silently, no dialog
local confirms3 = 0
local s3 = { hardcover_progress_sync=true, hardcover_token="t",
             resolveHardcoverMatch = function() confirms3 = confirms3 + 1 end,
             showAfterCloseNotice = Bookbridge.showAfterCloseNotice }
PENDING = { m = { title="X", percent=0.2 } }
MAP = { m = { decision="sync", book_id=42, title="X" } }
PUSHES = 0
Bookbridge.processHardcoverPending(s3)
ck(PUSHES == 1 and confirms3 == 0, "already-matched book pushes without a dialog")
ck(#shown == 0, "...and pushes silently (success toast removed on purpose in 6a7309c)")
ck(next(PENDING) == nil, "a successful push clears the queue entry")
ck(MAP.m.last_percent == 0.2, "...and remembers the position it pushed")

-- same position again (suspend/resume re-capture) -> no push, entry cleared
PENDING = { m = { title="X", percent=0.2 } }; PUSHES = 0
Bookbridge.processHardcoverPending(s3)
ck(PUSHES == 0 and next(PENDING) == nil, "unchanged position -> no push, queue entry cleared")
-- a new position pushes again
PENDING = { m = { title="X", percent=0.25 } }; PUSHES = 0
Bookbridge.processHardcoverPending(s3)
ck(PUSHES == 1 and MAP.m.last_percent == 0.25, "changed position -> pushed, position updated")

-- 3b. an edition with no page count fails permanently: announce it ONCE, then
-- keep retrying silently (reported 2026-09-23: the notice returned on every close)
do
  local NOPAGES = "Hardcover has no page count for this edition -- can't record progress."
  doHardcoverPushProgress = function() PUSHES = PUSHES + 1; return false, NOPAGES, "no_pages" end
  local sn = setmetatable({ hardcover_progress_sync = true, hardcover_token = "t",
      confirmHardcoverMatch = function() end, resolveHardcoverPending = function() end }, { __index = Bookbridge })
  MAP = { g = { decision = "sync", book_id = 9, title = "The Girl with the Dragon Tattoo" } }
  shown = {}; PUSHES = 0
  for i = 1, 3 do PENDING = { g = { title = "G", percent = 0.1 + i / 100 } }; sn:processHardcoverPending() end
  local notes = 0; for _, w in ipairs(shown) do if tostring(w.text or w):find("no page count", 1, true) then notes = notes + 1 end end
  ck(PUSHES == 3 and notes == 1, "no page count: retried every close, but announced only once (got "..notes..")")
  ck(PENDING.g ~= nil and MAP.g.push_notified_error == NOPAGES, "...record stays queued for a later retry, and remembers it said so")
  -- a later success re-arms the notice, so a genuinely new failure is still reported
  doHardcoverPushProgress = function() PUSHES = PUSHES + 1; return true, 8, 382 end
  PENDING = { g = { title = "G", percent = 0.5 } }; sn:processHardcoverPending()
  ck(MAP.g.no_pages_noticed == nil, "successful push clears the flag (notice re-armed)")
  -- any other permanent error: said once per book too, not on every close
  doHardcoverPushProgress = function() PUSHES = PUSHES + 1; return false, "Book not found" end
  MAP.h = { decision = "sync", book_id = 7, title = "H" }; shown = {}; PUSHES = 0
  for i = 1, 3 do PENDING = { h = { title = "H", percent = 0.2 + i / 100 } }; sn:processHardcoverPending() end
  ck(PUSHES == 3 and #shown == 1, "a book deleted on Hardcover: retried each close, announced once (got " .. #shown .. ")")
  -- ...but a DIFFERENT error is new information, so it is said
  doHardcoverPushProgress = function() PUSHES = PUSHES + 1; return false, "Edition was merged" end
  PENDING = { h = { title = "H", percent = 0.3 } }; sn:processHardcoverPending()
  ck(#shown == 2, "a different error for the same book is announced")
  -- an upgraded device keeps build 761a652's no_pages memory (no repeat on upgrade)
  doHardcoverPushProgress = function() PUSHES = PUSHES + 1; return false, NOPAGES, "no_pages" end
  MAP.u = { decision = "sync", book_id = 5, title = "U", no_pages_noticed = true }; shown = {}
  PENDING = { u = { title = "U", percent = 0.3 } }; sn:processHardcoverPending()
  ck(#shown == 0, "no_pages already announced by 761a652 is not repeated after upgrading")
  doHardcoverPushProgress = function() PUSHES = PUSHES + 1; return true, 8, 382 end
end

-- 3c. network conditions are transient: never narrated after a close
do
  ck(HC_TRANSIENT("Couldn't reach Hardcover.") == true, "a thrown socket/SSL error (\"Couldn't reach Hardcover.\") is transient")
  ck(HC_TRANSIENT("Hardcover returned an unreadable response.") == true, "a captive portal's non-JSON page is transient")
  ck(HC_TRANSIENT("Hardcover request timed out.") == true, "a timeout is transient (unchanged)")
  ck(HC_TRANSIENT("Hardcover has no page count for this edition -- can't record progress.") == false
     and HC_TRANSIENT("Book not found") == false, "real problems with the book are still permanent")
end

-- 3d. one finished book whose mark-Read keeps failing must not block the others
do
  local FIN = 0
  local sb = setmetatable({ hardcover_progress_sync = true, hardcover_token = "t",
      syncHardcoverFinish = function() FIN = FIN + 1 end,   -- the write fails: nothing cleared
      confirmHardcoverMatch = function() end, resolveHardcoverMatch = function() end }, { __index = Bookbridge })
  MAP = { f = { decision = "sync", book_id = 1, title = "Finished F" }, n = { decision = "sync", book_id = 2, title = "Reading N" } }
  PUSHES = 0
  for i = 1, 3 do
    PENDING = { f = { title = "F", percent = 1.0, finished = true, finished_date = "2026-09-23" },
                n = { title = "N", percent = 0.3 + i / 100 } }
    sb:processHardcoverPending()
  end
  ck(FIN == 3, "the failing finished book's mark-Read is retried every time (" .. FIN .. ")")
  ck(PUSHES == 3, "...and the OTHER book's progress still syncs every time (pushed " .. PUSHES .. ", the old code: 0)")
  ck(PENDING.f ~= nil, "...while the finished book stays queued for its retry")
end

-- 3e. runs are serialised: a trigger arriving mid-run is deferred, not run on top
do
  local sg = setmetatable({ hardcover_progress_sync = true, hardcover_token = "t",
      confirmHardcoverMatch = function() end, resolveHardcoverMatch = function() end }, { __index = Bookbridge })
  local nested = false
  doHardcoverPushProgress = function()
    PUSHES = PUSHES + 1
    if not nested then nested = true; Bookbridge.processHardcoverPending(sg) end   -- e.g. a wake landing mid-push
    return true, 8, 382
  end
  MAP = { g = { decision = "sync", book_id = 3, title = "G" } }
  PENDING = { g = { title = "G", percent = 0.4 } }; PUSHES = 0; scheduled = {}
  sg:processHardcoverPending()
  ck(PUSHES == 1, "a second trigger during a push does not start a concurrent run (pushed " .. PUSHES .. ")")
  ck(#scheduled == 1 and scheduled[1].delay == 1, "...it gets one follow-up run instead of being dropped")
  ck(sg._hc_processing == nil, "...and the in-progress mark is cleared when the run ends")
  -- a run that errors still clears the mark, and the error still surfaces
  doHardcoverPushProgress = function() error("boom") end
  PENDING = { g = { title = "G", percent = 0.5 } }
  local ok = pcall(sg.processHardcoverPending, sg)
  ck(not ok and sg._hc_processing == nil, "an error inside a run clears the mark (syncing isn't disabled) and is re-raised")
  -- a mark left by a run that never returned expires rather than blocking forever
  doHardcoverPushProgress = function() PUSHES = PUSHES + 1; return true, 8, 382 end
  sg._hc_processing = os.time() - 700; PUSHES = 0
  PENDING = { g = { title = "G", percent = 0.6 } }; sg:processHardcoverPending()
  ck(PUSHES == 1, "a stale in-progress mark (>10 min) doesn't block syncing")
end

-- 3f. a rejected API token: ONE notice, then Hardcover is paused until it changes
do
  local TOKMSG = "Hardcover rejected the API token (HTTP 401) -- update it under Bookbridge > Settings."
  ck(HC_TRANSIENT(TOKMSG) == false, "a rejected token is not transient (it was silently retried forever as \"request failed\")")
  local st = setmetatable({ hardcover_progress_sync = true, hardcover_token = "old",
      confirmHardcoverMatch = function() end, resolveHardcoverMatch = function() end }, { __index = Bookbridge })
  doHardcoverPushProgress = function() PUSHES = PUSHES + 1; return false, TOKMSG end
  MAP = { a = { decision = "sync", book_id = 1, title = "A" }, b = { decision = "sync", book_id = 2, title = "B" },
          c = { decision = "sync", book_id = 3, title = "C" } }
  shown = {}; PUSHES = 0
  for i = 1, 4 do
    PENDING = { a = { title = "A", percent = 0.1 + i / 100 }, b = { title = "B", percent = 0.2 + i / 100 }, c = { title = "C", percent = 0.3 + i / 100 } }
    st:processHardcoverPending()
  end
  local notes = 0; for _, w in ipairs(shown) do if tostring(w.text or w):find("rejected the API token", 1, true) then notes = notes + 1 end end
  ck(notes == 1, "3 queued books x 4 closes with a bad token: ONE notice (got " .. notes .. ")")
  ck(PUSHES == 1, "...and one request in total, not one per book per close (sent " .. PUSHES .. ")")
  ck(PENDING.a and PENDING.b and PENDING.c, "...all three stay queued for when the token is fixed")
  -- a new token in Settings resumes straight away
  doHardcoverPushProgress = function() PUSHES = PUSHES + 1; return true, 8, 382 end
  st.hardcover_token = "new"; PUSHES = 0
  st:processHardcoverPending()
  ck(PUSHES == 3 and next(PENDING) == nil, "new token: syncing resumes at once and the queue drains")
end

-- 4. Wi-Fi back -> flush, but only when there is something queued
local s4 = { hardcover_progress_sync=true, hardcover_token="t" }
PENDING = {}; scheduled = {}
Bookbridge.onNetworkConnected(s4)
ck(#scheduled == 0, "network back with an empty queue does nothing")
PENDING = { m = { title="X", percent=0.2 } }; scheduled = {}
Bookbridge.onNetworkConnected(s4)
ck(#scheduled == 1, "network back with queued progress schedules a flush")
ck(scheduled[1] and scheduled[1].delay == 2, "flush waits for the connection to settle")

-- and stays quiet when the feature is off
PENDING = { m = { title="X", percent=0.2 } }; scheduled = {}
Bookbridge.onNetworkConnected({ hardcover_progress_sync=false, hardcover_token="t" })
ck(#scheduled == 0, "progress sync off -> network events ignored")
Bookbridge.onNetworkConnected({ hardcover_progress_sync=true, hardcover_token="" })
ck(#scheduled == 0, "no token -> network events ignored")

-- capture records what the footer shows, not the raw page ratio
local LOGS = {}
debugLog = function(m) LOGS[#LOGS+1] = m end
PENDING = {}
local ui = {
    document = { info = { has_pages = false }, getProps = function() return { title = "T", authors = "A" } end },
    doc_settings = { readSetting = function(_s, k) if k == "partial_md5_checksum" then return "cap1" end end },
    rolling = { getLastPercent = function() return 0.40 end },
    view = { footer = { percent_finished = 0.42 } },
}
Bookbridge.captureReadingProgress({ hardcover_progress_sync = true, hardcover_token = "t", ui = ui })
ck(PENDING.cap1 and math.abs(PENDING.cap1.percent - 0.42) < 1e-9, "capture records the footer's 42%, not the raw 40%")
local noted = false; for _, m in ipairs(LOGS) do if m:find("footer shows 42.0%", 1, true) then noted = true end end
ck(noted, "...and logs that the two disagreed")
ui.view = nil; PENDING = {}
Bookbridge.captureReadingProgress({ hardcover_progress_sync = true, hardcover_token = "t", ui = ui })
ck(PENDING.cap1 and math.abs(PENDING.cap1.percent - 0.40) < 1e-9, "no footer value -> falls back to the raw ratio")

-- Bookshelf hot parking: the park is treated as the close, once
do
    local closes, ticks = 0, {}
    local old_next = UIManager.nextTick
    UIManager.nextTick = function(_s, f) ticks[#ticks+1] = f end
    local sm = { onCloseDocument = function() closes = closes + 1 end,
        hookBookshelfPark = Bookbridge.hookBookshelfPark, onCloseConfigMenu = Bookbridge.onCloseConfigMenu,
        onBookshelfParked = Bookbridge.onBookshelfParked }
    package.loaded["apps/reader/readerui"] = { instance = { shelfmark = sm } }
    ck(sm:hookBookshelfPark() == false, "no Bookshelf park module loaded -> nothing to hook")
    local parked = false
    package.loaded["lib/bookshelf_reader_park"] = { park = function() parked = true; return true end, isParked = function() return parked end }
    ck(sm:hookBookshelfPark() == true and sm:hookBookshelfPark() == true, "hooks once the module is there (idempotent)")
    package.loaded["lib/bookshelf_reader_park"].park()
    ck(closes == 1, "Park.park() -> the plugin's close handler runs at once")
    sm:onCloseConfigMenu(); for _, f in ipairs(ticks) do f() end; ticks = {}
    ck(closes == 1, "the CloseConfigMenu fallback a tick later is debounced (same park)")
    sm._hc_park_at = os.time() - 10; parked = false
    sm:onCloseConfigMenu(); for _, f in ipairs(ticks) do f() end; ticks = {}
    ck(closes == 1, "CloseConfigMenu with nothing parked (a normal config close) does nothing")
    parked = true
    sm:onCloseConfigMenu(); for _, f in ipairs(ticks) do f() end; ticks = {}
    ck(closes == 1, "CloseConfigMenu once the park is hooked -> ignored (the hook catches real parks; 5ad953d)")
    UIManager.nextTick = old_next
    package.loaded["lib/bookshelf_reader_park"] = nil; package.loaded["apps/reader/readerui"] = nil
end

print(pass.." passed, "..fail.." failed")
os.exit(fail==0 and 0 or 1)
LUA
