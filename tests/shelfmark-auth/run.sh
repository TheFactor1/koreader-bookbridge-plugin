#!/bin/bash
# A Shelfmark login that was refused is not re-sent in the background.
#
# Found 2026-09-23: Shelfmark locks a USERNAME for 30 minutes after 10 failed
# logins. A wrong saved password was re-sent by every action AND silently by the
# "ready to read" check on each wake, so an account could lock without anyone
# touching the Kindle. Runs the REAL doLogin, doApiRequest, apiRequest and
# checkPendingRequestNotifications from main.lua against a fake Shelfmark that
# counts login attempts. Offline; KOReader's luajit.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
M=${1:-$REPO/bookbridge.koplugin/main.lua}
KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
[ -x "${KDIR:-/nonexistent}/luajit" ] || { echo "SKIP  no local KOReader (set KOREADER_DIR)"; exit 3; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
ext() { awk -v a="$1" 'index($0, a) == 1 {f=1} f{print} f&&/^end$/{exit}' "$M"; }
{
  ext 'local function doLogin('
  ext 'local function doApiRequest('
  ext 'local function shelfmarkCredentialKey('
  ext 'function Bookbridge:apiRequest('
  ext 'function Bookbridge:shelfmarkLoginKnownBad('
  ext 'function Bookbridge:checkPendingRequestNotifications('
} > "$W/fns.lua"
grep -q "function doApiRequest" "$W/fns.lua" || { echo "FAIL  extraction failed"; exit 1; }
cd "$KDIR" || exit 1
SRC="$W/fns.lua" ./luajit - <<'LUA'
_ = function(s) return s end
T = function(s, ...) local a = {...}; return (s:gsub("%%(%d+)", function(n) return tostring(a[tonumber(n)]) end)) end
debugLog = function() end
UIManager = { show = function() end }
InfoMessage = { new = function(_s, t) return t end }
loadPendingNotifyList = function() return { r1 = { title = "Some Book" } } end
reconcilePendingNotifications = function() return {}, {} end   -- (ready, failed), as the real one returns
package.loaded["ui/trapper"] = { dismissableRunInSubprocess = function(_s, f) return true, f() end }
-- The fake Shelfmark. GOOD is the password it accepts; LOCKED/NETDOWN are switches.
LOGINS, GOOD, LOCKED, NETDOWN = 0, "right", false, false
doRawRequest = function(_url, cookie, _method, path, body)
  if NETDOWN then return nil, nil, nil, "Couldn't reach Shelfmark." end
  if path == "/api/auth/login" then
    LOGINS = LOGINS + 1
    if LOCKED then return { error = "Account locked due to 10 failed login attempts." }, 429 end
    if body.password == GOOD then return { success = true }, 200, "cookie-1" end
    return { error = "Invalid username or password." }, 401
  end
  if cookie then return { requests = {} }, 200, cookie end
  return { error = "Unauthorized" }, 401
end
Bookbridge = {}
assert(load(io.open(os.getenv("SRC")):read("*a")))()
local function kindle(pw) return setmetatable({ server_url = "http://sm", username = "admin", password = pw }, { __index = Bookbridge }) end
local pass, fail = 0, 0
local function ck(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end

-- 1. wrong saved password: the first background check tries once; later wakes don't
local k = kindle("wrong")
k:checkPendingRequestNotifications(); local after_first = LOGINS
for _ = 1, 5 do k:checkPendingRequestNotifications() end
ck(after_first == 1, "wrong password: the first background check tries the login once")
ck(LOGINS == 1, "...and 5 more wakes send it 0 more times (sent " .. (LOGINS - 1) .. " more; the old code: 5)")
-- 2. the user doing something still tries, and sees why
local _r, _c, err = k:apiRequest("GET", "/api/search?q=x", nil, false)
ck(LOGINS == 2 and tostring(err):find("Invalid username or password", 1, true), "a search the user starts still tries once and shows Shelfmark's reason")
-- 3. fixing the password in Settings lifts it without anything else
k.password = "right"; LOGINS = 0
k:checkPendingRequestNotifications()
ck(LOGINS == 1 and not k:shelfmarkLoginKnownBad(), "new credentials in Settings: the background check logs in again and it clears")
-- 4. fixing the password on the SERVER (same saved password) works on the next user action
local k2 = kindle("later-fixed"); GOOD = "nope"; LOGINS = 0
k2:checkPendingRequestNotifications()
GOOD = "later-fixed"
k2:apiRequest("GET", "/api/search?q=x", nil, false)
ck(not k2:shelfmarkLoginKnownBad(), "password fixed on the server: the user's next action succeeds and background checks resume")
-- 5. a lockout (429) is remembered the same way
local k3 = kindle("wrong"); GOOD = "right"; LOCKED = true; LOGINS = 0
k3:checkPendingRequestNotifications(); k3:checkPendingRequestNotifications()
ck(LOGINS == 1 and k3:shelfmarkLoginKnownBad(), "account locked (429): not re-sent in the background either")
LOCKED = false
-- 6. an outage is not a bad password: background checks keep trying
local k4 = kindle("right"); NETDOWN = true
k4:checkPendingRequestNotifications()
ck(not k4:shelfmarkLoginKnownBad(), "Shelfmark unreachable: says nothing about the password, nothing is paused")
NETDOWN = false
print(string.format("=== %d passed, %d failure(s)", pass, fail))
os.exit(fail == 0 and 0 or 1)
LUA
