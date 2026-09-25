#!/bin/bash
# Sleeping the Kindle pushes the Readest reading position.
#
# The Readest plugin pushes 5 s after a page turn (throttled to once per 30 s)
# and on close, never on sleep. Bookbridge:onSuspend now starts that push
# itself, quietly and only when Readest auto-sync is on and the device is
# online. When the real Readest plugin is available (READEST_PLUGIN_DIR, or an
# install in the local KOReader), its own pushBookConfig is used, so a Readest
# update that renames what this relies on shows up here. Offline.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
[ -x "${KDIR:-/nonexistent}/luajit" ] || { echo "SKIP  no local KOReader (set KOREADER_DIR)"; exit 3; }
RD=${READEST_PLUGIN_DIR:-$KDIR/plugins/readest.koplugin}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
M="$REPO/bookbridge.koplugin/main.lua"
awk '/^function Bookbridge:onSuspend/{f=1} f{print} f&&/^end$/{exit}' "$M" > "$W/fns.lua"
awk '/^function Bookbridge:pushReadestPositionBeforeSleep/{f=1} f{print} f&&/^end$/{exit}' "$M" >> "$W/fns.lua"
grep -E '^local READEST_PULL_DELAYS = ' "$M" >> "$W/fns.lua"
awk '/^function Bookbridge:pullReadestPositionWhenOnline/{f=1} f{print} f&&/^end$/{exit}' "$M" >> "$W/fns.lua"
grep -q "pushBookConfig" "$W/fns.lua" || { echo "FAIL  extraction failed"; exit 1; }
if [ -f "$RD/main.lua" ]; then
  { grep -E '^local API_CALL_DEBOUNCE_DELAY = ' "$RD/main.lua"
    echo 'ReadestSync = {}'
    awk '/^function ReadestSync:pushBookConfig/{f=1} f{print} f&&/^end$/{exit}' "$RD/main.lua"
    awk '/^function ReadestSync:scheduleBackgroundPull/{f=1} f{print} f&&/^end$/{exit}' "$RD/main.lua"; } > "$W/readest.lua"
fi
cd "$KDIR" || exit 1
W="$W" ./luajit - <<'LUA'
package.path = "frontend/?.lua;common/?.lua;" .. package.path
local W = os.getenv("W")
local logs = {}
debugLog = function(m) logs[#logs + 1] = m end
local ONLINE = true
package.loaded["ui/network/manager"] = { isOnline = function() return ONLINE end,
    willRerunWhenOnline = function() return false end }
NetworkMgr = package.loaded["ui/network/manager"]
Bookbridge = {}
assert(load(io.open(W .. "/fns.lua"):read("*a")))()
local pass, fail = 0, 0
local function ck(c, m) if c then pass = pass + 1; print("PASS  " .. m) else fail = fail + 1; print("FAIL  " .. m) end end

-- The Readest side: the REAL pushBookConfig when available, else a stand-in
-- with the same 30 s throttle.
local pushes = 0
local real = io.open(W .. "/readest.lua")
local ReadestProto
if real then
    local src = real:read("*a"); real:close()
    SyncConfig = { push = function(_s, ui, settings, client, interactive, last) pushes = pushes + 1; return os.time() end }
    assert(load(src))()
    ReadestProto = ReadestSync
    ReadestProto.ensureClient = function() return {} end
    print("INFO  using the real Readest pushBookConfig")
else
    print("INFO  Readest plugin not found; stand-in throttle (set READEST_PLUGIN_DIR)")
    ReadestProto = { pushBookConfig = function(self, interactive)
        if not interactive and os.time() - self.last_sync_timestamp <= 30 then return end
        pushes = pushes + 1; self.last_sync_timestamp = os.time() end }
end
local function readest(settings)
    return setmetatable({ settings = settings, last_sync_timestamp = os.time() - 5 }, { __index = ReadestProto })
end
local function bb(rs, doc)
    return setmetatable({ ui = { document = doc == nil and {} or doc, readest = rs },
        stopClipboardReceiver = function() end, captureReadingProgress = function() end }, { __index = Bookbridge })
end

-- a page was pushed 5 s ago, so Readest's own throttle would drop a push now
local rs = readest({ auto_sync = true, access_token = "t" })
rs:pushBookConfig(false)
ck(pushes == 0, "baseline: Readest's own throttle drops a push 5 s after the last one")
bb(rs):onSuspend()
ck(pushes == 1, "sleep: the position is pushed anyway (throttle reset)")
ck(logs[#logs] == "[readest] sleep: position push started", "...and logged")

pushes = 0; ONLINE = false
bb(readest({ auto_sync = true, access_token = "t" })):onSuspend()
ck(pushes == 0 and logs[#logs]:find("offline", 1, true), "offline: nothing sent, left for the next sync")
ONLINE = true

pushes = 0
bb(readest({ auto_sync = false, access_token = "t" })):onSuspend()
ck(pushes == 0, "Readest auto-sync off: nothing sent")
bb(readest({ auto_sync = true })):onSuspend()
ck(pushes == 0, "not signed in to Readest: nothing sent")
bb(nil):onSuspend()
ck(pushes == 0, "no Readest plugin: nothing happens")
bb(readest({ auto_sync = true, access_token = "t" }), false):onSuspend()
ck(pushes == 0, "file browser (no open book): nothing sent")

local broken = readest({ auto_sync = true, access_token = "t" })
broken.pushBookConfig = function() error("readest internals changed") end
local ok = pcall(function() bb(broken):onSuspend() end)
ck(ok and logs[#logs]:find("failed", 1, true), "a Readest error is caught and logged, sleep carries on")
-- network back after a wake: Readest's own background pull is scheduled
local scheduled = {}
UIManager = UIManager or {}
UIManager.scheduleIn = function(_s, d, f) scheduled[#scheduled + 1] = { d = d, f = f } end
UIManager.unschedule = function() end
package.loaded["ui/uimanager"] = UIManager
if not ReadestProto.scheduleBackgroundPull then
    ReadestProto.scheduleBackgroundPull = function(self, delay)
        UIManager:scheduleIn(delay, function() self:pullBookConfig(false) end)
    end
end
local pulls = 0
local function readestPull(settings)
    local r = readest(settings)
    r.pullBookConfig = function() pulls = pulls + 1 end
    r.pullBookNotes = function() end
    r.pullBookStats = function() end
    return r
end
bb(readestPull({ auto_sync = true, access_token = "t" })):pullReadestPositionWhenOnline()
ck(#scheduled == 2 and scheduled[1].d == 5 and scheduled[2].d == 15, "network back with a book open: pulls at +5 s and +15 s (lets DHCP settle)")
ck(logs[#logs] == "[readest] network back: position pulls scheduled (+5s, +15s)", "...logged")
local function drain() while #scheduled > 0 do local t = table.remove(scheduled, 1); t.f() end end
drain()
ck(pulls == 2, "...each runs Readest's own position pull (got " .. pulls .. ")")
scheduled, pulls = {}, 0
local b = bb(readestPull({ auto_sync = true, access_token = "t" }))
b:pullReadestPositionWhenOnline()
b.ui.document = nil
drain()
ck(pulls == 0, "book closed before the pull fires: nothing pulled")
scheduled, pulls = {}, 0
bb(readestPull({ auto_sync = false, access_token = "t" })):pullReadestPositionWhenOnline()
bb(readestPull({ auto_sync = true, access_token = "t" }), false):pullReadestPositionWhenOnline()
bb(nil):pullReadestPositionWhenOnline()
ck(#scheduled == 0, "no pull when auto sync is off, no book is open, or Readest isn't installed")
print(pass .. " passed, " .. fail .. " failed")
os.exit(fail == 0 and 0 or 1)
LUA
