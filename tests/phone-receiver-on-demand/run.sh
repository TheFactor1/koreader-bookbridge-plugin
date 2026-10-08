#!/bin/bash
# The phone receiver (port 8090) runs only while something needs it. It used
# to run all the time, so every book opened and closed stopped it (two
# iptables commands and the server, ~90 ms on Matt's Kindle) and the next
# file browser started it again. Now it starts for Type on your phone / Set
# up another device and stops when their code or offer runs out, or on
# sleep; a book closing leaves it alone. Real SimpleTCPServer and sockets.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd); M="$REPO/bookbridge.koplugin/main.lua"
KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
[ -x "${KDIR:-/nonexistent}/luajit" ] || { echo "SKIP  no local KOReader (set KOREADER_DIR)"; exit 3; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
for f in startClipboardReceiver stopClipboardReceiver stopReceiverWhenIdle onCloseWidget; do
    awk "/^function Bookbridge:$f\\(/{f=1} f{print} f&&/^end\$/{exit}" "$M"
done > "$W/fns.lua"
grep -q "function Bookbridge:stopReceiverWhenIdle" "$W/fns.lua" || { echo "FAIL  extraction failed"; exit 1; }
# the starts that made it always-on: plugin start-up and every wake
awk '/^function Bookbridge:init\(/{f=1} f{print} f&&/^end$/{exit}' "$M" > "$W/init.lua"
awk '/^function Bookbridge:onResume\(/{f=1} f{print} f&&/^end$/{exit}' "$M" > "$W/resume.lua"

cd "$KDIR" || exit 1
PORT=$((20000 + RANDOM % 20000))
W="$W" PORT="$PORT" ./luajit - <<'LUA'
package.path = "frontend/?.lua;common/?.lua;" .. package.path
package.cpath = "common/?.so;libs/?.so;" .. package.cpath
local W, PORT = os.getenv("W"), tonumber(os.getenv("PORT"))
_ = function(s) return s end
socket = require("socket")
CLIPBOARD_RECEIVER_PORT = PORT
CLIP = {}
local LOG, QUEUE = {}, {}
debugLog = function(m) LOG[#LOG + 1] = m end
UIManager = {
    scheduleIn = function(_s, t, f) QUEUE[#QUEUE + 1] = { t = t, f = f } end,
    nextTick = function(_s, f) QUEUE[#QUEUE + 1] = { t = 0, f = f } end,
    unschedule = function(_s, f) for i = #QUEUE, 1, -1 do if QUEUE[i].f == f then table.remove(QUEUE, i) end end end,
    insertZMQ = function(_s, z) return z end, removeZMQ = function() end,
}
package.loaded["device"] = { isKindle = function() return false end }
Bookbridge = {}
dofile(W .. "/fns.lua")
local pass, fail = 0, 0
local function ck(c, m) if c then pass = pass + 1; print("PASS  " .. m) else fail = fail + 1; print("FAIL  " .. m) end end
local function run() local q = QUEUE; QUEUE = {}; for _u, e in ipairs(q) do e.f() end end
local function listening()
    local c = socket.tcp(); c:settimeout(1)
    local ok = c:connect("127.0.0.1", PORT); c:close(); return ok == 1
end
local function src(p) local f = io.open(p); local s = f:read("*a"); f:close(); return s end
local function new() return setmetatable({}, { __index = Bookbridge }) end

ck(not src(W .. "/init.lua"):find(":startClipboardReceiver(", 1, true), "plugin start-up doesn't start the receiver")
ck(not src(W .. "/resume.lua"):find(":startClipboardReceiver(", 1, true), "a wake doesn't start it either")

-- Type on your phone: up while its code is good
local fm = new()
fm:startClipboardReceiver()
CLIP.session = { token = "t", expires = os.time() + 600 }
fm:stopReceiverWhenIdle()
ck(CLIP.server ~= nil and listening(), "a typing code open: the receiver is up")
ck(#QUEUE == 1 and QUEUE[1].t > 590 and QUEUE[1].t <= 601, "...with a check when the code runs out (+" .. tostring(QUEUE[1] and QUEUE[1].t) .. " s)")

-- a book opens and closes meanwhile: nothing stopped, nothing started
local n_log = #LOG
fm:onCloseWidget()
local reader = new()
ck(CLIP.server ~= nil and listening() and #LOG == n_log, "a book opening/closing leaves it alone (no stop, no restart)")

-- the code runs out
CLIP.session.expires = os.time() - 1
run()
ck(CLIP.server == nil and not listening() and #QUEUE == 0, "the code ran out: stopped, nothing left scheduled")
ck(LOG[#LOG]:find("nothing waiting for the phone", 1, true), "...and logged")

-- Set up another device: two minutes to choose; an offer keeps it up longer
reader:startClipboardReceiver()
CLIP.grace = { expires = os.time() + 120 }
reader:stopReceiverWhenIdle()
ck(CLIP.server ~= nil and #QUEUE == 1 and QUEUE[1].t <= 121, "setup screen: up for the two minutes of choosing")
CLIP.pair = { code = "abcd", expires = os.time() + 300 }
reader:stopReceiverWhenIdle()
ck(#QUEUE == 1 and QUEUE[1].t > 290, "an offer made: kept up until it expires (one check, not two)")
-- the other reader fetched it (the offer is cleared), the grace is over
CLIP.pair = nil; CLIP.grace.expires = os.time() - 1
reader:stopReceiverWhenIdle()
ck(CLIP.server == nil and #QUEUE == 0, "offer taken and nothing else waiting: stopped")

-- cancelled at the setup screen: stops when the grace is up
reader:startClipboardReceiver()
CLIP.grace = { expires = os.time() + 120 }
reader:stopReceiverWhenIdle()
CLIP.grace.expires = os.time() - 1
run()
ck(CLIP.server == nil, "setup cancelled: stopped once the two minutes are up")

-- sleep stops it, whichever instance started it
fm = new(); fm:startClipboardReceiver()
CLIP.session = { token = "t", expires = os.time() + 600 }
fm:stopReceiverWhenIdle()
fm:onCloseWidget()
local other = new()
other:stopClipboardReceiver()   -- (onSuspend in the live file browser)
ck(CLIP.server == nil and not listening() and #QUEUE == 0 and CLIP.grace == nil, "sleep: stopped by the live instance, its check cancelled")

-- nothing open at all: a check stops nothing and schedules nothing
CLIP.session = nil
other:stopReceiverWhenIdle()
ck(CLIP.server == nil and #QUEUE == 0, "nothing open: nothing to stop, nothing scheduled")

print(string.format("=== %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
LUA
