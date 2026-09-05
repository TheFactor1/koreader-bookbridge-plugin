--[[--
Search and request books/audiobooks from a self-hosted Shelfmark server
(https://github.com/calibrain/shelfmark) directly from KOReader.

Talks to Shelfmark's JSON REST API using the same session-cookie login a
browser would use. Only requests the book -- the actual file still arrives
on the device the normal way, via your existing OPDS catalog once
Calibre-Web-Automated (or whatever ingests Shelfmark's downloads) has
imported it.

Designed for home WiFi / Tailscale use, not for reaching the server through
an interactive-login gateway (e.g. Cloudflare Access) -- there is nothing
here that could complete that kind of login flow.

Several patterns here were learned from reading zlibrary.koplugin's own
source (https://github.com/ZlibraryKO/zlibrary.koplugin), a KOReader plugin
already installed on this device -- primarily written by ZlibraryKO
(https://github.com/ZlibraryKO), the account behind the large majority of
its commits, per the repo's own contributor history; the LICENSE and
README name no individual, so this is the closest attribution actually
available. Patterns borrowed: embedding cover images in a Menu row via the
stock item.state field, the freed-row-widget crash a Menu repaint can hit
if that widget isn't rebuilt fresh on every update, KOReader's
TextBoxWidget bold-span markup for row titles, and downloading-into-a-temp-
file-then-polling-its-size for a live progress bar without needing the
download itself to report progress. Credit where it's due -- none of this
would have been found by guessing.

@module koplugin.shelfmark
]]

local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local JSON = require("json")
local bit = require("bit")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local http = require("socket.http")
local https = require("ssl.https")
local lfs = require("libs/libkoreader-lfs")
local ltn12 = require("ltn12")
local logger = require("logger")
local mime = require("mime")
local socket = require("socket")
local socketurl = require("socket.url")
local socketutil = require("socketutil")
local _ = require("gettext")
local T = ffiUtil.template

local Shelfmark = WidgetContainer:extend{
    name = "shelfmark",
    settings_file = DataStorage:getSettingsDir() .. "/shelfmark.lua",
    sm_settings = nil,
    session_cookie = nil,
}

-- Superseded: network requests now run through Trapper (see apiRequest
-- below), which moves the actual blocking work into a subprocess instead
-- of merely delaying when it starts on the main thread. Every entry point
-- that used to call deferBlocking(fn) now calls Trapper:wrap(fn) instead.

-- ===== settings =====

function Shelfmark:loadSettings()
    if not Shelfmark.settings then
        Shelfmark.settings = LuaSettings:open(self.settings_file)
        if not next(Shelfmark.settings.data) then
            Shelfmark.settings.data = { shelfmark = {} }
        end
    end
    self.sm_settings = Shelfmark.settings
    self.server_url = self.sm_settings.data.shelfmark.server_url
    self.username = self.sm_settings.data.shelfmark.username
    self.password = self.sm_settings.data.shelfmark.password
    self.socks5_proxy = self.sm_settings.data.shelfmark.socks5_proxy
    -- CWA (Calibre-Web-Automated) is a separate server with its own login --
    -- only needed for "My requests" to jump straight to a delivered book's
    -- entry in CWA's OPDS catalog and download it, since Shelfmark itself
    -- has no record of where a delivered file ended up (see downloadFromCwa).
    self.cwa_url = self.sm_settings.data.shelfmark.cwa_url
    self.cwa_username = self.sm_settings.data.shelfmark.cwa_username
    self.cwa_password = self.sm_settings.data.shelfmark.cwa_password
    -- Where saveCwaEntry() (the "My requests" tap-to-download) writes the
    -- file. Defaults to a folder inside KOReader's own app dir, which is
    -- out of the way of any actual library/documents folder the device
    -- browses by default -- customizable so it can go straight into
    -- wherever books are actually kept instead of needing a manual move.
    self.download_dir = self.sm_settings.data.shelfmark.download_dir
    -- Only used by the QR-code / paste-based settings transfer between
    -- two devices -- see showSetupQrCode/importSettingsFromText. Prompted
    -- for lazily the first time either is used rather than living in one
    -- of the main settings dialogs, since it's a one-off/rare setting.
    self.pairing_relay_url = self.sm_settings.data.shelfmark.pairing_relay_url
    -- The annas-archive-api companion service (github.com/bitesized/
    -- annas-archive-api) -- see the note above doAnnasSearch for why this
    -- exists alongside Shelfmark's own direct_download integration. No
    -- hardcoded default here on purpose: this used to fall back to a real
    -- URL/donator key baked into the source, which meant they sat in
    -- plain text in every clone of this (once-private) repo -- see
    -- editAnnasSettings below for where these are actually configured now.
    self.annas_url = self.sm_settings.data.shelfmark.annas_url
    self.annas_download_key = self.sm_settings.data.shelfmark.annas_download_key
    self.annas_tld = self.sm_settings.data.shelfmark.annas_tld or "gd"
    -- Hardcover (hardcover.app) -- a public HTTPS GraphQL API, unlike Anna's
    -- Archive/CWA/the Shelfmark server, so no self-hosted companion or
    -- SOCKS5 proxy is needed for this one; it's reachable directly.
    self.hardcover_token = self.sm_settings.data.shelfmark.hardcover_token
end

function Shelfmark:defaultDownloadDir()
    return DataStorage:getFullDataDir() .. "/shelfmark_downloads"
end

function Shelfmark:init()
    self:loadSettings()
    self.ui.menu:registerToMainMenu(self)
    self:registerFileDialogButtons()
end

-- Writes every self.* setting field currently in memory -- shared by both
-- settings dialogs below, since each only edits its own subset of fields
-- but saveSetting() replaces the whole "shelfmark" table wholesale, not
-- a merge. Splitting one 8-field dialog into two 4-field ones was itself
-- the fix for the on-screen keyboard covering the lower fields/Apply
-- button on a Kindle-size screen -- confirmed live via screenshot.
function Shelfmark:saveAllSettings(msg)
    self.sm_settings:saveSetting("shelfmark", {
        server_url = self.server_url,
        username = self.username,
        password = self.password,
        socks5_proxy = self.socks5_proxy,
        cwa_url = self.cwa_url,
        cwa_username = self.cwa_username,
        cwa_password = self.cwa_password,
        download_dir = self.download_dir,
        pairing_relay_url = self.pairing_relay_url,
        annas_url = self.annas_url,
        annas_download_key = self.annas_download_key,
        annas_tld = self.annas_tld,
        hardcover_token = self.hardcover_token,
    })
    self.sm_settings:flush()
    self.session_cookie = nil -- force re-login with new creds
    UIManager:show(InfoMessage:new{ text = msg, timeout = 2 })
end

function Shelfmark:editServerSettings()
    self.settings_dialog = MultiInputDialog:new{
        title = _("Shelfmark settings"),
        fields = {
            { text = self.server_url, hint = _("Server URL, e.g. http://shelfmark:8084") },
            { text = self.username, hint = _("Username") },
            { text = self.password, text_type = "password", hint = _("Password") },
            {
                text = self.socks5_proxy,
                hint = _("SOCKS5 proxy host:port (optional, e.g. 127.0.0.1:1055 for Tailscale userspace mode)"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.settings_dialog)
                    end,
                },
                {
                    text = _("Apply"),
                    callback = function()
                        local fields = self.settings_dialog:getFields()
                        self.server_url = fields[1]:gsub("/*$", "")
                        self.username = fields[2]
                        self.password = fields[3]
                        self.socks5_proxy = fields[4] ~= "" and fields[4] or nil
                        UIManager:close(self.settings_dialog)
                        self:saveAllSettings(_("Saved. You'll be logged in on your next search or request."))
                    end,
                },
            },
        },
    }
    UIManager:show(self.settings_dialog)
    self.settings_dialog:onShowKeyboard()
end

function Shelfmark:editCwaSettings()
    self.cwa_settings_dialog = MultiInputDialog:new{
        title = _("CWA settings"),
        fields = {
            { text = self.cwa_url, hint = _("CWA URL, optional -- e.g. http://cwa:8083 (for 'My requests' download)") },
            { text = self.cwa_username, hint = _("CWA username (optional)") },
            { text = self.cwa_password, text_type = "password", hint = _("CWA password (optional)") },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.cwa_settings_dialog)
                    end,
                },
                {
                    text = _("Apply"),
                    callback = function()
                        local fields = self.cwa_settings_dialog:getFields()
                        self.cwa_url = fields[1] ~= "" and fields[1]:gsub("/*$", "") or nil
                        self.cwa_username = fields[2] ~= "" and fields[2] or nil
                        self.cwa_password = fields[3] ~= "" and fields[3] or nil
                        UIManager:close(self.cwa_settings_dialog)
                        self:saveAllSettings(_("Saved."))
                    end,
                },
            },
        },
    }
    UIManager:show(self.cwa_settings_dialog)
    self.cwa_settings_dialog:onShowKeyboard()
end

function Shelfmark:editAnnasSettings()
    self.annas_settings_dialog = MultiInputDialog:new{
        title = _("Anna's Archive settings"),
        fields = {
            { text = self.annas_url, hint = _("annas-archive-api URL, e.g. http://host:8087") },
            { text = self.annas_download_key, text_type = "password", hint = _("Donator download key (optional)") },
            { text = self.annas_tld, hint = _("Mirror TLD, e.g. gd (leave blank for default)") },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.annas_settings_dialog)
                    end,
                },
                {
                    text = _("Apply"),
                    callback = function()
                        local fields = self.annas_settings_dialog:getFields()
                        self.annas_url = fields[1] ~= "" and fields[1]:gsub("/*$", "") or nil
                        self.annas_download_key = fields[2] ~= "" and fields[2] or nil
                        self.annas_tld = fields[3] ~= "" and fields[3] or "gd"
                        UIManager:close(self.annas_settings_dialog)
                        self:saveAllSettings(_("Saved."))
                    end,
                },
            },
        },
    }
    UIManager:show(self.annas_settings_dialog)
    self.annas_settings_dialog:onShowKeyboard()
end

-- hardcover.app account token, used to log reading status and follow
-- authors. Generate one at hardcover.app -> Account Settings -> API Tokens.
function Shelfmark:editHardcoverSettings()
    self.hardcover_settings_dialog = MultiInputDialog:new{
        title = _("Hardcover settings"),
        fields = {
            {
                description = _("Get a token at hardcover.app/account/api"),
                text = self.hardcover_token,
                text_type = "password",
                hint = _("Hardcover API token"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.hardcover_settings_dialog)
                    end,
                },
                {
                    text = _("Apply"),
                    callback = function()
                        local fields = self.hardcover_settings_dialog:getFields()
                        self.hardcover_token = fields[1] ~= "" and fields[1] or nil
                        UIManager:close(self.hardcover_settings_dialog)
                        self:saveAllSettings(_("Saved."))
                    end,
                },
            },
        },
    }
    UIManager:show(self.hardcover_settings_dialog)
    self.hardcover_settings_dialog:onShowKeyboard()
end

-- Folder picker for the tap-to-download save location, in place of typing
-- a raw path -- easy to get wrong (confirmed live: typed "/mnt/books",
-- which doesn't exist on this device; the real library folder turned out
-- to be "/mnt/us/books", not the "/mnt/us/documents" this plugin guessed
-- at from what else was sitting there). Browsing and long-pressing the
-- actual folder sidesteps needing to already know its exact path.
function Shelfmark:chooseDownloadDir()
    local PathChooser = require("ui/widget/pathchooser")
    local start_path = self.download_dir or self:defaultDownloadDir()
    if lfs.attributes(start_path, "mode") ~= "directory" then
        start_path = "/mnt/us"
    end
    -- FileChooser (which PathChooser is built on) hides the "up a level"
    -- row whenever the current path exactly equals KOReader's own global
    -- home_dir *and* "Lock home folder" is on -- confirmed live via
    -- screenshot (only "Long-press here to choose current folder" showed,
    -- no "../" row, "Page 1 of 1") plus settings.reader.lua on this
    -- device: home_dir is /mnt/us/books with lock_home_folder = true,
    -- exactly the folder this was starting in. That's a global KOReader
    -- setting the user has for their own file manager, not something to
    -- silently work around by disabling it -- so instead, start one level
    -- up (the current folder's parent) so the picker never opens exactly
    -- on the locked path in the first place; navigating back down into it
    -- from there works fine, it's only that one exact starting path that
    -- gets the up-row suppressed.
    if G_reader_settings:isTrue("lock_home_folder")
        and start_path == G_reader_settings:readSetting("home_dir")
    then
        start_path = start_path:match("^(.*)/[^/]+$") or "/mnt/us"
    end
    local path_chooser = PathChooser:new{
        title = _("Long-press the folder to use for downloads"),
        path = start_path,
        select_directory = true,
        select_file = false,
        show_files = false,
        onConfirm = function(new_path)
            self.download_dir = new_path:gsub("/*$", "")
            self:saveAllSettings(T(_("Download folder set to %1"), self.download_dir))
        end,
    }
    UIManager:show(path_chooser)
end

-- ===== HTTP / API plumbing =====

-- Pulls just the name=value out of a Set-Cookie header, ignoring
-- attributes like Path/HttpOnly/SameSite/Expires -- we only need the one
-- Flask session cookie, not a general-purpose cookie jar.
local function extractSessionCookie(headers)
    if not headers then return nil end
    for key, value in pairs(headers) do
        if key:lower() == "set-cookie" then
            local pair = value:match("^([^;]+)")
            if pair then return pair end
        end
    end
    return nil
end

-- Everything from here down to doApiRequest() runs inside a forked
-- subprocess (see Shelfmark:apiRequest below) -- plain functions taking
-- explicit arguments rather than methods, since a fork's child memory is a
-- copy: mutating `self.session_cookie` inside the child would never be
-- visible back in the parent. The cookie flows through return values
-- instead, and Shelfmark:apiRequest applies it to `self` once the
-- subprocess has actually returned to the parent.

-- KOReader's JSON library (rapidjson) represents a decoded JSON `null` as
-- a sentinel value that is not a plain nil -- confirmed live: it's what
-- printed as "function: 0x..." in an earlier list-display bug (Lua's
-- default tostring() only produces that exact format for a real function
-- value). That alone was survivable when everything ran in-process, but
-- now that responses have to cross the Trapper subprocess boundary,
-- LuaJIT's string.buffer serializer explicitly refuses to serialize
-- functions/userdata/threads at all -- so ANY response containing a null
-- field (nearly all of them; most BookMetadata fields are optional)
-- silently produced an empty, undecodable response, with no visible
-- error: exactly the "searching does not bring up anything" symptom.
-- Replaced with `false` rather than removed, so array positions/indices
-- are never disturbed, and because every consumer in this file already
-- type-checks fields it cares about (e.g. `type(x) == "number"`) rather
-- than just truthy-checking them, `false` is treated identically to
-- "absent" everywhere that matters.
local function stripJsonNull(value, seen)
    local t = type(value)
    if t == "function" or t == "userdata" or t == "thread" then
        return false
    end
    if t ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] then return value end
    seen[value] = true
    for k, v in pairs(value) do
        value[k] = stripJsonNull(v, seen)
    end
    return value
end

-- Low-level request. `body` (if given) is a Lua table, JSON-encoded and
-- sent with Content-Type: application/json. Returns decoded JSON body (or
-- nil), the HTTP status code, the cookie to use from now on (unchanged if
-- the response didn't set a new one), and an error string on a
-- connection-level failure.
-- Plain file, not the logger module -- this runs inside the subprocess
-- (no UI, and no confirmation logger output actually reaches anywhere the
-- user can read without ADB set up), so writing directly to a file both
-- of us can inspect is the only debug channel actually available here.
-- Appends across sessions; delete the file to clear it.
-- Bumped by hand on any release tagged in the repo -- there's no build
-- step to derive this from git, so it has to be kept in sync manually
-- (matches the tag pushed via `gh release create`, e.g. this is "0.3.0"
-- for tag "v0.3.0").
local PLUGIN_VERSION = "0.3.0"
local UPDATE_REPO = "TheFactor1/koreader-shelfmark-plugin"

-- This file's own directory on disk, derived from the currently-executing
-- chunk's source rather than hardcoded -- kindle and kindle-pw don't
-- actually install to the same absolute path in every case, and this is
-- also how the self-update code below finds where to write the files it
-- downloads.
local function getPluginDir()
    local src = debug.getinfo(1, "S").source:gsub("^@", "")
    return src:match("^(.*)/[^/]+$") or "."
end

local DEBUG_LOG_PATH = DataStorage:getSettingsDir() .. "/shelfmark-debug.log"
local function debugLog(msg)
    local ok, f = pcall(io.open, DEBUG_LOG_PATH, "a")
    if ok and f then
        f:write(os.date("%Y-%m-%d %H:%M:%S") .. "  " .. tostring(msg) .. "\n")
        f:close()
    end
end

-- Registry of books this plugin has downloaded, keyed by CWA's uuid --
-- read by a separate homeserver-side script (shelfmark-kindle-sync in
-- homeserver-configs/scripts/) that polls CWA for metadata changes and
-- overwrites the file in place when it finds one, so an edit made in CWA
-- eventually reaches an already-downloaded copy without a manual
-- redownload. This plugin only ever writes to it; the sync script is the
-- only other reader/writer, over SSH, while the Kindle is on the LAN.
-- Same registry file the homeserver-side shelfmark-kindle-sync script
-- reads/writes over SSH -- shapes are compatible (that script only reads
-- entry.path/entry.title and ignores anything else), so both can operate
-- on it: the SSH-based script for the Kindle on its cron schedule, and
-- this in-plugin version (loadSyncRegistry/saveSyncRegistry/syncLibrary
-- below) for any device -- Android included -- where SSH access was
-- never set up at all.
local SYNC_REGISTRY_PATH = DataStorage:getSettingsDir() .. "/shelfmark_synced_books.json"

local function loadSyncRegistry()
    local f = io.open(SYNC_REGISTRY_PATH, "r")
    if not f then return {} end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then return {} end
    local ok, decoded = pcall(JSON.decode, content)
    if ok and type(decoded) == "table" then return decoded end
    return {}
end

local function saveSyncRegistry(registry)
    local out = io.open(SYNC_REGISTRY_PATH, "w")
    if not out then return false end
    out:write(JSON.encode(registry))
    out:close()
    return true
end

-- Requests this device has submitted and is still waiting to hear back on,
-- keyed by Shelfmark's own numeric request id (as a string -- JSON object
-- keys are always strings, and this round-trips through JSON.encode/decode
-- on every save/load anyway) -> the book title, so the on-device
-- notification can name what's ready without a second API round-trip.
local PENDING_NOTIFY_PATH = DataStorage:getSettingsDir() .. "/shelfmark_pending_notify.json"

local function loadPendingNotifyList()
    local f = io.open(PENDING_NOTIFY_PATH, "r")
    if not f then return {} end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then return {} end
    local ok, decoded = pcall(JSON.decode, content)
    if ok and type(decoded) == "table" then return decoded end
    return {}
end

local function savePendingNotifyList(list)
    local out = io.open(PENDING_NOTIFY_PATH, "w")
    if not out then return false end
    out:write(JSON.encode(list))
    out:close()
    return true
end

local function registerSyncedBook(uuid, path, title)
    if not uuid or uuid == "" then return end
    local registry = loadSyncRegistry()
    registry[uuid] = { path = path, title = title }
    saveSyncRegistry(registry)
end

-- Minimal SOCKS5 client (CONNECT command, no-auth only) -- for reaching a
-- Shelfmark instance over Tailscale from a device running Tailscale in
-- userspace-networking mode, where the OS has no route to 100.x.x.x
-- addresses at all and only this local proxy can reach tailnet peers.
-- LuaSocket has no built-in SOCKS5 support, but http.request accepts a
-- `create` function that must return a socket-like object; LuaSocket then
-- calls `:connect(host, port)` on it with the real destination itself. This
-- wraps a normal socket.tcp() (already timeout-patched by socketutil, see
-- above) and intercepts just that one call: connect to the proxy instead,
-- speak the SOCKS5 handshake to establish a tunnel to the real destination,
-- then hand the same live connection back for LuaSocket to use normally --
-- every other method (send/receive/close/settimeout/...) just delegates
-- straight through to the real socket.
-- LuaSocket's send() can do a partial write and returns how many bytes
-- actually went out (or nil, err, last_byte_sent on a partial failure) --
-- it's the caller's job to loop until everything is sent. The SOCKS5
-- handshake bytes are short, but not sending this loop is exactly the kind
-- of bug that only shows up against a real socket, never a mock that just
-- assumes a bare send() always succeeds in full.
local function sendAll(sock, data)
    local start = 1
    while start <= #data do
        local sent, err, last = sock:send(data, start)
        if sent then
            start = sent + 1
        elseif last then
            start = last + 1
        else
            return nil, err
        end
    end
    return true
end

local function makeSocks5Socket(proxy_host, proxy_port)
    local real = socket.tcp()
    local wrapper = {}

    function wrapper:connect(dest_host, dest_port)
        local ok, err = real:connect(proxy_host, proxy_port)
        if not ok then return nil, "socks5 proxy unreachable: " .. tostring(err) end

        -- Greeting: version 5, 1 auth method offered, method 0 = no-auth.
        local send_ok, send_err = sendAll(real, "\5\1\0")
        if not send_ok then return nil, "socks5 greeting send failed: " .. tostring(send_err) end
        local greet, greet_err = real:receive(2)
        if not greet or #greet < 2 then
            return nil, "socks5 greeting failed: " .. tostring(greet_err)
        end
        if greet:byte(1) ~= 5 or greet:byte(2) ~= 0 then
            return nil, "socks5 proxy requires auth or is not SOCKS5"
        end

        -- CONNECT request. Tailscale addresses are always numeric IPv4, so
        -- that's the only case that actually needs to work -- the domain
        -- name fallback (atyp 3) exists for defensiveness, not because
        -- this path is expected to see one.
        local a, b, c, d = dest_host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
        local atyp, addr_bytes
        if a then
            atyp = 1
            addr_bytes = string.char(tonumber(a), tonumber(b), tonumber(c), tonumber(d))
        else
            atyp = 3
            addr_bytes = string.char(#dest_host) .. dest_host
        end
        local port_bytes = string.char(math.floor(dest_port / 256) % 256, dest_port % 256)
        local conn_send_ok, conn_send_err = sendAll(real, string.char(5, 1, 0, atyp) .. addr_bytes .. port_bytes)
        if not conn_send_ok then return nil, "socks5 connect-request send failed: " .. tostring(conn_send_err) end

        -- Reply: version, reply code, reserved, bound-address type (4 bytes
        -- fixed header), then a variable-length bound address to discard.
        local hdr, hdr_err = real:receive(4)
        if not hdr or #hdr < 4 then
            return nil, "socks5 connect reply failed: " .. tostring(hdr_err)
        end
        if hdr:byte(2) ~= 0 then
            return nil, "socks5 connect refused, code " .. tostring(hdr:byte(2))
        end
        local reply_atyp = hdr:byte(4)
        if reply_atyp == 1 then
            real:receive(4 + 2) -- IPv4 + port
        elseif reply_atyp == 4 then
            real:receive(16 + 2) -- IPv6 + port
        elseif reply_atyp == 3 then
            local lenb = real:receive(1)
            if lenb then real:receive(lenb:byte(1) + 2) end
        end

        return 1 -- LuaSocket connect() success convention
    end

    setmetatable(wrapper, {
        __index = function(_, key)
            return function(_, ...) return real[key](real, ...) end
        end,
    })
    return wrapper
end

local function doRawRequest(server_url, cookie, method, path, body, socks5_proxy, block_timeout, total_timeout)
    if not server_url or server_url == "" then
        return nil, nil, cookie, _("Shelfmark server URL isn't set -- check Settings.")
    end

    local headers = { ["Accept"] = "application/json" }
    if cookie then
        headers["Cookie"] = cookie
    end

    local body_json
    if body then
        body_json = JSON.encode(body)
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#body_json)
    end

    local url = server_url .. path
    debugLog("-> " .. method .. " " .. url)

    -- No timeout was ever set before this -- LuaSocket blocks forever by
    -- default, so a stalled connection (of any kind: DNS, TCP connect, a
    -- server that accepts the connection but never responds) had no way
    -- to ever give up, which is the likely cause of it sitting on "Talking
    -- to Shelfmark..." indefinitely. block_timeout bounds a single stalled
    -- read; total_timeout bounds the whole request once data starts
    -- arriving (needs socketutil.table_sink, not plain ltn12.sink.table,
    -- to actually be honored -- see socketutil.lua's own comment on why
    -- block_timeout alone is not enough). 15/45 is the default, right for
    -- login/status/metadata-search calls (every one of those has
    -- consistently finished in 1-10s in real use) -- but /api/releases can
    -- legitimately run far longer than that: Shelfmark's own docs say a
    -- release search that needs a fresh Anna's Archive bot-challenge solve
    -- can take 60-120s on a cold cache, and its own server-side search
    -- budget is 300s specifically to accommodate that. Confirmed live: a
    -- real release search hit exactly this and got cut off by this
    -- 45s default with "Request timed out" -- the server would likely have
    -- answered fine given more room. browseReleases passes a longer
    -- override; everything else keeps the tight default so a genuinely
    -- dead connection on those still fails fast.
    socketutil:set_timeout(block_timeout or 15, total_timeout or 45)
    local sink, sink_table = socketutil.table_sink()

    local request = {
        method = method,
        url = url,
        headers = headers,
        sink = sink,
    }
    if body_json then
        request.source = ltn12.source.string(body_json)
    end
    if socks5_proxy and socks5_proxy ~= "" then
        local proxy_host, proxy_port = socks5_proxy:match("^([^:]+):(%d+)$")
        if proxy_host then
            request.create = function() return makeSocks5Socket(proxy_host, tonumber(proxy_port)) end
        else
            debugLog("<- invalid socks5_proxy setting, ignoring: " .. socks5_proxy)
        end
    end

    local ok, code, resp_headers = pcall(function()
        return socket.skip(1, http.request(request))
    end)
    socketutil:reset_timeout()

    if not ok then
        debugLog("<- connection error: " .. tostring(code))
        return nil, nil, cookie, _("Couldn't reach the Shelfmark server -- are you on your home network?")
    end
    if code == socketutil.TIMEOUT_CODE or code == socketutil.SINK_TIMEOUT_CODE then
        debugLog("<- timed out: " .. tostring(code))
        return nil, nil, cookie, _("Request to Shelfmark timed out.")
    end
    debugLog("<- HTTP " .. tostring(code))

    local new_cookie = extractSessionCookie(resp_headers) or cookie

    local content = table.concat(sink_table)
    debugLog("<- body length " .. tostring(#content))
    local decoded
    if content ~= "" then
        local decode_ok, result = pcall(JSON.decode, content)
        if decode_ok then
            decoded = stripJsonNull(result)
        else
            debugLog("<- JSON decode failed: " .. tostring(result))
        end
    end

    return decoded, code, new_cookie
end

-- Returns (true, cookie) on success, or (false, nil, error_string).
local function doLogin(server_url, username, password, socks5_proxy)
    local resp, code, cookie = doRawRequest(server_url, nil, "POST", "/api/auth/login", {
        username = username,
        password = password,
    }, socks5_proxy)
    if code == 200 and resp and resp.success ~= false then
        return true, cookie
    end
    local err = resp and resp.error or _("Login failed -- check your Shelfmark username/password in Settings.")
    return false, nil, err
end

-- The full operation: log in first if we don't have a session yet, do the
-- request, retry once on 401 in case the session expired mid-use. Returns
-- (decoded_body, http_code, cookie_to_remember, error_string).
local function doApiRequest(server_url, username, password, cookie, method, path, body, socks5_proxy, block_timeout, total_timeout)
    if not cookie then
        if not username or username == "" then
            return nil, nil, nil, _("No Shelfmark username set -- check Settings.")
        end
        local ok, new_cookie, login_err = doLogin(server_url, username, password, socks5_proxy)
        if not ok then return nil, nil, nil, login_err end
        cookie = new_cookie
    end

    local resp, code, new_cookie, err = doRawRequest(server_url, cookie, method, path, body, socks5_proxy, block_timeout, total_timeout)
    if err then return nil, nil, cookie, err end
    cookie = new_cookie

    if code == 401 then
        local ok, relog_cookie, login_err = doLogin(server_url, username, password, socks5_proxy)
        if not ok then return nil, nil, nil, login_err end
        cookie = relog_cookie
        resp, code, new_cookie, err = doRawRequest(server_url, cookie, method, path, body, socks5_proxy, block_timeout, total_timeout)
        if err then return nil, nil, cookie, err end
        cookie = new_cookie
    end

    return resp, code, cookie
end

-- CWA (Calibre-Web-Automated) plumbing -- a completely separate server
-- from Shelfmark, with its own plain HTTP Basic Auth (no session cookie),
-- used only so "My requests" can jump straight to a delivered book's OPDS
-- entry and download it. Shelfmark itself has no record of where a
-- delivered file ends up (see the note on Shelfmark:downloadFromCwa), so
-- this is the only way to close that loop from inside this plugin.

-- Returns the raw response body (a string; not JSON) plus the HTTP code.
local function doCwaRequest(cwa_url, username, password, path, socks5_proxy)
    if not cwa_url or cwa_url == "" then
        debugLog("[cwa] no cwa_url configured, aborting")
        return nil, nil, _("CWA URL isn't set -- add it under Shelfmark Settings.")
    end
    local headers = {}
    if username and username ~= "" then
        headers["Authorization"] = "Basic " .. mime.b64(username .. ":" .. (password or ""))
    end

    local url = cwa_url .. path
    debugLog("[cwa] -> GET " .. url)

    socketutil:set_timeout(15, 45)
    local sink, sink_table = socketutil.table_sink()
    local request = { method = "GET", url = url, headers = headers, sink = sink }
    if socks5_proxy and socks5_proxy ~= "" then
        local proxy_host, proxy_port = socks5_proxy:match("^([^:]+):(%d+)$")
        if proxy_host then
            request.create = function() return makeSocks5Socket(proxy_host, tonumber(proxy_port)) end
        end
    end

    local ok, code = pcall(function()
        return socket.skip(1, http.request(request))
    end)
    socketutil:reset_timeout()

    if not ok then
        debugLog("[cwa] <- connection error: " .. tostring(code))
        return nil, nil, _("Couldn't reach CWA -- check the CWA URL in Settings.")
    end
    if code == socketutil.TIMEOUT_CODE or code == socketutil.SINK_TIMEOUT_CODE then
        debugLog("[cwa] <- timed out: " .. tostring(code))
        return nil, nil, _("Request to CWA timed out.")
    end
    debugLog("[cwa] <- HTTP " .. tostring(code) .. ", body length " .. tostring(#table.concat(sink_table)))
    return table.concat(sink_table), code
end

-- Same idea, but streams straight to a file instead of building the whole
-- response up in memory first -- books can be a lot bigger than any JSON
-- response this plugin otherwise deals with. socketutil.file_sink (used
-- instead of plain ltn12.sink.file) is what makes the total_timeout above
-- actually apply to a slow/stalled download, not just to the JSON-style
-- requests -- see socketutil.lua's own comment on why the plain sink alone
-- can't enforce it.
local function doCwaFileDownload(cwa_url, username, password, path, socks5_proxy, save_path)
    if not cwa_url or cwa_url == "" then
        debugLog("[cwa] no cwa_url configured, aborting download")
        return nil, nil, _("CWA URL isn't set -- add it under Shelfmark Settings.")
    end
    local headers = {}
    if username and username ~= "" then
        headers["Authorization"] = "Basic " .. mime.b64(username .. ":" .. (password or ""))
    end

    local file, ferr = io.open(save_path, "wb")
    if not file then
        debugLog("[cwa] couldn't open " .. tostring(save_path) .. " for writing: " .. tostring(ferr))
        return nil, nil, _("Couldn't open file for writing: ") .. tostring(ferr)
    end

    local url = cwa_url .. path
    debugLog("[cwa] -> GET " .. url .. " (downloading to " .. tostring(save_path) .. ")")

    socketutil:set_timeout(15, 60)
    local sink = socketutil.file_sink(file)
    local request = { method = "GET", url = url, headers = headers, sink = sink }
    if socks5_proxy and socks5_proxy ~= "" then
        local proxy_host, proxy_port = socks5_proxy:match("^([^:]+):(%d+)$")
        if proxy_host then
            request.create = function() return makeSocks5Socket(proxy_host, tonumber(proxy_port)) end
        end
    end

    local ok, code = pcall(function()
        return socket.skip(1, http.request(request))
    end)
    socketutil:reset_timeout()

    if not ok then
        debugLog("[cwa] <- connection error: " .. tostring(code))
        return nil, nil, _("Couldn't reach CWA -- check the CWA URL in Settings.")
    end
    if code == socketutil.TIMEOUT_CODE or code == socketutil.SINK_TIMEOUT_CODE then
        debugLog("[cwa] <- timed out: " .. tostring(code))
        return nil, nil, _("Download from CWA timed out.")
    end
    debugLog("[cwa] <- HTTP " .. tostring(code) .. " saved to " .. tostring(save_path))
    return true, code
end

-- ===== Anna's Archive (via the annas-archive-api companion service) =====
--
-- A separate, self-hosted service (github.com/bitesized/annas-archive-api)
-- -- not part of Shelfmark itself. Every request is authenticated with an
-- Anna's Archive account secret key (never stored here, always passed
-- per-request via the Authorization header), which Anna's Archive
-- apparently doesn't challenge the way it challenges anonymous requests.
-- Confirmed live: Shelfmark's own built-in direct_download integration
-- needs a real headless-Chrome DDoS-guard solve on every single search
-- (10-15s minimum, 60-120s+ on a cold cache per Shelfmark's own docs, and
-- it got rate-limited by Anna's Archive during testing the same day this
-- was found -- the actual cause of a real "Shelfmark request timeout"
-- report) -- this path instead completed in 3-6s across every test.
--
-- Reached over the same Tailscale SOCKS5 proxy as Shelfmark/CWA (it's a
-- Tailscale-only internal service, same constraint as those); the actual
-- book/cover files that come out of it are Anna's Archive's own public
-- mirror URLs, reached directly over the device's normal connection with
-- no proxy involved at all -- same as how CWA-delivered files already
-- work.

local function doAnnasSearch(annas_url, download_key, tld, query, socks5_proxy)
    if not annas_url or annas_url == "" then
        return nil, nil, _("Anna's Archive API URL isn't set.")
    end
    local url = annas_url .. "/api/search?query=" .. socketurl.escape(query)
        .. "&limit=20&tld=" .. socketurl.escape(tld or "")
    local headers = {}
    if download_key and download_key ~= "" then
        headers["authorization"] = "Bearer " .. download_key
    end
    debugLog("[annas] -> GET " .. url)

    socketutil:set_timeout(10, 30)
    local sink, sink_table = socketutil.table_sink()
    local request = { method = "GET", url = url, headers = headers, sink = sink }
    if socks5_proxy and socks5_proxy ~= "" then
        local proxy_host, proxy_port = socks5_proxy:match("^([^:]+):(%d+)$")
        if proxy_host then
            request.create = function() return makeSocks5Socket(proxy_host, tonumber(proxy_port)) end
        end
    end

    local ok, code = pcall(function()
        return socket.skip(1, http.request(request))
    end)
    socketutil:reset_timeout()

    if not ok then
        debugLog("[annas] <- connection error: " .. tostring(code))
        return nil, nil, _("Couldn't reach the Anna's Archive service.")
    end
    if code == socketutil.TIMEOUT_CODE or code == socketutil.SINK_TIMEOUT_CODE then
        debugLog("[annas] <- timed out: " .. tostring(code))
        return nil, nil, _("Anna's Archive search timed out.")
    end
    local body = table.concat(sink_table)
    debugLog("[annas] <- HTTP " .. tostring(code) .. ", body length " .. tostring(#body))
    if code ~= 200 then
        -- The backend's error code (e.g. "MIRROR_DOWN") rides in the JSON
        -- body, not the HTTP status -- previously discarded here, which is
        -- why a dead mirror looked identical to any other failure.
        local d_ok, d = pcall(JSON.decode, body)
        local err_code = d_ok and d and d.code or nil
        local err_msg = (d_ok and d and d.error) or T(_("Anna's Archive search failed (HTTP %1)."), tostring(code))
        return nil, code, err_msg, err_code
    end
    local decode_ok, decoded = pcall(JSON.decode, body)
    if not decode_ok or not decoded or not decoded.results then
        return nil, code, _("Anna's Archive returned an unreadable response.")
    end
    -- stripJsonNull, not the raw decoded table -- see its own note above:
    -- rapidjson's null sentinel is a function value, and LuaJIT's
    -- string.buffer serializer refuses to cross a Trapper subprocess
    -- boundary with any function/userdata/thread in the payload. Confirmed
    -- live, the hard way: real search results (title/author/format/md5
    -- all present, 20 of them, JSON-decodes and #'s correctly when tested
    -- directly on-device) still came back as a flat nil on the parent
    -- side, no error, nothing logged past this point -- exactly this
    -- same "searching does not bring up anything" symptom the doRawRequest
    -- version of this fix already documents. Some AA result almost
    -- certainly had a null author/cover_url/downloads field.
    return stripJsonNull(decoded.results), code
end

-- Called only when a search just failed with err_code "MIRROR_DOWN" (see
-- Shelfmark:annasSearch's caller) -- never on a timer. Asks the backend to
-- check whether its configured Anna's Archive mirror is actually still
-- Anna's Archive and, if not, switch to another known-alive one.
local function doAnnasMirrorRefresh(annas_url, socks5_proxy)
    if not annas_url or annas_url == "" then
        return nil, nil, _("Anna's Archive API URL isn't set.")
    end
    local url = annas_url .. "/api/mirror-refresh"
    debugLog("[annas] -> GET " .. url)

    socketutil:set_timeout(10, 30)
    local sink, sink_table = socketutil.table_sink()
    local request = { method = "GET", url = url, sink = sink }
    if socks5_proxy and socks5_proxy ~= "" then
        local proxy_host, proxy_port = socks5_proxy:match("^([^:]+):(%d+)$")
        if proxy_host then
            request.create = function() return makeSocks5Socket(proxy_host, tonumber(proxy_port)) end
        end
    end

    local ok, code = pcall(function()
        return socket.skip(1, http.request(request))
    end)
    socketutil:reset_timeout()

    if not ok then
        debugLog("[annas] <- connection error: " .. tostring(code))
        return nil, nil, _("Couldn't reach the Anna's Archive service.")
    end
    local body = table.concat(sink_table)
    debugLog("[annas] <- HTTP " .. tostring(code) .. ", body length " .. tostring(#body))
    if code ~= 200 then
        return nil, code, T(_("Checking for a working mirror failed (HTTP %1)."), tostring(code))
    end
    local decode_ok, decoded = pcall(JSON.decode, body)
    if not decode_ok or not decoded then
        return nil, code, _("Anna's Archive returned an unreadable response.")
    end
    return decoded, code
end

local function doAnnasFetchDownloadUrl(annas_url, download_key, tld, md5, socks5_proxy)
    local url = annas_url .. "/api/download?md5=" .. socketurl.escape(md5)
        .. "&tld=" .. socketurl.escape(tld or "")
    local headers = { ["authorization"] = "Bearer " .. (download_key or "") }
    debugLog("[annas] -> GET " .. url)

    socketutil:set_timeout(10, 30)
    local sink, sink_table = socketutil.table_sink()
    local request = { method = "GET", url = url, headers = headers, sink = sink }
    if socks5_proxy and socks5_proxy ~= "" then
        local proxy_host, proxy_port = socks5_proxy:match("^([^:]+):(%d+)$")
        if proxy_host then
            request.create = function() return makeSocks5Socket(proxy_host, tonumber(proxy_port)) end
        end
    end
    local ok, code = pcall(function()
        return socket.skip(1, http.request(request))
    end)
    socketutil:reset_timeout()

    if not ok then
        debugLog("[annas] <- connection error: " .. tostring(code))
        return nil, nil, _("Couldn't reach the Anna's Archive service.")
    end
    local body = table.concat(sink_table)
    debugLog("[annas] <- HTTP " .. tostring(code) .. ", body length " .. tostring(#body))
    if code ~= 200 then
        local d_ok, d = pcall(JSON.decode, body)
        return nil, code, (d_ok and d and d.error) or T(_("Fetching the download link failed (HTTP %1)."), tostring(code))
    end
    local decode_ok, decoded = pcall(JSON.decode, body)
    if not decode_ok then return nil, code, _("Unreadable response fetching the download link.") end
    local dl_url = decoded.download_url or decoded.url
    if not dl_url then
        -- decoded.error over a generic message when present -- this is the
        -- one path a daily quota exhaustion (the account_fast_download_info
        -- quota confirmed live: 50/day, shared across both Kindles) would
        -- actually surface through, and "No download URL in response"
        -- alone gives no hint that's what happened.
        return nil, code, decoded.error or _("No download URL in response.")
    end
    return dl_url, code
end

-- No socks5_proxy param -- this is a direct request to a public-internet
-- destination (Anna's Archive's own file mirror), not the Tailscale-only
-- annas-archive-api service the two functions above talk to. https.request
-- rather than http.request: these URLs are always https://, and plain
-- socket.http can't speak TLS at all -- confirmed necessary building the
-- companion koplugin (annasarchive.koplugin), which hit exactly this.
-- Shared by doAnnasFileDownload below and the self-update downloader
-- further down -- neither the Anna's Archive mirrors nor GitHub's raw
-- content host need the SOCKS5 proxy (both are reached over plain public
-- HTTPS, unlike the Tailscale-only Shelfmark/CWA/annas-archive-api calls
-- elsewhere in this file).
local function doHttpDownloadToFile(url, save_path, log_prefix, block_timeout, total_timeout, headers)
    local file, ferr = io.open(save_path, "wb")
    if not file then
        return nil, nil, _("Couldn't open file for writing: ") .. tostring(ferr)
    end
    debugLog(log_prefix .. " -> GET " .. url .. " (downloading to " .. save_path .. ")")

    socketutil:set_timeout(block_timeout or 15, total_timeout or 60)
    local sink = socketutil.file_sink(file)
    local requester = url:match("^https:") and https or http
    local ok, code = pcall(function()
        return socket.skip(1, requester.request{ method = "GET", url = url, sink = sink, headers = headers })
    end)
    socketutil:reset_timeout()

    if not ok then
        os.remove(save_path)
        debugLog(log_prefix .. " <- connection error: " .. tostring(code))
        return nil, nil, _("Couldn't reach the file server.")
    end
    -- SSL_HANDSHAKE_CODE ("wantread", confirmed as a real, named LuaSec
    -- return value in socketutil.lua itself -- "from LuaSec's ssl.c") was
    -- missing here, so a stalled HTTPS handshake fell through to the
    -- generic branch below and surfaced as the literal, confusing
    -- "Download failed (HTTP wantread)." instead of a real timeout
    -- message -- confirmed live against an actual Anna's Archive mirror
    -- connection that stalled mid-handshake.
    if code == socketutil.TIMEOUT_CODE or code == socketutil.SINK_TIMEOUT_CODE
            or code == socketutil.SSL_HANDSHAKE_CODE then
        os.remove(save_path)
        debugLog(log_prefix .. " <- timed out: " .. tostring(code))
        return nil, nil, _("Download timed out.")
    end
    if type(code) ~= "number" or code >= 400 then
        os.remove(save_path)
        debugLog(log_prefix .. " <- HTTP " .. tostring(code) .. ", removed partial file")
        return nil, code, T(_("Download failed (HTTP %1)."), tostring(code))
    end
    debugLog(log_prefix .. " <- HTTP " .. tostring(code) .. " saved to " .. save_path)
    return true, code
end

-- A real percentage progress bar needs the total size ahead of the actual
-- GET -- Anna's Archive's own search results don't carry one (confirmed
-- by reading annas-archive-api's scraper directly: it parses format out of
-- the metadata line but discards the size text next to it), so this asks
-- the mirror host itself via a plain HEAD. Best-effort only: some mirror
-- hosts may not support HEAD or omit Content-Length, in which case this
-- returns nil and the caller just shows a progress dialog with no bar.
local function doHttpHeadContentLength(url)
    socketutil:set_timeout(10, 15)
    local requester = url:match("^https:") and https or http
    local ok, code, headers = pcall(function()
        return socket.skip(1, requester.request{ method = "HEAD", url = url, sink = ltn12.sink.table({}) })
    end)
    socketutil:reset_timeout()
    if not ok or type(code) ~= "number" or code >= 400 or type(headers) ~= "table" then
        return nil
    end
    local len = tonumber(headers["content-length"])
    return (len and len > 0) and len or nil
end

local function doAnnasFileDownload(download_url, save_path)
    local ok, code, err = doHttpDownloadToFile(download_url, save_path, "[annas]", 15, 60)
    if not ok and err then
        -- Keep the Anna's-Archive-specific wording this call already had
        -- rather than the generic fallback text.
        if err == _("Couldn't reach the file server.") then
            err = _("Couldn't reach Anna's Archive's file mirror.")
        elseif err == _("Download timed out.") then
            err = _("Download from Anna's Archive timed out.")
        end
    end
    return ok, code, err
end

-- ===== cover image caching =====
--
-- Disk-caches book cover images so results_menu/bibliography_menu can embed
-- them inline (see attachCoverSupport below). cover_url arrives in one of
-- two shapes, confirmed live against both real sources this feature covers:
-- an absolute upstream URL straight from Hardcover's own CDN (e.g.
-- "https://assets.hardcover.app/..." -- the author-bibliography path, which
-- queries Hardcover's GraphQL API directly) needing no auth at all, or a
-- path relative to the Shelfmark server itself (e.g. "/api/covers/..." --
-- the general-search path, via Shelfmark's own /api/metadata/search) which
-- 401s without the same session cookie every other Shelfmark API call uses.
local COVER_CACHE_DIR = DataStorage:getFullDataDir() .. "/shelfmark_covers"

-- Nothing else ever removes a cached cover, so left unchecked this grows
-- forever. 75MB cap by request, evicting oldest-accessed first once
-- exceeded -- same LRU-by-size approach as zlibrary.koplugin's own cover
-- cache (zlibrary/cache.lua's gc_clean), read directly as the reference
-- for this.
local COVER_CACHE_MAX_BYTES = 75 * 1024 * 1024

-- How many books' covers to prefetch synchronously before a results/
-- bibliography menu is ever shown -- matches attachCoverSupport's own
-- forced items_per_page, so the first page a reader actually sees never
-- needs its own lazy top-up. Covers for every page past the first are
-- fetched on demand, the first time that page is scrolled/paged to (see
-- attachCoverSupport's updateItems override) -- fetching all of them up
-- front, as before, meant waiting on covers for books the reader might
-- never scroll to, per explicit request for faster initial results.
local COVER_ITEMS_PER_PAGE = 5

local function evictOldCovers()
    local files = {}
    local total = 0
    for name in lfs.dir(COVER_CACHE_DIR) do
        if name ~= "." and name ~= ".." then
            local path = COVER_CACHE_DIR .. "/" .. name
            local attr = lfs.attributes(path)
            if attr and attr.mode == "file" then
                total = total + (attr.size or 0)
                table.insert(files, { path = path, size = attr.size or 0, time = attr.access or attr.modification or 0 })
            end
        end
    end
    if total <= COVER_CACHE_MAX_BYTES then return end
    table.sort(files, function(a, b) return a.time < b.time end)
    for _, f in ipairs(files) do
        if total <= COVER_CACHE_MAX_BYTES then break end
        os.remove(f.path)
        total = total - f.size
    end
end

-- Cover URLs carry no reliably-unique short id across every provider
-- Shelfmark's search can return, so the sanitized URL itself is the cache
-- key -- collisions are harmless (worst case a stale image for one exact
-- URL gets reused until it's next re-downloaded), and this avoids pulling
-- in a hashing library for what's purely a best-effort cache.
--
-- The .jpg suffix is not cosmetic -- confirmed live, its absence crashes
-- the whole reader. KOReader's DocumentRegistry:isImageFile() (which
-- ImageWidget:_loadfile gates on before ever looking at the file's actual
-- bytes) only checks the filename's extension against a fixed allow-list;
-- with no recognized extension it hits ImageWidget's `error("Image file
-- type not supported.")` -- an uncaught error thrown from inside paintTo,
-- which takes the whole process down, not just that row. The %w-only
-- sanitizing below previously mangled every real extension (".jpeg" ->
-- "_jpeg", unrecognized), so every single cached cover hit exactly this.
-- A fixed .jpg here doesn't need to match the real upstream format:
-- confirmed by reading frontend/ui/renderimage.lua directly, the actual
-- pixel decode (RenderImage:renderImageData) dispatches purely on the
-- file's real magic bytes (GIF8/RIFF/<svg/JPEG SOI, MuPDF as the fallback
-- for everything else including PNG) -- the extension only ever matters
-- for isImageFile()'s upstream gate, never for picking a decoder.
local function coverCacheKey(cover_url)
    local key = cover_url:gsub("[^%w]", "_")
    if #key > 100 then key = key:sub(-100) end
    return key .. ".jpg"
end

-- Standalone (no `self`) so it can run inside prefetchCovers' forked
-- Trapper subprocess below. Best-effort only -- any failure just means no
-- cover for that row, never worth surfacing as an error.
-- Hardcover's own cover images are frequently just hotlinked from Amazon's
-- CDN (confirmed live: assets.hardcover.app/.../*._SL1500_*.jpg-style
-- filenames), which serves multiple pre-rendered sizes of the same image
-- via this exact filename suffix -- rewriting the number fetches a
-- genuinely smaller file directly from the CDN, no local decode/re-encode
-- needed at all (confirmed live: a real 1500px cover dropped from 235KB to
-- 27KB requesting 200px instead). This KOReader build has no image-encode
-- capability of its own to build a "resize and re-save" step with anyway
-- (frontend/ui/renderimage.lua only ever decodes; tj3Compress8 exists in
-- the raw turbojpeg FFI header but nothing wraps it) -- this sidesteps
-- needing one. Hardcover's own natively-hosted images (no such suffix,
-- already smaller on average) are left untouched; there's no equivalent
-- trick for those.
--
-- Only applied to the direct-fetch (bibliography) path below, not the
-- general-search path's /api/covers proxy -- tried the equivalent rewrite
-- there too (decoding the proxy's own base64-encoded "url" query param,
-- shrinking it, re-encoding), but confirmed live against the real server
-- that it has no effect: requesting the exact same cover through the proxy
-- with the original 1500px URL and a rewritten 300px one returned
-- byte-for-byte identical, still-1500px images both times. That proxy
-- evidently caches by the hardcover_<id> alone, ignoring whatever URL is
-- actually passed -- so there was nothing to gain there, only complexity.
local COVER_TARGET_PX = 300
local function shrinkAmazonImageUrl(url)
    local rewritten, n = url:gsub("(%._S[LX])%d+(_%.[%a]+)$", "%1" .. COVER_TARGET_PX .. "%2")
    return n > 0 and rewritten or url
end

local function downloadCoverToPath(server_url, session_cookie, cover_url)
    if not cover_url or cover_url == "" then return nil end
    if lfs.attributes(COVER_CACHE_DIR, "mode") ~= "directory" then
        lfs.mkdir(COVER_CACHE_DIR)
    end
    -- Keyed on the original cover_url, not the shrunk one -- it's still a
    -- unique, stable identifier for this exact cover regardless of which
    -- variant's bytes actually end up on disk.
    local path = COVER_CACHE_DIR .. "/" .. coverCacheKey(cover_url)
    if lfs.attributes(path, "mode") == "file" then
        return path
    end

    local full_url, headers
    if cover_url:match("^https?://") then
        full_url = shrinkAmazonImageUrl(cover_url)
    else
        if not session_cookie then return nil end
        full_url = server_url .. cover_url
        headers = { Cookie = session_cookie }
    end

    local ok = doHttpDownloadToFile(full_url, path, "[cover]", 10, 30, headers)
    if not ok then
        os.remove(path)
        return nil
    end
    return path
end

-- Downloads/caches cover images for one freshly-fetched page of books,
-- setting book.cover_path in place. Wrapped in its own dismissable Trapper
-- subprocess -- this runs after the metadata search/bibliography fetch has
-- already returned (back on the main process), and a page's worth of
-- sequential cover GETs is exactly the kind of multi-second blocking work
-- that needs a cancelable progress dialog rather than freezing the UI.
-- Deliberately indexed with a plain numeric for loop rather than ipairs:
-- some books have no cover_url, and a hole in that table would make ipairs
-- stop early.
function Shelfmark:prefetchCovers(books)
    local server_url, session_cookie = self.server_url, self.session_cookie
    local n = #books
    local urls = {}
    for i = 1, n do urls[i] = books[i].cover_url end

    local Trapper = require("ui/trapper")
    -- pcall per-book: one malformed URL/response shouldn't cost the rest of
    -- the page their covers.
    local completed, paths = Trapper:dismissableRunInSubprocess(function()
        local results = {}
        for i = 1, n do
            local ok, res = pcall(downloadCoverToPath, server_url, session_cookie, urls[i])
            if ok then
                results[i] = res
            else
                debugLog("[cover] error for url " .. tostring(urls[i]) .. ": " .. tostring(res))
            end
        end
        return results
    end, _("Fetching covers..."))

    if completed and paths then
        for i = 1, n do
            books[i].cover_path = paths[i]
        end
    end

    -- Plain disk I/O on the main process, not inside the download
    -- subprocess above -- eviction doesn't need to compete with actual
    -- downloads for the fork's runtime, and a directory this size (a few
    -- hundred files at most under the 75MB cap) scans fast enough not to
    -- need its own progress dialog.
    if lfs.attributes(COVER_CACHE_DIR, "mode") == "directory" then
        evictOldCovers()
    end
end

-- Embeds a small cover-image widget into a Menu's rows via item.state -- a
-- stock, generic MenuItem field (confirmed by reading
-- frontend/ui/widget/menu.lua directly: `local state_button = self.entry.state
-- or HorizontalSpan:new{}`, originally meant for TOC tree-expand icons, but
-- generic enough for any widget), not something requiring a custom
-- Menu:extend{} subclass the way zlibrary.koplugin's own cover list needs.
-- The simplification that makes a plain Menu enough here: every cover this
-- feature shows is already synchronously downloaded to disk (via
-- prefetchCovers above) before the menu is ever constructed, so there's no
-- async/debounced loading to orchestrate -- just one thing to get right,
-- which zlibrary's own comments document as a real, previously-encountered
-- crash: KOReader's Menu:updateItems frees every row's embedded widget
-- (VerticalGroup:clear -> free), and since item.state lives on item_table
-- (which outlives any one row), a widget left there after that point is a
-- *freed* widget -- painting it again crashes with "attempt to index field
-- '_bb' (a nil value)". That's reachable here too: with ~25-30 items and no
-- explicit items_per_page, Menu paginates internally, and its own
-- next/prev-page controls call updateItems repeatedly on the same
-- item_table. So: null every item's state first, then rebuild only the
-- page actually being shown, on every single updateItems call -- never let
-- a widget survive past the call that painted it.
local function attachCoverSupport(menu, shelfmark_self)
    local ImageWidget = require("ui/widget/imagewidget")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Geom = require("ui/geometry")
    local Size = require("ui/size")

    -- Confirmed live: KOReader's Menu never sizes a row to fit its content
    -- -- item_dimen.h is a fixed available_height/items_per_page slice
    -- (frontend/ui/widget/menu.lua:_recalculateDimen), set once from
    -- whatever generic per-page default was already in effect (sized for
    -- short, mostly single-line rows) and never revisited afterward. A
    -- cover's state_w reservation narrows the text column, which needs
    -- more lines to say the same thing -- so text was getting clipped
    -- vertically well before it ran out of content, not because wrapping
    -- itself failed. zlibrary.koplugin's own cover list hits this same
    -- tension and fixes it the same way: force a smaller items_per_page
    -- and re-run dimension calc *before* ever sizing the cover off
    -- item_dimen.h, rather than trying to fit a cover into whatever
    -- generic row height happened to already be in effect. 5, not a
    -- computed value like zlibrary's own getCoverItemsPerPage -- matches
    -- what's actually visible per page in zlibrary's own reference
    -- screenshot, which is the density being matched here, and matches
    -- COVER_ITEMS_PER_PAGE (how many covers doSearch/browseAuthorBibliography
    -- prefetch up front) so the very first page shown never needs a lazy
    -- top-up of its own.
    menu.items_per_page = COVER_ITEMS_PER_PAGE
    menu:_recalculateDimen(false)

    local cover_h = math.max(60, (menu.item_dimen and menu.item_dimen.h or 120) - 2 * Size.line.medium)
    local cover_w = math.floor(cover_h * 2 / 3)
    menu.state_w = cover_w + 8 * Size.padding.small

    local server_url, session_cookie = shelfmark_self.server_url, shelfmark_self.session_cookie

    local orig_updateItems = menu.updateItems
    menu.updateItems = function(self, select_number, no_recalculate_dimen)
        for _, item in ipairs(self.item_table) do
            item.state = nil
        end
        local perpage = self.perpage or #self.item_table
        local page = self.page or 1
        local idx_offset = (page - 1) * perpage

        -- Lazy top-up: only the first COVER_ITEMS_PER_PAGE books get
        -- prefetched before the menu is ever shown (see doSearch/
        -- browseAuthorBibliography) -- with items_per_page forced down to
        -- make room for covers, most result sets now span many more pages
        -- than that, and downloading every one of them up front meant
        -- waiting on covers for books the reader might never scroll to.
        -- This fetches only the page that's actually about to be painted,
        -- the first time it's visited. Plain direct calls, not wrapped in
        -- Trapper's dismissable subprocess: this runs from a page-turn
        -- tap, well after the Trapper:wrap() coroutine covering the
        -- original search has already ended, so
        -- dismissableRunInSubprocess would just silently fall back to an
        -- equivalent blocking call anyway (confirmed by reading
        -- ui/trapper.lua) -- a handful of images blocking briefly on a
        -- page flip is a fair trade for a page load that no longer waits
        -- on covers it may never need.
        local fetched_any = false
        for idx = 1, perpage do
            local item = self.item_table[idx_offset + idx]
            if item and item.cover_url and not item.cover_path and not item._cover_fetch_failed then
                local path = downloadCoverToPath(server_url, session_cookie, item.cover_url)
                if path then
                    item.cover_path = path
                    fetched_any = true
                else
                    item._cover_fetch_failed = true
                end
            end
        end
        if fetched_any and lfs.attributes(COVER_CACHE_DIR, "mode") == "directory" then
            evictOldCovers()
        end

        for idx = 1, perpage do
            local item = self.item_table[idx_offset + idx]
            if item and item.cover_path then
                item.state = CenterContainer:new{
                    dimen = Geom:new{ w = cover_w, h = cover_h },
                    ImageWidget:new{
                        file = item.cover_path,
                        width = cover_w,
                        height = cover_h,
                        scale_factor = 0,
                        -- false, not true: at scale_factor=0, ImageWidget
                        -- decodes at the source's *native* resolution before
                        -- scaling down to fit the container (needed to
                        -- preserve aspect ratio -- see the class comment
                        -- above ImageWidget:_loadfile on why width/height
                        -- alone would double-scale). Confirmed live: caching
                        -- that full-resolution decode in KOReader's shared,
                        -- fixed-size ImageCache crashed the reader outright
                        -- with "not enough storage for cache" -- a single
                        -- Hardcover cover (source images run up to ~1500px)
                        -- decoded larger than the cache's entire budget, so
                        -- no amount of evicting other entries could ever
                        -- make room. file_do_cache=false keeps each
                        -- decoded bitmap scoped to its own widget instead,
                        -- freed the moment updateItems rebuilds the page
                        -- (item.state is already nulled out above every
                        -- time) -- the small re-decode cost on each repaint
                        -- is cheap for a disk-cached, already-small file.
                        file_do_cache = false,
                        alpha = false,
                        use_legacy_image_scaling = true,
                    },
                }
            end
        end
        return orig_updateItems(self, select_number, no_recalculate_dimen)
    end

    -- Forces one rebuild now, before the menu is ever shown -- the first
    -- construction pass already ran (with state_w still 0) to compute
    -- item_dimen, so this is what actually reserves the cover column and
    -- paints the images for the very first page.
    menu:updateItems()
end

-- ===== Hardcover (hardcover.app) =====
--
-- Unlike Anna's Archive, this is a normal public HTTPS GraphQL API with
-- Bearer-token auth and no bot-challenge -- no self-hosted companion or
-- SOCKS5 proxy needed, the device talks to it directly. Schema verified
-- directly against github.com/hardcoverapp/hardcover-docs before writing
-- any of this (search returns a plain ranked `ids` list alongside the
-- complex Typesense `results` blob, so the id list is used here and the
-- messy blob is never touched -- a plain books_by_pk/authors_by_pk lookup
-- gets a clean title/name for the confirmation dialog instead).
--
-- Every action here is manual and explicit -- triggered by a menu tap, with
-- a confirmation dialog showing exactly what was matched before anything is
-- written -- deliberately not automatic (e.g. no "detect when a book is
-- finished" heuristic), since that class of guess is exactly where a
-- reading-tracker silently logs the wrong thing.
local HARDCOVER_API_URL = "https://api.hardcover.app/v1/graphql"

-- status_id values per Hardcover's own docs: 1 Want to Read, 2 Currently
-- Reading, 3 Read, 4 Paused, 5 Did Not Finish. Only the two that matter for
-- "track your reading habits" are exposed in the menu for now.
local HARDCOVER_STATUS_CURRENTLY_READING = 2
local HARDCOVER_STATUS_READ = 3

local function doHardcoverGraphQL(token, query, variables)
    if not token or token == "" then
        return nil, _("Hardcover API token isn't set -- check Settings.")
    end
    local body_json = JSON.encode({ query = query, variables = variables or {} })
    local headers = {
        ["Content-Type"] = "application/json",
        ["Content-Length"] = tostring(#body_json),
        ["Authorization"] = "Bearer " .. token,
    }
    debugLog("[hardcover] -> POST " .. HARDCOVER_API_URL)

    socketutil:set_timeout(10, 30)
    local sink, sink_table = socketutil.table_sink()
    local request = {
        method = "POST",
        url = HARDCOVER_API_URL,
        headers = headers,
        sink = sink,
        source = ltn12.source.string(body_json),
    }
    local ok, code = pcall(function()
        return socket.skip(1, http.request(request))
    end)
    socketutil:reset_timeout()

    if not ok then
        debugLog("[hardcover] <- connection error: " .. tostring(code))
        return nil, _("Couldn't reach Hardcover.")
    end
    if code == socketutil.TIMEOUT_CODE or code == socketutil.SINK_TIMEOUT_CODE then
        return nil, _("Hardcover request timed out.")
    end
    local raw_body = table.concat(sink_table)
    debugLog("[hardcover] <- HTTP " .. tostring(code) .. ", body length " .. tostring(#raw_body))
    if code ~= 200 then
        return nil, T(_("Hardcover request failed (HTTP %1)."), tostring(code))
    end
    local decode_ok, decoded = pcall(JSON.decode, raw_body)
    if not decode_ok or not decoded then
        return nil, _("Hardcover returned an unreadable response.")
    end
    decoded = stripJsonNull(decoded)
    -- Two different error shapes confirmed live: a bad/expired token gets
    -- rejected by an auth layer in front of GraphQL entirely, in OAuth-style
    -- {error, error_description} form (e.g. "invalid_token" / "Token is not
    -- associated with a user") -- distinct from an actual GraphQL execution
    -- error, which comes back as the standard {errors: [{message}]} array.
    if decoded.error then
        return nil, decoded.error_description or decoded.error
    end
    if decoded.errors and decoded.errors[1] then
        return nil, decoded.errors[1].message or _("Hardcover rejected the request.")
    end
    return decoded.data
end

-- Searches by title (query_type "Book"), takes the top-ranked id from the
-- plain `ids` array, then a separate simple lookup for a clean title/author
-- to show in the confirmation dialog -- see the section note above for why
-- the raw Typesense `results` blob is avoided entirely.
-- author is optional (an embedded EPUB author, when the caller has one --
-- never user-typed) and used only to pick among several same-titled
-- candidates, never as part of the search query itself.
--
-- per_page was 1 here -- confirmed live this is a real problem, not a
-- theoretical one: Hardcover's own title search for "Run" ranks John
-- Lewis & Andrew Aydin's graphic novel first, ahead of Blake Crouch's
-- same-titled thriller, despite Crouch's edition having more Hardcover
-- users (368 vs 53) -- title relevance there evidently isn't popularity-
-- ordered. Long-press "Mark as Read" on a Crouch book named exactly "Run"
-- would silently log the wrong book (the confirmation dialog does show
-- the found author first, but that's a safety net, not a fix). Widening
-- to 5 and checking each candidate's actual contributors against the
-- given author closes that gap; falls back to the plain #1 result when no
-- author is available or none of the candidates match it.
local function doHardcoverFindBook(token, title, author)
    local search_data, err = doHardcoverGraphQL(token, [[
        query Search($q: String!) {
            search(query: $q, query_type: "Book", per_page: 5) { ids }
        }
    ]], { q = title })
    if not search_data then return nil, nil, nil, err end
    local ids = search_data.search and search_data.search.ids
    if not ids or not ids[1] then
        return nil, nil, nil, _("No matching book found on Hardcover.")
    end

    local candidates = {}
    for i = 1, math.min(#ids, 5) do
        local book_data = doHardcoverGraphQL(token, [[
            query BookById($id: Int!) {
                books_by_pk(id: $id) {
                    title
                    contributions { contribution author { name } }
                }
            }
        ]], { id = ids[i] })
        if book_data and book_data.books_by_pk then
            table.insert(candidates, { id = ids[i], data = book_data.books_by_pk })
        end
    end
    if #candidates == 0 then
        return nil, nil, nil, _("Found a match but couldn't fetch its details.")
    end

    -- Prefer a contributor explicitly tagged "Author" over the first
    -- contribution listed -- confirmed live, this same "Run" audiobook
    -- edition lists its narrator (Phil Gigante) ahead of Blake Crouch,
    -- so contributions[1] alone would report the wrong "found author"
    -- even once the right *book* is chosen. Untyped contributions (nil
    -- role) are accepted too, matching entries that never got tagged.
    local function primaryAuthorName(book)
        for _, c in ipairs(book.contributions or {}) do
            if c.author and (c.contribution == nil or c.contribution == "Author") then
                return c.author.name
            end
        end
        local contributions = book.contributions
        return contributions and contributions[1] and contributions[1].author
            and contributions[1].author.name or nil
    end

    local chosen = candidates[1]
    if author and author ~= "" then
        -- Surname only, matching releaseRelevanceScore's own convention
        -- elsewhere in this file -- robust to "Blake Crouch" vs.
        -- "Crouch, Blake" ordering differences between an EPUB's embedded
        -- metadata and Hardcover's own contributor names.
        local surname = author:match("(%S+)%s*$")
        if surname and #surname > 1 then
            surname = surname:lower()
            for _, c in ipairs(candidates) do
                local matched = false
                for _, contribution in ipairs(c.data.contributions or {}) do
                    if contribution.author and contribution.author.name
                            and contribution.author.name:lower():find(surname, 1, true) then
                        matched = true
                        break
                    end
                end
                if matched then
                    chosen = c
                    break
                end
            end
        end
    end

    return chosen.id, chosen.data.title, primaryAuthorName(chosen.data)
end

local function doHardcoverFindAuthor(token, name)
    local search_data, err = doHardcoverGraphQL(token, [[
        query Search($q: String!) {
            search(query: $q, query_type: "Author", per_page: 1) { ids }
        }
    ]], { q = name })
    if not search_data then return nil, nil, err end
    local ids = search_data.search and search_data.search.ids
    if not ids or not ids[1] then
        return nil, nil, _("No matching author found on Hardcover.")
    end
    local author_id = ids[1]

    local author_data, lookup_err = doHardcoverGraphQL(token, [[
        query AuthorById($id: Int!) {
            authors_by_pk(id: $id) { name }
        }
    ]], { id = author_id })
    if not author_data or not author_data.authors_by_pk then
        return nil, nil, lookup_err or _("Found a match but couldn't fetch its details.")
    end
    return author_id, author_data.authors_by_pk.name
end

local function doHardcoverSetStatus(token, book_id, status_id)
    local data, err = doHardcoverGraphQL(token, [[
        mutation SetStatus($book_id: Int!, $status_id: Int!) {
            insert_user_book(object: { book_id: $book_id, status_id: $status_id }) {
                id
                error
            }
        }
    ]], { book_id = book_id, status_id = status_id })
    if not data then return false, err end
    local result = data.insert_user_book
    if not result or result.error then
        return false, (result and result.error) or _("Hardcover didn't confirm the update.")
    end
    return true
end

local function doHardcoverFollowAuthor(token, author_id)
    local data, err = doHardcoverGraphQL(token, [[
        mutation FollowAuthor($id: Int!) {
            insert_follow(followable_id: $id, followable_type: "Author") { id }
        }
    ]], { id = author_id })
    if not data then return false, err end
    if not data.insert_follow or not data.insert_follow.id then
        return false, _("Hardcover didn't confirm the follow.")
    end
    return true
end

-- Lists authors currently followed on Hardcover -- read fresh every time
-- rather than mirrored locally, so a follow made on hardcover.app's own
-- website (or via the long-press action below) shows up immediately with
-- nothing to keep in sync. `me`/`authors` are array-returning root fields on
-- this schema (confirmed live: a plain `{me{id}}` query returned
-- `{"me":[{"id":...}]}`), not single objects -- indexing [1] is required.
local function doHardcoverListFollowedAuthors(token)
    local data, err = doHardcoverGraphQL(token, [[
        query FollowedAuthors {
            me {
                follows(where: {followable_type: {_eq: "Author"}}, order_by: {author: {name: asc}}) {
                    author { id name books_count cached_image }
                }
            }
        }
    ]], {})
    if not data then return nil, err end
    local me = data.me and data.me[1]
    local follows = me and me.follows
    if not follows then return {} end
    local authors = {}
    for _, f in ipairs(follows) do
        if f.author then
            table.insert(authors, {
                id = f.author.id,
                name = f.author.name,
                books_count = f.author.books_count,
                cover_url = type(f.author.cached_image) == "table" and f.author.cached_image.url or nil,
            })
        end
    end
    return authors
end

-- Thousands-comma grouping for Hardcover's raw GraphQL numbers (unlike the
-- Shelfmark-server-side Hardcover provider, which pre-formats these as
-- strings before this plugin ever sees them via /api/metadata/search).
local function formatCount(n)
    if type(n) ~= "number" then return tostring(n) end
    local out = tostring(math.floor(n)):reverse():gsub("(%d%d%d)", "%1,"):reverse()
    if out:sub(1, 1) == "," then out = out:sub(2) end
    return out
end

-- An author's full bibliography, paginated. Query shape (the
-- canonical_id/state filters and the nested book-scoped order_by) copied
-- verbatim from calibrain/shelfmark's own production Hardcover provider
-- (shelfmark/metadata_providers/hardcover.py) rather than guessed, since
-- that's the same account/API this plugin's own annas_download_key-style
-- server integration already relies on for "Most popular". Returns each
-- book already shaped the way describeBook/describeMetrics/browseReleases
-- expect from any other source (title/authors/publish_year/display_fields/
-- provider/provider_id) -- see the note above doSearch's book_data shape.
local function doHardcoverAuthorBibliography(token, author_id, limit, offset)
    local data, err = doHardcoverGraphQL(token, [[
        query AuthorBooks($authorId: Int!, $limit: Int!, $offset: Int!) {
            authors(where: {id: {_eq: $authorId}}, limit: 1) {
                name
                contributions(
                    where: {
                        contributable_type: {_eq: "Book"}
                        book: { canonical_id: {_is_null: true}, state: {_in: ["normalized", "normalizing"]}, compilation: {_eq: false} }
                    }
                    order_by: [
                        {book: {users_count: desc_nulls_last}},
                        {book: {ratings_count: desc_nulls_last}},
                        {book: {id: asc}}
                    ]
                    limit: $limit
                    offset: $offset
                ) {
                    book {
                        id
                        title
                        release_year
                        release_date
                        rating
                        ratings_count
                        users_count
                        cached_image
                        contributions(where: {contribution: {_eq: "Author"}}) { author { name } }
                    }
                }
                contributions_aggregate(
                    where: {
                        contributable_type: {_eq: "Book"}
                        book: { canonical_id: {_is_null: true}, state: {_in: ["normalized", "normalizing"]}, compilation: {_eq: false} }
                    }
                ) { aggregate { count } }
            }
        }
    ]], { authorId = author_id, limit = limit, offset = offset })
    if not data then return nil, nil, nil, err end
    local author = data.authors and data.authors[1]
    if not author then return nil, nil, nil, _("Author not found on Hardcover.") end

    -- Safety net alongside the compilation:false filter above -- cheap
    -- insurance against any other duplicate source (a book credited to this
    -- author under more than one contribution row, translated editions that
    -- slip past canonical_id, etc.) rather than a fix for a specific known
    -- cause.
    local seen_ids = {}
    local books = {}
    for _, c in ipairs(author.contributions or {}) do
        local b = c.book
        if b and not seen_ids[b.id] then
            seen_ids[b.id] = true
            local authors = {}
            for _, bc in ipairs(b.contributions or {}) do
                if bc.author and bc.author.name then table.insert(authors, bc.author.name) end
            end
            if #authors == 0 then authors = { author.name } end

            -- Same type-checked pattern doSearch's describeYear already uses:
            -- a missing value decodes as KOReader's JSON-null sentinel, which
            -- is truthy but not a number.
            local publish_year = nil
            if type(b.release_year) == "number" then
                publish_year = b.release_year
            elseif type(b.release_date) == "string" then
                local y = b.release_date:match("^(%d%d%d%d)")
                if y then publish_year = tonumber(y) end
            end

            local display_fields = {}
            if type(b.rating) == "number" then
                local rating_str = string.format("%.1f", b.rating)
                if type(b.ratings_count) == "number" and b.ratings_count > 0 then
                    rating_str = rating_str .. " (" .. formatCount(b.ratings_count) .. ")"
                end
                table.insert(display_fields, { label = "Rating", value = rating_str })
            end
            if type(b.users_count) == "number" and b.users_count > 0 then
                table.insert(display_fields, { label = "Readers", value = formatCount(b.users_count) })
            end

            table.insert(books, {
                title = b.title,
                authors = authors,
                publish_year = publish_year,
                display_fields = display_fields,
                cover_url = type(b.cached_image) == "table" and b.cached_image.url or nil,
                provider = "hardcover",
                provider_id = tostring(b.id),
            })
        end
    end

    local total = author.contributions_aggregate
        and author.contributions_aggregate.aggregate
        and author.contributions_aggregate.aggregate.count
        or #books
    return books, total, author.name
end

-- ===== long-press-on-cover Hardcover actions (FileManager extension) =====
--
-- FileManager:addFileDialogButtons is a real, first-class KOReader
-- extension point -- confirmed live against this device's own installed
-- files: coverbrowser.koplugin (the only real first-party consumer of this
-- API) uses exactly this pattern to add its own "Ignore cover"/"Refresh
-- cached info" rows to the same long-press dialog. Four separate calls are
-- required, one per FileManager-family class table -- confirmed via
-- coverbrowser.koplugin's own `_modified_widgets` table, which maps
-- "filemanager"/"history"/"collections"/"filesearcher" directly to the four
-- required()'d class tables themselves (not instances) -- the "long-press
-- file_dialog in FileManager, History, Collections, FileSearcher" comment in
-- KOReader's own source only documents that all four *read* the same kind
-- of registered-buttons table, not that one registration reaches all of
-- them.

-- book_props is nil for any file that's never been opened and has no
-- CoverBrowser cache -- confirmed live by reading filemanager.lua's own
-- showFileDialog: it's only populated via CoverBrowser's cache or a book's
-- saved doc_settings, neither of which exist for a freshly downloaded,
-- never-opened book. Falls back to a metadata-only document open (no
-- render, no page count -- the same fallback FileManagerBookInfo's own
-- getDocProps uses) and finally to the filename itself. Deliberately only
-- ever called from a long-press button's own tap callback, never from
-- row_func below -- row_func runs on every single long-press on every book,
-- so opening a document there would add real cost to an action that
-- doesn't need it.
local function deriveFileDialogMetadata(file, book_props)
    if book_props and book_props.title then
        return book_props.title, book_props.authors
    end

    local title, authors
    local DocumentRegistry = require("document/documentregistry")
    if DocumentRegistry:hasProvider(file) then
        local open_ok, document = pcall(function() return DocumentRegistry:openDocument(file) end)
        if open_ok and document then
            if document.loadDocument then
                pcall(function() document:loadDocument(false) end)
            end
            local props_ok, props = pcall(function() return document:getProps() end)
            if props_ok and props then
                title = props.title
                authors = props.authors
            end
            DocumentRegistry:closeDocument(file)
        end
    end

    if not title or title == "" then
        title = require("apps/filemanager/filemanagerutil").splitFileNameType(file)
    end
    return title, authors
end

function Shelfmark:registerFileDialogButtons()
    local FileManager = require("apps/filemanager/filemanager")
    local FileManagerHistory = require("apps/filemanager/filemanagerhistory")
    local FileManagerCollection = require("apps/filemanager/filemanagercollection")
    local FileManagerFileSearcher = require("apps/filemanager/filemanagerfilesearcher")
    local DocumentRegistry = require("document/documentregistry")
    local self_ref = self

    local function row_func(file, is_file, book_props)
        if not is_file or not DocumentRegistry:hasProvider(file) then return nil end

        local function logCallback(status_id, status_label)
            return function()
                local title, author = deriveFileDialogMetadata(file, book_props)
                local Trapper = require("ui/trapper")
                Trapper:wrap(function()
                    self_ref:promptHardcoverLogBookForFile(title, author, status_id, status_label)
                end)
            end
        end

        local row = {
            { text = _("Currently Reading"), callback = logCallback(HARDCOVER_STATUS_CURRENTLY_READING, _("Currently Reading")) },
            { text = _("Read"), callback = logCallback(HARDCOVER_STATUS_READ, _("Read")) },
        }

        -- Cheap check (no document open) when book_props is already known;
        -- otherwise show the button anyway and let the tap-time fallback
        -- (which does open the document) decide -- see
        -- deriveFileDialogMetadata's own note on why that lookup only ever
        -- happens lazily, at tap time, never here.
        local known_author = book_props and book_props.authors and book_props.authors ~= ""
        if known_author or not book_props then
            table.insert(row, {
                text = _("Follow Author"),
                callback = function()
                    local _title, author = deriveFileDialogMetadata(file, book_props)
                    if not author or author == "" then
                        UIManager:show(InfoMessage:new{ text = _("Couldn't determine this book's author.") })
                        return
                    end
                    local Trapper = require("ui/trapper")
                    Trapper:wrap(function()
                        self_ref:promptHardcoverFollowAuthorForFile(author)
                    end)
                end,
            })
        end

        return row
    end

    -- Idempotent (addFileDialogButtons dedups on row_id per target table),
    -- safe to call unconditionally every time any Shelfmark instance inits.
    FileManager.addFileDialogButtons(FileManager, "shelfmark_hardcover", row_func)
    FileManager.addFileDialogButtons(FileManagerHistory, "shelfmark_hardcover", row_func)
    FileManager.addFileDialogButtons(FileManagerCollection, "shelfmark_hardcover", row_func)
    FileManager.addFileDialogButtons(FileManagerFileSearcher, "shelfmark_hardcover", row_func)
end

-- ===== self-update check (GitHub releases) =====

local function isNewerVersion(remote_version, local_version)
    local function parts(v)
        local t = {}
        for n in tostring(v):gsub("^v", ""):gmatch("%d+") do t[#t + 1] = tonumber(n) end
        return t
    end
    local r, l = parts(remote_version), parts(local_version)
    for i = 1, math.max(#r, #l) do
        local rv, lv = r[i] or 0, l[i] or 0
        if rv ~= lv then return rv > lv end
    end
    return false
end

local function doCheckForUpdate()
    local url = "https://api.github.com/repos/" .. UPDATE_REPO .. "/releases/latest"
    debugLog("[update] -> GET " .. url)

    socketutil:set_timeout(15, 30)
    local sink, sink_table = socketutil.table_sink()
    local ok, code = pcall(function()
        return socket.skip(1, https.request{
            method = "GET",
            url = url,
            headers = {
                ["User-Agent"] = "shelfmark.koplugin",
                ["Accept"] = "application/vnd.github+json",
            },
            sink = sink,
        })
    end)
    socketutil:reset_timeout()

    if not ok then
        debugLog("[update] <- connection error: " .. tostring(code))
        return nil, nil, _("Couldn't reach GitHub to check for updates.")
    end
    local content = table.concat(sink_table)
    if type(code) ~= "number" or code >= 400 then
        debugLog("[update] <- HTTP " .. tostring(code))
        return nil, code, T(_("GitHub returned HTTP %1."), tostring(code))
    end
    local decode_ok, decoded = pcall(JSON.decode, content)
    if not decode_ok or type(decoded) ~= "table" or type(decoded.tag_name) ~= "string" then
        debugLog("[update] <- couldn't parse response")
        return nil, code, _("Couldn't parse GitHub's response.")
    end
    return stripJsonNull(decoded), code
end

-- Downloads the tagged release's main.lua/_meta.lua to temp files first,
-- sanity-checks that main.lua actually parses (loadfile compiles without
-- executing), and only then swaps them over the live files -- a bad
-- download or a truncated file this way can never leave the plugin
-- unable to load on next start, worst case the update is just silently
-- not applied.
local function doApplyUpdate(tag)
    local plugin_dir = getPluginDir()
    local base = "https://raw.githubusercontent.com/" .. UPDATE_REPO .. "/" .. tag .. "/shelfmark.koplugin/"
    local files = { "main.lua", "_meta.lua" }
    local tmp_paths = {}

    for idx = 1, #files do
        local fname = files[idx]
        local tmp_path = plugin_dir .. "/" .. fname .. ".update-tmp"
        local ok, _dl_code, dl_err = doHttpDownloadToFile(base .. fname, tmp_path, "[update]", 15, 45)
        if not ok then
            for j = 1, #tmp_paths do os.remove(tmp_paths[j]) end
            return nil, dl_err or T(_("Couldn't download %1."), fname)
        end
        tmp_paths[#tmp_paths + 1] = tmp_path
    end

    local chunk, load_err = loadfile(plugin_dir .. "/main.lua.update-tmp")
    if not chunk then
        for j = 1, #tmp_paths do os.remove(tmp_paths[j]) end
        return nil, _("Downloaded update failed to parse, not installed: ") .. tostring(load_err)
    end

    for idx = 1, #files do
        local fname = files[idx]
        os.rename(plugin_dir .. "/" .. fname .. ".update-tmp", plugin_dir .. "/" .. fname)
    end
    debugLog("[update] <- installed " .. tag .. " to " .. plugin_dir)
    return true
end

-- ===== CWA library sync (device -> CWA, no SSH/homeserver script) =====
--
-- Everything above (doCwaRequest/doCwaFileDownload) authenticates to CWA
-- with plain HTTP Basic Auth, which is all OPDS and /ajax/book/<uuid>
-- accept -- confirmed live, a valid session cookie is actually *rejected*
-- (401) on /ajax/book/<uuid> specifically. The routes below (/login,
-- /upload) are the opposite: they're CWA's own web-app routes, protected
-- by Flask-Login's session cookie plus a CSRF token, and reject Basic
-- Auth. So this is a second, separate auth flow, not a variant of the
-- first.
--
-- CWA (crocodilestick/calibre-web-automated) also diverges from the
-- upstream calibre-web project it's forked from in ways that matter here
-- -- confirmed live while building fix_description.py (the homeserver
-- script this mirrors): the /ajax/editbooks/<param> edit endpoint takes
-- form-encoded data with a bare numeric pk, not upstream's JSON with a
-- list-valued pk. /upload hasn't been checked against upstream at all;
-- this was built directly from CWA's own fork source.

local function doCwaRawFormRequest(cwa_url, cookie, method, path, form_fields, extra_headers, socks5_proxy)
    local headers = {}
    for k, v in pairs(extra_headers or {}) do headers[k] = v end
    if cookie then headers["Cookie"] = cookie end

    local body
    if form_fields then
        local parts = {}
        for k, v in pairs(form_fields) do
            table.insert(parts, socketurl.escape(k) .. "=" .. socketurl.escape(v))
        end
        body = table.concat(parts, "&")
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        headers["Content-Length"] = tostring(#body)
    end

    local url = cwa_url .. path
    debugLog("[cwa] -> " .. method .. " " .. url)

    socketutil:set_timeout(15, 45)
    local sink, sink_table = socketutil.table_sink()
    local request = { method = method, url = url, headers = headers, sink = sink }
    if body then request.source = ltn12.source.string(body) end
    if socks5_proxy and socks5_proxy ~= "" then
        local proxy_host, proxy_port = socks5_proxy:match("^([^:]+):(%d+)$")
        if proxy_host then
            request.create = function() return makeSocks5Socket(proxy_host, tonumber(proxy_port)) end
        end
    end

    local ok, code, resp_headers = pcall(function()
        return socket.skip(1, http.request(request))
    end)
    socketutil:reset_timeout()

    if not ok then
        debugLog("[cwa] <- connection error: " .. tostring(code))
        return nil, nil, nil, _("Couldn't reach CWA -- check the CWA URL in Settings.")
    end
    local content = table.concat(sink_table)
    debugLog("[cwa] <- HTTP " .. tostring(code) .. ", body length " .. tostring(#content))
    return content, code, resp_headers
end

local function extractCsrfToken(html_body)
    return html_body and html_body:match('csrf_token"%s+value="([^"]+)"')
end

-- Returns (cookie, err). The cookie carries the authenticated session for
-- every subsequent doCwaRawFormRequest/upload call in this same process.
local function doCwaLogin(cwa_url, username, password, socks5_proxy)
    local login_page, code1, headers1 = doCwaRawFormRequest(cwa_url, nil, "GET", "/login", nil, nil, socks5_proxy)
    if not login_page then return nil, _("Couldn't reach CWA's login page.") end
    -- Flask-WTF ties the csrf_token to the specific pre-login session it
    -- was issued under -- confirmed live: posting the token back without
    -- also carrying this cookie forward gets a 400, not an auth failure.
    local pre_login_cookie = extractSessionCookie(headers1)
    local csrf_token = extractCsrfToken(login_page)
    if not csrf_token then
        return nil, _("Couldn't find CWA's login form -- its page layout may have changed.")
    end

    local body, code2, headers2 = doCwaRawFormRequest(cwa_url, pre_login_cookie, "POST", "/login", {
        csrf_token = csrf_token,
        username = username or "",
        password = password or "",
        submit = "Login",
    }, nil, socks5_proxy)
    if not body then return nil, _("Couldn't reach CWA's login page.") end
    local cookie = extractSessionCookie(headers2)
    if not cookie or (code2 ~= 200 and code2 ~= 302) then
        return nil, _("CWA login failed -- check the CWA username/password in Settings.")
    end
    return cookie
end

local function doCwaMultipartUpload(cwa_url, cookie, filename, file_bytes, socks5_proxy)
    -- A fresh csrf_token from an authenticated page -- the one from the
    -- login form above is single-use/tied to the pre-login session,
    -- confirmed while building fix_description.py: reusing it against an
    -- authenticated POST elsewhere failed until a token was re-pulled
    -- from a page fetched *with* the session cookie attached.
    local home_body = doCwaRawFormRequest(cwa_url, cookie, "GET", "/", nil, nil, socks5_proxy)
    local csrf_token = home_body and extractCsrfToken(home_body)
    if not csrf_token then
        return nil, nil, _("Couldn't get a fresh CSRF token from CWA.")
    end

    local boundary = "----shelfmarkkoplugin" .. tostring(os.time())
    local parts = {
        "--" .. boundary .. "\r\n",
        'Content-Disposition: form-data; name="btn-upload"; filename="' .. filename .. '"\r\n',
        "Content-Type: application/epub+zip\r\n\r\n",
        file_bytes,
        "\r\n--" .. boundary .. "--\r\n",
    }
    local body = table.concat(parts)

    local headers = {
        Cookie = cookie,
        ["X-CSRFToken"] = csrf_token,
        ["Content-Type"] = "multipart/form-data; boundary=" .. boundary,
        ["Content-Length"] = tostring(#body),
    }

    local url = cwa_url .. "/upload"
    debugLog("[cwa] -> POST " .. url .. " (uploading " .. filename .. ", " .. #file_bytes .. " bytes)")
    socketutil:set_timeout(20, 90)
    local sink, sink_table = socketutil.table_sink()
    local request = { method = "POST", url = url, headers = headers, sink = sink, source = ltn12.source.string(body) }
    if socks5_proxy and socks5_proxy ~= "" then
        local proxy_host, proxy_port = socks5_proxy:match("^([^:]+):(%d+)$")
        if proxy_host then
            request.create = function() return makeSocks5Socket(proxy_host, tonumber(proxy_port)) end
        end
    end
    local ok, code = pcall(function() return socket.skip(1, http.request(request)) end)
    socketutil:reset_timeout()
    if not ok then
        debugLog("[cwa] <- connection error: " .. tostring(code))
        return nil, nil, _("Upload to CWA failed -- connection error.")
    end
    debugLog("[cwa] <- HTTP " .. tostring(code) .. ", body length " .. tostring(#table.concat(sink_table)))
    return true, code
end

-- ===== device-to-device settings transfer (QR code / paste) =====
--
-- No crypto library exists anywhere in KOReader's Lua environment
-- (confirmed by a full search of its frontend/ffi/common trees for
-- anything sha/aes/crypt/cipher/hmac-shaped) -- hand-rolling a real
-- cipher like AES from scratch was the alternative, and that's a real
-- bug-surface risk to get subtly wrong for something claiming to be
-- secure. A one-time pad sidesteps that entirely: XOR the plaintext with
-- a key that is (a) truly random, (b) exactly as long as the message,
-- and (c) never reused -- all three genuinely guaranteed here, since a
-- fresh key is generated from scratch for every single use of this
-- feature -- and it is information-theoretically unbreakable, not just
-- "good enough". The pairing relay (homeserver-configs/
-- shelfmark-pairing-relay) only ever sees the ciphertext; the key travels
-- separately, folded into the same QR code/pairing text, and never
-- touches that service at all.

-- /dev/urandom, not math.random -- math.random is a plain PRNG (seeded
-- from time in KOReader), predictable enough that it must never be used
-- for anything claiming real secrecy. /dev/urandom is a real CSPRNG
-- backed by the kernel, present and world-readable on both Linux-based
-- platforms this plugin runs on (the Kindle and Android).
local function randomBytes(n)
    local f = io.open("/dev/urandom", "rb")
    if not f then return nil, _("Couldn't open /dev/urandom for randomness.") end
    local bytes = f:read(n)
    f:close()
    if not bytes or #bytes ~= n then
        return nil, _("Couldn't read enough randomness from /dev/urandom.")
    end
    return bytes
end

-- Symmetric: the same function encrypts and decrypts, since XOR is its
-- own inverse. Both arguments must be the same length.
local function xorBytes(a, b)
    if #a ~= #b then return nil, "xorBytes: length mismatch" end
    local out = {}
    for i = 1, #a do
        out[i] = string.char(bit.bxor(a:byte(i), b:byte(i)))
    end
    return table.concat(out)
end

local function doPairingUpload(relay_url, ciphertext_b64, socks5_proxy)
    local headers = { ["Content-Type"] = "application/json" }
    local body = JSON.encode({ ciphertext = ciphertext_b64 })
    headers["Content-Length"] = tostring(#body)

    local url = relay_url .. "/pair"
    debugLog("[pair] -> POST " .. url)
    socketutil:set_timeout(10, 20)
    local sink, sink_table = socketutil.table_sink()
    local request = { method = "POST", url = url, headers = headers, sink = sink, source = ltn12.source.string(body) }
    if socks5_proxy and socks5_proxy ~= "" then
        local proxy_host, proxy_port = socks5_proxy:match("^([^:]+):(%d+)$")
        if proxy_host then
            request.create = function() return makeSocks5Socket(proxy_host, tonumber(proxy_port)) end
        end
    end
    local ok, code = pcall(function() return socket.skip(1, http.request(request)) end)
    socketutil:reset_timeout()
    if not ok then
        debugLog("[pair] <- connection error: " .. tostring(code))
        return nil, nil, _("Couldn't reach the pairing relay -- check its URL.")
    end
    local content = table.concat(sink_table)
    debugLog("[pair] <- HTTP " .. tostring(code))
    if code ~= 200 then
        return nil, code, _("Pairing relay rejected the request.")
    end
    local decode_ok, decoded = pcall(JSON.decode, content)
    if not decode_ok or type(decoded) ~= "table" or type(decoded.code) ~= "string" then
        return nil, code, _("Pairing relay gave an unexpected response.")
    end
    return decoded.code, code
end

local function doPairingDownload(relay_url, pair_code, socks5_proxy)
    local url = relay_url .. "/pair/" .. pair_code
    debugLog("[pair] -> GET " .. url)
    socketutil:set_timeout(10, 20)
    local sink, sink_table = socketutil.table_sink()
    local request = { method = "GET", url = url, headers = {}, sink = sink }
    if socks5_proxy and socks5_proxy ~= "" then
        local proxy_host, proxy_port = socks5_proxy:match("^([^:]+):(%d+)$")
        if proxy_host then
            request.create = function() return makeSocks5Socket(proxy_host, tonumber(proxy_port)) end
        end
    end
    local ok, code = pcall(function() return socket.skip(1, http.request(request)) end)
    socketutil:reset_timeout()
    if not ok then
        debugLog("[pair] <- connection error: " .. tostring(code))
        return nil, nil, _("Couldn't reach the pairing relay -- check its URL.")
    end
    local content = table.concat(sink_table)
    debugLog("[pair] <- HTTP " .. tostring(code))
    if code == 404 then
        return nil, code, _("That code has already been used or has expired.")
    end
    if code ~= 200 then
        return nil, code, _("Pairing relay rejected the request.")
    end
    local decode_ok, decoded = pcall(JSON.decode, content)
    if not decode_ok or type(decoded) ~= "table" or type(decoded.ciphertext) ~= "string" then
        return nil, code, _("Pairing relay gave an unexpected response.")
    end
    return decoded.ciphertext, code
end

-- Lightweight, deliberately non-general OPDS/Atom parsing -- plain string
-- patterns rather than a real XML parser, since this only ever has to
-- understand feeds from one specific, already-inspected server (CWA), not
-- arbitrary OPDS catalogs. Pulls just title/author/the acquisition
-- download link out of each <entry>, preferring an epub acquisition link
-- when an entry happens to have more than one format available.
-- Not just for OPDS/XML despite the name's origin -- confirmed live that
-- Shelfmark's own JSON /api/releases response passes indexer release
-- titles through with raw HTML entities still in them too (e.g. "&amp;"
-- showing up literally on-screen instead of "&"), so this gets reused for
-- release titles as well, not just CWA's Atom feed.
local function decodeHtmlEntities(s)
    if not s then return s end
    return (s:gsub("&#34;", '"'):gsub("&#39;", "'"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&"))
end

local function parseOpdsEntries(xml)
    local entries = {}
    for entry_xml in xml:gmatch("<entry>(.-)</entry>") do
        local title = decodeHtmlEntities(entry_xml:match("<title>(.-)</title>"))
        local author = decodeHtmlEntities(entry_xml:match("<author>%s*<name>(.-)</name>"))
        -- CWA's own stable per-book identifier (independent of title/href,
        -- which can both change) -- kept so a redownload can be tracked
        -- for auto-sync even across a metadata edit that changes the
        -- title. Matches what CWA's /ajax/book/<uuid> endpoint expects.
        local uuid = entry_xml:match("<id>urn:uuid:(.-)</id>")
        local best_href, best_type
        for link_tag in entry_xml:gmatch("<link[^>]->") do
            if link_tag:find('rel="http://opds%-spec%.org/acquisition"') then
                local href = link_tag:match('href="([^"]+)"')
                local ltype = link_tag:match('type="([^"]+)"')
                if href and (not best_href or (ltype and ltype:find("epub", 1, true))) then
                    best_href, best_type = href, ltype
                end
            end
        end
        if title and best_href then
            table.insert(entries, { title = title, author = author, href = best_href, type = best_type, uuid = uuid })
        end
    end
    return entries
end

-- ===== library sync (device <-> CWA, no SSH/homeserver script needed) =====
--
-- Mirrors homeserver-configs/scripts/shelfmark-kindle-sync/sync.py, but
-- runs entirely on-device over plain HTTP -- built for platforms (Android
-- KOReader, notably) that don't have an SSH server the way the jailbroken
-- Kindle does, so that script has no way to reach in. Same registry file,
-- same idea in both directions: books that appear locally by any means
-- (this plugin's own downloads, a different KOReader plugin, a file
-- copied on manually) get matched against CWA or uploaded as new: books
-- already tracked get checked against CWA for changes and re-pulled.

local SYNC_STOPWORDS = { the = true, a = true, an = true, of = true, ["and"] = true, novel = true }

-- Repeatedly strips a *trailing* "(...)" group -- never content in the
-- middle of a title, which is far more likely to be meaningfully
-- title-distinguishing rather than noise. Two independent, confirmed-live
-- reasons this exists: (1) CWA's own metadata enrichment routinely appends
-- a trailing parenthetical -- "(Red Rising Series Book 2)", "(Book 3)",
-- etc -- that the original, pre-import filename never had and never could
-- have predicted, which broke titleWordsSubsetOf's match and caused
-- doSyncLibrary to silently re-upload a genuine duplicate on every
-- subsequent run (caught via CWA's own ingest logs: three separate "Golden
-- Son" uploads over two days). (2) Some sources -- confirmed live for
-- zlibrary.koplugin -- save files as "Title (Author) (mirror domains
-- tried).epub"; searching CWA with that trailing domain-list junk left in
-- returns zero results even when the book is already in the catalog under
-- a clean title, which is a different failure mode with the same
-- symptom -- caught the same way, "Fourth Wing" uploaded twice.
local function stripTrailingParenGroups(text)
    while true do
        local stripped = text:gsub("%s*%b()%s*$", " ")
        if stripped == text then break end
        text = stripped
    end
    return text
end

local function normalizeTitleWords(text)
    if not text then return {} end
    text = text:lower():gsub("%(z%-library%)", "")
    text = stripTrailingParenGroups(text)
    text = text:gsub("[^%w]+", " ")
    local words = {}
    for w in text:gmatch("%S+") do
        if not SYNC_STOPWORDS[w] and #w > 1 then
            words[w] = true
        end
    end
    return words
end

-- True only when title_words is a subset of filename_words AND filename_words
-- is fully explained by title_words plus author_words -- deliberately exact,
-- no fuzzy scoring. A looser "closest match" approach already mixed up
-- "Pines" and "Wayward Pines - 02 Wayward" for two different files during
-- the first (manual) pass at this same kind of matching for the
-- homeserver-side script -- better to flag ambiguity than guess wrong
-- silently.
--
-- The author-bound check (added after the subset-only version let a real
-- book get bounced) exists because a short series title is naturally a
-- word-subset of a longer sibling's filename: "Mistborn" is fully contained
-- in "Mistborn - The Well of Ascension - Brandon Sanderson.epub", so a
-- subset-only check matched book 2's file to book 1's already-registered
-- CWA entry and silently skipped a genuinely new book as a "duplicate".
-- Requiring every leftover filename word to be explained by the candidate's
-- own title or author rejects that case ("well"/"ascension" are neither)
-- without reintroducing the fuzzy scoring this function's history already
-- shows doesn't work here.
local function titleWordsSubsetOf(title_words, author_words, filename_words)
    local any = false
    for w in pairs(title_words) do
        any = true
        if not filename_words[w] then return false end
    end
    if not any then return false end
    for w in pairs(filename_words) do
        if not title_words[w] and not author_words[w] then return false end
    end
    return true
end

-- Runs entirely inside a Trapper subprocess (see Shelfmark:syncLibrary
-- below) -- a real fork, so file writes it makes (downloaded books, the
-- registry itself) land on the real filesystem same as if done in the
-- parent; only in-memory Lua state doesn't cross back. Returns a list of
-- plain report-line strings for the parent to display -- deliberately
-- not the registry itself, avoiding the rapidjson-null string.buffer
-- serialization trap documented on stripJsonNull above.
local function doSyncLibrary(cwa_url, cwa_username, cwa_password, socks5_proxy, download_dir)
    local report = {}
    local function addLine(s) table.insert(report, s) end

    if not cwa_url or cwa_url == "" then
        return { _("CWA URL isn't set -- add it under Shelfmark Settings.") }
    end

    if lfs.attributes(download_dir, "mode") ~= "directory" then
        -- A real, reachable case, not just defensiveness: on a fresh
        -- install nothing has downloaded a book yet, so the configured
        -- (or default) download folder may not exist at all the first
        -- time this runs.
        return { T(_("Download folder doesn't exist yet: %1"), download_dir) }
    end

    local local_files = {}
    local ok, iter, dir_obj = pcall(lfs.dir, download_dir)
    if not ok or type(iter) ~= "function" then
        return { T(_("Couldn't list %1: %2"), download_dir, tostring(iter)) }
    end
    for name in iter, dir_obj do
        if name:lower():match("%.epub$") then
            table.insert(local_files, download_dir .. "/" .. name)
        end
    end

    local registry = loadSyncRegistry()
    local known_paths = {}
    for _, entry in pairs(registry) do
        if type(entry) == "table" and entry.path then known_paths[entry.path] = true end
    end
    local unregistered = {}
    for _, path in ipairs(local_files) do
        if not known_paths[path] then table.insert(unregistered, path) end
    end

    addLine(T(_("Found %1 book(s) locally, %2 already tracked."), #local_files, #local_files - #unregistered))

    local to_upload = {}
    if #unregistered > 0 then
        addLine(T(_("Checking %1 untracked book(s) against CWA..."), #unregistered))
        -- Not "for _, path" -- that shadows gettext's _() for the rest of
        -- this loop body, which does call it (confirmed live: "attempt to
        -- call local '_' (a number value)" the first time this ran for
        -- real, thrown from the addLine(_(...)) calls below).
        for _idx, path in ipairs(unregistered) do
            local fname = path:match("([^/]+)%.[Ee][Pp][Uu][Bb]$") or path
            -- Trailing paren groups stripped first, on the real fname
            -- (with real parens still intact) -- see stripTrailingParenGroups's
            -- note above on why: zlibrary.koplugin-style filenames end in
            -- "(mirror domains tried)", and searching CWA with that left in
            -- returns zero results even when the book is already in the
            -- catalog, which is what actually caused the fresh "Fourth
            -- Wing" duplicate this fixes.
            local cleaned_fname = stripTrailingParenGroups(fname)
            -- Search on the title alone, not "Title - Author" combined --
            -- confirmed live: CWA's own OPDS search appears to AND across
            -- every word in the query, and "Dune Messiah   Frank Herbert"
            -- (title+author combined, this file's own convention for
            -- z-library-sourced filenames) returned zero entries even
            -- though "Dune Messiah" alone finds the book immediately --
            -- caught the same way as the two fixes above, a genuine
            -- "Dune Messiah" duplicate. The word-matching step below still
            -- checks the FULL fname (title and author both) for precision,
            -- so this only broadens the initial CWA search, not the actual
            -- match decision -- a real different-book match still needs
            -- the author to show up in its own title too, same as before.
            -- Only splits on a *spaced* " - " (an author separator in
            -- this convention); a hyphen with no surrounding spaces, as in
            -- an actual hyphenated title word, is left alone.
            -- Confirmed live: Anna's Archive's OWN download filenames (see
            -- doAnnasFileDownload/the annasarchive.koplugin download path)
            -- use "Lastname, Firstname - Title", the opposite order from
            -- this file's other "Title - Author" convention -- e.g. "Liu,
            -- Cixin - The Dark Forest (The Three-Body Problem)". Blindly
            -- taking the pre-separator segment as the title searched CWA
            -- for the AUTHOR NAME ("Liu, Cixin"), which real-world found a
            -- different Liu Cixin book already in CWA by author-match, that
            -- correctly failed the word-subset check (its title shares no
            -- words with the actual local file) -- so the genuinely new
            -- book got "none matched confidently, skipped" for a query that
            -- was never actually looking for it in the first place. A comma
            -- in the pre-separator segment is a reliable signal it's a
            -- "Last, First" author, not a title -- use the other side then.
            local before_sep, after_sep = cleaned_fname:match("^(.-)%s+%-%s+(.+)$")
            local search_title
            if before_sep and before_sep:find(",") and after_sep and after_sep ~= "" then
                search_title = after_sep
            elseif before_sep and before_sep ~= "" then
                search_title = before_sep
            else
                search_title = cleaned_fname
            end
            local query = search_title:gsub("[_%-%[%]%(%)]", " ")
            local resp_body, code = doCwaRequest(cwa_url, cwa_username, cwa_password,
                "/opds/search/" .. socketurl.escape(query), socks5_proxy)
            local matches = {}
            -- Separate from #matches -- see below. CWA's search genuinely
            -- returning nothing is the only case safe to treat as "not in
            -- CWA yet"; a search that DID return entries, just none our
            -- strict word-matcher trusted, is a different situation
            -- entirely and was silently falling into the same "upload it"
            -- branch as a real zero-result search -- confirmed live as the
            -- actual cause of a genuine "Dune Messiah" duplicate: CWA's
            -- search returned a real, non-empty response, the matcher just
            -- didn't recognize it, and the old logic uploaded anyway.
            local raw_entry_count = 0
            if resp_body and code == 200 then
                local fname_words = normalizeTitleWords(fname)
                local seen_uuids = {}
                for _, e in ipairs(parseOpdsEntries(resp_body)) do
                    raw_entry_count = raw_entry_count + 1
                    if e.uuid and not seen_uuids[e.uuid] then
                        if titleWordsSubsetOf(normalizeTitleWords(e.title), normalizeTitleWords(e.author), fname_words) then
                            table.insert(matches, e)
                            seen_uuids[e.uuid] = true
                        end
                    end
                end
            end
            if #matches == 1 then
                local m = matches[1]
                if registry[m.uuid] then
                    addLine(T(_("  [%1] matches already-tracked \"%2\" -- possible duplicate file, skipped."), fname, m.title))
                else
                    registry[m.uuid] = { path = path, title = m.title }
                    addLine(T(_("  [%1] matched existing CWA book \"%2\" -- registered."), fname, m.title))
                end
            elseif #matches > 1 then
                local titles = {}
                for _, m in ipairs(matches) do table.insert(titles, m.title) end
                addLine(T(_("  [%1] matched more than one CWA book (%2) -- ambiguous, skipped."), fname, table.concat(titles, ", ")))
            elseif raw_entry_count > 0 then
                -- CWA's search found something for this query, just nothing
                -- the strict word-matcher trusted as the same book -- safer
                -- to leave it for a human to check than to risk a duplicate
                -- upload. Not registered either, so it's re-checked (and
                -- can self-resolve once a future fix improves the matcher)
                -- on every subsequent sync rather than being silently
                -- dropped forever.
                addLine(T(_("  [%1] CWA search returned %2 result(s) for this query but none matched confidently -- skipped, check manually."), fname, tostring(raw_entry_count)))
            else
                table.insert(to_upload, path)
            end
        end
        -- Cancelling this (a "dismissable" subprocess -- the user can
        -- back out mid-run) kills the child immediately
        -- (ffiutil.terminateSubProcess), and the only save was at the
        -- very end -- so any matches already found this run would be
        -- silently lost and have to be re-searched from scratch next
        -- time. Saving after each phase means a cancelled run only
        -- redoes what it hadn't finished yet, not everything.
        saveSyncRegistry(registry)
    end

    if #to_upload > 0 then
        addLine(T(_("Uploading %1 new book(s) to CWA..."), #to_upload))
        local cookie, login_err = doCwaLogin(cwa_url, cwa_username, cwa_password, socks5_proxy)
        if not cookie then
            addLine(T(_("  couldn't log in to CWA to upload: %1"), tostring(login_err)))
        else
            for _idx, path in ipairs(to_upload) do -- see note above on why not "_"
                local fname = path:match("([^/]+)$") or path
                -- Confirmed live: CWA's ingest watcher silently ignores an
                -- uppercase .EPUB extension (no error, no log line at all)
                -- -- normalized here since this plugin has no control over
                -- how other sources (e.g. a Z-Library plugin) name files.
                local upload_name = fname:gsub("%.[Ee][Pp][Uu][Bb]$", ".epub")
                local f = io.open(path, "rb")
                if not f then
                    addLine(T(_("  [%1] couldn't open local file to upload."), fname))
                else
                    local file_bytes = f:read("*a")
                    f:close()
                    local up_ok, up_code, up_err = doCwaMultipartUpload(cwa_url, cookie, upload_name, file_bytes, socks5_proxy)
                    if up_ok and up_code == 200 then
                        addLine(T(_("  [%1] uploaded -- will finish registering once CWA imports it (next sync)."), fname))
                    elseif up_err then
                        addLine(T(_("  [%1] upload failed: %2"), fname, up_err))
                    else
                        addLine(T(_("  [%1] upload failed (HTTP %2)."), fname, tostring(up_code)))
                    end
                end
            end
        end
    end

    local tracked_count = 0
    for _ in pairs(registry) do tracked_count = tracked_count + 1 end
    addLine(T(_("Checking %1 tracked book(s) for CWA-side changes..."), tracked_count))
    for uuid, entry in pairs(registry) do
        if type(entry) == "table" and entry.path then
            local body, code = doCwaRequest(cwa_url, cwa_username, cwa_password, "/ajax/book/" .. uuid, socks5_proxy)
            if body and code == 200 then
                local decode_ok, decoded = pcall(JSON.decode, body)
                local book = decode_ok and stripJsonNull(decoded)
                local last_modified = book and book.last_modified
                if type(last_modified) == "string" then
                    if not entry.last_modified then
                        entry.last_modified = last_modified
                    elseif entry.last_modified ~= last_modified then
                        local epub_path = book.main_format and book.main_format.epub
                        if type(epub_path) == "string" then
                            addLine(T(_("  [%1] changed in CWA, re-downloading..."), entry.title or uuid))
                            local dl_ok = doCwaFileDownload(cwa_url, cwa_username, cwa_password, epub_path, socks5_proxy, entry.path)
                            if dl_ok then
                                entry.last_modified = last_modified
                                addLine(T(_("  [%1] synced."), entry.title or uuid))
                            else
                                addLine(T(_("  [%1] re-download failed."), entry.title or uuid))
                            end
                        end
                    end
                end
            end
        end
    end

    saveSyncRegistry(registry)
    addLine(_("Done."))
    return report
end

-- KOReader's own equivalent list (readersearch.lua's find-results Menu)
-- uses the same covers_fullscreen/is_borderless/is_popout/title_bar_fm_style
-- combination we do, so that's not the differentiator -- but it also sets
-- multilines_forced/items_max_lines and only ever feeds it short text.
-- Our "mandatory" field (author lists) and release titles (full torrent/
-- usenet filenames) can run well past what that field is normally used
-- for (confirmed: a 4-author book, and scene-release-style filenames with
-- quality/codec tags, both 80+ chars). Truncating defensively here even
-- though the exact crash mechanism (a native SIGABRT with no Lua
-- traceback) isn't confirmed -- this narrows a real, concrete difference
-- from the working reference case.
--
-- Defined here (ahead of downloadFromCwa/apiRequest) rather than down by
-- its other original callers (describeBook et al.) -- it was defined too
-- late in the file to be in scope for downloadFromCwa's item_table build,
-- a real bug confirmed via crash.log: "attempt to call global 'truncate'
-- (a nil value)" on every single tap-to-download attempt, thrown before
-- the CWA-matches menu ever got shown. Trapper:wrap swallows the error
-- with no UI feedback at all (frontend/ui/trapper.lua just logger.warns
-- it), which is exactly why this looked like a silent no-op rather than a
-- crash -- there was no dialog, no error message, nothing on-screen.
local function truncate(text, maxlen)
    if type(text) ~= "string" or #text <= maxlen then return text end
    -- Byte position, not character position -- back off while the byte
    -- right after the cut is a UTF-8 continuation byte (0x80-0xBF) so a
    -- multi-byte character never gets sliced in half. A cut mid-character
    -- leaves a malformed trailing byte sequence right before the appended
    -- "…", which is exactly the kind of malformed UTF-8 that has already
    -- been confirmed (see the ConfirmBox note below) to cause a native,
    -- untraceable crash rather than a catchable Lua error -- and explains
    -- why this only ever showed up on Hardcover-sourced Discover results
    -- (real bibliographic titles/author names, full of diacritics and
    -- non-ASCII) and never on Prowlarr release titles (plain-ASCII scene
    -- filenames).
    local cut = maxlen - 1
    while cut > 0 do
        local b = text:byte(cut + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end
        cut = cut - 1
    end
    return text:sub(1, cut) .. "…" -- raw UTF-8, not \u{} -- see bullet note above
end

-- Runs the whole request off the main UI thread via Trapper's subprocess
-- execution, showing a cancelable progress dialog. The releases search in
-- particular can take real time (it's actively querying Prowlarr/other
-- indexers live), and a synchronous call on the main thread was a real,
-- reproducible cause of the app freezing during it -- and plausibly of the
-- earlier native crashes too, if Android's watchdog decided the
-- unresponsive app needed to be force-killed. Must be called from within a
-- Trapper:wrap()'d coroutine (every entry point below is).
function Shelfmark:apiRequest(method, path, body, progress_text, block_timeout, total_timeout)
    local Trapper = require("ui/trapper")
    local server_url, username, password, cookie, socks5_proxy =
        self.server_url, self.username, self.password, self.session_cookie, self.socks5_proxy

    local completed, resp, code, new_cookie, err = Trapper:dismissableRunInSubprocess(function()
        return doApiRequest(server_url, username, password, cookie, method, path, body, socks5_proxy, block_timeout, total_timeout)
    end, progress_text or _("Talking to Shelfmark..."))

    if not completed then
        return nil, nil, _("Cancelled.")
    end
    if new_cookie then
        self.session_cookie = new_cookie
    end
    return resp, code, err
end

-- Mirrors apiRequest's Trapper-subprocess wrapping above, but for CWA's
-- simpler basic-auth (there's no session cookie to carry back across the
-- fork boundary the way Shelfmark's login needs).
function Shelfmark:cwaRequest(path, progress_text)
    local Trapper = require("ui/trapper")
    local cwa_url, cwa_username, cwa_password, socks5_proxy =
        self.cwa_url, self.cwa_username, self.cwa_password, self.socks5_proxy

    local completed, body, code, err = Trapper:dismissableRunInSubprocess(function()
        return doCwaRequest(cwa_url, cwa_username, cwa_password, path, socks5_proxy)
    end, progress_text or _("Searching CWA..."))

    if not completed then return nil, nil, _("Cancelled.") end
    return body, code, err
end

function Shelfmark:cwaFileDownload(path, save_path, progress_text)
    local Trapper = require("ui/trapper")
    local cwa_url, cwa_username, cwa_password, socks5_proxy =
        self.cwa_url, self.cwa_username, self.cwa_password, self.socks5_proxy

    local completed, ok, code, err = Trapper:dismissableRunInSubprocess(function()
        return doCwaFileDownload(cwa_url, cwa_username, cwa_password, path, socks5_proxy, save_path)
    end, progress_text or _("Downloading book..."))

    if not completed then return nil, nil, _("Cancelled.") end
    return ok, code, err
end

-- Mirrors apiRequest/cwaRequest's Trapper-subprocess wrapping above.
function Shelfmark:annasSearch(query, progress_text)
    local Trapper = require("ui/trapper")
    local annas_url, download_key, tld, socks5_proxy =
        self.annas_url, self.annas_download_key, self.annas_tld, self.socks5_proxy

    local completed, results, code, err, err_code = Trapper:dismissableRunInSubprocess(function()
        return doAnnasSearch(annas_url, download_key, tld, query, socks5_proxy)
    end, progress_text or _("Searching Anna's Archive..."))

    if not completed then return nil, nil, _("Cancelled.") end
    return results, code, err, err_code
end

-- See doAnnasMirrorRefresh above for when this actually gets called.
function Shelfmark:annasMirrorRefresh()
    local Trapper = require("ui/trapper")
    local annas_url, socks5_proxy = self.annas_url, self.socks5_proxy

    local completed, result, code, err = Trapper:dismissableRunInSubprocess(function()
        return doAnnasMirrorRefresh(annas_url, socks5_proxy)
    end, _("Looking for a working Anna's Archive mirror..."))

    if not completed then return nil, nil, _("Cancelled.") end
    return result, code, err
end

function Shelfmark:hardcoverFindBook(title, author)
    local Trapper = require("ui/trapper")
    local token = self.hardcover_token
    local completed, id, found_title, found_author, err = Trapper:dismissableRunInSubprocess(function()
        return doHardcoverFindBook(token, title, author)
    end, _("Searching Hardcover..."))
    if not completed then return nil, nil, nil, _("Cancelled.") end
    return id, found_title, found_author, err
end

function Shelfmark:hardcoverSetStatus(book_id, status_id)
    local Trapper = require("ui/trapper")
    local token = self.hardcover_token
    local completed, ok, err = Trapper:dismissableRunInSubprocess(function()
        return doHardcoverSetStatus(token, book_id, status_id)
    end, _("Updating Hardcover..."))
    if not completed then return false, _("Cancelled.") end
    return ok, err
end

function Shelfmark:hardcoverFindAuthor(name)
    local Trapper = require("ui/trapper")
    local token = self.hardcover_token
    local completed, id, found_name, err = Trapper:dismissableRunInSubprocess(function()
        return doHardcoverFindAuthor(token, name)
    end, _("Searching Hardcover..."))
    if not completed then return nil, nil, _("Cancelled.") end
    return id, found_name, err
end

function Shelfmark:hardcoverFollowAuthor(author_id)
    local Trapper = require("ui/trapper")
    local token = self.hardcover_token
    local completed, ok, err = Trapper:dismissableRunInSubprocess(function()
        return doHardcoverFollowAuthor(token, author_id)
    end, _("Following on Hardcover..."))
    if not completed then return false, _("Cancelled.") end
    return ok, err
end

function Shelfmark:hardcoverListFollowedAuthors()
    local Trapper = require("ui/trapper")
    local token = self.hardcover_token
    local completed, authors, err = Trapper:dismissableRunInSubprocess(function()
        return doHardcoverListFollowedAuthors(token)
    end, _("Loading followed authors..."))
    if not completed then return nil, _("Cancelled.") end
    return authors, err
end

function Shelfmark:hardcoverAuthorBibliography(author_id, limit, offset)
    local Trapper = require("ui/trapper")
    local token = self.hardcover_token
    local completed, books, total, author_name, err = Trapper:dismissableRunInSubprocess(function()
        return doHardcoverAuthorBibliography(token, author_id, limit, offset)
    end, _("Loading author's books..."))
    if not completed then return nil, nil, nil, _("Cancelled.") end
    return books, total, author_name, err
end

function Shelfmark:annasFetchDownloadUrl(md5, progress_text)
    local Trapper = require("ui/trapper")
    local annas_url, download_key, tld, socks5_proxy =
        self.annas_url, self.annas_download_key, self.annas_tld, self.socks5_proxy

    local completed, dl_url, code, err = Trapper:dismissableRunInSubprocess(function()
        return doAnnasFetchDownloadUrl(annas_url, download_key, tld, md5, socks5_proxy)
    end, progress_text or _("Fetching download link..."))

    if not completed then return nil, nil, _("Cancelled.") end
    return dl_url, code, err
end

-- Manual trigger for doSyncLibrary above -- runs in a Trapper subprocess
-- since it can involve several network round-trips in sequence (OPDS
-- searches, a login, one or more uploads, then a check per tracked book),
-- same reasoning as every other network entry point in this file.
function Shelfmark:syncLibrary()
    local Trapper = require("ui/trapper")
    local cwa_url, cwa_username, cwa_password, socks5_proxy =
        self.cwa_url, self.cwa_username, self.cwa_password, self.socks5_proxy
    local download_dir = (self.download_dir and self.download_dir ~= "") and self.download_dir
        or self:defaultDownloadDir()

    local completed, report = Trapper:dismissableRunInSubprocess(function()
        return doSyncLibrary(cwa_url, cwa_username, cwa_password, socks5_proxy, download_dir)
    end, _("Syncing library with CWA..."))

    if not completed then return end
    if type(report) ~= "table" or #report == 0 then
        UIManager:show(InfoMessage:new{ text = _("Sync finished with no output.") })
        return
    end

    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{
        title = _("Library sync report"),
        text = table.concat(report, "\n"),
        justified = false,
    })
end

-- Mirrors syncLibrary's Trapper-subprocess wrapping above.
function Shelfmark:checkForUpdate()
    local Trapper = require("ui/trapper")
    local completed, info, code, err = Trapper:dismissableRunInSubprocess(function()
        return doCheckForUpdate()
    end, _("Checking for updates..."))

    if not completed then return end
    if not info then
        UIManager:show(InfoMessage:new{ text = err or T(_("Couldn't check for updates (HTTP %1)."), tostring(code)) })
        return
    end

    local remote_version = info.tag_name
    if not isNewerVersion(remote_version, PLUGIN_VERSION) then
        UIManager:show(InfoMessage:new{ text = T(_("You're up to date (v%1)."), PLUGIN_VERSION) })
        return
    end

    local ConfirmBox = require("ui/widget/confirmbox")
    local notes = truncate((info.body or ""):gsub("\r\n", "\n"), 500)
    local msg = T(_("%1 is available (you have v%2).\n\n%3"), tostring(info.name or remote_version), PLUGIN_VERSION, notes)
    UIManager:show(ConfirmBox:new{
        text = msg,
        ok_text = _("Update"),
        ok_callback = function()
            local Trapper2 = require("ui/trapper")
            Trapper2:wrap(function() self:applyUpdate(remote_version) end)
        end,
    })
end

function Shelfmark:applyUpdate(tag)
    local Trapper = require("ui/trapper")
    local completed, ok, err = Trapper:dismissableRunInSubprocess(function()
        return doApplyUpdate(tag)
    end, _("Downloading update..."))

    if not completed then return end
    if not ok then
        UIManager:show(InfoMessage:new{ text = err or _("Update failed.") })
        return
    end
    UIManager:show(InfoMessage:new{
        text = _("Updated. Restart KOReader for the new version to take effect."),
        timeout = 6,
    })
end

-- ===== device-to-device settings transfer (QR code / paste) =====

-- Shared by showSetupQrCode/importSettingsFromText -- both need the
-- relay URL first and do the same "ask once, save it, then continue"
-- dance if it isn't set yet.
function Shelfmark:promptPairingRelayUrl(on_success)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Pairing relay URL"),
        description = _("A small always-on service both devices can reach (homeserver-configs/shelfmark-pairing-relay). Only asked once -- saved after this."),
        input = "",
        input_hint = _("e.g. http://homeserver:8086"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Continue"),
                    is_enter_default = true,
                    callback = function()
                        local url = dialog:getInputText()
                        UIManager:close(dialog)
                        if url and url:gsub("%s", "") ~= "" then
                            self.pairing_relay_url = url:gsub("/*$", "")
                            self:saveAllSettings(_("Saved."))
                            on_success()
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Shelfmark:showSetupQrCode()
    if not self.pairing_relay_url or self.pairing_relay_url == "" then
        self:promptPairingRelayUrl(function() self:showSetupQrCode() end)
        return
    end

    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("This shows a QR code carrying your Shelfmark and CWA settings (encrypted, but visible to anyone who can see or photograph the screen while it's open). It expires in 5 minutes either way. Continue?"),
        ok_text = _("Show it"),
        ok_callback = function()
            local Trapper = require("ui/trapper")
            Trapper:wrap(function() self:generateAndShowPairingQr() end)
        end,
    })
end

-- Runs as a Trapper:wrap coroutine (see caller) -- the encryption itself
-- is local/instant and stays on the main thread; only the actual upload
-- to the pairing relay forks a subprocess, same division as every other
-- network entry point in this file.
function Shelfmark:generateAndShowPairingQr()
    local plaintext = JSON.encode({
        server_url = self.server_url,
        username = self.username,
        password = self.password,
        socks5_proxy = self.socks5_proxy,
        cwa_url = self.cwa_url,
        cwa_username = self.cwa_username,
        cwa_password = self.cwa_password,
    })

    local key, rand_err = randomBytes(#plaintext)
    if not key then
        UIManager:show(InfoMessage:new{ text = rand_err })
        return
    end
    local ciphertext, xor_err = xorBytes(plaintext, key)
    if not ciphertext then
        UIManager:show(InfoMessage:new{ text = tostring(xor_err) })
        return
    end
    local ciphertext_b64 = mime.b64(ciphertext)
    local key_b64 = mime.b64(key)

    local relay_url, socks5_proxy = self.pairing_relay_url, self.socks5_proxy
    local Trapper = require("ui/trapper")
    local completed, pair_code, code, err = Trapper:dismissableRunInSubprocess(function()
        return doPairingUpload(relay_url, ciphertext_b64, socks5_proxy)
    end, _("Uploading encrypted settings..."))

    if not completed then return end
    if not pair_code then
        UIManager:show(InfoMessage:new{ text = err or T(_("Pairing relay error (HTTP %1)."), tostring(code)) })
        return
    end

    -- The key never touches the pairing relay -- it only ever exists in
    -- this string, which only ever exists on-screen as a QR code (or in
    -- transit, decoded, on the importing device). See the note above
    -- doPairingUpload for why that split is what makes this a real
    -- one-time pad rather than security theater.
    local pairing_text = "shelfmark-pair:" .. pair_code .. ":" .. key_b64

    local QRMessage = require("ui/widget/qrmessage")
    local Screen = require("device").screen
    UIManager:show(QRMessage:new{
        text = pairing_text,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        timeout = 300, -- matches the pairing relay's own 5-minute expiry
    })
end

function Shelfmark:importSettingsFromText()
    if not self.pairing_relay_url or self.pairing_relay_url == "" then
        self:promptPairingRelayUrl(function() self:importSettingsFromText() end)
        return
    end

    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Import settings"),
        description = _("Paste the text your camera/QR app decoded from the other device's QR code."),
        input = "",
        allow_newline = true,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Import"),
                    is_enter_default = true,
                    callback = function()
                        local pairing_text = dialog:getInputText()
                        UIManager:close(dialog)
                        if pairing_text and pairing_text:gsub("%s", "") ~= "" then
                            local Trapper = require("ui/trapper")
                            Trapper:wrap(function() self:applyPairingText(pairing_text) end)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Shelfmark:applyPairingText(pairing_text)
    local trimmed = pairing_text:gsub("^%s+", ""):gsub("%s+$", "")
    local pair_code, key_b64 = trimmed:match("^shelfmark%-pair:([0-9a-f]+):(%S+)$")
    if not pair_code then
        UIManager:show(InfoMessage:new{ text = _("That doesn't look like a Shelfmark pairing code.") })
        return
    end

    local relay_url, socks5_proxy = self.pairing_relay_url, self.socks5_proxy
    local Trapper = require("ui/trapper")
    local completed, ciphertext_b64, code, err = Trapper:dismissableRunInSubprocess(function()
        return doPairingDownload(relay_url, pair_code, socks5_proxy)
    end, _("Fetching encrypted settings..."))

    if not completed then return end
    if not ciphertext_b64 then
        UIManager:show(InfoMessage:new{ text = err or T(_("Pairing relay error (HTTP %1)."), tostring(code)) })
        return
    end

    local key_ok, key = pcall(mime.unb64, key_b64)
    local ciphertext = ciphertext_b64 and mime.unb64(ciphertext_b64)
    if not key_ok or not key or not ciphertext or #ciphertext ~= #key then
        UIManager:show(InfoMessage:new{ text = _("Pairing data looked corrupted (bad encoding or length mismatch).") })
        return
    end
    local plaintext, xor_err = xorBytes(ciphertext, key)
    if not plaintext then
        UIManager:show(InfoMessage:new{ text = tostring(xor_err) })
        return
    end
    local decode_ok, settings_tbl = pcall(JSON.decode, plaintext)
    if not decode_ok or type(settings_tbl) ~= "table" then
        UIManager:show(InfoMessage:new{ text = _("Decrypted data wasn't valid settings.") })
        return
    end
    settings_tbl = stripJsonNull(settings_tbl)

    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = T(_("Import these settings?\n\nServer: %1\nCWA: %2\n\nThis overwrites your current Server settings and CWA settings on this device. Your download folder is left alone -- that stays per-device."),
            tostring(settings_tbl.server_url), tostring(settings_tbl.cwa_url)),
        ok_text = _("Import"),
        ok_callback = function()
            self.server_url = settings_tbl.server_url or nil
            self.username = settings_tbl.username or nil
            self.password = settings_tbl.password or nil
            self.socks5_proxy = settings_tbl.socks5_proxy or nil
            self.cwa_url = settings_tbl.cwa_url or nil
            self.cwa_username = settings_tbl.cwa_username or nil
            self.cwa_password = settings_tbl.cwa_password or nil
            self:saveAllSettings(_("Settings imported."))
        end,
    })
end

-- Shelfmark itself has no record of where a delivered file ends up -- it
-- hands the file off to CWA's ingest folder and doesn't track it past
-- that point (confirmed against the request_routes.py/user_db.py schema:
-- no file-path or download-URL column exists on a request at all). So
-- "tap a delivered request to get the file" has to mean something
-- different in practice: search CWA's own OPDS catalog by title (the book
-- should already be imported there by the time a request shows
-- delivery_state "complete") and let you download straight from there.
function Shelfmark:downloadFromCwa(title)
    if not self.cwa_url or self.cwa_url == "" then
        UIManager:show(InfoMessage:new{
            text = _("Add a CWA URL under Shelfmark Settings to enable downloading from here."),
        })
        return
    end

    local body, code, err = self:cwaRequest("/opds/search/" .. socketurl.escape(title))
    if err then
        UIManager:show(InfoMessage:new{ text = err })
        return
    end
    if code ~= 200 or not body then
        UIManager:show(InfoMessage:new{ text = T(_("CWA search failed (HTTP %1)"), tostring(code)) })
        return
    end

    local entries = parseOpdsEntries(body)
    if #entries == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No matching book found in CWA yet -- it may still be importing."),
            timeout = 3,
        })
        return
    end

    local item_table = {}
    for i, e in ipairs(entries) do
        item_table[i] = {
            text = truncate(e.title, 70) or e.title,
            mandatory = truncate(e.author or "", 30),
            entry = e,
        }
    end

    local results_menu
    results_menu = Menu:new{
        title = _("Matches in CWA -- tap to download"),
        item_table = item_table,
        multilines_forced = true,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        onMenuSelect = function(_menu_self, item)
            UIManager:close(results_menu)
            local Trapper = require("ui/trapper")
            Trapper:wrap(function() self:saveCwaEntry(item.entry) end)
        end,
    }
    UIManager:show(results_menu)
end

function Shelfmark:saveCwaEntry(entry)
    local dir = (self.download_dir and self.download_dir ~= "") and self.download_dir or self:defaultDownloadDir()
    if lfs.attributes(dir, "mode") ~= "directory" then
        -- One level at a time -- lfs.mkdir isn't recursive (no "mkdir -p"),
        -- so a configured path several levels below an existing root (e.g.
        -- a fresh "/mnt/us/documents/shelfmark") needs each segment created
        -- in order or the final mkdir fails on a missing parent.
        local built = ""
        for segment in dir:gmatch("[^/]+") do
            built = built .. "/" .. segment
            if lfs.attributes(built, "mode") ~= "directory" then
                lfs.mkdir(built)
            end
        end
        if lfs.attributes(dir, "mode") ~= "directory" then
            UIManager:show(InfoMessage:new{
                text = T(_("Couldn't create download folder: %1"), dir),
            })
            return
        end
    end
    local ext = entry.href:match("([^/]+)/?$") or "epub"
    local safe_title = (entry.title or "book"):gsub('[/\\:%*%?"<>|]', "_")
    local save_path = dir .. "/" .. safe_title .. "." .. ext

    local ok, code, err = self:cwaFileDownload(entry.href, save_path)
    if err then
        UIManager:show(InfoMessage:new{ text = err })
        return
    end
    if not ok or code ~= 200 then
        UIManager:show(InfoMessage:new{ text = T(_("Download failed (HTTP %1)"), tostring(code)) })
        return
    end
    UIManager:show(InfoMessage:new{
        text = T(_("Saved to %1"), save_path),
        timeout = 4,
    })

    registerSyncedBook(entry.uuid, save_path, entry.title)

    -- The file manager (if it's the screen this was opened from, which it
    -- usually is -- Shelfmark's menu lives in the file browser's menu, not
    -- the reader's) only re-lists a folder when it navigates into it; it
    -- has no way to know a background download just dropped a new file
    -- into whatever folder it's already sitting on, so without this the
    -- new book is genuinely invisible there until you leave and come back.
    -- Confirmed as the actual cause live: the file existed on disk (SSH
    -- ls) the whole time the file manager claimed otherwise.
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then
        FileManager.instance:onRefresh()
    end
end

-- ===== menu =====

function Shelfmark:addToMainMenu(menu_items)
    menu_items.shelfmark = {
        text = _("Shelfmark"),
        sub_item_table = {
            {
                text = _("Search & request a book"),
                keep_menu_open = true,
                callback = function() self:startSearch() end,
            },
            -- Two direct entries instead of a "Discover" submenu that just
            -- led to these same two choices -- cuts one menu hop (open,
            -- render, close) off every Discover-originated flow. This
            -- matters because of a confirmed live bug: the confirmation
            -- dialog after tapping an NZB release can get silently stomped
            -- by a third-party home-screen plugin's own periodic UI
            -- refresh, and how often that race is actually lost tracks with
            -- how much wall-clock time/menu traffic elapses before the
            -- dialog tries to show -- Discover's extra submenu hop plus its
            -- much larger default result list (see the limit=30 below) gave
            -- it meaningfully more exposure than typed search ever had.
            {
                text = _("Most popular"),
                keep_menu_open = true,
                callback = function()
                    local Trapper = require("ui/trapper")
                    Trapper:wrap(function()
                        self:doSearch({ query = "*", page = 1, limit = 30, title_override = _("Most Popular") })
                    end)
                end,
            },
            {
                text = _("My requests"),
                keep_menu_open = true,
                callback = function()
                    local Trapper = require("ui/trapper")
                    Trapper:wrap(function() self:showMyRequests() end)
                end,
            },
            {
                text = _("Sync library with CWA"),
                keep_menu_open = true,
                callback = function() self:syncLibrary() end,
            },
            -- Every action here is manual/explicit -- see the section note
            -- above doHardcoverGraphQL for why there's no automatic
            -- "detect when I've finished a book" step.
            {
                text = _("Hardcover"),
                separator = true,
                sub_item_table = {
                    {
                        text = _("Follow an author..."),
                        keep_menu_open = true,
                        callback = function() self:promptHardcoverFollowAuthor() end,
                    },
                    {
                        text = _("Followed authors..."),
                        keep_menu_open = true,
                        callback = function()
                            local Trapper = require("ui/trapper")
                            Trapper:wrap(function() self:browseFollowedAuthors() end)
                        end,
                    },
                    {
                        text = _("Browse a Hardcover list..."),
                        keep_menu_open = true,
                        separator = true,
                        callback = function()
                            local Trapper = require("ui/trapper")
                            Trapper:wrap(function() self:browseHardcoverLists() end)
                        end,
                    },
                },
            },
            -- Everything below is either one-time setup or rarely touched
            -- day to day -- folded into one submenu so the top level stays
            -- to the things actually used every session.
            {
                text = _("Settings"),
                sub_item_table = {
                    {
                        text = _("Server settings"),
                        keep_menu_open = true,
                        callback = function() self:editServerSettings() end,
                    },
                    {
                        text = _("CWA settings"),
                        keep_menu_open = true,
                        callback = function() self:editCwaSettings() end,
                    },
                    {
                        text = _("Anna's Archive settings"),
                        keep_menu_open = true,
                        callback = function() self:editAnnasSettings() end,
                    },
                    {
                        text = _("Hardcover settings"),
                        keep_menu_open = true,
                        callback = function() self:editHardcoverSettings() end,
                    },
                    {
                        text_func = function()
                            return T(_("Download folder: %1"), self.download_dir or self:defaultDownloadDir())
                        end,
                        keep_menu_open = true,
                        callback = function() self:chooseDownloadDir() end,
                    },
                    {
                        text = _("Show setup QR code"),
                        keep_menu_open = true,
                        callback = function() self:showSetupQrCode() end,
                    },
                    {
                        text = _("Import settings from text"),
                        keep_menu_open = true,
                        separator = true,
                        callback = function() self:importSettingsFromText() end,
                    },
                    {
                        text_func = function()
                            return T(_("Check for updates (v%1)"), PLUGIN_VERSION)
                        end,
                        keep_menu_open = true,
                        callback = function()
                            local Trapper = require("ui/trapper")
                            Trapper:wrap(function() self:checkForUpdate() end)
                        end,
                    },
                    {
                        text = _("View debug log"),
                        keep_menu_open = true,
                        callback = function() self:showDebugLog() end,
                    },
                },
            },
        },
    }
end

function Shelfmark:showDebugLog()
    local TextViewer = require("ui/widget/textviewer")
    local f = io.open(DEBUG_LOG_PATH, "r")
    local content
    if f then
        content = f:read("*a")
        f:close()
    end
    if not content or content == "" then
        content = _("No debug log yet -- try a search first.")
    else
        -- Keep only the tail: this file appends across every session, and
        -- TextViewer isn't meant for huge bodies of text.
        local max_chars = 6000
        if #content > max_chars then
            content = "...\n" .. content:sub(-max_chars)
        end
    end
    local viewer
    viewer = TextViewer:new{
        title = _("Shelfmark debug log"),
        text = content,
        justified = false,
        add_default_buttons = true, -- keep the built-in "Close" alongside ours
        buttons_table = {
            {
                {
                    text = _("Clear log"),
                    callback = function()
                        local ConfirmBox = require("ui/widget/confirmbox")
                        UIManager:show(ConfirmBox:new{
                            text = _("Clear the debug log?"),
                            ok_text = _("Clear"),
                            ok_callback = function()
                                local cf = io.open(DEBUG_LOG_PATH, "w")
                                if cf then cf:close() end
                                UIManager:close(viewer)
                            end,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(viewer)
end

-- ===== search + request flow =====

function Shelfmark:startSearch()
    -- Two fields rather than one free-text box: Hardcover (the configured
    -- metadata provider) exposes a dedicated "author" search field,
    -- separate from its generic title/keyword search -- using it actually
    -- surfaces an author's other books, instead of relying on relevance
    -- ranking of a plain-text query to happen to turn them up.
    self.search_dialog = MultiInputDialog:new{
        title = _("Search Shelfmark"),
        fields = {
            { hint = _("Title or keywords") },
            { hint = _("Author (optional)") },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(self.search_dialog) end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local fields = self.search_dialog:getFields()
                        local query = fields[1] or ""
                        local author = fields[2] or ""
                        UIManager:close(self.search_dialog)
                        if query ~= "" or author ~= "" then
                            local Trapper = require("ui/trapper")
                            Trapper:wrap(function()
                                self:doSearch({ query = query, author = author, page = 1 })
                            end)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(self.search_dialog)
    self.search_dialog:onShowKeyboard()
end

-- ===== discovery =====

-- Hardcover's "Most Popular" isn't its own endpoint -- it's sort=
-- popularity (users_count:desc) applied to a wildcard query. A genuinely
-- empty query is rejected server-side ("Either 'query' or search field
-- values are required", confirmed live), but query="*" isn't empty and
-- Hardcover/Typesense treats it as match-everything -- confirmed live
-- against the real server: query=*&sort=popularity returns exactly the
-- global top-users_count books (1984, Project Hail Mary, Harry Potter,
-- Dune, ...), not an error. ("Most popular" is a direct entry in the main
-- menu -- see addToMainMenu -- rather than living behind a separate
-- "Discover" submenu. There used to be a "My Hardcover lists" entry here
-- too, browsing the connected account's own curated lists -- dropped by
-- explicit request, since Shelfmark's connected Hardcover account is the
-- device owner's personal one, shared as the metadata source for both
-- Kindles.)

local function describeAuthor(book)
    if book.authors and #book.authors > 0 then
        return table.concat(book.authors, ", ")
    end
    return ""
end

-- Title + author, used as the manual_query sent straight to browseReleases
-- as soon as a book is picked -- an explicit choice to accept the
-- AND-indexer risk Shelfmark's own devs backed out of (see the note on
-- browseReleases) in exchange for not needing a second tap into "Custom
-- search query..." just to get the same qualified query every time.
local function defaultReleaseQuery(book)
    local author = describeAuthor(book)
    return table.concat({ book.title or "", author }, " "):gsub("^%s+", ""):gsub("%s+$", "")
end

-- Hardcover's search results carry a display_fields list -- Rating (e.g.
-- "4.5 (3,764)") and Readers, when available -- which is exactly the
-- popularity signal the sort=popularity ordering is already using;
-- surfacing the actual numbers makes that ranking legible instead of
-- just trusting it blindly.
local function describeMetrics(book)
    if type(book.display_fields) ~= "table" then return "" end
    local parts = {}
    for _, f in ipairs(book.display_fields) do
        if f.label and f.value then
            table.insert(parts, f.label .. " " .. f.value)
        end
    end
    return table.concat(parts, " \xC2\xB7 ") -- " · ", raw UTF-8 bytes
end

-- type-checked rather than a truthy check: a missing publish_year decodes
-- as KOReader's JSON-null sentinel, which is truthy but not a number --
-- tostring()-ing it printed literal "function: 0x..." in the list
-- (confirmed on-device) instead of just omitting the year.
local function describeYear(book)
    if type(book.publish_year) == "number" then
        return " (" .. tostring(book.publish_year) .. ")"
    end
    return ""
end

-- KOReader's TextBoxWidget "Pango Text Format" bold-span markup: a leading
-- PTF_HEADER unlocks PTF_BOLD_START..PTF_BOLD_END spans later in the same
-- string (confirmed in frontend/ui/widget/textboxwidget.lua -- a real,
-- general widget feature, not something zlibrary.koplugin invented, though
-- reading its own row-building code is what surfaced it here). Raw UTF-8
-- bytes for U+FFF1/FFF2/FFF3, not \u{} escapes -- LuaJIT/Lua 5.1 doesn't
-- support that escape form (see the note on describeMetrics' bullet char).
local PTF_HEADER = "\xEF\xBF\xB1"
local PTF_BOLD_START = "\xEF\xBF\xB2"
local PTF_BOLD_END = "\xEF\xBF\xB3"

-- One flowing line -- bold title, "by Author (Year)", then metrics joined
-- with " | " -- that wraps naturally across as many lines as it actually
-- needs, rather than forcing title/byline/metrics onto three fixed lines
-- regardless of how short any one of them is. Matches zlibrary.koplugin's
-- own row format (read directly from its ui.lua: `"%s by %s%s"` plus
-- " | "-joined extras) -- the previous three-line layout looked visibly
-- choppier and wasted a full line on short titles/authors by comparison.
local function formatBookRowText(book, maxlen)
    local title = truncate(book.title, maxlen or 300) or _("Untitled")
    local text = PTF_HEADER .. PTF_BOLD_START .. title .. PTF_BOLD_END
    local author = describeAuthor(book)
    if author ~= "" then
        text = text .. " " .. T(_("by %1"), author) .. describeYear(book)
    else
        text = text .. describeYear(book)
    end
    local metrics = describeMetrics(book)
    if metrics ~= "" then
        text = text .. " | " .. metrics
    end
    return text
end

local function describeBook(book)
    local text = truncate(book.title, 90) or _("Untitled")
    local author = describeAuthor(book)
    if author ~= "" then
        text = text .. "\n" .. author
    end
    text = text .. describeYear(book)
    local metrics = describeMetrics(book)
    if metrics ~= "" then
        text = text .. "\n" .. metrics
    end
    return text
end

-- params: {query=, author=, page=, limit=, fields=, title_override=}. fields
-- is an optional {key=value} table of Hardcover's own advanced search
-- fields (e.g. hardcover_list) sent alongside/instead of query -- currently
-- unused by any caller in this file, kept as general-purpose plumbing.
-- limit defaults to 100; the Discover-originated "Most popular" caller in
-- addToMainMenu passes 30 instead, to cut down how much there is to scroll
-- through before reaching a release -- see the note there on why that
-- exposure window matters. existing_books, when given, is the accumulated
-- result list so far (used by "Load more" to append rather than replace).
function Shelfmark:doSearch(params, existing_books)
    UIManager:show(InfoMessage:new{ text = _("Searching..."), timeout = 1 })

    local qs = { "limit=" .. tostring(params.limit or 100), "sort=popularity", "page=" .. tostring(params.page or 1) }
    if params.query and params.query ~= "" then
        table.insert(qs, "query=" .. socketurl.escape(params.query))
    end
    if params.author and params.author ~= "" then
        table.insert(qs, "author=" .. socketurl.escape(params.author))
    end
    if params.fields then
        for key, value in pairs(params.fields) do
            table.insert(qs, socketurl.escape(key) .. "=" .. socketurl.escape(value))
        end
    end

    local resp, code, err = self:apiRequest("GET", "/api/metadata/search?" .. table.concat(qs, "&"))
    if err then
        UIManager:show(InfoMessage:new{ text = err })
        return
    end
    if code ~= 200 or not resp or not resp.books then
        local msg = (resp and (resp.message or resp.error)) or _("Search failed.")
        UIManager:show(InfoMessage:new{ text = msg })
        return
    end

    local books = existing_books or {}
    for _, book in ipairs(resp.books) do
        table.insert(books, book)
    end

    if #books == 0 then
        UIManager:show(InfoMessage:new{ text = _("No results.") })
        return
    end

    -- Only prefetch enough covers for the page actually shown first --
    -- books carried over via existing_books already have cover_path set on
    -- the same table (mutated in place, not copied) from their own
    -- original prefetch; the rest of this batch loads lazily as the reader
    -- pages to it (see attachCoverSupport).
    local first_page_books = {}
    for i = 1, math.min(#resp.books, COVER_ITEMS_PER_PAGE) do
        first_page_books[i] = resp.books[i]
    end
    self:prefetchCovers(first_page_books)

    local item_table = {}
    for i, book in ipairs(books) do
        item_table[i] = {
            text = formatBookRowText(book),
            book_data = book,
            cover_path = book.cover_path,
            cover_url = book.cover_url,
        }
    end
    if resp.has_more then
        item_table[#item_table + 1] = { text = _("-- Load more results --"), is_load_more = true }
    end

    local menu_title = params.title_override and T(_("%1 (%2)"), params.title_override, #books)
        or T(_("Search results (%1)"), #books)

    local results_menu
    results_menu = Menu:new{
        title = menu_title,
        item_table = item_table,
        multilines_forced = true,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        onMenuSelect = function(_menu_self, item)
            UIManager:close(results_menu)
            if item.is_load_more then
                local Trapper = require("ui/trapper")
                Trapper:wrap(function()
                    self:doSearch({
                        query = params.query,
                        author = params.author,
                        fields = params.fields,
                        limit = params.limit,
                        title_override = params.title_override,
                        page = (params.page or 1) + 1,
                    }, books)
                end)
            else
                local Trapper = require("ui/trapper")
                Trapper:wrap(function()
                    self:browseReleases(item.book_data, defaultReleaseQuery(item.book_data))
                end)
            end
        end,
    }
    attachCoverSupport(results_menu, self)
    UIManager:show(results_menu)
end

local function describeRelease(release)
    local bits = {}
    if release.format then table.insert(bits, release.format) end
    if release.size then table.insert(bits, release.size) end
    if release.indexer then table.insert(bits, release.indexer) end
    if release.peers then
        table.insert(bits, release.peers)
    elseif release.seeders then
        table.insert(bits, tostring(release.seeders) .. "S")
    end
    -- Prowlarr's own historical grab count (Torznab's "grabs" attribute) --
    -- confirmed live in release.extra.grabs on real search results. This
    -- is the one popularity/reliability signal usenet releases actually
    -- have: NZB releases never carry peers/seeders (there's no live swarm
    -- to count), so without this the field above is always empty for them.
    local grabs = release.extra and release.extra.grabs
    if grabs then
        table.insert(bits, tostring(grabs) .. "G")
    end
    return table.concat(bits, " • ") -- bullet-separated (raw UTF-8, not \u{} -- LuaJIT/Lua 5.1 doesn't support that escape form)
end

-- Searches release sources (Prowlarr, direct download, etc.) for this one
-- specific book -- deliberately not run during the metadata search above,
-- so indexers only get queried for a book you've actually committed to.
-- manual_query, when given, is passed straight through to Shelfmark's
-- manual_query param -- the only lever that actually changes what gets
-- sent to Prowlarr/indexers as the search term. Shelfmark's own Prowlarr
-- source deliberately searches title-only otherwise: its source code
-- (release_sources/prowlarr/source.py) used to append the author to every
-- indexer query and reverted that (their issue #1293) because AND-based
-- indexers like MyAnonamouse return nothing when the metadata provider's
-- author spelling doesn't exactly match the tracker's ("Timothy Ferriss"
-- vs "Tim Ferriss") -- confirmed by reading that file directly. Author
-- there only affects result *ordering* (affinity sort), never which query
-- string reaches the indexer, and there's no per-request way to opt back
-- into an author-qualified query except manual_query. So "the Prowlarr
-- query itself doesn't include the author" is Shelfmark's own intentional
-- design, not something this plugin's title=/author= params control.
-- Shapes an Anna's Archive search result into the same {title, format,
-- indexer, source, extra={grabs=}} structure Prowlarr/direct_download
-- releases already carry, so describeRelease/releaseRelevanceScore/the
-- menu-building code below all work unchanged regardless of which source a
-- given release actually came from. "Author - Title" (not "Title -
-- Author") specifically to match the scene-release convention
-- releaseRelevanceScore's author bonus already looks for -- Anna's
-- Archive's title/author fields are clean and reliably separated, unlike a
-- scraped release filename, but formatting them this way means a genuine
-- primary-work match still earns the full relevance score, and a
-- companion/adaptation result credited to a different author still gets
-- caught by the same adaptation-keyword penalty.
local function annasResultToRelease(result)
    local title = result.title or "?"
    if type(result.author) == "string" and result.author ~= "" then
        title = result.author .. " - " .. title
    end
    return {
        title = title,
        format = result.format,
        indexer = "Anna's Archive",
        source = "annasarchive",
        md5 = result.md5,
        extra = { grabs = result.downloads },
    }
end

-- Entry point: runs the Anna's Archive search, and only when it fails
-- specifically because the mirror looks dead (err_code "MIRROR_DOWN", not a
-- bad key, a bot challenge, or a plain "no results") offers to look for a
-- working one before falling through to Prowlarr -- see mirror-watch.js in
-- annas-archive-api for why this is a manual, on-demand action rather than
-- something checked automatically in the background.
function Shelfmark:browseReleases(book, manual_query)
    -- Anna's Archive as the primary source, Prowlarr/Shelfmark's own
    -- direct_download only as a fallback when Anna's Archive genuinely has
    -- nothing -- explicit choice per user request ("Prowlarr as the
    -- backup and annas as main"), not a merge of both on every search.
    -- annasSearch is fast enough (3-6s typical, see the note above
    -- doAnnasSearch) that trying it first costs little even on the
    -- occasions it comes up empty and Prowlarr ends up doing the real
    -- work anyway.
    local aa_query = (manual_query and manual_query ~= "") and manual_query or defaultReleaseQuery(book)
    local aa_results, _aa_code, aa_err, aa_err_code = self:annasSearch(aa_query)
    if aa_err == _("Cancelled.") then return end

    if aa_err_code == "MIRROR_DOWN" then
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = _("Anna's Archive's usual address seems to be down. Look for a working mirror, or skip it and search other sources?"),
            ok_text = _("Find a working mirror"),
            cancel_text = _("Skip, search other sources"),
            ok_callback = function()
                local result = self:annasMirrorRefresh()
                if result and result.switched then
                    UIManager:show(InfoMessage:new{
                        text = T(_("Switched to annas-archive.%1 — searching again..."), result.activeTld),
                        timeout = 2,
                    })
                    self:browseReleases(book, manual_query)
                elseif result and result.allDead then
                    UIManager:show(InfoMessage:new{
                        text = _("Every known Anna's Archive mirror is unreachable right now. Searching other sources instead..."),
                        timeout = 3,
                    })
                    self:browseReleasesContinue(book, manual_query, nil)
                else
                    UIManager:show(InfoMessage:new{
                        text = _("That mirror looks fine now — the earlier failure may have been temporary. Try your search again."),
                    })
                end
            end,
            cancel_callback = function()
                self:browseReleasesContinue(book, manual_query, nil)
            end,
        })
        return
    end

    self:browseReleasesContinue(book, manual_query, aa_results)
end

function Shelfmark:browseReleasesContinue(book, manual_query, aa_results)
    local releases
    if aa_results and #aa_results > 0 then
        releases = {}
        for _, r in ipairs(aa_results) do
            table.insert(releases, annasResultToRelease(r))
        end
    end

    if not releases then
        UIManager:show(InfoMessage:new{ text = _("Searching release sources (Prowlarr etc.)..."), timeout = 2 })

        local qs = {
            "provider=" .. socketurl.escape(book.provider or ""),
            "book_id=" .. socketurl.escape(book.provider_id or ""),
            "content_type=ebook",
        }
        if book.title then table.insert(qs, "title=" .. socketurl.escape(book.title)) end
        local author = describeAuthor(book)
        if author ~= "" then table.insert(qs, "author=" .. socketurl.escape(author)) end
        if manual_query and manual_query ~= "" then
            table.insert(qs, "manual_query=" .. socketurl.escape(manual_query))
        end

        -- Longer timeout than apiRequest's 15/45 default -- confirmed live,
        -- this endpoint alone can legitimately run past 45s: Shelfmark's
        -- own docs say a release search needing a fresh Anna's Archive
        -- bot-challenge solve can take 60-120s on a cold cache (its own
        -- server-side search budget is 300s for exactly that reason). This
        -- is exactly the case this whole function now tries to avoid by
        -- trying annasSearch first -- but if that came back empty (rather
        -- than erroring), Shelfmark's own direct_download might still
        -- have something annasSearch's specific query/mirror didn't, so
        -- it's still worth the wait here rather than giving up. The
        -- Trapper progress dialog is dismissable, so a longer timeout
        -- doesn't trap anyone -- they can still cancel any time they
        -- don't want to wait.
        local resp, code, err = self:apiRequest("GET", "/api/releases?" .. table.concat(qs, "&"),
            _("Searching release sources (Prowlarr, Anna's Archive, etc. -- can take a couple of minutes)..."),
            30, 150)
        if err then
            UIManager:show(InfoMessage:new{ text = err })
            return
        end
        if code ~= 200 or not resp or not resp.releases then
            local msg = (resp and (resp.message or resp.error)) or _("Release search failed.")
            UIManager:show(InfoMessage:new{ text = msg })
            return
        end
        if #resp.releases == 0 then
            UIManager:show(InfoMessage:new{
                text = _("No releases found for this book. You can still submit a plain request and let Shelfmark keep looking."),
                timeout = 3,
            })
            self:confirmBookLevelRequest(book)
            return
        end
        releases = resp.releases
    end

    -- Relevance first, then EPUB, then the server's own ordering (a plain
    -- table.sort isn't guaranteed stable, so the original index is used
    -- as an explicit tiebreaker rather than leaving that to chance).
    --
    -- Prowlarr/indexer search is a broad keyword match, not a precise
    -- one -- confirmed live: searching "The Stand" returned 29 pages,
    -- most of them unrelated ("Last Stand", "Stand-In", even a
    -- different, unrelated book that's also literally titled "The
    -- Stand"). Release objects carry no author field of their own, but
    -- indexer release titles conventionally include the author's name,
    -- so that's the actual signal used here: an exact book-title
    -- substring match plus an author-surname match scores highest.
    local book_author = describeAuthor(book)
    -- Release titles that are ADAPTATIONS/COMPANIONS about a book, not the
    -- book itself, routinely still contain the searched title and author as
    -- a substring -- a radio dramatization or "making of" book both
    -- legitimately mention the original work by name. Confirmed live:
    -- searching "The Hitchhiker's Guide to the Galaxy" surfaced both "Don't
    -- Panic" (Neil Gaiman's biography of Douglas Adams) and "...Further
    -- Radio Scripts" (a BBC radio-drama script collection) scoring as high
    -- as an actual copy of the novel. Two cheap, targeted signals catch
    -- these without trying to solve the general problem: (1) a curated
    -- keyword list of adaptation/companion markers, penalized rather than
    -- excluded -- if it's genuinely all that's available it should still be
    -- requestable; (2) the author bonus only counts when the surname
    -- appears before the release's first " - " separator (the scene-release
    -- "Author - Title" convention) -- "Don't Panic" credits Neil Gaiman
    -- there and only mentions "Douglas Adams" afterward as the subject, not
    -- the author of the release.
    local ADAPTATION_KEYWORDS = {
        "radio script", "radio drama", "screenplay", "teleplay",
        "study guide", "book club guide", "cliffsnotes", "sparknotes",
        "companion", "making of", "unauthorized biography",
    }
    local function releaseRelevanceScore(release_title)
        if type(release_title) ~= "string" then return 0 end
        local rt = release_title:lower()
        local score = 0
        if type(book.title) == "string" and book.title ~= "" and rt:find(book.title:lower(), 1, true) then
            score = score + 100
        end
        if book_author ~= "" then
            local surname = book_author:match("(%S+)%s*$")
            if surname and #surname > 2 then
                local surname_pos = rt:find(surname:lower(), 1, true)
                if surname_pos then
                    local sep_pos = rt:find(" - ", 1, true)
                    if not sep_pos or surname_pos < sep_pos then
                        score = score + 50
                    end
                end
            end
        end
        for _, kw in ipairs(ADAPTATION_KEYWORDS) do
            if rt:find(kw, 1, true) then
                score = score - 200
                break
            end
        end
        return score
    end

    -- releases is already set above -- either from Anna's Archive or from
    -- resp.releases in the Prowlarr/Shelfmark fallback branch.
    for _, r in ipairs(releases) do
        r.title = decodeHtmlEntities(r.title)
    end
    for i, r in ipairs(releases) do
        r._orig_index = i
        r._relevance = releaseRelevanceScore(r.title)
    end
    table.sort(releases, function(a, b)
        if a._relevance ~= b._relevance then return a._relevance > b._relevance end
        local a_epub = (a.format and a.format:lower() == "epub") and 0 or 1
        local b_epub = (b.format and b.format:lower() == "epub") and 0 or 1
        if a_epub ~= b_epub then return a_epub < b_epub end
        -- Grabs as the last tiebreaker before falling back to the server's
        -- own ordering -- among otherwise-equal candidates (same relevance,
        -- same format), the one more people have actually grabbed is the
        -- better bet, and it's the only volume/reliability signal usenet
        -- releases carry at all (see the note on describeRelease).
        local a_grabs = (a.extra and a.extra.grabs) or 0
        local b_grabs = (b.extra and b.extra.grabs) or 0
        if a_grabs ~= b_grabs then return a_grabs > b_grabs end
        return a._orig_index < b._orig_index
    end)
    for _, r in ipairs(releases) do
        r._orig_index = nil
        r._relevance = nil
    end

    -- Prowlarr/indexer search is title-only by Shelfmark's own design (see
    -- the comment above browseReleases()) -- it never gets an author or
    -- format term, no matter what this plugin sends. Client-side relevance
    -- sort is the mitigation for that, but for a common/ambiguous title
    -- (many books literally called "The Stand") it can't distinguish a
    -- same-titled unrelated book. manual_query is the one real override,
    -- so it's offered here as an explicit opt-in action rather than done
    -- automatically -- automatically qualifying every search this way
    -- would reintroduce the exact AND-indexer breakage Shelfmark reverted.
    local item_table = {
        { text = _("\xE2\x9C\x8E Custom search query..."), is_custom_query = true }, -- "✎ ..."
    }
    -- Not "for _, release" -- that shadows gettext's _() for the rest of
    -- this loop body, which calls it in the fallback branch below (found
    -- by an audit for this exact pattern, not hit by any release seen so
    -- far in practice: every real Prowlarr release title has been
    -- truthy, so the or _("Untitled release") fallback never fired
    -- during testing -- but a release genuinely missing a title would
    -- have crashed with "attempt to call a number value").
    -- mandatory (a right-aligned secondary column) forces the row into a
    -- single fixed-height line regardless of multilines_forced -- confirmed
    -- live, long titles were truncating to "..." even with that flag set.
    -- Folding the format/source/size line into text itself, bold title
    -- plus " | "-joined metrics flowing naturally, matches
    -- formatBookRowText's own style (see the note there) -- multilines
    -- applies cleanly once nothing else shares the row.
    for _idx, release in ipairs(releases) do
        local title_text = PTF_HEADER .. PTF_BOLD_START
            .. (truncate(release.title, 300) or _("Untitled release")) .. PTF_BOLD_END
        local meta = describeRelease(release)
        if meta ~= "" then title_text = title_text .. " | " .. meta end
        table.insert(item_table, {
            text = title_text,
            release_data = release,
            cover_path = book.cover_path,
        })
    end

    -- book.cover_path may already be set (e.g. arriving here from a search
    -- result whose page was already prefetched) -- only fetch if it isn't,
    -- so re-opening this same book's releases doesn't redownload its cover.
    if not book.cover_path then
        self:prefetchCovers({ book })
        for _, item in ipairs(item_table) do
            item.cover_path = book.cover_path
        end
    end

    -- The default query (title + author, sent automatically -- see
    -- defaultReleaseQuery) isn't flagged as "custom"; only a query that's
    -- actually been hand-edited via "Custom search query..." is.
    local menu_title = T(_("Releases for: %1"), truncate(book.title, 40) or _("this book"))
    if manual_query and manual_query ~= "" and manual_query ~= defaultReleaseQuery(book) then
        menu_title = menu_title .. _(" (custom query)")
    end

    local releases_menu
    releases_menu = Menu:new{
        title = menu_title,
        item_table = item_table,
        multilines_forced = true,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        onMenuSelect = function(_menu_self, item)
            UIManager:close(releases_menu)
            -- This callback runs synchronously on the main UI thread,
            -- outside any Trapper:wrap, so an error here isn't even
            -- reaching Trapper's own swallow-and-warn -- xpcall +
            -- debug.traceback is what actually gets a real traceback into
            -- shelfmark-debug.log if something ever does throw here,
            -- instead of a silent drop back to the previous screen with
            -- nothing in any log. (The actual root cause behind the
            -- disappearing-UI reports turned out to be external -- see
            -- showResilientConfirmBox -- but this stays as a genuine safety
            -- net for anything that does throw a real Lua error here.)
            local ok, err = xpcall(function()
                if item.is_custom_query then
                    self:promptCustomReleaseQuery(book, manual_query)
                else
                    self:confirmReleaseRequest(book, item.release_data)
                end
            end, debug.traceback)
            if not ok then
                debugLog("onMenuSelect (release) ERROR: " .. tostring(err))
                UIManager:show(InfoMessage:new{
                    text = _("Something went wrong opening that release. Details were logged."),
                })
            end
        end,
    }
    attachCoverSupport(releases_menu, self)
    UIManager:show(releases_menu)
end

-- Opens an editable query box (pre-filled with title + author) and re-runs
-- browseReleases with it as Shelfmark's manual_query -- the raw string is
-- sent to indexers verbatim instead of Shelfmark's default title-only
-- search, so this is the way to actually get an author (or anything else,
-- e.g. "epub") into what Prowlarr searches for.
-- Shared shape for all four Hardcover actions below: ask for a title/name,
-- search, show exactly what matched, and only write on explicit
-- confirmation -- see the section note above doHardcoverGraphQL for why
-- nothing here happens without that confirmation step.
local function promptHardcoverText(title, hint, on_confirm)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = title,
        input_hint = hint,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local text = dialog:getInputText()
                        UIManager:close(dialog)
                        if text and text:gsub("%s", "") ~= "" then
                            -- Without this wrap, on_confirm's own network calls
                            -- (hardcoverFindBook/FindAuthor, which use
                            -- Trapper:dismissableRunInSubprocess) run outside any
                            -- coroutine -- confirmed by reading ui/trapper.lua:
                            -- that silently degrades to a blocking, non-
                            -- cancelable synchronous call instead of the normal
                            -- dismissable progress dialog.
                            local Trapper = require("ui/trapper")
                            Trapper:wrap(function() on_confirm(text) end)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Shared by the manual "Log a book..." menu flow and the long-press-on-cover
-- action below -- search, show exactly what matched, write only on explicit
-- confirmation. Must already be running inside a Trapper-wrapped coroutine
-- (both call sites ensure this).
local function confirmAndLogBookOnHardcover(self, title, author, status_id, status_label)
    local id, found_title, found_author, err = self:hardcoverFindBook(title, author)
    if not id then
        UIManager:show(InfoMessage:new{ text = err or _("Search failed.") })
        return
    end
    local ConfirmBox = require("ui/widget/confirmbox")
    local desc = found_author and T(_("\"%1\" by %2"), found_title, found_author) or found_title
    UIManager:show(ConfirmBox:new{
        text = T(_("Found %1 on Hardcover. Mark as %2?"), desc, status_label),
        ok_text = _("Mark as ") .. status_label,
        ok_callback = function()
            local ok, set_err = self:hardcoverSetStatus(id, status_id)
            UIManager:show(InfoMessage:new{
                text = ok and T(_("Marked as %1 on Hardcover."), status_label) or (set_err or _("Failed to update Hardcover.")),
                timeout = ok and 2 or nil,
            })
        end,
    })
end

-- Shared by the manual "Follow an author..." menu flow and the long-press
-- action below -- same search/confirm/write shape as the function above.
local function confirmAndFollowAuthorOnHardcover(self, author_name)
    local id, found_name, err = self:hardcoverFindAuthor(author_name)
    if not id then
        UIManager:show(InfoMessage:new{ text = err or _("Search failed.") })
        return
    end
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = T(_("Found \"%1\" on Hardcover. Follow this author?"), found_name),
        ok_text = _("Follow"),
        ok_callback = function()
            local ok, follow_err = self:hardcoverFollowAuthor(id)
            UIManager:show(InfoMessage:new{
                text = ok and T(_("Now following %1 on Hardcover."), found_name) or (follow_err or _("Failed to follow.")),
                timeout = ok and 2 or nil,
            })
        end,
    })
end

-- Long-press-on-cover entry point (see registerFileDialogButtons below) --
-- the title is already known from the file itself, so this skips straight
-- to search+confirm with no typing at all.
function Shelfmark:promptHardcoverLogBookForFile(title, author, status_id, status_label)
    if not self.hardcover_token or self.hardcover_token == "" then
        UIManager:show(InfoMessage:new{ text = _("Set your Hardcover API token in Settings first.") })
        return
    end
    confirmAndLogBookOnHardcover(self, title, author, status_id, status_label)
end

function Shelfmark:promptHardcoverFollowAuthor()
    if not self.hardcover_token or self.hardcover_token == "" then
        UIManager:show(InfoMessage:new{ text = _("Set your Hardcover API token in Settings first.") })
        return
    end
    promptHardcoverText(_("Follow an author on Hardcover"), _("Author name"), function(name)
        confirmAndFollowAuthorOnHardcover(self, name)
    end)
end

-- Long-press-on-cover entry point -- see promptHardcoverLogBookForFile above.
function Shelfmark:promptHardcoverFollowAuthorForFile(author_name)
    if not self.hardcover_token or self.hardcover_token == "" then
        UIManager:show(InfoMessage:new{ text = _("Set your Hardcover API token in Settings first.") })
        return
    end
    confirmAndFollowAuthorOnHardcover(self, author_name)
end

-- Browses whatever the Shelfmark server's own connected Hardcover account
-- follows -- this goes through the server's existing Hardcover connection
-- (self:apiRequest, same auth as "Most popular"), not the device's own
-- hardcover_token from Settings above, which is a separate, unrelated
-- credential used only for writing (marking books read, following authors).
-- Nothing to configure here beyond following lists on hardcover.app itself.
function Shelfmark:browseHardcoverLists()
    local resp, code, err = self:apiRequest("GET", "/api/metadata/field-options?provider=hardcover&field=hardcover_list")
    if err then
        UIManager:show(InfoMessage:new{ text = err })
        return
    end
    if code ~= 200 or not resp or not resp.options then
        local msg = (resp and (resp.message or resp.error)) or _("Couldn't load Hardcover lists.")
        UIManager:show(InfoMessage:new{ text = msg })
        return
    end
    if #resp.options == 0 then
        UIManager:show(InfoMessage:new{ text = _("No lists found -- follow some on hardcover.app first.") })
        return
    end

    local item_table = {}
    for i, opt in ipairs(resp.options) do
        item_table[i] = {
            text = opt.group and T(_("%1  [%2]"), opt.label, opt.group) or opt.label,
            value = opt.value,
            label = opt.label,
        }
    end

    local lists_menu
    lists_menu = Menu:new{
        title = _("Browse a Hardcover list"),
        item_table = item_table,
        multilines_forced = true,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        onMenuSelect = function(_menu_self, item)
            UIManager:close(lists_menu)
            local Trapper = require("ui/trapper")
            Trapper:wrap(function()
                self:doSearch({ fields = { hardcover_list = item.value }, limit = 30, title_override = item.label })
            end)
        end,
    }
    UIManager:show(lists_menu)
end

-- Fixed page size for browseAuthorBibliography's "Load more" pagination --
-- matches Hardcover's own documented per-page convention.
local HARDCOVER_BIBLIOGRAPHY_PAGE_SIZE = 25

-- Reads "who do I follow" fresh from Hardcover every time (see the note
-- above doHardcoverListFollowedAuthors) -- no local list to keep in sync,
-- so a follow made here, on hardcover.app's own website, or via the
-- long-press "Follow Author" action all show up the same way.
function Shelfmark:browseFollowedAuthors()
    if not self.hardcover_token or self.hardcover_token == "" then
        UIManager:show(InfoMessage:new{ text = _("Set your Hardcover API token in Settings first.") })
        return
    end
    local authors, err = self:hardcoverListFollowedAuthors()
    if not authors then
        UIManager:show(InfoMessage:new{ text = err or _("Couldn't load followed authors.") })
        return
    end
    if #authors == 0 then
        UIManager:show(InfoMessage:new{ text = _("You're not following any authors yet -- use \"Follow an author...\" first.") })
        return
    end

    local item_table = {}
    for i, author in ipairs(authors) do
        item_table[i] = {
            text = author.books_count and T(_("%1  (%2 books)"), author.name, author.books_count) or author.name,
            author_id = author.id,
            author_name = author.name,
        }
    end

    local authors_menu
    authors_menu = Menu:new{
        title = _("Followed authors"),
        item_table = item_table,
        multilines_forced = true,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        onMenuSelect = function(_menu_self, item)
            UIManager:close(authors_menu)
            local Trapper = require("ui/trapper")
            Trapper:wrap(function()
                self:browseAuthorBibliography(item.author_id, item.author_name, 0, nil)
            end)
        end,
    }
    UIManager:show(authors_menu)
end

-- Mirrors doSearch's own accumulate-and-"Load more" idiom exactly (see
-- that function) so tapping a book here reaches browseReleases with the
-- exact same book_data shape a normal search result already carries --
-- title/authors/publish_year/display_fields/provider/provider_id, all
-- built by doHardcoverAuthorBibliography to match what
-- describeBook/describeMetrics already expect.
function Shelfmark:browseAuthorBibliography(author_id, author_name, offset, existing_books)
    local new_books, total, resolved_name, err = self:hardcoverAuthorBibliography(
        author_id, HARDCOVER_BIBLIOGRAPHY_PAGE_SIZE, offset or 0)
    if not new_books then
        UIManager:show(InfoMessage:new{ text = err or _("Couldn't load this author's books.") })
        return
    end

    local books = existing_books or {}
    for _, book in ipairs(new_books) do
        table.insert(books, book)
    end

    if #books == 0 then
        UIManager:show(InfoMessage:new{ text = _("No books found for this author.") })
        return
    end

    -- Only prefetch enough covers for the page shown first -- see the
    -- identical note in doSearch above.
    local first_page_books = {}
    for i = 1, math.min(#new_books, COVER_ITEMS_PER_PAGE) do
        first_page_books[i] = new_books[i]
    end
    self:prefetchCovers(first_page_books)

    local item_table = {}
    for i, book in ipairs(books) do
        item_table[i] = {
            text = formatBookRowText(book),
            book_data = book,
            cover_path = book.cover_path,
            cover_url = book.cover_url,
        }
    end
    if total and #books < total then
        item_table[#item_table + 1] = { text = _("-- Load more results --"), is_load_more = true }
    end

    local menu_title = T(_("%1 (%2)"), author_name or resolved_name or _("Author"), #books)

    local bibliography_menu
    bibliography_menu = Menu:new{
        title = menu_title,
        item_table = item_table,
        multilines_forced = true,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        onMenuSelect = function(_menu_self, item)
            UIManager:close(bibliography_menu)
            local Trapper = require("ui/trapper")
            if item.is_load_more then
                Trapper:wrap(function()
                    self:browseAuthorBibliography(author_id, author_name or resolved_name, #books, books)
                end)
            else
                Trapper:wrap(function()
                    self:browseReleases(item.book_data, defaultReleaseQuery(item.book_data))
                end)
            end
        end,
    }
    attachCoverSupport(bibliography_menu, self)
    UIManager:show(bibliography_menu)
end

function Shelfmark:promptCustomReleaseQuery(book, prefill)
    local InputDialog = require("ui/widget/inputdialog")
    local default_query = prefill or defaultReleaseQuery(book)

    local dialog
    dialog = InputDialog:new{
        title = _("Custom Prowlarr/indexer query"),
        description = _("Sent to indexers as-is, in place of Shelfmark's default title-only search. Edit freely -- e.g. drop the author if this comes back empty, or add a format like \"epub\"."),
        input = default_query,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local query = dialog:getInputText()
                        UIManager:close(dialog)
                        if query and query:gsub("%s", "") ~= "" then
                            local Trapper = require("ui/trapper")
                            Trapper:wrap(function() self:browseReleases(book, query) end)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- The search endpoint returns "authors" (a list), but request validation
-- requires a singular "author" string it never provides itself --
-- confirmed against requests_service.py's required_fields. Shelfmark's own
-- web UI must derive this before submitting; do the same here.
local function withAuthorField(book)
    if not book.author then
        local author = describeAuthor(book)
        if author ~= "" then book.author = author end
    end
    return book
end

-- Confirmed live: something else on the device (a third-party home-screen
-- plugin's own periodic UI refresh -- see the Discover exposure-window note
-- above) can silently call UIManager:close() on Shelfmark's own confirmation
-- dialog, with no Lua error and no crash.log entry anywhere -- the tap just
-- appears to do nothing. UIManager:close() always fires onCloseWidget on
-- whatever it's closing, no matter who called it, which is the one hook
-- available to detect this: ok_callback/cancel_callback are wrapped to flag
-- a legitimate dismissal first (ConfirmBox's own onClose/onTapClose --
-- tap-outside-to-dismiss -- also call cancel_callback before closing, so
-- those count as legitimate too), and an onCloseWidget firing *without*
-- that flag set can only mean something else closed it directly. Re-shows
-- the same dialog automatically (bounded, so this can't turn into an
-- endless fight with whatever keeps closing it), and tells the user plainly
-- if it still loses the race after that.
function Shelfmark:showResilientConfirmBox(opts)
    local ConfirmBox = require("ui/widget/confirmbox")
    local dismissed = false
    local retries = 0
    local MAX_RETRIES = 2
    local user_ok = opts.ok_callback or function() end
    local user_cancel = opts.cancel_callback or function() end

    -- A retry MUST build a brand new ConfirmBox, never re-UIManager:show()
    -- the one that just got closed -- confirmed live, the hard way:
    -- onCloseWidget tears the widget down for real (TextBoxWidget:free()
    -- nils out its internal render buffer), and re-showing that same
    -- now-freed instance crashed the entire app on the next repaint
    -- ("attempt to index field '_bb' (a nil value)" in paintTo, escaping
    -- uncaught from UIManager's own repaint loop -- outside anything a
    -- pcall in this file could ever have caught). show_box is a self-
    -- referencing local specifically so each retry gets a fresh instance.
    local show_box
    show_box = function()
        local confirm_box
        confirm_box = ConfirmBox:new{
            text = opts.text,
            ok_text = opts.ok_text,
            ok_callback = function()
                dismissed = true
                user_ok()
            end,
            cancel_callback = function()
                dismissed = true
                user_cancel()
            end,
        }
        local base_on_close_widget = confirm_box.onCloseWidget
        confirm_box.onCloseWidget = function(self_box)
            base_on_close_widget(self_box)
            if dismissed then return end
            debugLog("showResilientConfirmBox: force-closed externally (retries=" .. retries .. "): "
                .. tostring(opts.text):sub(1, 60))
            if retries < MAX_RETRIES then
                retries = retries + 1
                UIManager:scheduleIn(0.2, show_box)
            else
                UIManager:show(InfoMessage:new{
                    text = _("This dialog kept getting closed by something else on this device. Try again, or use Search instead of Discover."),
                })
            end
        end
        UIManager:show(confirm_box)
    end
    show_box()
end

-- release.source == "annasarchive" releases skip Shelfmark's own
-- request/fulfillment queue entirely -- there's nothing to wait for, the
-- file is fetched and saved right here, same as the standalone
-- annasarchive.koplugin's own download flow (see doAnnasFileDownload's
-- note on why). Landing in the same download_dir Shelfmark itself uses
-- means "Sync library with CWA" picks it up naturally on its next run,
-- same as any other externally-acquired book (Z-Library, the standalone
-- plugin, etc).
function Shelfmark:downloadFromAnnasArchive(release)
    local dl_url, _code, err = self:annasFetchDownloadUrl(release.md5)
    if err then
        UIManager:show(InfoMessage:new{ text = err })
        return
    end
    if not dl_url then
        UIManager:show(InfoMessage:new{ text = _("No download URL returned.") })
        return
    end

    local dir = (self.download_dir and self.download_dir ~= "") and self.download_dir or self:defaultDownloadDir()
    if lfs.attributes(dir, "mode") ~= "directory" then
        -- One level at a time -- lfs.mkdir isn't recursive.
        local built = ""
        for segment in dir:gmatch("[^/]+") do
            built = built .. "/" .. segment
            if lfs.attributes(built, "mode") ~= "directory" then
                lfs.mkdir(built)
            end
        end
        if lfs.attributes(dir, "mode") ~= "directory" then
            UIManager:show(InfoMessage:new{ text = T(_("Couldn't create download folder: %1"), dir) })
            return
        end
    end

    local ext = (type(release.format) == "string" and release.format ~= "") and release.format:lower() or "epub"
    -- truncate(), not a raw :sub() -- byte-position slicing can cut a
    -- multi-byte UTF-8 character in half (see truncate's own note at its
    -- definition); release.title here is "Author - Title" from Anna's
    -- Archive, which genuinely has multi-byte names/titles (confirmed live
    -- elsewhere this session, e.g. "Joandomènec Ros i Aragonès").
    -- Filesystem-unsafe characters stripped first so the cut lands on the
    -- already-sanitized string.
    local safe_title = truncate((release.title or "book"):gsub('[/\\:%*%?"<>|]', "_"), 120)
    local save_path = dir .. "/" .. safe_title .. "." .. ext

    -- Downloads into a sibling temp file, renamed onto save_path only on
    -- full success -- same reasoning as zlibrary.koplugin's own
    -- Api.downloadBook (see the credit at the top of this file): opening
    -- save_path directly would truncate any earlier copy before the first
    -- byte of a retry ever arrives. This temp file is also what the
    -- progress poll below watches grow -- a prior killed download never
    -- got to clean up after itself, hence the pcall(os.remove...) first.
    local temp_path = save_path .. ".downloading"
    pcall(os.remove, temp_path)

    -- Best-effort real progress bar -- see doHttpHeadContentLength's own
    -- note on why this needs a separate HEAD request at all. content_length
    -- staying nil (HEAD unsupported/no Content-Length from this mirror)
    -- just means ProgressbarDialog hides the bar itself and shows the
    -- title/subtitle alone -- no separate fallback path needed.
    local content_length = doHttpHeadContentLength(dl_url)

    local ProgressbarDialog = require("ui/widget/progressbardialog")
    local progress_dialog = ProgressbarDialog:new{
        title = _("Downloading… (tap to cancel)"),
        subtitle = safe_title,
        progress_max = content_length,
        refresh_time_seconds = 1,
    }
    progress_dialog:show()

    -- Polls the temp file's size from this (parent) process rather than
    -- getting a byte count out of the download itself: the download runs
    -- in a forked child below so the UI stays responsive and cancelable,
    -- and a fork can't reach back into this process's own widgets --
    -- confirmed by reading ui/trapper.lua's own docs on
    -- dismissableRunInSubprocess. Watching the file grow from out here
    -- sidesteps that entirely (same trick zlibrary.koplugin's own
    -- downloader uses).
    local stopped = false
    local function poll()
        if stopped then return end
        local size = lfs.attributes(temp_path, "size")
        if size and content_length then
            progress_dialog:reportProgress(math.min(size, content_length))
        end
        UIManager:scheduleIn(1, poll)
    end
    UIManager:scheduleIn(1, poll)

    -- false, not a text string: an invisible, screen-covering trap widget
    -- that swallows the cancelling tap, same as zlibrary.koplugin's own
    -- downloader -- progress_dialog above is purely the visual, this is
    -- what actually makes tap-to-cancel work.
    local Trapper = require("ui/trapper")
    local completed, ok, _dl_code, dl_err = Trapper:dismissableRunInSubprocess(function()
        return doAnnasFileDownload(dl_url, temp_path)
    end, false)

    stopped = true
    UIManager:unschedule(poll)
    progress_dialog:close()

    if not completed then
        pcall(os.remove, temp_path)
        return
    end
    if not ok then
        pcall(os.remove, temp_path)
        UIManager:show(InfoMessage:new{ text = dl_err or _("Download failed.") })
        return
    end

    if not os.rename(temp_path, save_path) then
        pcall(os.remove, temp_path)
        UIManager:show(InfoMessage:new{ text = _("Download succeeded but couldn't be saved.") })
        return
    end
    UIManager:show(InfoMessage:new{ text = T(_("Saved to %1"), save_path), timeout = 4 })
end

function Shelfmark:confirmReleaseRequest(book, release)
    if release.source == "annasarchive" then
        -- Immediate download, not a queued request -- see
        -- downloadFromAnnasArchive's note on why this branch exists at
        -- all.
        self:showResilientConfirmBox{
            text = (truncate(release.title, 90) or _("This release")) .. "\n\n" .. _("Download from Anna's Archive now?"),
            ok_text = _("Download"),
            ok_callback = function()
                local Trapper = require("ui/trapper")
                Trapper:wrap(function() self:downloadFromAnnasArchive(release) end)
            end,
        }
        return
    end

    -- truncate() here, not just in the release list -- raw Prowlarr/scene
    -- release filenames run 100-150+ chars (quality/codec tags, group
    -- names), and this ConfirmBox was the one place in the file still
    -- passing that text through unclipped. Matches part of the symptom
    -- reported live (the UI disappearing right after tapping a release) --
    -- the other part turned out to be the external-close issue
    -- showResilientConfirmBox now handles above.
    self:showResilientConfirmBox{
        text = (truncate(release.title, 90) or _("This release")) .. "\n\n" .. _("Request this release?"),
        ok_text = _("Request"),
        ok_callback = function()
            local Trapper = require("ui/trapper")
            Trapper:wrap(function() self:submitRequest(withAuthorField(book), release) end)
        end,
    }
end

function Shelfmark:confirmBookLevelRequest(book)
    self:showResilientConfirmBox{
        text = describeBook(book) .. "\n\n" .. _("Submit a plain request for this book (no specific release found)?"),
        ok_text = _("Request"),
        ok_callback = function()
            local Trapper = require("ui/trapper")
            Trapper:wrap(function() self:submitRequest(withAuthorField(book), nil) end)
        end,
    }
end

-- release is optional: nil submits a book-level request (Shelfmark finds a
-- release later), given submits a release-level request (this exact file).
function Shelfmark:submitRequest(book, release)
    local body = {
        book_data = book,
        context = { content_type = "ebook" },
    }
    if release then
        body.release_data = release
        body.context.source = release.source
    end

    local resp, code, err = self:apiRequest("POST", "/api/requests", body)
    if err then
        UIManager:show(InfoMessage:new{ text = err })
        return
    end
    if code == 200 or code == 201 then
        -- Watch this one so a completion notification can actually fire on
        -- this device -- see checkPendingRequestNotifications -- rather than
        -- the message below being an empty promise like it was before that
        -- existed. resp.id is Shelfmark's own request id (confirmed live on
        -- a real POST /api/requests: 201 responses return the full created
        -- request object, id included) -- silently skips watching if it's
        -- somehow missing rather than erroring, since the request itself
        -- still succeeded either way.
        if resp and resp.id then
            local pending = loadPendingNotifyList()
            -- truncate() here, same as every other title that reaches a
            -- widget in this file (see confirmReleaseRequest/describeBook's
            -- own notes on why) -- this one reaches checkPendingRequestNotifications's
            -- InfoMessage completely unguarded otherwise, on a delay (device
            -- resume, possibly much later) that makes it easy to miss this
            -- gap testing the request flow itself.
            pending[tostring(resp.id)] = truncate((resp.book_data and resp.book_data.title) or book.title, 90) or _("Untitled")
            savePendingNotifyList(pending)
        end
        UIManager:show(InfoMessage:new{
            text = _("Requested. You'll get a notification on this device once it's ready."),
            timeout = 4,
        })
    else
        local msg = (resp and (resp.message or resp.error)) or (_("Request failed (HTTP ") .. tostring(code) .. ")")
        UIManager:show(InfoMessage:new{ text = msg })
    end
end

-- ===== my requests =====

-- Reconciles the pending-notification watch list (see submitRequest) against
-- an already-fetched /api/requests list: drops entries that reached a
-- terminal state -- delivered, or cancelled/rejected/declined -- or vanished
-- from the list entirely, and returns the titles that just became delivered
-- (empty if none) so the caller can decide whether to show anything. Takes
-- the list rather than fetching its own, since showMyRequests already has
-- one on hand -- checkPendingRequestNotifications below (used from onResume,
-- where nothing's been fetched yet) is the one place that calls the API.
local TERMINAL_NON_DELIVERED_STATUSES = { cancelled = true, rejected = true, declined = true }
local function reconcilePendingNotifications(requests)
    local pending = loadPendingNotifyList()
    if next(pending) == nil then return {} end

    local by_id = {}
    for _, r in ipairs(requests or {}) do
        if r.id then by_id[tostring(r.id)] = r end
    end

    local newly_ready = {}
    local changed = false
    for id_str, title in pairs(pending) do
        local r = by_id[id_str]
        if not r then
            -- Vanished from the list entirely (removed some other way) --
            -- nothing more to learn about it here, stop watching.
            pending[id_str] = nil
            changed = true
        elseif r.delivery_state == "complete" then
            table.insert(newly_ready, title)
            pending[id_str] = nil
            changed = true
        elseif TERMINAL_NON_DELIVERED_STATUSES[r.status] then
            pending[id_str] = nil
            changed = true
        end
    end
    if changed then savePendingNotifyList(pending) end
    return newly_ready
end

-- Checks whether anything this device requested (see submitRequest) has
-- since been delivered, and shows an on-device notification naming it if
-- so. Called from onResume (waking the device is the natural "might want to
-- know now" moment) and once from showMyRequests below. Skips the API call
-- entirely when nothing's being watched, and fails silent on a network
-- error -- this runs unprompted, most often right after waking when
-- Tailscale may not have reconnected yet (see the note on
-- onNetworkConnected-style reconnection delay elsewhere in this session's
-- work), so surfacing an error the user didn't ask for would be worse than
-- just quietly retrying next time something triggers a check.
function Shelfmark:checkPendingRequestNotifications()
    local pending = loadPendingNotifyList()
    if next(pending) == nil then return end

    local resp, code, err = self:apiRequest("GET", "/api/requests")
    if err or code ~= 200 or not resp then return end
    local requests = resp.requests or resp
    if type(requests) ~= "table" then return end

    local newly_ready = reconcilePendingNotifications(requests)
    if #newly_ready == 0 then return end

    local text
    if #newly_ready == 1 then
        text = T(_("Ready to read: %1"), newly_ready[1])
    else
        text = T(_("%1 books are ready to read:"), tostring(#newly_ready))
            .. "\n\n" .. table.concat(newly_ready, "\n")
    end
    -- No timeout -- stays on screen until dismissed rather than flashing by,
    -- since this can appear unprompted right as the screen wakes up.
    UIManager:show(InfoMessage:new{ text = text })
end

function Shelfmark:onResume()
    -- scheduleIn rather than checking immediately -- confirmed live earlier
    -- this session that Tailscale's userspace daemon isn't necessarily
    -- reconnected the instant the device wakes, so an immediate check would
    -- routinely just fail silently for no good reason. Throttled separately
    -- (self._last_notify_check) so a quick series of wake/sleep cycles
    -- (e.g. repeatedly checking the time) doesn't spam requests.
    local now = os.time()
    if self._last_notify_check and (now - self._last_notify_check) < 300 then
        return
    end
    self._last_notify_check = now
    UIManager:scheduleIn(5, function()
        local Trapper = require("ui/trapper")
        Trapper:wrap(function() self:checkPendingRequestNotifications() end)
    end)
end

function Shelfmark:showMyRequests()
    local resp, code, err = self:apiRequest("GET", "/api/requests")
    if err then
        UIManager:show(InfoMessage:new{ text = err })
        return
    end
    if code ~= 200 or not resp then
        UIManager:show(InfoMessage:new{ text = _("Couldn't load requests.") })
        return
    end

    -- The endpoint may return either a bare list or {requests: [...]} --
    -- handle both rather than guessing which.
    local requests = resp.requests or resp
    -- Silent reconcile (no popup -- the list about to be shown already
    -- makes delivered status visible) so the watch list doesn't grow stale
    -- just because the user checked here instead of waiting for onResume.
    if type(requests) == "table" then reconcilePendingNotifications(requests) end
    if type(requests) ~= "table" or #requests == 0 then
        UIManager:show(InfoMessage:new{ text = _("No requests yet.") })
        return
    end

    local item_table = {}
    for i, r in ipairs(requests) do
        local title = r.title or (r.book_data and r.book_data.title) or _("Untitled")
        local status = r.status or "?"
        -- delivery_state (per Shelfmark's own QueueStatus enum) is
        -- separate from the request-approval status field above -- this
        -- is the one that actually means "the file exists somewhere now".
        local delivery = r.delivery_state or "none"
        local is_delivered = delivery == "complete"
        item_table[i] = {
            text = truncate(title, 80) .. "\n" .. status,
            mandatory = is_delivered and _("Ready - tap to download") or delivery,
            title = title,
            is_delivered = is_delivered,
        }
    end

    local requests_menu
    requests_menu = Menu:new{
        title = _("My Shelfmark requests"),
        item_table = item_table,
        multilines_forced = true,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        onMenuSelect = function(_menu_self, item)
            if not item.is_delivered then
                UIManager:show(InfoMessage:new{ text = _("Not delivered yet."), timeout = 2 })
                return
            end
            UIManager:close(requests_menu)
            local Trapper = require("ui/trapper")
            Trapper:wrap(function() self:downloadFromCwa(item.title) end)
        end,
        -- Explicit, separate from tap: tapping a delivered request already
        -- searches CWA and re-downloads, so this is functionally the same
        -- action -- but as a hold-triggered "Redownload" it's discoverable
        -- as its own deliberate command (e.g. if you deleted the file
        -- off-device, or the earlier download landed with a mangled
        -- filename) rather than something that just happens to be what tap
        -- does.
        onMenuHold = function(_menu_self, item)
            if not item.is_delivered then
                UIManager:show(InfoMessage:new{ text = _("Not delivered yet."), timeout = 2 })
                return
            end
            local ButtonDialog = require("ui/widget/buttondialog")
            local hold_dialog
            hold_dialog = ButtonDialog:new{
                title = item.title,
                buttons = {
                    {
                        {
                            text = _("Redownload"),
                            callback = function()
                                UIManager:close(hold_dialog)
                                UIManager:close(requests_menu)
                                local Trapper = require("ui/trapper")
                                Trapper:wrap(function() self:downloadFromCwa(item.title) end)
                            end,
                        },
                    },
                    {
                        {
                            text = _("Cancel"),
                            callback = function() UIManager:close(hold_dialog) end,
                        },
                    },
                },
            }
            UIManager:show(hold_dialog)
        end,
    }
    UIManager:show(requests_menu)
end

return Shelfmark
