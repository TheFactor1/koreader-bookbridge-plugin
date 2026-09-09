#!/bin/bash
# autoCheckForUpdate's clock, in isolation: a check that can't reach the
# server must not start the six-hour interval (it retries in ten minutes);
# a completed check does, and persists its time.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd); M="$REPO/bookbridge.koplugin/main.lua"
KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
[ -x "${KDIR:-/nonexistent}/luajit" ] || { echo "SKIP  no local KOReader (set KOREADER_DIR)"; exit 3; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
awk '/^-- ===== automatic updates =====/{f=1} f{print} f&&/^function Bookbridge:autoCheckForUpdate/{g=1} g&&/^end$/{exit}' "$M" > "$W/fn.lua"
grep -q 'function Bookbridge:autoCheckForUpdate' "$W/fn.lua" || { echo "FAIL  extraction failed"; exit 1; }
cat > "$W/t.lua" <<'LUA'
local fails, n = 0, 0
local function ck(c, msg) n = n + 1; if c then print("PASS  " .. msg) else print("FAIL  " .. msg); fails = fails + 1 end end
Bookbridge = {}; LOG = {}
function debugLog(m) LOG[#LOG + 1] = m end
B = 1700000000  -- a real-looking clock: "never checked" is time 0, six hours before any small number
NOW = B; os.time = function() return NOW end
CHECK = nil  -- what doCheckForUpdate returns
function doCheckForUpdate() return CHECK, 0, CHECK == nil and "no route" or nil end
package.loaded["ui/trapper"] = { wrap = function(_, f) f() end, dismissableRunInSubprocess = function(_, f) return true, f() end }
dofile(os.getenv("FN"))
local saved = 0; local installed = 0
local function plugin(t) return setmetatable(t, { __index = Bookbridge }) end
local dev = plugin({ auto_update = true, update_url = "http://srv", saveAllSettings = function(s) saved = saved + 1 end, applyUpdate = function(s, info) installed = installed + 1 end })
-- 1. no network: nothing persisted, retry allowed after ten minutes, not before
CHECK = nil; Bookbridge.autoCheckForUpdate(dev, "wake")
ck(#LOG == 2 and LOG[2]:find("couldn't check"), "unreachable server is logged")
ck(saved == 0 and dev.last_auto_update_check == nil, "a failed check does not persist a check time")
LOG = {}; NOW = B + 300; Bookbridge.autoCheckForUpdate(dev, "wake")
ck(#LOG == 0, "five minutes later: still holding off")
NOW = B + 601; Bookbridge.autoCheckForUpdate(dev, "network")
ck(#LOG == 2, "ten minutes later: tried again")
-- 2. server reachable and up to date: clock starts, time persisted
LOG = {}; CHECK = { manifest = true, changed = {}, build = "abc" }; NOW = B + 2000; Bookbridge.autoCheckForUpdate(dev, "wake")
ck(LOG[2] and LOG[2]:find("up to date"), "up to date is logged")
ck(saved == 1 and dev.last_auto_update_check == B + 2000, "a completed check persists its time")
LOG = {}; NOW = B + 2000 + 5 * 3600; Bookbridge.autoCheckForUpdate(dev, "wake")
ck(#LOG == 0, "five hours later: inside the interval, no check")
-- 3. a changed build installs
LOG = {}; CHECK = { manifest = true, changed = { "main.lua" }, build = "def" }; NOW = B + 2000 + 7 * 3600; Bookbridge.autoCheckForUpdate(dev, "startup")
ck(installed == 1 and LOG[2]:find("installing"), "seven hours later: a changed build is installed")
-- 4. switch off / no source: nothing at all
LOG = {}; NOW = NOW + 24 * 3600; Bookbridge.autoCheckForUpdate(plugin({ auto_update = false, update_url = "http://srv" }), "wake"); Bookbridge.autoCheckForUpdate(plugin({ auto_update = true, update_url = "" }), "wake")
ck(#LOG == 0, "off, or no update source: never checks")
print(("=== AUTO UPDATE UNIT %d/%d"):format(n - fails, n), fails == 0 and "PASS" or "FAIL"); os.exit(fails == 0 and 0 or 1)
LUA
(cd "$KDIR" && FN="$W/fn.lua" ./luajit "$W/t.lua")
