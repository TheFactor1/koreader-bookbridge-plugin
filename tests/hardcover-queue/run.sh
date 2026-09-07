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
M="$REPO/shelfmark.koplugin/main.lua"
awk '/^function Shelfmark:processHardcoverPending/{f=1} f{print} f&&/^end$/{exit}' "$M" >  "$W/fns.lua"
awk '/^function Shelfmark:onNetworkConnected/{f=1}     f{print} f&&/^end$/{exit}' "$M" >> "$W/fns.lua"
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
UIManager = { scheduleIn = function(_s,d,f) scheduled[#scheduled+1]={delay=d,fn=f} end, show=function() end }
package.loaded["ui/trapper"] = {
    wrap = function(_s,f) return f() end,
    dismissableRunInSubprocess = function(_s,f) return true, f() end,
}
local PUSHES = 0
doHardcoverPushProgress = function() PUSHES = PUSHES + 1; return true, 8, 382 end
Shelfmark = {}
assert(load(io.open(SRC):read("*a")))()

local pass, fail = 0, 0
local function ck(c,m) if c then pass=pass+1; print("PASS  "..m) else fail=fail+1; print("FAIL  "..m) end end

-- 1. lookup still running -> wait, do NOT confirm
local confirms = 0
local s1 = { hardcover_progress_sync=true, hardcover_token="t",
             _hc_prefetch_inflight = { md5a = true },
             resolveHardcoverMatch = function() confirms = confirms + 1 end }
PENDING = { md5a = { title="Red Rising", percent=0.5 } }; MAP = {}; scheduled = {}
Shelfmark.processHardcoverPending(s1)
ck(confirms == 0, "open-time lookup in flight -> does NOT start a competing search")
ck(#scheduled == 1, "instead it schedules a retry")

ck(scheduled[1] and scheduled[1].delay == 1, "retry is one second out")

-- ...and gives up eventually rather than waiting forever
s1._hc_wait_tries = 20
scheduled = {}
Shelfmark.processHardcoverPending(s1)
ck(confirms == 1, "after 20 tries it stops waiting and searches")
-- a book parked for review is neither pushed nor resolved again
local resolves = 0
local sr = { hardcover_progress_sync=true, hardcover_token="t", resolveHardcoverMatch=function() resolves = resolves + 1 end }
PENDING = { r = { title="R", percent=0.3 } }; MAP = { r = { decision="review", title="R" } }; PUSHES = 0
Shelfmark.processHardcoverPending(sr)
ck(resolves == 0 and PUSHES == 0 and PENDING.r ~= nil, "review entry: not pushed, not re-resolved, progress kept")

-- 2. no lookup in flight -> confirm immediately
local confirms2 = 0
local s2 = { hardcover_progress_sync=true, hardcover_token="t",
             resolveHardcoverMatch = function() confirms2 = confirms2 + 1 end }
PENDING = { m = { title="X", percent=0.2 } }; MAP = {}; scheduled = {}
Shelfmark.processHardcoverPending(s2)
ck(confirms2 == 1, "nothing in flight -> confirms straight away")

-- 3. a book already mapped pushes silently, no dialog
local confirms3 = 0
local s3 = { hardcover_progress_sync=true, hardcover_token="t",
             resolveHardcoverMatch = function() confirms3 = confirms3 + 1 end }
PENDING = { m = { title="X", percent=0.2 } }
MAP = { m = { decision="sync", book_id=42, title="X" } }
PUSHES = 0
Shelfmark.processHardcoverPending(s3)
ck(PUSHES == 1 and confirms3 == 0, "already-matched book pushes silently, no dialog")
ck(next(PENDING) == nil, "a successful push clears the queue entry")
ck(MAP.m.last_percent == 0.2, "...and remembers the position it pushed")

-- same position again (suspend/resume re-capture) -> no push, entry cleared
PENDING = { m = { title="X", percent=0.2 } }; PUSHES = 0
Shelfmark.processHardcoverPending(s3)
ck(PUSHES == 0 and next(PENDING) == nil, "unchanged position -> no push, queue entry cleared")
-- a new position pushes again
PENDING = { m = { title="X", percent=0.25 } }; PUSHES = 0
Shelfmark.processHardcoverPending(s3)
ck(PUSHES == 1 and MAP.m.last_percent == 0.25, "changed position -> pushed, position updated")

-- 4. Wi-Fi back -> flush, but only when there is something queued
local s4 = { hardcover_progress_sync=true, hardcover_token="t" }
PENDING = {}; scheduled = {}
Shelfmark.onNetworkConnected(s4)
ck(#scheduled == 0, "network back with an empty queue does nothing")
PENDING = { m = { title="X", percent=0.2 } }; scheduled = {}
Shelfmark.onNetworkConnected(s4)
ck(#scheduled == 1, "network back with queued progress schedules a flush")
ck(scheduled[1] and scheduled[1].delay == 2, "flush waits for the connection to settle")

-- and stays quiet when the feature is off
PENDING = { m = { title="X", percent=0.2 } }; scheduled = {}
Shelfmark.onNetworkConnected({ hardcover_progress_sync=false, hardcover_token="t" })
ck(#scheduled == 0, "progress sync off -> network events ignored")
Shelfmark.onNetworkConnected({ hardcover_progress_sync=true, hardcover_token="" })
ck(#scheduled == 0, "no token -> network events ignored")

print(pass.." passed, "..fail.." failed")
os.exit(fail==0 and 0 or 1)
LUA
