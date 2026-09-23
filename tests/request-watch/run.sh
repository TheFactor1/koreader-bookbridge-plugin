#!/bin/bash
# The "ready to read" watch: an approved request whose download FAILED (or was
# cancelled) is reported once and dropped, instead of being re-checked on every
# wake forever with nobody told (found 2026-09-23). Runs the REAL
# reconcilePendingNotifications and checkPendingRequestNotifications from
# main.lua. Offline; KOReader's luajit.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
M=${1:-$REPO/bookbridge.koplugin/main.lua}
KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
[ -x "${KDIR:-/nonexistent}/luajit" ] || { echo "SKIP  no local KOReader (set KOREADER_DIR)"; exit 3; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
{ grep -E '^local TERMINAL_(NON_DELIVERED_STATUSES|FAILED_DELIVERY_STATES) = ' "$M"
  awk '/^local function reconcilePendingNotifications/{f=1} f{print} f&&/^end$/{exit}' "$M"
  awk '/^function Bookbridge:checkPendingRequestNotifications/{f=1} f{print} f&&/^end$/{exit}' "$M"; } > "$W/fns.lua"
grep -q "checkPendingRequestNotifications" "$W/fns.lua" || { echo "FAIL  extraction failed"; exit 1; }
cd "$KDIR" || exit 1
SRC="$W/fns.lua" ./luajit - <<'LUA'
_ = function(s) return s end
T = function(s, ...) local a = {...}; return (s:gsub("%%(%d+)", function(n) return tostring(a[tonumber(n)]) end)) end
debugLog = function() end
local WATCH, REQUESTS, QUERIES, shown = {}, {}, 0, {}
loadPendingNotifyList = function() local c = {}; for k, v in pairs(WATCH) do c[k] = v end; return c end
savePendingNotifyList = function(t) WATCH = t end
UIManager = { show = function(_s, w) shown[#shown + 1] = w end }
InfoMessage = { new = function(_s, t) return t end }
Bookbridge = {}
assert(load(io.open(os.getenv("SRC")):read("*a")))()
local k = setmetatable({ shelfmarkLoginKnownBad = function() return false end,
  apiRequest = function() QUERIES = QUERIES + 1; return { requests = REQUESTS }, 200, nil end }, { __index = Bookbridge })
local pass, fail = 0, 0
local function ck(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end
local function wake() shown = {}; k:checkPendingRequestNotifications() end
-- 1. approved, but the download errored
WATCH = { ["7"] = "Failed Book" }; REQUESTS = { { id = 7, status = "approved", delivery_state = "error" } }; QUERIES = 0
wake()
ck(shown[1] and tostring(shown[1].text):find("Couldn't be delivered", 1, true) and tostring(shown[1].text):find("Failed Book", 1, true),
   "a download that failed is reported (\"Couldn't be delivered\")")
ck(next(WATCH) == nil, "...and leaves the watch list")
QUERIES = 0; wake(); wake()
ck(QUERIES == 0 and #shown == 0, "later wakes: no more queries, no repeat (queried " .. QUERIES .. "; the old code: every wake)")
-- 2. unchanged: complete -> ready; still downloading -> keep watching quietly
WATCH = { ["8"] = "Good Book" }; REQUESTS = { { id = 8, status = "approved", delivery_state = "complete" } }
wake()
ck(shown[1] and tostring(shown[1].text):find("Ready to read: Good Book", 1, true) and next(WATCH) == nil, "a delivered book still says \"Ready to read\"")
WATCH = { ["9"] = "Busy Book" }; REQUESTS = { { id = 9, status = "approved", delivery_state = "downloading" } }
wake()
ck(#shown == 0 and WATCH["9"] ~= nil, "a download in progress stays watched, nothing shown")
-- 3. both at once: one message with both parts
WATCH = { ["1"] = "Ready One", ["2"] = "Broken Two" }
REQUESTS = { { id = 1, status = "approved", delivery_state = "complete" }, { id = 2, status = "approved", delivery_state = "cancelled" } }
wake()
local t = shown[1] and tostring(shown[1].text) or ""
ck(#shown == 1 and t:find("Ready One", 1, true) and t:find("Broken Two", 1, true), "ready + failed at once: one message with both")
-- 4. the watch list empties between the caller's check and the reconcile (e.g. My requests
-- reconciled it a moment earlier): no crash, nothing shown
WATCH = { ["5"] = "Race Book" }; REQUESTS = {}
local real_load = loadPendingNotifyList; local calls = 0
loadPendingNotifyList = function() calls = calls + 1; if calls == 1 then return real_load() end; return {} end
local ok = pcall(function() wake() end)
loadPendingNotifyList = real_load
ck(ok and #shown == 0, "watch list emptied mid-check: no crash, nothing shown")
print(string.format("=== %d passed, %d failure(s)", pass, fail))
os.exit(fail == 0 and 0 or 1)
LUA
