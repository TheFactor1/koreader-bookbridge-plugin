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
end

function Shelfmark:defaultDownloadDir()
    return DataStorage:getFullDataDir() .. "/shelfmark_downloads"
end

function Shelfmark:init()
    self:loadSettings()
    self.ui.menu:registerToMainMenu(self)
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

local function doRawRequest(server_url, cookie, method, path, body, socks5_proxy)
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
    -- block_timeout alone is not enough).
    socketutil:set_timeout(15, 45)
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
local function doApiRequest(server_url, username, password, cookie, method, path, body, socks5_proxy)
    if not cookie then
        if not username or username == "" then
            return nil, nil, nil, _("No Shelfmark username set -- check Settings.")
        end
        local ok, new_cookie, login_err = doLogin(server_url, username, password, socks5_proxy)
        if not ok then return nil, nil, nil, login_err end
        cookie = new_cookie
    end

    local resp, code, new_cookie, err = doRawRequest(server_url, cookie, method, path, body, socks5_proxy)
    if err then return nil, nil, cookie, err end
    cookie = new_cookie

    if code == 401 then
        local ok, relog_cookie, login_err = doLogin(server_url, username, password, socks5_proxy)
        if not ok then return nil, nil, nil, login_err end
        cookie = relog_cookie
        resp, code, new_cookie, err = doRawRequest(server_url, cookie, method, path, body, socks5_proxy)
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

local function normalizeTitleWords(text)
    if not text then return {} end
    text = text:lower():gsub("%(z%-library%)", "")
    text = text:gsub("[^%w]+", " ")
    local words = {}
    for w in text:gmatch("%S+") do
        if not SYNC_STOPWORDS[w] and #w > 1 then
            words[w] = true
        end
    end
    return words
end

-- True only when every word of title_words is present in filename_words --
-- deliberately one-directional and exact, no fuzzy scoring. A looser
-- "closest match" approach already mixed up "Pines" and "Wayward Pines -
-- 02 Wayward" for two different files during the first (manual) pass at
-- this same kind of matching for the homeserver-side script -- better to
-- flag ambiguity than guess wrong silently.
local function titleWordsSubsetOf(title_words, filename_words)
    local any = false
    for w in pairs(title_words) do
        any = true
        if not filename_words[w] then return false end
    end
    return any
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
            local query = fname:gsub("[_%-%[%]%(%)]", " ")
            local resp_body, code = doCwaRequest(cwa_url, cwa_username, cwa_password,
                "/opds/search/" .. socketurl.escape(query), socks5_proxy)
            local matches = {}
            if resp_body and code == 200 then
                local fname_words = normalizeTitleWords(fname)
                local seen_uuids = {}
                for _, e in ipairs(parseOpdsEntries(resp_body)) do
                    if e.uuid and not seen_uuids[e.uuid] then
                        if titleWordsSubsetOf(normalizeTitleWords(e.title), fname_words) then
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
function Shelfmark:apiRequest(method, path, body, progress_text)
    local Trapper = require("ui/trapper")
    local server_url, username, password, cookie, socks5_proxy =
        self.server_url, self.username, self.password, self.session_cookie, self.socks5_proxy

    local completed, resp, code, new_cookie, err = Trapper:dismissableRunInSubprocess(function()
        return doApiRequest(server_url, username, password, cookie, method, path, body, socks5_proxy)
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
            {
                text = _("Discover"),
                keep_menu_open = true,
                callback = function() self:showDiscover() end,
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
                text_func = function()
                    return T(_("Download folder: %1"), self.download_dir or self:defaultDownloadDir())
                end,
                keep_menu_open = true,
                callback = function() self:chooseDownloadDir() end,
            },
            {
                text = _("Sync library with CWA"),
                keep_menu_open = true,
                callback = function() self:syncLibrary() end,
            },
            {
                text = _("Show setup QR code"),
                keep_menu_open = true,
                callback = function() self:showSetupQrCode() end,
            },
            {
                text = _("Import settings from text"),
                keep_menu_open = true,
                callback = function() self:importSettingsFromText() end,
            },
            {
                text = _("View debug log"),
                keep_menu_open = true,
                separator = true,
                callback = function() self:showDebugLog() end,
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
-- Dune, ...), not an error.
function Shelfmark:showDiscover()
    local item_table = {
        { text = _("Most Popular"), action = "popular" },
        { text = _("My Hardcover Lists"), action = "lists" },
    }
    local discover_menu
    discover_menu = Menu:new{
        title = _("Discover"),
        item_table = item_table,
        multilines_forced = true,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        onMenuSelect = function(_menu_self, item)
            UIManager:close(discover_menu)
            local Trapper = require("ui/trapper")
            if item.action == "popular" then
                Trapper:wrap(function()
                    self:doSearch({ query = "*", page = 1, title_override = _("Most Popular") })
                end)
            elseif item.action == "lists" then
                Trapper:wrap(function() self:browseHardcoverLists() end)
            end
        end,
    }
    UIManager:show(discover_menu)
end

-- Hardcover's own curated lists for whichever account Shelfmark's
-- HARDCOVER_API_KEY is configured with (Want to Read / Currently Reading /
-- Read / Did Not Finish, plus any of that account's own named lists) --
-- this is Shelfmark's "Browse a list..." advanced search field
-- (hardcover_list), surfaced here directly since this plugin has no
-- general advanced-search UI to put it behind. Confirmed live:
-- /api/metadata/field-options?provider=hardcover&field=hardcover_list
-- returns {group=, label=, value=} entries -- value is what gets sent
-- back as the hardcover_list field to actually run the browse.
function Shelfmark:browseHardcoverLists()
    local resp, code, err = self:apiRequest(
        "GET", "/api/metadata/field-options?provider=hardcover&field=hardcover_list",
        nil, _("Loading lists...")
    )
    if err then
        UIManager:show(InfoMessage:new{ text = err })
        return
    end
    if code ~= 200 or not resp or not resp.options then
        UIManager:show(InfoMessage:new{ text = _("Couldn't load Hardcover lists.") })
        return
    end
    if #resp.options == 0 then
        UIManager:show(InfoMessage:new{ text = _("No lists found for the configured Hardcover account.") })
        return
    end

    local item_table = {}
    for i, opt in ipairs(resp.options) do
        item_table[i] = {
            text = opt.label or opt.value,
            mandatory = opt.group,
            list_value = opt.value,
            list_label = opt.label,
        }
    end

    local lists_menu
    lists_menu = Menu:new{
        title = _("My Hardcover Lists"),
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
                self:doSearch({
                    fields = { hardcover_list = item.list_value },
                    page = 1,
                    title_override = item.list_label,
                })
            end)
        end,
    }
    UIManager:show(lists_menu)
end

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

-- params: {query=, author=, page=, fields=, title_override=}. fields is an
-- optional {key=value} table of Hardcover's own advanced search fields
-- (currently only hardcover_list -- see showDiscover) sent alongside/
-- instead of query. existing_books, when given, is the accumulated
-- result list so far (used by "Load more" to append rather than replace).
function Shelfmark:doSearch(params, existing_books)
    UIManager:show(InfoMessage:new{ text = _("Searching..."), timeout = 1 })

    local qs = { "limit=100", "sort=popularity", "page=" .. tostring(params.page or 1) }
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

    local item_table = {}
    for i, book in ipairs(books) do
        -- Confirmed on-device: cramming metrics+byline into "mandatory"
        -- made that column wide enough to squeeze the title itself down
        -- to a handful of visible characters -- the exact opposite of
        -- legible. Title needs its own full line; author/year go on a
        -- second line underneath it (multilines_forced is already set),
        -- and "mandatory" goes back to being short -- just the rating,
        -- which is what was actually asked for as the at-a-glance signal.
        local byline = describeAuthor(book) .. describeYear(book)
        local title_text = truncate(book.title, 80) or _("Untitled")
        if byline ~= "" then
            title_text = title_text .. "\n" .. byline
        end
        item_table[i] = {
            text = title_text,
            mandatory = truncate(describeMetrics(book), 20),
            book_data = book,
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
function Shelfmark:browseReleases(book, manual_query)
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

    local resp, code, err = self:apiRequest("GET", "/api/releases?" .. table.concat(qs, "&"))
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
    local function releaseRelevanceScore(release_title)
        if type(release_title) ~= "string" then return 0 end
        local rt = release_title:lower()
        local score = 0
        if type(book.title) == "string" and book.title ~= "" and rt:find(book.title:lower(), 1, true) then
            score = score + 100
        end
        if book_author ~= "" then
            local surname = book_author:match("(%S+)%s*$")
            if surname and #surname > 2 and rt:find(surname:lower(), 1, true) then
                score = score + 50
            end
        end
        return score
    end

    local releases = resp.releases
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
    for _idx, release in ipairs(releases) do
        table.insert(item_table, {
            text = truncate(release.title, 90) or _("Untitled release"),
            mandatory = truncate(describeRelease(release), 40),
            release_data = release,
        })
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
            if item.is_custom_query then
                self:promptCustomReleaseQuery(book, manual_query)
            else
                self:confirmReleaseRequest(book, item.release_data)
            end
        end,
    }
    UIManager:show(releases_menu)
end

-- Opens an editable query box (pre-filled with title + author) and re-runs
-- browseReleases with it as Shelfmark's manual_query -- the raw string is
-- sent to indexers verbatim instead of Shelfmark's default title-only
-- search, so this is the way to actually get an author (or anything else,
-- e.g. "epub") into what Prowlarr searches for.
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

function Shelfmark:confirmReleaseRequest(book, release)
    local ConfirmBox = require("ui/widget/confirmbox")
    -- truncate() here, not just in the release list -- raw Prowlarr/scene
    -- release filenames run 100-150+ chars (quality/codec tags, group
    -- names), and this ConfirmBox was the one place in the file still
    -- passing that text through unclipped. Matches the exact symptom
    -- reported live: the UI disappearing right after tapping a release,
    -- no error in either log -- consistent with the native, untraceable
    -- crash already confirmed earlier this session to correlate with long
    -- text into certain widgets, not a Lua-level exception this file's
    -- own logging could ever have caught.
    UIManager:show(ConfirmBox:new{
        text = (truncate(release.title, 90) or _("This release")) .. "\n\n" .. _("Request this release?"),
        ok_text = _("Request"),
        ok_callback = function()
            local Trapper = require("ui/trapper")
            Trapper:wrap(function() self:submitRequest(withAuthorField(book), release) end)
        end,
    })
end

function Shelfmark:confirmBookLevelRequest(book)
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = describeBook(book) .. "\n\n" .. _("Submit a plain request for this book (no specific release found)?"),
        ok_text = _("Request"),
        ok_callback = function()
            local Trapper = require("ui/trapper")
            Trapper:wrap(function() self:submitRequest(withAuthorField(book), nil) end)
        end,
    })
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
        UIManager:show(InfoMessage:new{
            text = _("Requested. You'll be notified separately once it's ready -- check the ingest folder / your OPDS catalog then."),
            timeout = 4,
        })
    else
        local msg = (resp and (resp.message or resp.error)) or (_("Request failed (HTTP ") .. tostring(code) .. ")")
        UIManager:show(InfoMessage:new{ text = msg })
    end
end

-- ===== my requests =====

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
