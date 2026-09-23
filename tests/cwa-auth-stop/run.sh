#!/bin/bash
# A wrong Calibre-Web password (or an active CWA lockout) must stop a library
# sync after ONE request, not carry on through every book.
#
# Found 2026-09-23: CWA locks an account after 3 failed logins a minute and
# answers 429 from then on, but doSyncLibrary kept going regardless -- one
# request per tracked book, several per untracked file. Measured on the real
# server: 68 requests in 18 s, 63 of them already refused by the lockout.
#
# Runs the REAL doSyncLibrary AND the real doCwaRequest (with its per-run
# guard) extracted from main.lua; only the socket underneath is fake, a server
# that answers every request with a chosen status, counting each one.
#   bash tests/cwa-auth-stop/run.sh [path/to/main.lua]
# Needs: docker (openresty image, for LuaJIT + cjson). Offline otherwise.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
M=${1:-$REPO/bookbridge.koplugin/main.lua}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
extract() { local s=$(grep -n "^local function $1(" "$M" | head -1 | cut -d: -f1); local e=$(awk -v s="$s" 'NR>s && /^end$/ {print NR; exit}' "$M"); sed -n "${s},${e}p" "$M"; }
range() { local s=$(grep -n "$1" "$M" | head -1 | cut -d: -f1); local e=$(awk -v s="$(grep -n "$2" "$M" | head -1 | cut -d: -f1)" 'NR>s && /^end$/ {print NR; exit}' "$M"); sed -n "${s},${e}p" "$M"; }
{
cat <<'LUA'
package.cpath = "/usr/local/openresty/lualib/?.so;" .. package.cpath
local cjson = require("cjson")
local JSON = { decode = cjson.decode, encode = cjson.encode, null = cjson.null }
local _ = function(s) return s end
local function T(str, ...) local a = {...}; return (str:gsub("%%(%d+)", function(n) return tostring(a[tonumber(n)]) end)) end
local function debugLog() end
local ffiUtil = { sleep = function() end }
local socketurl = { escape = function(s) return (s:gsub("([^A-Za-z0-9_])", function(c) return string.format("%%%02x", c:byte()) end)) end }
local DL = "/books"
local VFILES = { [DL] = { "Tracked One.epub", "Tracked Two.epub", "Tracked Three.epub", "Tracked Four.epub", "Tracked Five.epub",
                          "Loose Alpha Beta Gamma.epub", "Loose Delta Epsilon.epub", "Loose Zeta.epub" } }
local lfs = {
  dir = function(d) local i = 0; local list = VFILES[d] or {}; return function() i = i + 1; return list[i] end, nil end,
  attributes = function(p) if VFILES[p] then return "directory" end
    local dir, name = p:match("^(.*)/([^/]+)$"); for _, n in ipairs(VFILES[dir] or {}) do if n == name then return "file" end end; return nil end,
}
local SAVED
local function loadSyncRegistry()
  local r = {}
  for i, n in ipairs({ "One", "Two", "Three", "Four", "Five" }) do
    r["uuid-" .. i] = { path = DL .. "/Tracked " .. n .. ".epub", title = "Tracked " .. n, last_modified = "2026-01-01 00:00:00+00:00" }
  end
  return r
end
local function saveSyncRegistry(r) SAVED = r end
local function loadPendingUploads() return {} end
local function savePendingUploads() end
-- The fake network: counts every request that actually reaches the socket.
NET = 0; UPLOAD_LOGINS = 0; RESPOND = nil
local http = { request = function(req) NET = NET + 1; local code, body = RESPOND(NET, req.url); req.sink(body or ""); req.sink(nil); return 1, code end }
local socket = { skip = function(n, ...) return select(n + 1, ...) end }
local socketutil = { set_timeout = function() end, reset_timeout = function() end, TIMEOUT_CODE = "timeout", SINK_TIMEOUT_CODE = "sink timeout",
  table_sink = function() local t = {}; return function(c) if c then t[#t + 1] = c end; return 1 end, t end }
local mime = { b64 = function(s) return s end }
local function makeSocks5Socket() error("no proxy in this test") end
local function doCwaFileDownload() return false end
local function doCwaLogin() UPLOAD_LOGINS = UPLOAD_LOGINS + 1; return nil, "login refused" end
local function doCwaMultipartUpload() error("upload must never be reached") end
LUA
grep -E '^local (CATALOG_PAGE|CATALOG_MAX_PAGES) ' "$M"
# The real request function -- and, on the fixed code, the guard declared right above it.
if grep -q '^local cwa_run_guard = nil' "$M"; then range '^local cwa_run_guard = nil' '^local function doCwaRequest'; else extract doCwaRequest; fi
extract stripJsonNull
extract decodeHtmlEntities
extract parseOpdsEntries
range '^local SYNC_STOPWORDS = ' '^local function titleWordsSubsetOf'
extract fetchCwaCatalog
extract checkTrackedBookAgainstCwa
extract doSyncLibrary
cat <<'LUA'
local pass, fail = 0, 0
local function ck(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end
local function run(respond)
  NET = 0; UPLOAD_LOGINS = 0; SAVED = nil; RESPOND = respond
  local report = doSyncLibrary("http://cwa", "admin", "wrong", nil, DL, nil)
  local kept = 0; for _ in pairs(SAVED or {}) do kept = kept + 1 end
  return table.concat(report or {}, "\n"), kept
end
-- 1. wrong password: every request is refused
local text, kept = run(function() return 401 end)
ck(NET == 1, "wrong password (401): stops after ONE request (sent " .. NET .. "; the old code sent 15 here, 68 on the real library)")
ck(text:find("rejected the login (HTTP 401)", 1, true) ~= nil and not text:find("Done.", 1, true), "...and says why, instead of reporting \"Done.\"")
ck(kept == 5 and UPLOAD_LOGINS == 0, "...registry saved intact (" .. kept .. "/5), no upload login attempted")
-- 2. lockout begins mid-run: the catalog works, then CWA answers 429
text, kept = run(function(n) if n == 1 then return 200, "<feed></feed>" end; return 429 end)
ck(NET == 2, "lockout mid-run (429): stops at the first refusal (sent " .. NET .. ")")
ck(text:find("too many failed logins", 1, true) ~= nil, "...and tells the user to wait and check the password")
ck(kept == 5 and UPLOAD_LOGINS == 0, "...registry saved intact, no upload login against the lockout")
-- 3. forbidden account
text = run(function() return 403 end)
ck(NET == 1 and text:find("HTTP 403", 1, true) ~= nil, "forbidden (403): one request, clear message")
-- 4. a healthy run is not affected by the guard left over from a stopped one
run(function() return 401 end)
NET = 0; RESPOND = function(n) if n == 1 then return 200, "<feed></feed>" end; return 404 end
local report = doSyncLibrary("http://cwa", "admin", "right", nil, DL, nil)
ck(NET > 2 and table.concat(report, "\n"):find("Done.", 1, true) ~= nil, "a later healthy run starts fresh and completes (sent " .. NET .. ")")
print(string.format("=== %d passed, %d failure(s)", pass, fail))
os.exit(fail == 0 and 0 or 1)
LUA
} > "$W/t.lua"
docker run --rm -v "$W":/w openresty/openresty:alpine /usr/local/openresty/luajit/bin/luajit /w/t.lua 2>&1
