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
  for f in collectStatusRows showStatus checkConnections runStatusChecks saveAndVerify autoTailscaleProxy showServiceError maybeShowFirstRunSetup editServerSettings showHostingGuide; do awk "/^function Bookbridge:$f/{f=1} f{print} f&&/^end\$/{exit}" "$M"; done
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
local msgs = {}
UIManager = { show = function(_s, w) shown = w; msgs[#msgs + 1] = w end, close = function() end }
InfoMessage = { new = function(_s, t) return t end }
Menu = { new = function(_s, t) return t end }
shelfmarkCredentialKey = function(u, n, p) return tostring(u) .. "|" .. tostring(n) .. "|" .. tostring(p) end
local NET = {}
doLogin = function() return NET.sm_ok, nil, nil, NET.sm_code end
doCwaRequest = function() return "", NET.cwa_code end
doHardcoverGraphQL = function() if NET.hc_ok then return { me = {} } end return nil, NET.hc_err end
doTestService = function() return NET.annas_ok end
local ANNAS_CALLS = 0
doAnnasSearch = function(url, key, tld, q, proxy, opts)
    ANNAS_CALLS = ANNAS_CALLS + 1; NET.annas_opts = opts
    if NET.annas == "ok" then return { {} }, 200 end
    if NET.annas == "mirror" then return nil, 502, "mirror", "MIRROR_DOWN" end
    if NET.annas == "token" then return nil, 401, "Anna's Archive rejected the download key -- check it in Settings." end
    if NET.annas == "challenge" then return nil, 401, "challenge" end
    return nil, nil, "down"
end
local SOCK_OK = false
socket = { tcp = function() return { settimeout = function() end, connect = function() return SOCK_OK and 1 or nil end, close = function() end } end }
G_reader_settings = { _d = {}, isTrue = function(self, k) return self._d[k] == true end, saveSetting = function(self, k, v) self._d[k] = v end }
local DEVICE = { isDesktop = function() return false end, isAndroid = function() return false end }
package.loaded["device"] = DEVICE
local CB = {}
package.loaded["ui/widget/confirmbox"] = { new = function(_s, t) CB[#CB + 1] = t; return t end }
local MID
MultiInputDialog = { new = function(_s, t) MID = t; t.onShowKeyboard = function() end; t.getFields = function() return t._vals end; return t end }
local ONLINE = true
package.loaded["ui/network/manager"] = { isOnline = function() return ONLINE end }
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
ck(row(rows, "Shelfmark").mandatory == "Saved", "Shelfmark: 'Saved' until checked (not the ambiguous 'Set up')")
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
-- Opening the screen with no recent result checks first, then shows "Signed in"
b._status_checks = nil
NET = { sm_ok = true, cwa_code = 200, hc_ok = true }
shown = nil
b:showStatus()
ck(shown and row(shown.item_table, "Shelfmark").mandatory == "Signed in" and row(shown.item_table, "Calibre-Web").mandatory == "Signed in, 3 books",
   "opening the screen checks the logins first when there's no recent result")
local calls = 0
local real = doLogin; doLogin = function(...) calls = calls + 1; return real(...) end
b:showStatus()
ck(calls == 0, "...but not again while the result is fresh (no repeated logins)")
b._status_checks = nil; ONLINE = false; shown = nil
b:showStatus()
ck(calls == 0 and shown and row(shown.item_table, "Shelfmark").mandatory == "Saved", "offline: opens straight away without checking")
ONLINE = true; doLogin = real

-- Verify at setup: saving a connection tests just that login and says so
b.saveAllSettings = function() end
local function last() return msgs[#msgs] and msgs[#msgs].text or "" end
NET = { sm_ok = true }
b:saveAndVerify("shelfmark")
ck(last() == "Saved -- signed in to Shelfmark as matt.", "save Shelfmark, login works: 'signed in as matt'")
NET = { sm_ok = false, sm_code = 401 }
b:saveAndVerify("shelfmark")
ck(last() == "Saved, but Shelfmark refused this username or password.", "save Shelfmark, wrong password: says so")
NET = { sm_ok = false, sm_code = 429 }
b:saveAndVerify("shelfmark")
ck(last():find("locked this account", 1, true), "save Shelfmark, account locked: says to wait")
NET = { cwa_code = 200 }
local before = calls
b:saveAndVerify("cwa")
ck(last() == "Saved -- signed in to Calibre-Web as admin.", "save Calibre-Web: signed in")
NET = { cwa_code = nil }
b:saveAndVerify("cwa")
ck(last():find("couldn't reach Calibre-Web", 1, true), "save Calibre-Web, server down: can't reach")
NET = { hc_ok = false, hc_err = "Hardcover rejected the API token (HTTP 401)" }
b:saveAndVerify("hardcover")
ck(last():find("refused this token", 1, true) and getRej() == "tok", "save Hardcover, bad token: says so and pauses Hardcover")
NET = { hc_ok = true }
b:saveAndVerify("hardcover")
ck(last() == "Saved -- Hardcover accepted the token." and getRej() == nil, "save Hardcover, good token: accepted, Hardcover resumes")
b.hardcover_token = nil
b:saveAndVerify("hardcover")
ck(last() == "Saved.", "cleared a setting: just 'Saved.', nothing to test")
b.hardcover_token = "tok"; ONLINE = false
b:saveAndVerify("cwa")
ck(last():find("Connect to Wi-Fi", 1, true), "offline: saved, with how to test later")
ONLINE = true
-- Anna's Archive: the key itself is tested (a one-result search logs in with it)
b.annas_url = "http://a"; b.annas_download_key = "k"; b.annas_tld = "gd"
NET = { annas = "ok" }
b:saveAndVerify("annas")
ck(last() == "Saved -- Anna's Archive accepted your download key.", "save Anna's Archive, good key: accepted")
ck(NET.annas_opts and NET.annas_opts.probe == true, "...via the one-result probe search (no download used)")
ck(row(b:collectStatusRows(), "Anna's Archive").mandatory == "Key works", "status: 'Key works'")
NET = { annas = "token" }; b:saveAndVerify("annas")
ck(last():find("rejected this download key", 1, true) and row(b:collectStatusRows(), "Anna's Archive").mandatory == "Key refused", "bad key: 'rejected this download key' / 'Key refused'")
NET = { annas = "mirror" }; b:saveAndVerify("annas")
ck(last():find("mirror (.gd) isn't answering", 1, true) and row(b:collectStatusRows(), "Anna's Archive").mandatory == "Mirror down", "mirror down: says which and what to try")
NET = { annas = "challenge" }; b:saveAndVerify("annas")
ck(last():find("bot check", 1, true), "bot challenge: key couldn't be tested right now")
b.annas_download_key = nil; NET = { annas_ok = true }; b:saveAndVerify("annas")
ck(last():find("Add your download key", 1, true) and row(b:collectStatusRows(), "Anna's Archive").mandatory == "No key yet", "no key: reachable, asks for the key")
-- only the saved service is tested
local logins, cwas = 0, 0
local rl, rc = doLogin, doCwaRequest
doLogin = function(...) logins = logins + 1; return rl(...) end
doCwaRequest = function(...) cwas = cwas + 1; return rc(...) end
NET = { cwa_code = 200 }
b:saveAndVerify("cwa")
ck(logins == 0 and cwas == 1, "saving Calibre-Web tests only Calibre-Web (no Shelfmark login)")
-- Tailscale proxy fills itself in
local p = bb({ server_url = "http://100.64.0.10:8084", saveAllSettings = function() end })
SOCK_OK = true
ck(p:autoTailscaleProxy() == true and p.socks5_proxy == "127.0.0.1:1055", "Tailscale proxy listening + tailnet server: filled in")
local q = bb({ server_url = "http://192.168.1.5:8084", saveAllSettings = function() end })
ck(q:autoTailscaleProxy() == false and q.socks5_proxy == nil, "LAN server address: left alone")
local fresh_kindle = bb({ saveAllSettings = function() end })
ck(fresh_kindle:autoTailscaleProxy("100.64.0.10") == true and fresh_kindle.socks5_proxy == "127.0.0.1:1055", "brand-new reader importing from a Tailscale address: proxy filled in first")
SOCK_OK = false
local r = bb({ server_url = "http://100.64.0.10:8084", saveAllSettings = function() end })
ck(r:autoTailscaleProxy() == false and r.socks5_proxy == nil, "no proxy listening: left alone")
SOCK_OK = true
DEVICE.isDesktop = function() return true end
ck(bb({ server_url = "http://100.64.0.10:8084", saveAllSettings = function() end }):autoTailscaleProxy() == false, "desktop: never")
DEVICE.isDesktop = function() return false end
ck(bb({ server_url = "http://100.64.0.10:8084", socks5_proxy = "10.0.0.1:9", saveAllSettings = function() end }):autoTailscaleProxy() == false, "a proxy already set: never overwritten")
ck(bb({ server_url = "http://100.64.0.10:8084", _proxy_autoset_off = true, saveAllSettings = function() end }):autoTailscaleProxy() == false, "emptied on purpose in Advanced: not refilled")
SOCK_OK = false

-- Errors from what you just did offer Status & setup
CB = {}
local e = bb({})
e:showServiceError("Couldn't reach Shelfmark.")
ck(CB[1] and CB[1].text == "Couldn't reach Shelfmark." and CB[1].ok_text == "Status & setup" and CB[1].cancel_text == "Close", "an error offers 'Status & setup' / 'Close'")

-- First start with nothing set up opens Status & setup, once
local sched = {}
UIManager.scheduleIn = function(_s, d, f) sched[#sched + 1] = f end
local fresh = bb({ ui = {} })
fresh:maybeShowFirstRunSetup(); fresh:maybeShowFirstRunSetup()
ck(#sched == 1, "first start, nothing configured: Status & setup opens once")
bb({ ui = {}, server_url = "http://s" }):maybeShowFirstRunSetup()
bb({ ui = { document = {} } }):maybeShowFirstRunSetup()
ck(#sched == 1, "configured, or in a book: never")

-- What you need to host: reachable from the screen, names every piece
local TV
package.loaded["ui/widget/textviewer"] = { new = function(_s, x) TV = x; return x end }
local hg = row(bb({ server_url = "http://s" }):collectStatusRows(), "What you need to host")
ck(hg ~= nil, "Status & setup has a 'What you need to host' line")
hg.action()
ck(TV and TV.text:find("REQUIRED", 1, true) and TV.text:find("Shelfmark", 1, true) and TV.text:find("shelfmark-stack", 1, true)
   and TV.text:find("annas-archive-api", 1, true) and TV.text:find("Readest", 1, true), "...which names every piece, what's required, and the one-command stack")
-- The Shelfmark dialog asks only for what a new user needs
bb({ server_url = "http://s", username = "u", password = "p" }):editServerSettings()
ck(MID and #MID.fields == 3, "Shelfmark settings: address, username, password only")
local btns = {}; for _, x in ipairs(MID.buttons[1]) do btns[#btns + 1] = x.text end
ck(table.concat(btns, ",") == "Cancel,Advanced,Apply", "...with an Advanced button for the proxy and relay")
print(pass .. " passed, " .. fail .. " failed")
os.exit(fail == 0 and 0 or 1)
LUA
