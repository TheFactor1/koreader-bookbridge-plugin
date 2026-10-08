#!/bin/bash
# The clipboard receiver comes back when its port is still held. On Matt's
# Kindle (2026-10-07) closing a book stopped the receiver; a background task
# forked while it was up still had the socket, the restart failed with
# "address already in use", and nothing listened until the next wake. Real
# SimpleTCPServer and sockets; the port is held by a second socket here.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd); M="$REPO/bookbridge.koplugin/main.lua"
KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
[ -x "${KDIR:-/nonexistent}/luajit" ] || { echo "SKIP  no local KOReader (set KOREADER_DIR)"; exit 3; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
for f in startClipboardReceiver stopClipboardReceiver; do
    awk "/^function Bookbridge:$f\\(/{f=1} f{print} f&&/^end\$/{exit}" "$M"
done > "$W/fns.lua"
grep -q "CLIP.retry" "$W/fns.lua" || { echo "FAIL  extraction failed"; exit 1; }

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
    scheduleIn = function(_s, _t, f) QUEUE[#QUEUE + 1] = f end,
    unschedule = function(_s, f) for i = #QUEUE, 1, -1 do if QUEUE[i] == f then table.remove(QUEUE, i) end end end,
    insertZMQ = function(_s, z) return z end, removeZMQ = function() end,
}
package.loaded["device"] = { isKindle = function() return false end }
Bookbridge = {}
dofile(W .. "/fns.lua")
local pass, fail = 0, 0
local function ck(c, m) if c then pass = pass + 1; print("PASS  " .. m) else fail = fail + 1; print("FAIL  " .. m) end end
local function run() local q = QUEUE; QUEUE = {}; for _u, f in ipairs(q) do f() end end
local function listening()
    local c = socket.tcp(); c:settimeout(1)
    local ok = c:connect("127.0.0.1", PORT); c:close(); return ok == 1
end

-- the port held, the way a forked task's copy of the socket holds it
local holder = socket.tcp()
holder:setoption("reuseaddr", true)
assert(holder:bind("*", PORT)); assert(holder:listen(5))
local bb = setmetatable({}, { __index = Bookbridge })
bb:startClipboardReceiver()
ck(CLIP.server == nil and #QUEUE == 1 and LOG[#LOG]:find("again in 3 s (1)", 1, true), "port taken: not up, a retry in 3 s")
run()
ck(CLIP.server == nil and #QUEUE == 1 and CLIP.retries == 2, "still taken: tried again, another retry waiting")
bb:startClipboardReceiver()   -- (a wake's start meanwhile: still one retry, not two)
ck(#QUEUE == 1, "a second start while waiting doesn't stack retries")
holder:close()
run()
ck(CLIP.server ~= nil and #QUEUE == 0 and CLIP.retries == nil, "port let go: up on the next try, nothing left scheduled")
ck(listening(), "...and really listening")
ck(LOG[#LOG]:find("receiver listening", 1, true), "logged as listening")

-- asleep: a stop cancels a waiting retry
bb:stopClipboardReceiver()
holder = socket.tcp(); holder:setoption("reuseaddr", true); assert(holder:bind("*", PORT)); assert(holder:listen(5))
bb:startClipboardReceiver()
ck(#QUEUE == 1, "taken again: a retry waiting")
bb:stopClipboardReceiver()
ck(#QUEUE == 0 and CLIP.retries == nil, "the Kindle sleeps: the waiting retry is cancelled")

-- gives up after a minute
CLIP.retries = 20
bb:startClipboardReceiver()
ck(#QUEUE == 0 and LOG[#LOG]:find("giving up", 1, true), "held for a minute: gives up (Type on your phone tries again when tapped)")
holder:close()
-- a closed instance's retry doesn't start anything
CLIP.retries = nil
holder = socket.tcp(); holder:setoption("reuseaddr", true); assert(holder:bind("*", PORT)); assert(holder:listen(5))
bb:startClipboardReceiver()
holder:close()
bb._closed = true
run()
ck(CLIP.server == nil, "the instance closed meanwhile: its retry does nothing")

print(string.format("=== %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
LUA
