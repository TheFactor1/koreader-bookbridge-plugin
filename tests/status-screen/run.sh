#!/bin/bash
# Status & setup screen: every part of Bookbridge reports the right state and
# its fix, the right-hand status stays short (a long one crashed KOReader's
# text layout), and "Check connections now" maps login results to labels and
# keeps the background-login guards in step. Offline; stubs the network.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
[ -x "${KDIR:-/nonexistent}/luajit" ] || { echo "SKIP  no local KOReader (set KOREADER_DIR)"; exit 3; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
M="$REPO/bookbridge.koplugin/main.lua"
{ grep -E '^local HC_TOKEN_REJECTED = |^local hc_rejected_token = |^local CLIPBOARD_RECEIVER_PORT = |^local STATUS_CHECK_MAX_AGE = |^local STATUS_MAX = ' "$M"
  for f in statusCheckedLabel statusShort; do awk "/^local function $f/{f=1} f{print} f&&/^end\$/{exit}" "$M"; done
  for f in collectStatusRows showStatus runStatusChecks; do awk "/^function Bookbridge:$f/{f=1} f{print} f&&/^end\$/{exit}" "$M"; done
  echo 'return function() return hc_rejected_token end, function(v) hc_rejected_token = v end'
} > "$W/fns.lua"
grep -q "collectStatusRows" "$W/fns.lua" || { echo "FAIL  extraction failed"; exit 1; }
cd "$KDIR" || exit 1
W="$W" ./luajit - <<'LUA'
package.path = "frontend/?.lua;common/?.lua;" .. package.path
local W = os.getenv("W")
_ = function(s) return s end
T = require("ffi/util").template
lfs = { attributes = function(p, k) return (p == "/mnt/us/books") and "directory" or nil end }
local REG, MAP = {}, {}
loadSyncRegistry = function() return REG end
loadHardcoverMap = function() return MAP end
debugLog = function() end
local shown
UIManager = { show = function(_s, w) shown = w end, close = function() end }
InfoMessage = { new = function(_s, t) return t end }
Menu = { new = function(_s, t) return t end }
shelfmarkCredentialKey = function(u, n, p) return tostring(u) .. "|" .. tostring(n) .. "|" .. tostring(p) end
local NET = {}
doLogin = function() return NET.sm_ok, nil, nil, NET.sm_code end
doCwaRequest = function() return "", NET.cwa_code end
doHardcoverGraphQL = function() if NET.hc_ok then return { me = {} } end return nil, NET.hc_err end
doTestService = function() return NET.annas_ok end
package.loaded["ui/trapper"] = { wrap = function(_s, f) return f() end, dismissableRunInSubprocess = function(_s, f) return true, f() end }
Bookbridge = {}
local getRej, setRej = assert(load(io.open(W .. "/fns.lua"):read("*a")))()
local pass, fail = 0, 0
local function ck(c, m) if c then pass = pass + 1; print("PASS  " .. m) else fail = fail + 1; print("FAIL  " .. m) end end
local function bb(t)
    t = t or {}
    t.defaultDownloadDir = function() return "/mnt/us/books" end
    t.shelfmarkLoginKnownBad = function(self) return self._shelfmark_login_rejected ~= nil and self._shelfmark_login_rejected == shelfmarkCredentialKey(self.server_url, self.username, self.password) end
    return setmetatable(t, { __index = Bookbridge })
end
local function row(rows, prefix) for _, r in ipairs(rows) do if r.text:find(prefix, 1, true) == 1 then return r end end end

-- A fresh install: nothing set up, and a "Start here" row first
local rows = bb({}):collectStatusRows()
ck(rows[1].text:find("Start here", 1, true) and rows[1].action, "nothing configured: the first row is 'Start here: import settings'")
ck(row(rows, "Shelfmark").mandatory == "Not set up" and row(rows, "Calibre-Web").mandatory == "Not set up"
   and row(rows, "Hardcover").mandatory == "Not set up" and row(rows, "Readest").mandatory == "Not installed",
   "every part says 'Not set up' / 'Not installed'")

-- A configured Kindle, nothing checked yet
REG = { a = {}, b = {}, c = {} }
local ok_rs = { settings = { access_token = "t", auto_sync = true } }
local b = bb({ server_url = "http://s", username = "matt", password = "p", cwa_url = "http://c", cwa_username = "admin",
    hardcover_token = "tok", hardcover_progress_sync = true, update_url = "http://u", auto_update = true,
    ui = { readest = ok_rs }, clipboard_server = {}, download_dir = "/mnt/us/books" })
rows = b:collectStatusRows()
ck(not rows[1].text:find("Start here", 1, true), "configured: no 'Start here' row")
ck(row(rows, "Shelfmark").mandatory == "Set up", "Shelfmark: 'Set up' until checked")
ck(row(rows, "Calibre-Web").mandatory == "3 books synced", "Calibre-Web: shows the synced book count")
ck(row(rows, "Hardcover").mandatory == "Syncing", "Hardcover: 'Syncing'")
ck(row(rows, "Readest").mandatory == "Syncing", "Readest: 'Syncing' when signed in with auto sync")
ck(row(rows, "Updates").mandatory == "Automatic", "Updates: 'Automatic'")
ck(row(rows, "Phone clipboard").mandatory == "Listening on 8090", "clipboard: listening")
ck(row(rows, "Download folder").mandatory == "/mnt/us/books", "download folder shown")
for _, r in ipairs(rows) do if #r.mandatory > 22 then ck(false, "status too long: " .. r.mandatory) end end
ck(true, "no right-hand status longer than 22 characters")

-- Long download path: the end is kept, capped (the crash found on the desktop)
lfs.attributes = function() return "directory" end
b.download_dir = "/tmp/claude-1000/some/very/long/sandbox/path/books"
ck(#row(b:collectStatusRows(), "Download folder").mandatory <= 22 and row(b:collectStatusRows(), "Download folder").mandatory:sub(-5) == "books",
   "a long path is shortened to its end (never wider than 22)")

-- Things that need attention
MAP = { x = { decision = "review" }, y = { decision = "review" } }
rows = b:collectStatusRows()
ck(row(rows, "Hardcover").mandatory == "2 to review", "Hardcover: books waiting for review are counted")
MAP = {}
ok_rs.settings.auto_sync = false
rows = b:collectStatusRows()
ck(row(rows, "Readest").mandatory == "Auto sync off", "Readest: auto sync off is flagged")
local toggled = false
ok_rs.onReadestSyncToggleAutoSync = function(_s, v) toggled = v end
row(rows, "Readest").action()
ck(toggled == true, "...and tapping it turns Readest's auto sync on")
ok_rs.settings.access_token = nil
ck(row(b:collectStatusRows(), "Readest").mandatory == "Not signed in", "Readest: not signed in")
ok_rs.settings.access_token = "t"; ok_rs.settings.auto_sync = true

-- Check connections now
NET = { sm_ok = false, sm_code = 401, cwa_code = 200, hc_ok = false, hc_err = "Hardcover rejected the API token (HTTP 401)" }
b:runStatusChecks()
rows = b:collectStatusRows()
ck(row(rows, "Shelfmark").mandatory == "Wrong login", "check: Shelfmark 401 -> 'Wrong login'")
ck(b._shelfmark_login_rejected == shelfmarkCredentialKey("http://s", "matt", "p"), "...and background logins pause for those credentials")
ck(row(rows, "Calibre-Web").mandatory == "Signed in, 3 books", "check: Calibre-Web 200 -> 'Signed in'")
ck(row(rows, "Hardcover").mandatory == "Token refused" and getRej() == "tok", "check: refused token -> 'Token refused', Hardcover paused")
ck(shown and shown.title == "Bookbridge status", "the screen reopens with the results")
NET = { sm_ok = true, cwa_code = nil, hc_ok = true }
b:runStatusChecks()
rows = b:collectStatusRows()
ck(row(rows, "Shelfmark").mandatory == "Signed in" and b._shelfmark_login_rejected == nil, "check: Shelfmark OK -> 'Signed in', guard cleared")
ck(row(rows, "Calibre-Web").mandatory == "Can't reach", "check: no answer -> 'Can't reach'")
ck(row(rows, "Hardcover").mandatory == "Syncing" and getRej() == nil, "check: token accepted again -> Hardcover resumes")
NET = { sm_ok = false, sm_code = 429, cwa_code = 401, hc_ok = true }
b:runStatusChecks()
rows = b:collectStatusRows()
ck(row(rows, "Shelfmark").mandatory == "Locked -- try later" and row(rows, "Calibre-Web").mandatory == "Wrong login", "check: 429 -> 'Locked', CWA 401 -> 'Wrong login'")
b._status_checks.at = os.time() - 3600
ck(row(b:collectStatusRows(), "Shelfmark").mandatory == "Wrong login", "results older than 10 minutes are dropped (the known-bad guard still shows)")
print(pass .. " passed, " .. fail .. " failed")
os.exit(fail == 0 and 0 or 1)
LUA
