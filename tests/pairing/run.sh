#!/bin/bash
# Set up another device without a server (PAIR): reader A seals its settings
# with a fresh key and serves the blob once from its own HTTP receiver; the
# ~90-char code carries A's address, a selector and the key; reader B fetches,
# checks the MAC, imports an allowlist of fields (never the download folder),
# and is offered the companions A has. Legacy "shelfmark-pair:" codes (relay +
# one-time pad, 7 fields) still import. Offline: B's HTTP call is routed
# straight into A's request handler.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
[ -x "${KDIR:-/nonexistent}/luajit" ] || { echo "SKIP  no local KOReader (set KOREADER_DIR)"; exit 3; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
M="$REPO/bookbridge.koplugin/main.lua"
{ grep -E '^local CLIPBOARD_RECEIVER_PORT = |^local CLIP = ' "$M" | sed 's/^local //'   # (globals: the test reaches CLIP)
  awk '/^-- ===== CO begin/{f=1} f{print} f&&/^-- ===== CO end/{exit}' "$M"
  awk '/^-- ===== PAIR begin/{f=1} f{print} f&&/^-- ===== PAIR end/{exit}' "$M" | sed 's/^local PAIR = {}/PAIR = {}/'
  for f in randomBytes xorBytes stripJsonNull doPairingDownload; do awk "/^local function $f\\(/{f=1} f{print} f&&/^end\$/{exit}" "$M" | sed "s/^local function $f(/function $f(/"; done   # (globals: the test calls them too)
  for f in showSetupQrCode generateAndShowPairingQr importSettingsFromText applyPairingText _onPairRequest _onClipboardRequest _clipboardSend companionState askCompanionRestart promptPairingRelayUrl phoneButtonRow; do awk "/^function Bookbridge:$f\\(/{f=1} f{print} f&&/^end\$/{exit}" "$M"; done
} > "$W/fns.lua"
grep -q "function PAIR.seal" "$W/fns.lua" && grep -q "function Bookbridge:applyPairingText" "$W/fns.lua" || { echo "FAIL  extraction failed"; exit 1; }
cd "$KDIR" || exit 1
W="$W" ./luajit - <<'LUA'
package.path = "frontend/?.lua;common/?.lua;" .. package.path
package.cpath = "common/?.so;libs/?.so;" .. package.cpath
local W = os.getenv("W")
_ = function(s) return s end
T = require("ffi/util").template
JSON = require("json")
mime = require("mime")
ltn12 = require("ltn12")
lfs = { attributes = function() return nil end }
debugLog = function() end
getPluginDir = function() return "/nonexistent/plugins/bookbridge.koplugin" end
DataStorage = { getSettingsDir = function() return W end }
-- (KOReader's settings module only loads inside KOReader: a stand-in that
-- writes the same kind of file)
package.loaded["luasettings"] = { open = function(_c, path)
    local t = { path = path, d = {} }
    local ok, old = pcall(dofile, path); if ok and type(old) == "table" then t.d = old end
    function t:readSetting(k) return self.d[k] end
    function t:saveSetting(k, v) self.d[k] = v end
    function t:flush()
        local parts = {}
        for k, v in pairs(self.d) do parts[#parts + 1] = string.format("[%q] = %s", k, type(v) == "string" and string.format("%q", v) or tostring(v)) end
        local f = io.open(self.path, "w"); f:write("return { " .. table.concat(parts, ", ") .. " }\n"); f:close()
    end
    return t
end }
package.loaded["bookbridge.clipboard_receiver"] = {}  -- (main.lua's CLIP picks this up)
socketutil = { set_timeout = function() end, reset_timeout = function() end,
    table_sink = function() local t = {} return function(c) if c then t[#t + 1] = c end return 1 end, t end }
socket = { skip = function(d, ...) return select(d + 1, ...) end }
makeSocks5Socket = function() error("no proxy expected") end
PHONE_PAGE = "<html>{{msg}}{{t}}{{hide}}</html>"
findFocusedInputText = function() return nil end
package.loaded["util"] = { urlDecode = function(s) return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end }
local DEVICE = { isDesktop = function() return false end, isAndroid = function() return false end, isKindle = function() return true end,
    screen = { getWidth = function() return 1200 end, getHeight = function() return 1600 end } }
package.loaded["device"] = DEVICE
local msgs, CB, BD, QR, ID = {}, {}, nil, nil, nil
UIManager = { show = function(_s, w) msgs[#msgs + 1] = w end, close = function() end, nextTick = function(_s, f) f() end,
    isWidgetShown = function() return false end, restartKOReader = function() end }
InfoMessage = { new = function(_s, t) t.kind = "info"; return t end }
QRMessage = { new = function(_s, t) QR = t; t.kind = "qr"; return t end }
package.loaded["ui/widget/confirmbox"] = { new = function(_s, t) CB[#CB + 1] = t; t.kind = "confirm"; return t end }
package.loaded["ui/widget/buttondialog"] = { new = function(_s, t) BD = t; t.kind = "buttons"; return t end }
package.loaded["ui/widget/inputdialog"] = { new = function(_s, t) ID = t; t.onShowKeyboard = function() end; t.getInputText = function() return t._text end; return t end }
package.loaded["ui/trapper"] = { wrap = function(_s, f) return f() end, dismissableRunInSubprocess = function(_s, f) return true, f() end }
G_reader_settings = { _d = {}, isTrue = function(self, k) return self._d[k] == true end, readSetting = function(self, k) return self._d[k] end, saveSetting = function(self, k, v) self._d[k] = v end }
local IP = "192.168.1.23"
localAddress = function() return IP end
Bookbridge = {}
assert(load(io.open(W .. "/fns.lua"):read("*a")))()
-- A's receiver: "send" keeps the response; B's http.request hands the GET to A
local A
local RESP = {}
local function fake_server() return { send = function(_s, resp, client) client.out = resp end } end
local FETCHES = {}
http = { request = function(req)
    FETCHES[#FETCHES + 1] = req
    local host, port, path = req.url:match("^http://([^:/]+):?(%d*)(/.*)$")
    if host == "relay.example" then
        if RELAY and RELAY[path] then req.sink(RELAY[path]); req.sink(nil); return 1, 200 end
        return 1, 404
    end
    if host ~= IP then return nil, "connection refused" end
    local client = {}
    A:_onClipboardRequest("GET " .. path .. " HTTP/1.1\r\nHost: x\r\n\r\n", client)
    local code = tonumber((client.out or ""):match("^HTTP/1%.1 (%d+)"))
    local body = (client.out or ""):match("\r\n\r\n(.*)$") or ""
    req.sink(body); req.sink(nil)
    return 1, code
end }
local pass, fail = 0, 0
local function ck(c, m) if c then pass = pass + 1; print("PASS  " .. m) else fail = fail + 1; print("FAIL  " .. m) end end
local function last(kind) for i = #msgs, 1, -1 do if msgs[i].kind == kind then return msgs[i] end end end
local function reader(t)
    t = t or {}
    t.saved = {}
    t.saveAllSettings = function(self, msg) self.saved[#self.saved + 1] = msg or "" end
    t.startClipboardReceiver = function() CLIP.server = CLIP.server or fake_server() end
    t.installed = {}
    t.installCompanion = function(self, id, opts) self.installed[#self.installed + 1] = { id, opts }; return "installed" end
    t.showStatus = function(self) self.status_shown = (self.status_shown or 0) + 1 end
    t.editAnnasSettings = function() end
    return setmetatable(t, { __index = Bookbridge })
end

-- 1. the cipher
local key = randomBytes(32)
local ks = PAIR.keystream(key, 100)
ck(#ks == 100 and ks:find("[^%x]") ~= nil, "keystream: the asked-for length, binary (not hex)")
local blob = PAIR.seal("hello settings", key)
ck(blob and #blob == #"hello settings" + 16 and PAIR.open(blob, key) == "hello settings", "seal/open round trip; 16-byte MAC")
ck(PAIR.open(blob, randomBytes(32)) == nil, "a wrong key is refused")
local flipped = blob:sub(1, 3) .. string.char(bit.bxor(blob:byte(4), 1)) .. blob:sub(5)
ck(PAIR.open(flipped, key) == nil, "a flipped byte is refused (MAC)")
ck(PAIR.seal("hello settings", randomBytes(32)) ~= blob, "two keys, two ciphertexts")
ck(PAIR.unb64url(PAIR.b64url(key)) == key and not PAIR.b64url(key):find("[+/=]"), "base64url round trip, no + / =")

-- 2. A shows a code
A = reader({ server_url = "http://sm:8084", username = "u", password = "p", cwa_url = "http://cwa:8083", cwa_username = "cu", cwa_password = "cp",
    socks5_proxy = "127.0.0.1:1055", annas_download_key = "annakey", annas_tld = "gl", hardcover_token = ("x"):rep(800), hardcover_language = "en",
    hardcover_progress_sync = true, sources_order = { "zlibrary", "annasarchive", "shelfmark" }, sources_enabled = { shelfmark = false }, sources_stop_first = true,
    companions_in_ko_menu = false, ai_relay_url = "http://ai", ai_relay_token = "tok", pairing_relay_url = "",
    download_dir = "/mnt/us/A-books", annas_session = { cookie = "secret" }, annas_mirrors = { tlds = { "gd" } }, companions = { zlibrary = { version = "1" } },
    update_url = "http://my-updates", auto_update = true })
lfs.attributes = function(p, k) if p:find("zlibrary.koplugin$") or p:find("readest.koplugin$") then return "directory" end end
msgs = {}; CB = {}
A:showSetupQrCode()
ck(last("confirm") ~= nil and last("confirm").text:find("works once and expires in 5 minutes", 1, true), "A: one confirm, says what travels and that it works once")
last("confirm").ok_callback()
local text = QR and QR.text
ck(text and text:match("^bookbridge%-pair:192%.168%.1%.23:8090:%x%x%x%x%x%x%x%x:[%w%-_]+$") ~= nil, "A: the code is bookbridge-pair:<ip>:<port>:<code>:<key> (" .. tostring(text and #text) .. " chars)")
ck(text and #text < 120, "...short enough to type")
ck(last("info") and last("info").text:find(text, 1, true), "...and the text is shown under the QR for typing")
ck(CLIP.pair and CLIP.pair.expires - os.time() <= PAIR.TTL and CLIP.pair.expires - os.time() >= PAIR.TTL - 2, "A: offer kept in memory for 5 minutes")
local p = PAIR.parse(text)
local payload = JSON.decode(PAIR.open(mime.unb64(CLIP.pair.blob_b64), p.key))
ck(payload.v == 2 and payload.hardcover_token == A.hardcover_token and payload.annas_download_key == "annakey" and payload.sources_order[2] == "annasarchive"
   and payload.sources_enabled.shelfmark == false and payload.ai_relay_token == "tok" and payload.cwa_password == "cp", "payload: every allowlisted field, v=2")
ck(payload.download_dir == nil and payload.annas_session == nil and payload.annas_mirrors == nil and payload.companions == nil and payload.update_url == nil and payload.auto_update == nil,
   "payload: never the download folder, sessions, companion records or the update source")
ck(#payload.wants == 2 and payload.wants[1] == "zlibrary" and payload.wants[2] == "readest", "payload: wants = the companions A has installed")

-- 3. B imports over the Wi-Fi
lfs.attributes = function() return nil end   -- (B has no companions)
local B = reader({ download_dir = "/mnt/us/B-books", annas_session = { cookie = "old" }, session_cookie = "c", socks5_proxy = "127.0.0.1:1055" })
msgs = {}; CB = {}; FETCHES = {}
B:applyPairingText("  " .. text .. "\n")
local confirm = last("confirm")
ck(confirm and confirm.text:find("Shelfmark: http://sm:8084", 1, true) and confirm.text:find("Anna's Archive key: yes", 1, true) and confirm.text:find("Hardcover token: yes", 1, true)
   and confirm.text:find("Sources: zlibrary, annasarchive, shelfmark", 1, true), "B: the confirm lists what arrives (keys as yes/--, not their values)")
ck(FETCHES[1] and FETCHES[1].url == "http://192.168.1.23:8090/pair/" .. p.code and FETCHES[1].create == nil, "B fetched from A's address, with no SOCKS proxy")
confirm.ok_callback()
ck(B.server_url == "http://sm:8084" and B.password == "p" and B.cwa_password == "cp" and B.annas_download_key == "annakey" and B.hardcover_token == A.hardcover_token
   and B.sources_order[3] == "shelfmark" and B.sources_enabled.shelfmark == false and B.sources_stop_first == true and B.ai_relay_token == "tok", "B: A's settings are now B's")
ck(B.download_dir == "/mnt/us/B-books", "B: its own download folder is untouched")
ck(B.annas_session == nil and B.annas_mirrors == nil and B.session_cookie == nil, "B: sessions start afresh")
ck(B.socks5_proxy == "127.0.0.1:1055", "B (a Kindle): keeps the Tailscale proxy")
ck(B.saved[#B.saved] == "Settings imported.", "B: saved with 'Settings imported.'")
local offer = last("confirm")
ck(offer ~= confirm and offer.text:find("The other reader uses Z-Library and Readest. Install them here too?", 1, true), "B: offered the companions A has")
offer.ok_callback()
ck(#B.installed == 2 and B.installed[1][1] == "zlibrary" and B.installed[1][2].auto == true and B.installed[2][1] == "readest", "...Install: both installed quietly")
ck(#CB > 0 and CB[#CB].text:find("Restart now?", 1, true) and CB[#CB].text:find("Z-Library", 1, true) and CB[#CB].text:find("Readest", 1, true), "...then one restart question for both")

-- 4. one-time, expiry, wrong codes
ck(CLIP.pair == nil, "A: the offer is gone after one fetch")
msgs = {}; FETCHES = {}
B:applyPairingText(text)
ck(last("info") and last("info").text:find("already been used or has expired", 1, true), "a second fetch of the same code: already used")
A:generateAndShowPairingQr("lan"); local text2 = QR.text
CLIP.pair.expires = os.time() - 1
msgs = {}; B:applyPairingText(text2)
ck(last("info") and last("info").text:find("already been used or has expired", 1, true), "an expired offer: the same answer")
A:generateAndShowPairingQr("lan"); local text3 = QR.text
local wrong = text3:gsub(":(%x%x%x%x%x%x%x%x):", ":00000000:")
for _ = 1, PAIR.MAX_TRIES do B:applyPairingText(wrong) end
ck(CLIP.pair == nil, "ten wrong selectors: the offer is dropped")
msgs = {}; B:applyPairingText(text3)
ck(last("info") and last("info").text:find("already been used or has expired", 1, true), "...and the right one no longer works either")

-- 5. not reachable / not a code / newer plugin
IP = "10.0.0.9"; msgs = {}; A:generateAndShowPairingQr("lan"); local text4 = QR.text; IP = "192.168.1.23"
msgs = {}; B:applyPairingText(text4)
ck(last("info") and last("info").text:find("Couldn't reach the other reader at 10.0.0.9", 1, true) and last("info").text:find("same Wi%-Fi"), "A unreachable: says so, asks about the Wi-Fi")
msgs = {}; B:applyPairingText("hello there")
ck(last("info") and last("info").text == "That doesn't look like a Bookbridge pairing code.", "nonsense: not a code")
ck(PAIR.parse("bookbridge-pair:1.2.3.4:8090:abcd1234:tooshort") == nil, "a key of the wrong length is not a code")
do
    A:generateAndShowPairingQr("lan"); local t5 = QR.text; local p5 = PAIR.parse(t5)
    local newer = JSON.decode(PAIR.open(mime.unb64(CLIP.pair.blob_b64), p5.key)); newer.v = 3
    CLIP.pair.blob_b64 = mime.b64(PAIR.seal(JSON.encode(newer), p5.key))
    msgs = {}; B:applyPairingText(t5)
    ck(last("info") and last("info").text:find("newer than this one", 1, true), "a payload from a newer plugin: update this one first")
end

-- 6. the receiver's other routes are untouched; POST /pair is not a thing
do
    A:generateAndShowPairingQr("lan")
    local c = {}; A:_onClipboardRequest("POST /pair/" .. CLIP.pair.code .. " HTTP/1.1\r\n\r\n", c)
    ck(c.out:match("^HTTP/1%.1 404") ~= nil and CLIP.pair ~= nil, "POST /pair/<code>: 404, offer kept")
    c = {}; A:_onClipboardRequest("GET /clip?text=hi HTTP/1.1\r\n\r\n", c)
    ck(c.out:match("^HTTP/1%.1 200") ~= nil, "/clip still works while an offer is up")
    c = {}; A:_onClipboardRequest("GET /pair/ HTTP/1.1\r\n\r\n", c)
    ck(c.out:match("^HTTP/1%.1 404") ~= nil, "/pair/ with no code: 404")
    CLIP.pair = nil
end

-- 7. no address and no relay; address and relay -> a choice; relay-only -> relay flow
IP = nil; CLIP.server = nil
A.startClipboardReceiver = function() end
msgs = {}; A:showSetupQrCode()
ck(last("info") and last("info").text:find("Connect this reader to Wi%-Fi first"), "no address, no relay: asks for Wi-Fi")
IP = "192.168.1.23"; CLIP.server = fake_server(); A.pairing_relay_url = "http://relay.example"
BD = nil; A:showSetupQrCode()
ck(BD and BD.title:find("reach this one") and #BD.buttons == 3 and BD.buttons[1][1].text:find("Same Wi%-Fi") and BD.buttons[2][1].text:find("pairing relay"), "address and relay: a choice between them")
-- relay: the blob goes up, the code says relay
RELAY = {}
doPairingUpload = function(url, blob_b64) RELAY["/pair/cafe0001"] = JSON.encode({ ciphertext = blob_b64 }); return "cafe0001" end
msgs = {}; A:generateAndShowPairingQr("relay")
ck(QR.text:match("^bookbridge%-pair:relay:cafe0001:[%w%-_]+$") ~= nil and CLIP.pair == nil, "relay: bookbridge-pair:relay:<code>:<key>, nothing kept on A")
local B2 = reader({ download_dir = "/x" }); msgs = {}; CB = {}
B2:applyPairingText(QR.text)
ck(ID and ID.title == "Pairing relay URL", "B without a relay URL: asked for it first")
B2.pairing_relay_url = "http://relay.example"; msgs = {}; CB = {}
B2:applyPairingText(QR.text); last("confirm").ok_callback()
ck(B2.hardcover_token == A.hardcover_token and B2.download_dir == "/x", "...then imports through the relay")

-- 8. a legacy code from an older Bookbridge: relay + one-time pad, 7 fields only
do
    local plain = JSON.encode({ server_url = "http://old:8084", username = "ou", password = "op", socks5_proxy = "", cwa_url = "http://oldcwa", cwa_username = "oc", cwa_password = "ocp" })
    local pad = randomBytes(#plain)
    RELAY["/pair/01d01d01d"] = JSON.encode({ ciphertext = mime.b64(xorBytes(plain, pad)) })
    local B3 = reader({ pairing_relay_url = "http://relay.example", hardcover_token = "keepme", download_dir = "/y" })
    msgs = {}; CB = {}
    B3:applyPairingText("shelfmark-pair:01d01d01d:" .. mime.b64(pad))
    ck(last("confirm") and last("confirm").text:find("Server: http://old:8084", 1, true), "legacy code: the old confirm")
    last("confirm").ok_callback()
    ck(B3.server_url == "http://old:8084" and B3.cwa_password == "ocp" and B3.hardcover_token == "keepme" and B3.download_dir == "/y", "legacy import: the 7 server fields, nothing else touched")
end

-- 9. a desktop drops a Kindle's proxy; no companions offered when B has them
DEVICE.isDesktop = function() return true end
local B4 = reader({})
PAIR.apply(B4, { socks5_proxy = "127.0.0.1:1055", server_url = "http://s" })
ck(B4.socks5_proxy == nil and B4.server_url == "http://s", "a desktop importing a Kindle's settings drops the Tailscale proxy")
DEVICE.isDesktop = function() return false end
lfs.attributes = function(p) if p:find("koplugin$") then return "directory" end end
msgs = {}; CB = {}
ck(PAIR.offerCompanions(B4, { "zlibrary", "readest" }) == false and #CB == 0, "B already has both companions: no offer")
ck(PAIR.offerCompanions(B4, nil) == false, "no wants: no offer")

-- 10. the Reading Ledger's choices travel too, once
do
    local function mem() local t = { d = {}, flushed = 0 }
        function t:readSetting(k) return self.d[k] end
        function t:saveSetting(k, v) self.d[k] = v end
        function t:flush() self.flushed = self.flushed + 1 end
        return t end
    lfs.attributes = function(p) if p:find("ledger.koplugin$") then return "directory" end end
    local la = mem(); la.d = { runner = "rabbit", rival = "tortoise", rabbit_name = "Hops", race_style = "scoreboard", onboarded = true, animations = false, races = { x = 1 } }
    local A2 = reader({ ui = { ledger = { settings = la } } })
    local out = PAIR.collect(A2)
    ck(out.ledger and out.ledger.runner == "rabbit" and out.ledger.rabbit_name == "Hops" and out.ledger.race_style == "scoreboard" and out.ledger.onboarded == true,
        "Ledger choices go in the code: runner, rival, names, race look")
    ck(out.ledger.animations == nil and out.ledger.races == nil, "...not per-device things (animations) or race data")
    local lb = mem(); lb.d = { runner = "cat", animations = true }
    local B2 = reader({ ui = { ledger = { settings = lb } } })
    PAIR.apply(B2, out)
    ck(lb.d.runner == "rabbit" and lb.d.rival == "tortoise" and lb.d.rabbit_name == "Hops" and lb.d.animations == true and lb.flushed == 1,
        "...land in the other reader's running Ledger, keeping its own animations")
    -- the other reader has the Ledger installed but not loaded: its file
    local B3 = reader({ ui = {} })
    PAIR.apply(B3, out)
    local f = io.open(W .. "/ledger.lua"); local body = f and f:read("*a") or ""; if f then f:close() end
    ck(body:find("rabbit", 1, true) and body:find("Hops", 1, true), "...or in its settings file when it isn't running")
end

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
LUA
