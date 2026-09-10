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

local Bookbridge = WidgetContainer:extend{
    name = "bookbridge",
    settings_file = DataStorage:getSettingsDir() .. "/shelfmark.lua",
    sm_settings = nil,
    session_cookie = nil,
}

-- Superseded: network requests now run through Trapper (see apiRequest
-- below), which moves the actual blocking work into a subprocess instead
-- of merely delaying when it starts on the main thread. Every entry point
-- that used to call deferBlocking(fn) now calls Trapper:wrap(fn) instead.

-- ===== settings =====

function Bookbridge:loadSettings()
    if not Bookbridge.settings then
        Bookbridge.settings = LuaSettings:open(self.settings_file)
        if not next(Bookbridge.settings.data) then
            Bookbridge.settings.data = { shelfmark = {} }
        end
    end
    self.sm_settings = Bookbridge.settings
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
    -- shelfmark-ai-relay: suggests a match for files doSyncLibrary could not
    -- resolve on its own. Optional -- everything works exactly as before when
    -- unset, the leftovers just stay reported as "check manually".
    self.ai_relay_url = self.sm_settings.data.shelfmark.ai_relay_url
    self.ai_relay_token = self.sm_settings.data.shelfmark.ai_relay_token
    -- Where "Check for updates" looks. Blank = GitHub releases for
    -- UPDATE_REPO, which is what a public install gets and what this shipped
    -- with -- but that path 404s while the repo is private, which is the
    -- whole reason this setting exists. Set it to a base URL serving
    -- manifest.json alongside the plugin files (the homeserver's
    -- shelfmark-update service) and updates work off the working tree, with
    -- no release to tag and no version to bump between test builds.
    --
    -- Deliberately just a base URL, and the manifest format is
    -- host-agnostic: pointing this at
    -- raw.githubusercontent.com/<repo>/main/shelfmark.koplugin once the repo
    -- is public is a settings change, not a code change. Clearing it falls
    -- back to the GitHub *releases* path below, unchanged.
    self.update_url = self.sm_settings.data.shelfmark.update_url
    -- Automatic updates from the self-hosted source: checked quietly when
    -- the device wakes, gets its network back, or starts (at most once every
    -- six hours), installed without asking, and only the restart is offered.
    -- Nothing is ever checked unasked against the GitHub-releases path.
    self.auto_update = self.sm_settings.data.shelfmark.auto_update
    if self.auto_update == nil then self.auto_update = true end
    self.last_auto_update_check = self.sm_settings.data.shelfmark.last_auto_update_check
    -- Hardcover (hardcover.app) -- a public HTTPS GraphQL API, unlike Anna's
    -- Archive/CWA/the Shelfmark server, so no self-hosted companion or
    -- SOCKS5 proxy is needed for this one; it's reachable directly.
    self.hardcover_token = self.sm_settings.data.shelfmark.hardcover_token
    -- Preferred language for Hardcover matches (ISO 639-1, e.g. "en"); blank
    -- means no preference. Default English: searches otherwise return foreign
    -- editions and near-empty duplicate entries ahead of the real book.
    self.hardcover_language = self.sm_settings.data.shelfmark.hardcover_language
    if self.hardcover_language == nil then self.hardcover_language = "en" end
    -- Opt-in: push reading progress to Hardcover on close/suspend (see onCloseDocument).
    self.hardcover_progress_sync = self.sm_settings.data.shelfmark.hardcover_progress_sync
    self.bt_keyboard_addr = self.sm_settings.data.shelfmark.bt_keyboard_addr
    self.bt_ready_on_wake = self.sm_settings.data.shelfmark.bt_ready_on_wake
end

function Bookbridge:defaultDownloadDir()
    return DataStorage:getFullDataDir() .. "/shelfmark_downloads"
end

function Bookbridge:init()
    self:loadSettings()
    self:migratePluginFolder()
    self.ui.menu:registerToMainMenu(self)
    -- Automatic update check a little after start; the interval inside makes
    -- this free on every start but the first in six hours.
    if self.auto_update and self.update_url and self.update_url ~= "" then
        UIManager:scheduleIn(30, function() self:autoCheckForUpdate("startup") end)
    end
    self:registerFileDialogButtons()
    -- Always-on clipboard receiver so a phone can push text into the clipboard.
    self:startClipboardReceiver()
end

-- Writes every self.* setting field currently in memory -- shared by both
-- settings dialogs below, since each only edits its own subset of fields
-- but saveSetting() replaces the whole "shelfmark" table wholesale, not
-- a merge. Splitting one 8-field dialog into two 4-field ones was itself
-- the fix for the on-screen keyboard covering the lower fields/Apply
-- button on a Kindle-size screen -- confirmed live via screenshot.
function Bookbridge:saveAllSettings(msg)
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
        hardcover_language = self.hardcover_language,
        hardcover_progress_sync = self.hardcover_progress_sync,
        ai_relay_url = self.ai_relay_url,
        ai_relay_token = self.ai_relay_token,
        update_url = self.update_url,
        auto_update = self.auto_update,
        last_auto_update_check = self.last_auto_update_check,
        bt_keyboard_addr = self.bt_keyboard_addr,
        bt_ready_on_wake = self.bt_ready_on_wake,
    })
    self.sm_settings:flush()
    self.session_cookie = nil -- force re-login with new creds
    UIManager:show(InfoMessage:new{ text = msg, timeout = 2 })
end

function Bookbridge:editServerSettings()
    self.settings_dialog = MultiInputDialog:new{
        title = _("Shelfmark server settings"),
        fields = {
            { text = self.server_url, hint = _("Server URL, e.g. http://shelfmark:8084") },
            { text = self.username, hint = _("Username") },
            { text = self.password, text_type = "password", hint = _("Password") },
            {
                text = self.socks5_proxy,
                hint = _("SOCKS5 proxy host:port (optional, e.g. 127.0.0.1:1055 for Tailscale userspace mode)"),
            },
            {
                -- Used by device pairing and "Send debug log to server". Was
                -- only ever set by a one-time prompt, so a wrong value had no
                -- way back.
                text = self.pairing_relay_url,
                hint = _("Pairing relay URL (optional, e.g. http://homeserver:8086 -- pairing and debug-log upload)"),
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
                        self.pairing_relay_url = fields[5] ~= "" and fields[5]:gsub("/*$", "") or nil
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

function Bookbridge:editCwaSettings()
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

-- The relay only ever answers "which of these candidates is the same book",
-- and only for files the deterministic matcher already gave up on. The token
-- here grants nothing except the right to ask it that question -- the actual
-- model credentials (if a remote provider is configured) live on the server,
-- never on the device, which is the whole reason the relay exists rather
-- than the plugin calling a model API directly.
function Bookbridge:editAiSettings()
    self.ai_settings_dialog = MultiInputDialog:new{
        title = _("Match suggestions (AI)"),
        fields = {
            { text = self.ai_relay_url, hint = _("Relay URL, e.g. http://host:8089 (blank = disabled)") },
            { text = self.ai_relay_token, text_type = "password", hint = _("Relay token") },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.ai_settings_dialog)
                    end,
                },
                {
                    text = _("Apply"),
                    callback = function()
                        local fields = self.ai_settings_dialog:getFields()
                        self.ai_relay_url = fields[1] ~= "" and fields[1]:gsub("/*$", "") or nil
                        self.ai_relay_token = fields[2] ~= "" and fields[2] or nil
                        UIManager:close(self.ai_settings_dialog)
                        self:saveAllSettings(_("Saved."))
                    end,
                },
            },
        },
    }
    UIManager:show(self.ai_settings_dialog)
    self.ai_settings_dialog:onShowKeyboard()
end

function Bookbridge:editUpdateSettings()
    self.update_settings_dialog = MultiInputDialog:new{
        title = _("Update source"),
        fields = {
            {
                text = self.update_url,
                hint = _("Base URL serving manifest.json (blank = GitHub releases)"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.update_settings_dialog)
                    end,
                },
                {
                    text = _("Apply"),
                    callback = function()
                        local fields = self.update_settings_dialog:getFields()
                        self.update_url = fields[1] ~= "" and fields[1]:gsub("/*$", "") or nil
                        UIManager:close(self.update_settings_dialog)
                        self:saveAllSettings(_("Saved."))
                    end,
                },
            },
        },
    }
    UIManager:show(self.update_settings_dialog)
    self.update_settings_dialog:onShowKeyboard()
end

function Bookbridge:editAnnasSettings()
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
function Bookbridge:editHardcoverSettings()
    self.hardcover_settings_dialog = MultiInputDialog:new{
        title = _("Hardcover settings"),
        fields = {
            {
                description = _("Get a token at hardcover.app/account/api"),
                text = self.hardcover_token,
                text_type = "password",
                hint = _("Hardcover API token"),
            },
            {
                text = self.hardcover_language,
                hint = _("Preferred language for matches, 2-letter code (en, de, fr...) -- blank for any"),
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
                        self.hardcover_language = (fields[2] or ""):lower():gsub("%s", "")
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
function Bookbridge:chooseDownloadDir()
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
-- subprocess (see Bookbridge:apiRequest below) -- plain functions taking
-- explicit arguments rather than methods, since a fork's child memory is a
-- copy: mutating `self.session_cookie` inside the child would never be
-- visible back in the parent. The cookie flows through return values
-- instead, and Bookbridge:apiRequest applies it to `self` once the
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
-- Appends across sessions; rotates at DEBUG_LOG_MAX_BYTES (see below),
-- or clear it by hand from the "View debug log" menu.
-- Bumped by hand on any release tagged in the repo -- there's no build
-- step to derive this from git, so it has to be kept in sync manually
-- (matches the tag pushed via `gh release create`, e.g. this is "0.3.0"
-- for tag "v0.3.0").
local PLUGIN_VERSION = "0.3.0"
local UPDATE_REPO = "TheFactor1/koreader-bookbridge-plugin"

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
local DEBUG_LOG_PREV_PATH = DEBUG_LOG_PATH .. ".1"
-- One rotation rather than unbounded growth. This file is append-only across
-- every session and nothing ever truncated it except the manual "Clear log"
-- button in showDebugLog, so on a device left running a while it just grows
-- forever -- wasted flash on a Kindle, where flash writes aren't free
-- power-wise either. At the cap the current file becomes .1 (replacing any
-- previous .1) and logging restarts, so the worst case on disk is 2x the cap
-- and the most recent DEBUG_LOG_MAX_BYTES of history is always intact --
-- unlike a plain truncate, which would throw the history away at exactly the
-- moment something interesting had just filled it.
local DEBUG_LOG_MAX_BYTES = 256 * 1024
local function debugLog(msg)
    local ok, f = pcall(io.open, DEBUG_LOG_PATH, "a")
    if not (ok and f) then return end
    f:write(os.date("%Y-%m-%d %H:%M:%S") .. "  " .. tostring(msg) .. "\n")
    -- Size straight off the open handle rather than a separate
    -- lfs.attributes() stat: this runs on all ~76 call sites, some of them
    -- inside forked subprocesses, so it's worth not paying for a second
    -- syscall per line just to find out we're nowhere near the cap.
    local ok_size, size = pcall(f.seek, f, "end")
    f:close()
    if ok_size and size and size > DEBUG_LOG_MAX_BYTES then
        -- pcall'd, and the return value deliberately ignored: a failed
        -- rotation (read-only mount, .1 held open elsewhere) must not take
        -- down whatever real operation was only trying to log a line.
        pcall(os.rename, DEBUG_LOG_PATH, DEBUG_LOG_PREV_PATH)
    end
end

-- Renamed from Shelfmark (September 2026). The updater installs into the
-- folder the plugin runs from, so the first Bookbridge build lands inside
-- the old shelfmark.koplugin folder on every device. From there it copies
-- itself into bookbridge.koplugin, disables the old folder and asks for a
-- restart; the next start, running from the right folder, removes the old
-- one. Settings and log files keep their shelfmark* names on purpose --
-- nothing on the device is migrated by hand.
function Bookbridge:migratePluginFolder()
    -- self.path is set by PluginLoader; the debug fallback covers a direct load.
    local dir = self.path or (debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/[^/]+$"))
    if not dir then return end
    local parent, folder = dir:match("^(.*)/([^/]+)$")
    if not folder then return end
    local disabled = G_reader_settings:readSetting("plugins_disabled") or {}
    if folder == "bookbridge.koplugin" then
        local old = parent .. "/shelfmark.koplugin"
        if lfs.attributes(old, "mode") == "directory" then
            os.execute("rm -rf '" .. old:gsub("'", "'\\''") .. "'")
            disabled.shelfmark = nil
            G_reader_settings:saveSetting("plugins_disabled", disabled)
            debugLog("[rename] removed the old shelfmark.koplugin folder")
        end
        return
    end
    local new_dir = parent .. "/bookbridge.koplugin"
    lfs.mkdir(new_dir)
    for _, f in ipairs({ "main.lua", "_meta.lua", "manifest.json", "installed-build" }) do
        local src = io.open(dir .. "/" .. f, "rb")
        if src then
            local data = src:read("*a"); src:close()
            local dst = io.open(new_dir .. "/" .. f, "wb")
            if dst then dst:write(data); dst:close() end
        end
    end
    local check = io.open(new_dir .. "/main.lua", "rb")
    if not check then debugLog("[rename] could not write " .. new_dir); return end
    check:close()
    disabled[folder:gsub("%.koplugin$", "")] = true
    G_reader_settings:saveSetting("plugins_disabled", disabled)
    G_reader_settings:flush()
    debugLog("[rename] copied into " .. new_dir .. "; " .. folder .. " disabled; restart pending")
    UIManager:nextTick(function()
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = _("Shelfmark is now Bookbridge. It has moved into its own folder; the change takes effect when KOReader restarts.\n\nRestart now?"),
            ok_text = _("Restart now"),
            cancel_text = _("Later"),
            ok_callback = function() UIManager:restartKOReader() end,
        })
    end)
end

-- Drops KOReader's own cached metadata/cover row for a book file this
-- plugin just overwrote, so the file browser and bookshelf re-read the
-- new file instead of showing the replaced copy's title/author/cover.
--
-- Confirmed live, the hard way: after a CWA-side metadata edit synced a
-- corrected file down (right title, right authors, description embedded),
-- the bookshelf still showed the OLD title and authors and no
-- description -- the file on disk was correct the whole time, hidden
-- behind coverbrowser's cached row for the previous copy.
-- coverbrowser's cache does record filesize/filemtime, and
-- bookshelf.koplugin's own startup "stale-sweep" purges rows whose
-- file changed underneath them -- which is why restarting KOReader
-- resolved it -- but nothing invalidated the row *during* a running
-- session, so a sync's own replacement stayed invisible until the next
-- restart. This closes that window.
--
-- MUST only be called from the main process: doSyncLibrary runs inside a
-- forked Trapper subprocess, and BookInfoManager opens its own SQLite
-- connection to a WAL database the parent also has open -- hence
-- doSyncLibrary collecting paths and syncLibrary invalidating them after
-- the fork has exited, rather than invalidating inline. Same
-- pcall-and-feature-check idiom bookshelf.koplugin's own stale-sweep
-- uses (lib/bookshelf_stale_sweep.lua), since coverbrowser is a separate
-- plugin that may not be installed at all.
local function invalidateBookInfoCache(path)
    if type(path) ~= "string" or path == "" then return end

    local ok_bim, BIM = pcall(require, "bookinfomanager")
    if ok_bim and BIM and BIM.deleteBookInfo then
        local ok_del, del_err = pcall(function() BIM:deleteBookInfo(path) end)
        if ok_del then
            debugLog("[cache] invalidated cached book info for " .. path)
        else
            debugLog("[cache] failed to invalidate " .. path .. ": " .. tostring(del_err))
        end
    else
        debugLog("[cache] coverbrowser BookInfoManager unavailable, skipping invalidation")
    end

    -- Dropping BIM's row alone refreshes the title/author/description but
    -- NOT the cover: bookshelf.koplugin keeps its own scaled-cover cache
    -- (in memory, mirrored to cache/bookshelf_covers on disk) keyed only
    -- by the file PATH -- which a sync replacing a book in place does not
    -- change. The superseded thumbnail therefore stayed valid-looking
    -- forever, which is why a synced cover change only appeared after a
    -- manual long-press "Refresh metadata". That is precisely the case
    -- ScaledCoverCache:drop() exists for -- its own docs cite "the book's
    -- source bytes changed ... must re-decode from BIM" -- and it clears
    -- the disk layer as well as the resident one.
    local ok_scc, SCC = pcall(require, "lib/bookshelf_scaled_cover_cache")
    if ok_scc and SCC and SCC.drop then
        local ok_drop, drop_err = pcall(function() SCC:drop(path) end)
        if ok_drop then
            debugLog("[cache] dropped scaled cover for " .. path)
        else
            debugLog("[cache] failed to drop scaled cover for " .. path .. ": " .. tostring(drop_err))
        end
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
local PENDING_UPLOADS_PATH = DataStorage:getSettingsDir() .. "/shelfmark_pending_uploads.json"

-- Files this device pushed to CWA that have NOT been matched back into the
-- registry yet. CWA's ingest is async, and -- the case that made this
-- necessary -- an epub whose embedded author disagrees with its filename gets
-- indexed under metadata the filename-based matcher can't find (a real
-- "Suzanne Collins - The Hunger Games.epub" whose embedded author was "David
-- Wheeler"). Without this list such a file looks untracked on every sync and
-- is uploaded again and again, one duplicate per run. Keyed by local path: a
-- file we already pushed is never pushed a second time -- it only keeps
-- retrying the match until CWA imports it or its metadata is fixed.
local function loadPendingUploads()
    local f = io.open(PENDING_UPLOADS_PATH, "r")
    if not f then return {} end
    local content = f:read("*a"); f:close()
    if not content or content == "" then return {} end
    local ok, decoded = pcall(JSON.decode, content)
    if ok and type(decoded) == "table" then return decoded end
    return {}
end

local function savePendingUploads(t)
    local out = io.open(PENDING_UPLOADS_PATH, "w")
    if not out then return false end
    out:write(JSON.encode(t)); out:close()
    return true
end

local HARDCOVER_MAP_PATH = DataStorage:getSettingsDir() .. "/shelfmark_hardcover_map.json"
-- Maps a book's KOReader partial-md5 to its Hardcover identity and the user's
-- one-time decision, so a local file is matched to Hardcover exactly once and
-- then synced silently. Keyed by md5 -> { book_id, title, decision } where
-- decision is "sync" (matched -- keep pushing progress) or "skip" (declined --
-- never ask again). partial-md5, not path: a renamed/moved file keeps syncing.
local function loadHardcoverMap()
    local f = io.open(HARDCOVER_MAP_PATH, "r")
    if not f then return {} end
    local c = f:read("*a"); f:close()
    if not c or c == "" then return {} end
    local ok, d = pcall(JSON.decode, c)
    if ok and type(d) == "table" then return d end
    return {}
end
local function saveHardcoverMap(t)
    local out = io.open(HARDCOVER_MAP_PATH, "w")
    if not out then return false end
    out:write(JSON.encode(t)); out:close(); return true
end

local HARDCOVER_PENDING_PATH = DataStorage:getSettingsDir() .. "/shelfmark_hardcover_pending.json"
-- Reading progress captured on close/suspend but not yet pushed. The push runs
-- the network from a calm context (FileManager, or on resume), never during
-- document teardown. md5 -> { title, author, percent, at }.
local function loadHardcoverPending()
    local f = io.open(HARDCOVER_PENDING_PATH, "r")
    if not f then return {} end
    local c = f:read("*a"); f:close()
    if not c or c == "" then return {} end
    local ok, d = pcall(JSON.decode, c)
    if ok and type(d) == "table" then return d end
    return {}
end
local function saveHardcoverPending(t)
    local out = io.open(HARDCOVER_PENDING_PATH, "w")
    if not out then return false end
    out:write(JSON.encode(t)); out:close(); return true
end

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
-- delivered file ends up (see the note on Bookbridge:downloadFromCwa), so
-- this is the only way to close that loop from inside this plugin.

-- Returns the raw response body (a string; not JSON) plus the HTTP code.
local function doCwaRequest(cwa_url, username, password, path, socks5_proxy)
    if not cwa_url or cwa_url == "" then
        debugLog("[cwa] no cwa_url configured, aborting")
        return nil, nil, _("CWA URL isn't set -- add it under Bookbridge > Settings.")
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
-- Downloads into a sibling temp file, renamed onto save_path only on full
-- success, and treats any non-200 status as a real failure -- confirmed
-- live, the hard way, that this function previously did neither: it
-- opened save_path directly in truncating write mode before the request
-- even started, and reported "true" (success) after any completed HTTP
-- exchange regardless of status code. A CWA-side metadata edit changed
-- this exact book's title and broke its own file-serving path (still 404
-- afterward, not transient) -- doSyncLibrary's "changed in CWA,
-- re-downloading" step hit that 404, and this function destroyed the
-- reader's existing, perfectly good 1.1MB epub, replacing it with CWA's
-- own ~1.3KB HTML error page, silently reported as a successful sync.
-- Same temp-file-then-rename fix downloadFromAnnasArchive already uses,
-- for the identical reason.
local function doCwaFileDownload(cwa_url, username, password, path, socks5_proxy, save_path)
    if not cwa_url or cwa_url == "" then
        debugLog("[cwa] no cwa_url configured, aborting download")
        return nil, nil, _("CWA URL isn't set -- add it under Bookbridge > Settings.")
    end
    local headers = {}
    if username and username ~= "" then
        headers["Authorization"] = "Basic " .. mime.b64(username .. ":" .. (password or ""))
    end

    local temp_path = save_path .. ".downloading"
    local file, ferr = io.open(temp_path, "wb")
    if not file then
        debugLog("[cwa] couldn't open " .. tostring(temp_path) .. " for writing: " .. tostring(ferr))
        return nil, nil, _("Couldn't open file for writing: ") .. tostring(ferr)
    end

    local url = cwa_url .. path
    debugLog("[cwa] -> GET " .. url .. " (downloading to " .. tostring(temp_path) .. ")")

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
        os.remove(temp_path)
        return nil, nil, _("Couldn't reach CWA -- check the CWA URL in Settings.")
    end
    if code == socketutil.TIMEOUT_CODE or code == socketutil.SINK_TIMEOUT_CODE then
        debugLog("[cwa] <- timed out: " .. tostring(code))
        os.remove(temp_path)
        return nil, nil, _("Download from CWA timed out.")
    end
    if type(code) ~= "number" or code >= 400 then
        debugLog("[cwa] <- HTTP " .. tostring(code) .. ", discarded -- left any existing file at "
            .. tostring(save_path) .. " untouched")
        os.remove(temp_path)
        return nil, code, T(_("Download from CWA failed (HTTP %1)."), tostring(code))
    end

    if not os.rename(temp_path, save_path) then
        debugLog("[cwa] <- HTTP " .. tostring(code) .. " but couldn't move " .. temp_path .. " into place")
        os.remove(temp_path)
        return nil, code, _("Download succeeded but couldn't be saved.")
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
-- Bookbridge:annasSearch's caller) -- never on a timer. Asks the backend to
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
local function doHttpDownloadToFile(url, save_path, log_prefix, block_timeout, total_timeout, headers, socks5_proxy)
    local file, ferr = io.open(save_path, "wb")
    if not file then
        return nil, nil, _("Couldn't open file for writing: ") .. tostring(ferr)
    end
    debugLog(log_prefix .. " -> GET " .. url .. " (downloading to " .. save_path .. ")")

    socketutil:set_timeout(block_timeout or 15, total_timeout or 60)
    local sink = socketutil.file_sink(file)
    local requester = url:match("^https:") and https or http
    local request = { method = "GET", url = url, sink = sink, headers = headers }
    -- Same one-call interception the CWA/Shelfmark requests use: only set
    -- when a caller actually passes a proxy, so every existing caller
    -- (Anna's Archive, covers, the GitHub updater) is byte-for-byte
    -- unchanged.
    if socks5_proxy and socks5_proxy ~= "" then
        local proxy_host, proxy_port = socks5_proxy:match("^([^:]+):(%d+)$")
        if proxy_host then
            request.create = function() return makeSocks5Socket(proxy_host, tonumber(proxy_port)) end
        else
            debugLog(log_prefix .. " invalid socks5_proxy setting, ignoring: " .. socks5_proxy)
        end
    end
    local ok, code = pcall(function()
        return socket.skip(1, requester.request(request))
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
    -- luasocket signals a connection-level failure as a NON-NUMERIC second
    -- return ("connection refused", "host unreachable"), not as a status,
    -- and the timeout sentinels above are the only other non-numeric
    -- values. Folding the rest into the HTTP branch produced "Download
    -- failed (HTTP connection refused)", which names the wrong thing. It's
    -- the same couldn't-reach case the pcall branch above already handles,
    -- so it returns that same message -- which is also what lets
    -- doAnnasFileDownload's remap relabel it for Anna's mirror instead of
    -- leaking a raw socket string to the reader.
    if type(code) ~= "number" then
        os.remove(save_path)
        debugLog(log_prefix .. " <- request failed: " .. tostring(code))
        return nil, nil, _("Couldn't reach the file server.")
    end
    if code >= 400 then
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
-- Applies to both the bibliography's direct-fetch path and the
-- general-search path below (which decodes and fetches the proxy's own
-- target URL directly rather than asking the proxy for a smaller size --
-- see downloadCoverToPath's own note on why: confirmed live the proxy
-- ignores the url= parameter and caches by hardcover_<id> alone, so
-- rewriting it while still going *through* the proxy has no effect).
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
        -- Shelfmark's own /api/covers proxy carries the real upstream URL
        -- base64-encoded in its own "url" query parameter, and that
        -- upstream host (Hardcover's CDN, or the Amazon CDN it frequently
        -- hotlinks -- confirmed live, both serve these with no auth at
        -- all) can just be fetched directly instead of going through the
        -- proxy, applying the same Amazon-suffix shrink used above.
        -- Rewriting the size *within* the proxy's own url= param has no
        -- effect (confirmed live: that proxy caches by hardcover_<id>
        -- alone and ignores it) -- fetching the decoded target directly
        -- sidesteps that entirely, and saves the extra hop plus Shelfmark's
        -- own proxying bandwidth. Falls back to the proxied fetch (needs
        -- the session cookie) if decoding doesn't produce something that
        -- looks like a real URL -- never a hard failure, matching every
        -- other cover helper in this section.
        local prefix, encoded_url = cover_url:match("^(.-%?url=)(.+)$")
        local decoded_ok, decoded = false, nil
        if prefix then
            decoded_ok, decoded = pcall(function() return mime.unb64(socketurl.unescape(encoded_url)) end)
        end
        if decoded_ok and decoded and decoded:match("^https?://") then
            full_url = shrinkAmazonImageUrl(decoded)
        else
            if not session_cookie then return nil end
            full_url = server_url .. cover_url
            headers = { Cookie = session_cookie }
        end
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
function Bookbridge:prefetchCovers(books)
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

-- Plain JSON GET with the same timeouts and sink as the Hardcover call.
-- Used for the Open Library second opinion; returns a table, or nil + why.
local function fetchJsonUrl(url, log_prefix, attempt)
    log_prefix = log_prefix or "[http]"
    attempt = attempt or 1
    socketutil:set_timeout(10, 20)
    local sink, sink_table = socketutil.table_sink()
    local ok, code = pcall(function()
        return socket.skip(1, http.request{
            method = "GET", url = url, sink = sink,
            headers = { ["User-Agent"] = "KOReader bookbridge.koplugin (https://github.com/TheFactor1/koreader-bookbridge-plugin)",
                        ["Accept"] = "application/json" },
        })
    end)
    socketutil:reset_timeout()
    debugLog(log_prefix .. " GET " .. (url:gsub("%?.*$", "?...")) .. " -> " .. tostring(ok and code or ("error: " .. tostring(code))))
    -- Open Library resets connections now and then; one retry, once.
    if (not ok or code == socketutil.TIMEOUT_CODE or code == socketutil.SINK_TIMEOUT_CODE) and attempt == 1 then
        require("ffi/util").sleep(1)
        return fetchJsonUrl(url, log_prefix, 2)
    end
    if not ok then return nil, "unreachable" end
    if code == socketutil.TIMEOUT_CODE or code == socketutil.SINK_TIMEOUT_CODE then return nil, "timeout" end
    if code ~= 200 then return nil, "HTTP " .. tostring(code) end
    local dok, obj = pcall(JSON.decode, table.concat(sink_table))
    if not dok or type(obj) ~= "table" then
        -- an empty 200 body is another of Open Library's moods
        if attempt == 1 then require("ffi/util").sleep(1); return fetchJsonUrl(url, log_prefix, 2) end
        return nil, "unreadable response"
    end
    return stripJsonNull(obj)
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
-- ONE round trip. Hardcover's search returns the full Typesense documents
-- inline (id, title, author_names) next to the plain id list, so the five
-- follow-up books_by_pk queries this used to make -- six sequential TLS
-- round trips from a Kindle, and the whole reason the progress-sync confirm
-- took several seconds to appear -- collapse into this single request.
--
-- `results.hits` arrives in relevance order (same order as `ids`). Don't
-- reorder it: hits[1] is the fallback pick when no author matches.
-- HARDCOVER MATCH BLOCK -- tests/hardcover-match extracts from here to END.
-- Identifiers the file carries, in the newline-separated "scheme:value"
-- form KOReader hands over (getProps().identifiers): ISBN-13, labelled
-- ISBN-10, ASIN, and a hardcover-id written by Calibre's Hardcover plugin.
local function parseBookIdentifiers(text)
    local ids = { isbn13 = {}, isbn10 = {}, asin = {}, hardcover_id = nil }
    if type(text) ~= "string" or text == "" then return ids end
    local seen = {}
    local function add(list, v) if v and not seen[v] then seen[v] = true; list[#list + 1] = v end end
    ids.hardcover_id = tonumber(text:match("[Hh]ardcover%-?[Ii][Dd]%s*[:=]%s*(%d+)"))
    local flat = text:gsub("%-", "")                    -- 978-0-7653-8203-0 -> 9780765382030
    for v in flat:gmatch("97[89]%d%d%d%d%d%d%d%d%d%d") do add(ids.isbn13, v) end
    for v in flat:gmatch("[Ii][Ss][Bb][Nn][^%d]*(%d%d%d%d%d%d%d%d%d[%dXx])%f[^%dXx]") do
        if not v:match("^97[89]") then add(ids.isbn10, v:upper()) end
    end
    for v in text:gmatch("%f[%w](B0[0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z])%f[^%w]") do add(ids.asin, v) end
    return ids
end

-- Authors from a book's contributions, "Author" entries first (an
-- audiobook's narrator is listed among them too).
local function contributionNames(contribs)
    local names = {}
    for _, c in ipairs(contribs or {}) do
        if c.author and c.author.name then
            if c.contribution == nil or c.contribution == "Author" then table.insert(names, 1, c.author.name)
            else names[#names + 1] = c.author.name end
        end
    end
    return names
end

-- Exact lookups: one query carrying every identifier the file has. An
-- identifier hit is certain by construction, so it never goes through the
-- title scoring, and the edition it names is the file's own -- its page
-- count is what progress is recorded against.
-- Returns book_id, title, author, err, ranked, confident, unreachable, edition{id,pages}
local function doHardcoverFindByIdentifiers(token, ids, lang)
    if not (ids.hardcover_id or ids.isbn13[1] or ids.isbn10[1] or ids.asin[1]) then return nil end
    -- Only the identifier kinds actually present go into the query: the JSON
    -- encoder turns an empty Lua table into {} (an object), which Hardcover
    -- rejects where a string list is expected -- seen live.
    local decls, clauses, vars = {}, {}, {}
    if ids.isbn13[1] then decls[#decls + 1] = "$isbn13: [String!]!"; clauses[#clauses + 1] = "{ isbn_13: { _in: $isbn13 } }"; vars.isbn13 = ids.isbn13 end
    if ids.isbn10[1] then decls[#decls + 1] = "$isbn10: [String!]!"; clauses[#clauses + 1] = "{ isbn_10: { _in: $isbn10 } }"; vars.isbn10 = ids.isbn10 end
    if ids.asin[1] then decls[#decls + 1] = "$asin: [String!]!"; clauses[#clauses + 1] = "{ asin: { _in: $asin } }"; vars.asin = ids.asin end
    local parts = {}
    if #clauses > 0 then
        parts[#parts + 1] = "editions(where: { _or: [ " .. table.concat(clauses, ", ") .. " ] }, limit: 10) { id book_id pages title language { code2 } book { id title users_count contributions { contribution author { name } } } }"
    end
    if ids.hardcover_id then
        decls[#decls + 1] = "$hcid: Int!"; vars.hcid = ids.hardcover_id
        parts[#parts + 1] = "books_by_pk(id: $hcid) { id title users_count contributions { contribution author { name } } }"
    end
    local query = "query ByIdentifiers(" .. table.concat(decls, ", ") .. ") { " .. table.concat(parts, " ") .. " }"
    local data, err = doHardcoverGraphQL(token, query, vars)
    if not data then return nil, nil, nil, err, nil, false, true end
    local best
    for _, e in ipairs(data.editions or {}) do
        if e.book_id and e.book then
            local score = math.log10((tonumber(e.book.users_count) or 0) + 1)
            if lang and lang ~= "" and e.language and e.language.code2 == lang then score = score + 10 end
            if tonumber(e.pages) and tonumber(e.pages) > 0 then score = score + 1 end
            if not best or score > best.score then best = { score = score, e = e } end
        end
    end
    if best then
        local e = best.e
        local names = contributionNames(e.book.contributions)
        local edition = { id = e.id, pages = tonumber(e.pages) }
        return e.book_id, e.book.title or e.title, names[1], nil,
            { { id = e.book_id, title = e.book.title or e.title, author = names[1] } }, true, false, edition
    end
    local b = data.books_by_pk
    if b and b.id then
        local names = contributionNames(b.contributions)
        return b.id, b.title, names[1], nil, { { id = b.id, title = b.title, author = names[1] } }, true, false, nil
    end
    return nil
end

-- Open Library as a second opinion when the title search isn't sure: the
-- work's ISBN-13s, which Hardcover then answers exactly. No key needed.
local function doOpenLibraryIsbns(title, author)
    local function esc(t) return (tostring(t or ""):gsub("[^%w%-%._~ ]", function(c) return string.format("%%%02X", c:byte()) end):gsub(" ", "+")) end
    local url = "https://openlibrary.org/search.json?title=" .. esc(title)
        .. ((author and author ~= "") and ("&author=" .. esc(author)) or "")
        .. "&fields=key,title,author_name,author_alternative_name,isbn,edition_count&limit=3"
    local data = fetchJsonUrl(url, "[openlibrary]")
    return data and data.docs or nil
end

local function doHardcoverFindBook(token, title, author, lang, identifiers)
    -- 1. The file's own identifiers: an exact answer, no scoring.
    local ids = parseBookIdentifiers(identifiers)
    if ids.hardcover_id or ids.isbn13[1] or ids.isbn10[1] or ids.asin[1] then
        local bid, bt, ba, berr, branked, _bc, bunreach, bed = doHardcoverFindByIdentifiers(token, ids, lang)
        if bunreach then return nil, nil, nil, berr, nil, false, true end
        if bid then
            debugLog(string.format("[hc] identifier match: %s -> %s by %s (edition %s, %s pages)", tostring(title), tostring(bt),
                tostring(ba), tostring(bed and bed.id), tostring(bed and bed.pages)))
            return bid, bt, ba, nil, branked, true, false, bed
        end
        debugLog("[hc] identifiers not on Hardcover; trying the title search")
    end
    -- 2. Title search.
    local data, err = doHardcoverGraphQL(token, [[
        query Search($q: String!) {
            search(query: $q, query_type: "Book", per_page: 5) { ids results }
        }
    ]], { q = title })
    -- Seventh value: true when Hardcover could not be reached at all (offline,
    -- DNS, timeout) as opposed to answering with nothing. Callers keep the
    -- book queued on the former and only park it for review on the latter.
    if not data then return nil, nil, nil, err, nil, false, true end
    local search = data.search
    local ids = search and search.ids

    -- Normalized candidate: { id = number, title = string, names = {string,...} }
    local candidates = {}
    local hits = search and search.results and search.results.hits
    if type(hits) == "table" then
        for i = 1, math.min(#hits, 5) do
            local doc = hits[i] and hits[i].document
            -- document.id is a STRING ("427473") in the search index; every
            -- mutation downstream takes an Int.
            local id = doc and tonumber(doc.id)
            if id and doc.title then
                local names = {}
                for _, n in ipairs(doc.author_names or {}) do
                    if type(n) == "string" then names[#names + 1] = n end
                end
                candidates[#candidates + 1] = { id = id, title = doc.title, names = names,
                    -- Both decide confidence below: an omnibus is flagged
                    -- compilation, and Hardcover's near-empty duplicate entries
                    -- have a handful of readers where the real one has thousands.
                    compilation = (doc.compilation == true), users = tonumber(doc.users_count) or 0 }
            end
        end
    end

    -- Fallback if the search index ever stops returning usable documents:
    -- one batched query for every id, not the old one-at-a-time loop.
    if #candidates == 0 and ids and ids[1] then
        local want = {}
        for i = 1, math.min(#ids, 5) do want[i] = ids[i] end
        local bd = doHardcoverGraphQL(token, [[
            query Books($ids: [Int!]!) {
                books(where: { id: { _in: $ids } }) {
                    id title contributions { contribution author { name } }
                }
            }
        ]], { ids = want })
        local by_id = {}
        for _, b in ipairs((bd and bd.books) or {}) do by_id[b.id] = b end
        -- books() comes back ordered by id, NOT by relevance -- walk `want`
        -- so the search's own ranking survives.
        for i = 1, #want do
            local b = by_id[want[i]]
            if b then
                local names = {}
                for _, c in ipairs(b.contributions or {}) do
                    -- Contributors tagged "Author" go first: this same "Run"
                    -- audiobook lists its narrator (Phil Gigante) among the
                    -- contributions, so taking the listed order as-is would
                    -- report the wrong author. Untyped entries count as
                    -- authors, matching entries that were never tagged.
                    if c.author and c.author.name then
                        if c.contribution == nil or c.contribution == "Author" then
                            table.insert(names, 1, c.author.name)
                        else
                            names[#names + 1] = c.author.name
                        end
                    end
                end
                candidates[#candidates + 1] = { id = b.id, title = b.title, names = names, compilation = false, users = 0 }
            end
        end
    end

    if #candidates == 0 then
        return nil, nil, nil, _("No matching book found on Hardcover."), {}, false, false
    end

    -- Language preference. The search index carries no language at all; it
    -- lives on editions. One batched query asks, for every candidate, whether
    -- ANY edition exists in the preferred language, and candidates without
    -- one are dropped -- but only when at least one candidate has one, so a
    -- book Hardcover only knows in another language is never lost. Measured:
    -- for "The Three-Body Problem" the real entry has 101 editions with
    -- English; the four near-empty duplicates ahead of it have none.
    if lang and lang ~= "" and #candidates > 1 then
        local ids = {}
        for i, c in ipairs(candidates) do ids[i] = c.id end
        local ld = doHardcoverGraphQL(token, [[
            query Lang($ids: [Int!]!, $lang: String!) {
                books(where: { id: { _in: $ids } }) {
                    id
                    editions(where: { language: { code2: { _eq: $lang } } }, limit: 1) { id }
                }
            }
        ]], { ids = ids, lang = lang })
        if ld and type(ld.books) == "table" then
            local has = {}
            for _, b in ipairs(ld.books) do
                if type(b.editions) == "table" and b.editions[1] then has[b.id] = true end
            end
            local kept = {}
            for _, c in ipairs(candidates) do if has[c.id] then kept[#kept + 1] = c end end
            if #kept > 0 and #kept < #candidates then
                debugLog(string.format("[hardcover] language %s: kept %d of %d candidates", lang, #kept, #candidates))
                candidates = kept
            end
        end
    end

    -- Score every candidate and pick the best; report whether that pick is
    -- confident enough to sync silently. Confident means: the author matches
    -- (when the file has one), the title matches after normalisation
    -- (case, punctuation, a subtitle after ":", a leading article), and the
    -- candidate is not an omnibus unless the file's own title says it is
    -- one. Anything less goes to the review list instead of Hardcover.
    local function norm(t)
        t = (t or ""):lower():gsub("\u{2019}", "'"):gsub("\u{2018}", "'"):gsub("`", "'")
        t = t:gsub("%s*:.*$", "")
        -- "(Forward collection)", "[Kindle Edition]": tags, not title.
        t = t:gsub("%b()", " "):gsub("%b[]", " ")
        t = t:gsub("[^%w%s']", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        t = t:gsub("^the ", ""):gsub("^an ", ""):gsub("^a ", "")
        return t
    end
    local want = norm(title)
    local lt = (title or ""):lower()
    local local_omnibus = lt:find("omnibus", 1, true) or lt:find("complete", 1, true) or lt:find("collection", 1, true)
        or lt:find("novels", 1, true) or lt:find("trilogy", 1, true) or lt:find("box set", 1, true) or lt:find("books 1", 1, true)
    -- The file may credit several people -- KOReader joins them with newlines,
    -- other tools with ";", "&" or "and" -- and 1984 on the Kindle credits
    -- its editor after Orwell. Taking the last word of the whole field gave
    -- the editor's surname, which matched nothing, and a plainly right book
    -- went to review. So: every credited person's surname counts, and a
    -- candidate that carries any of them is an author hit. Surname only,
    -- matching releaseRelevanceScore's convention elsewhere in this file --
    -- robust to "Blake Crouch" vs "Crouch, Blake".
    local surnames = {}
    for person in ((author or "") .. "\n"):gmatch("([^\n;&]+)") do
        person = person:gsub("%s+and%s+", "\n")
        for one in (person .. "\n"):gmatch("([^\n]+)") do
            local sn = one:match("(%S+)%s*$")
            if sn then
                sn = sn:lower():gsub("[%.,]+$", "")
                -- "unknown author", "Anonymous", "Various": not surnames. The
                -- Kindle's 1984 credits "George Orwell\nunknown author".
                local generic = { jr = true, sr = true, phd = true, md = true, author = true, unknown = true,
                                  anonymous = true, various = true, editor = true, translator = true, illustrator = true }
                if #sn > 1 and not generic[sn] then surnames[#surnames + 1] = sn end
            end
        end
    end
    local surname = surnames[1]
    for i2, c in ipairs(candidates) do
        local score = -0.01 * i2                       -- search order breaks ties
        c.author_hit = nil
        if surname then
            for _, n in ipairs(c.names) do
                local nl = n:lower()
                for _, sn in ipairs(surnames) do
                    if nl:find(sn, 1, true) then c.author_hit = n; break end
                end
                if c.author_hit then break end
            end
        end
        if c.author_hit then score = score + 3 end
        local have = norm(c.title)
        c.title_exact = (want ~= "" and have == want)
        if c.title_exact then score = score + 3
        elseif want ~= "" and have ~= "" and (have:find(want, 1, true) or want:find(have, 1, true)) then score = score + 1 end
        if c.compilation then score = score + (local_omnibus and 1 or -2) end
        score = score + math.log10((c.users or 0) + 1) * 0.5
        c.score = score
    end
    table.sort(candidates, function(a, b) return a.score > b.score end)
    local chosen = candidates[1]
    local confident = chosen.title_exact and not (chosen.compilation and not local_omnibus)
        and ((surname and chosen.author_hit ~= nil) or (not surname and (chosen.users or 0) >= 50))

    -- The full ranked list travels along so the review list can offer the
    -- alternatives; confidence is the sixth value.
    local ranked = {}
    for i2, c in ipairs(candidates) do ranked[i2] = { id = c.id, title = c.title, author = c.author_hit or c.names[1] } end

    -- 3. Not sure? Ask Open Library for the work by title+author and let its
    -- ISBNs settle it on Hardcover. Only its own exact-title, author-matching
    -- work counts; anything else keeps the review verdict.
    if not confident then
        local docs = doOpenLibraryIsbns(title, author)
        for _, d in ipairs(docs or {}) do
            local ok_title = want ~= "" and norm(d.title) == want
            -- Open Library's primary author name may be the native script
            -- ("Όμηρος"); its alternative names carry the Latin forms ("Homer").
            local ok_author = (#surnames == 0)
            local function author_hit(list)
                for _, n in ipairs(list or {}) do
                    for _, sn in ipairs(surnames) do if type(n) == "string" and n:lower():find(sn, 1, true) then return true end end
                end
                return false
            end
            if author_hit(d.author_name) or author_hit(d.author_alternative_name) then ok_author = true end
            if ok_title and ok_author and type(d.isbn) == "table" then
                local list = {}
                for _, v in ipairs(d.isbn) do if #list < 20 and type(v) == "string" and #v == 13 then list[#list + 1] = v end end
                if #list > 0 then
                    local bid, bt, ba, _berr, branked, _bc, bunreach, bed = doHardcoverFindByIdentifiers(token, { isbn13 = list, isbn10 = {}, asin = {} }, lang)
                    if bid and not bunreach then
                        debugLog(string.format("[hc] Open Library confirmed %s -> %s by %s via ISBN", tostring(title), tostring(bt), tostring(ba)))
                        return bid, bt, ba, nil, branked, true, false, bed
                    end
                end
                break
            end
        end
    end
    return chosen.id, chosen.title, chosen.author_hit or chosen.names[1], nil, ranked, confident and true or false
end
-- END HARDCOVER MATCH BLOCK

-- How many author matches to offer the reader to choose from. Hardcover's
-- search ranks by relevance, so the real author is usually first, but the
-- top hit is often a study-guide/"summary of" account instead -- letting the
-- reader pick (with a book count to tell a 102-book author from a 1-book
-- imitator) is far more forgiving than blindly following hit #1.
local HARDCOVER_AUTHOR_MATCH_LIMIT = 12

-- Returns an ordered list of { id, name, books_count } candidates (relevance
-- order preserved), an empty list when nothing matched, or nil + an error.
local function doHardcoverFindAuthors(token, name, limit)
    limit = limit or HARDCOVER_AUTHOR_MATCH_LIMIT
    local search_data, err = doHardcoverGraphQL(token, [[
        query Search($q: String!, $n: Int!) {
            search(query: $q, query_type: "Author", per_page: $n) { ids }
        }
    ]], { q = name, n = limit })
    if not search_data then return nil, err end
    local ids = search_data.search and search_data.search.ids
    if not ids or not ids[1] then
        return {}, nil
    end
    -- Search may hand ids back as strings or numbers; the authors query wants
    -- Ints. Coerce and cap to the limit, keeping the relevance order.
    local id_list = {}
    for _, v in ipairs(ids) do
        local n = tonumber(v)
        if n then
            id_list[#id_list + 1] = n
            if #id_list >= limit then break end
        end
    end
    if not id_list[1] then return {}, nil end

    -- One round trip for display names plus a disambiguating book count.
    local detail, lookup_err = doHardcoverGraphQL(token, [[
        query AuthorsByIds($ids: [Int!]!) {
            authors(where: { id: { _in: $ids } }) { id name books_count }
        }
    ]], { ids = id_list })
    if not detail or not detail.authors then
        return nil, lookup_err or _("Found matches but couldn't fetch their details.")
    end
    local by_id = {}
    for _, a in ipairs(detail.authors) do by_id[a.id] = a end

    local results = {}
    for _, id in ipairs(id_list) do
        local a = by_id[id]
        if a and a.name and a.name ~= "" then
            results[#results + 1] = { id = id, name = a.name, books_count = a.books_count or 0 }
        end
    end
    return results, nil
end

local function doHardcoverSetStatus(token, book_id, status_id, edition_id)
    -- edition_id: the file's own edition when an identifier named it, so the
    -- page count progress is recorded against is the file's. Only on first
    -- add -- a book the user already shelved keeps their edition.
    local data, err = doHardcoverGraphQL(token, [[
        mutation SetStatus($book_id: Int!, $status_id: Int!, $edition_id: Int) {
            insert_user_book(object: { book_id: $book_id, status_id: $status_id, edition_id: $edition_id }) {
                id
                error
            }
        }
    ]], { book_id = book_id, status_id = status_id, edition_id = edition_id })
    if not data then return false, err end
    local result = data.insert_user_book
    if not result or result.error then
        return false, (result and result.error) or _("Hardcover didn't confirm the update.")
    end
    return true
end

-- The user's relationship to a Hardcover book: the user_book row with its
-- edition and latest read, or nil if the book isn't on their shelf yet.
local function doHardcoverGetUserBook(token, book_id)
    local data, err = doHardcoverGraphQL(token, [[
        query UB($id: Int!) {
            me {
                user_books(where: { book_id: { _eq: $id } }, limit: 1) {
                    id
                    status_id
                    edition { id pages }
                    user_book_reads(order_by: { id: desc }, limit: 1) {
                        id progress_pages edition_id finished_at
                    }
                }
            }
        }
    ]], { id = book_id })
    if not data then return nil, err end
    local me = data.me
    return me and me[1] and me[1].user_books and me[1].user_books[1]  -- may be nil
end

-- Pushes reading progress (percent, 0..1) to Hardcover for a resolved book_id.
-- Converts to the edition's page count so KOReader's own pagination doesn't
-- matter -- 42% of a 352-page edition is recorded as page 148, matching what
-- Hardcover shows. Auto-marks the book currently-reading if it isn't already,
-- and never downgrades a book already marked read.
local function doHardcoverPushProgress(token, book_id, percent, edition_id)
    local ub, err = doHardcoverGetUserBook(token, book_id)
    if err then return false, err end
    if not ub or (ub.status_id ~= 2 and ub.status_id ~= 3) then
        local ok, serr = doHardcoverSetStatus(token, book_id, 2, edition_id)  -- 2 = currently reading
        if not ok then return false, serr end
        -- Hardcover's read-after-write lags: on the phone the re-read 300 ms
        -- after a successful insert still came back empty and the push was
        -- retried 40 s later. Give it a moment, twice, before giving up.
        -- Only ever runs on a book's first sync.
        local util = require("ffi/util")
        for attempt = 1, 3 do
            ub = doHardcoverGetUserBook(token, book_id)
            if ub then break end
            if attempt < 3 then util.sleep(1) end
        end
        if not ub then return false, _("Couldn't mark the book currently reading on Hardcover.") end
    end
    local edition = ub.edition
    local pages = edition and tonumber(edition.pages)
    if not edition or not pages or pages <= 0 then
        return false, _("Hardcover has no page count for this edition -- can't record progress.")
    end
    local progress_pages = math.floor(percent * pages + 0.5)
    if progress_pages < 1 then progress_pages = 1 end
    if progress_pages > pages then progress_pages = pages end
    local read = ub.user_book_reads and ub.user_book_reads[1]
    if read and not read.finished_at then
        local data, uerr = doHardcoverGraphQL(token, [[
            mutation UpdRead($id: Int!, $p: Int!) {
                update_user_book_read(id: $id, object: { progress_pages: $p }) { id error }
            }
        ]], { id = read.id, p = progress_pages })
        local r = data and data.update_user_book_read
        if not r or r.error then return false, (r and r.error) or uerr or _("Hardcover didn't confirm the progress update.") end
    else
        local data, ierr = doHardcoverGraphQL(token, [[
            mutation InsRead($ubid: Int!, $eid: Int!, $p: Int!, $d: date!) {
                insert_user_book_read(user_book_id: $ubid, user_book_read: { edition_id: $eid, progress_pages: $p, started_at: $d }) { id error }
            }
        ]], { ubid = ub.id, eid = edition.id, p = progress_pages, d = os.date("!%Y-%m-%d") })
        local r = data and data.insert_user_book_read
        if not r or r.error then return false, (r and r.error) or ierr or _("Hardcover didn't confirm the new reading record.") end
    end
    return true, progress_pages, pages
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

-- Finds, for each given Hardcover book id, whichever sibling edition
-- (grouped by canonical_id) actually has the most readers -- some
-- editions logged as "Currently Reading"/"Read" carry no cover at all or
-- a negligible reader count next to a far more popular edition of the
-- exact same book (confirmed live: Blake Crouch's "Run" alone has 369
-- users; three other editions of the same book have 0, none of them
-- logged). Two batched queries regardless of how many ids are given --
-- this runs once over a whole status list, not once per book, from
-- doSearch's prefer_popular_edition path.
--
-- Returns a map of id (number) -> {title=, cover_url=} for entries whose
-- winning edition differs from the one passed in; an id that's already
-- the most popular in its own group is simply absent from the result, for
-- the caller to leave untouched.
local function doHardcoverBestEditions(token, provider_ids)
    if #provider_ids == 0 then return {} end
    local canon_data = doHardcoverGraphQL(token, [[
        query CanonIds($ids: [Int!]) {
            books(where: {id: {_in: $ids}}) { id canonical_id }
        }
    ]], { ids = provider_ids })
    if not canon_data or not canon_data.books then return {} end

    -- canonical_id is Hardcover's null sentinel (already normalized to
    -- `false` by doHardcoverGraphQL's own stripJsonNull) when a book
    -- already is the canonical record -- its own id is then the group to
    -- search for siblings.
    local group_ids_set = {}
    local id_to_group = {}
    for _, b in ipairs(canon_data.books) do
        local group_id = (type(b.canonical_id) == "number") and b.canonical_id or b.id
        id_to_group[b.id] = group_id
        group_ids_set[group_id] = true
    end
    local group_ids = {}
    for id in pairs(group_ids_set) do table.insert(group_ids, id) end
    if #group_ids == 0 then return {} end

    local sib_data = doHardcoverGraphQL(token, [[
        query Siblings($ids: [Int!]) {
            books(where: {_or: [{id: {_in: $ids}}, {canonical_id: {_in: $ids}}]}) {
                id
                canonical_id
                title
                users_count
                cached_image
            }
        }
    ]], { ids = group_ids })
    if not sib_data or not sib_data.books then return {} end

    -- Best (highest users_count) book per group.
    local best_by_group = {}
    for _, b in ipairs(sib_data.books) do
        local group_id = (type(b.canonical_id) == "number") and b.canonical_id or b.id
        local users_count = type(b.users_count) == "number" and b.users_count or 0
        local current = best_by_group[group_id]
        if not current or users_count > current.users_count then
            best_by_group[group_id] = {
                id = b.id,
                title = b.title,
                users_count = users_count,
                cover_url = type(b.cached_image) == "table" and b.cached_image.url or nil,
            }
        end
    end

    local result = {}
    for _, original_id in ipairs(provider_ids) do
        local group_id = id_to_group[original_id]
        local best = group_id and best_by_group[group_id]
        if best and best.id ~= original_id then
            result[original_id] = { title = best.title, cover_url = best.cover_url }
        end
    end
    return result
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

function Bookbridge:registerFileDialogButtons()
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

        -- Only when a CWA server is actually configured -- matches the same
        -- guard doSyncLibrary itself uses, and there's nothing to check
        -- against otherwise.
        if self_ref.cwa_url and self_ref.cwa_url ~= "" then
            table.insert(row, {
                text = _("Refresh from CWA"),
                callback = function()
                    self_ref:refreshBookMetadata(file)
                end,
            })
        end

        -- Push counterpart to "Refresh from CWA" above: get THIS book into
        -- the library without running a whole-library sync.
        if self_ref.cwa_url and self_ref.cwa_url ~= "" then
            table.insert(row, {
                text = _("Send to CWA"),
                callback = function()
                    local Trapper = require("ui/trapper")
                    Trapper:wrap(function()
                        self_ref:sendBookToCwa(file)
                    end)
                end,
            })
        end

        -- One-off counterpart to the batch review offered after a sync: same
        -- suggest-then-confirm path, for when a single book is bothering you
        -- rather than waiting for the next sync to surface it.
        if self_ref.cwa_url and self_ref.cwa_url ~= ""
                and self_ref.ai_relay_url and self_ref.ai_relay_url ~= "" then
            table.insert(row, {
                text = _("Suggest match"),
                callback = function()
                    local Trapper = require("ui/trapper")
                    Trapper:wrap(function()
                        self_ref:suggestMatchForFile(file)
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

-- The files the updater ever touches. Everything else in the plugin
-- directory (settings, caches) is left alone.
local UPDATE_FILES = { "main.lua", "_meta.lua" }

-- KOReader ships a pure-Lua SHA-256; measured on the Kindle at 0.03s for
-- this file's ~350KB, so hashing on every check is free. Returns nil if the
-- library or file is missing, and every caller treats nil as "can't tell"
-- rather than "differs", so a missing library degrades to a version-number
-- comparison instead of offering a pointless update.
local function sha256OfFile(path)
    local lib_ok, sha = pcall(require, "ffi/sha2")
    if not lib_ok or type(sha) ~= "table" or type(sha.sha256) ~= "function" then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    if not data then return nil end
    local ok, digest = pcall(sha.sha256, data)
    if not ok or type(digest) ~= "string" then return nil end
    return digest:lower()
end

-- A SOCKS5 proxy set for Tailscale userspace mode can only reach tailnet
-- peers, never the public internet -- so routing a github.com fetch through
-- it would break the very path it's meant to help. Only private/tailnet
-- destinations get proxied; anything public goes direct. Both Kindles
-- currently have a real tailscale0 and reach the homeserver without the
-- proxy at all, so this is a fallback for if userspace mode ever returns.
local function proxyForUrl(url, socks5_proxy)
    if not socks5_proxy or socks5_proxy == "" then return nil end
    local host = tostring(url):match("^%a+://([^/:]+)")
    if not host then return nil end
    if host == "localhost" or host:match("^127%.") or host:match("^10%.")
            or host:match("^192%.168%.") then
        return socks5_proxy
    end
    local a, b = host:match("^(%d+)%.(%d+)%.")
    a, b = tonumber(a), tonumber(b)
    if a and b then
        if a == 100 and b >= 64 and b <= 127 then return socks5_proxy end   -- tailnet CGNAT
        if a == 172 and b >= 16 and b <= 31 then return socks5_proxy end
    end
    return nil
end

local function doHttpGetString(url, socks5_proxy, log_prefix, block_timeout, total_timeout)
    debugLog(log_prefix .. " -> GET " .. url)
    socketutil:set_timeout(block_timeout or 10, total_timeout or 25)
    local sink, sink_table = socketutil.table_sink()
    local requester = url:match("^https:") and https or http
    local request = {
        method = "GET",
        url = url,
        sink = sink,
        headers = { ["User-Agent"] = "bookbridge.koplugin" },
    }
    local proxy = proxyForUrl(url, socks5_proxy)
    if proxy then
        local proxy_host, proxy_port = proxy:match("^([^:]+):(%d+)$")
        if proxy_host then
            request.create = function() return makeSocks5Socket(proxy_host, tonumber(proxy_port)) end
        end
    end
    local ok, code = pcall(function() return socket.skip(1, requester.request(request)) end)
    socketutil:reset_timeout()
    if not ok then
        debugLog(log_prefix .. " <- connection error: " .. tostring(code))
        return nil, nil, tostring(code)
    end
    -- luasocket reports a connection-level failure as a non-numeric second
    -- return ("connection refused", "host unreachable"), not as a status.
    -- Folding that into the HTTP branch produced "Update server returned
    -- HTTP connection refused" -- which is the message a Kindle away from
    -- home would show every time, since the update server is LAN/Tailscale
    -- only. Keep the two apart so the error names the real problem.
    if type(code) ~= "number" then
        debugLog(log_prefix .. " <- request failed: " .. tostring(code))
        return nil, nil, tostring(code)
    end
    if code >= 400 then
        debugLog(log_prefix .. " <- HTTP " .. tostring(code))
        return nil, code
    end
    return table.concat(sink_table), code
end

-- Self-hosted path: fetch <base>/manifest.json and compare its per-file
-- checksums against what's actually installed on disk.
--
-- Comparing CONTENT, not version numbers, is the point: while the repo is
-- private and every build is a test build, PLUGIN_VERSION doesn't move, so a
-- version comparison would report "up to date" for a file that changed
-- minutes ago. Hashing the installed file is also honest about a copy
-- scp'd on by hand, which no stored "last installed" marker would be.
local function doCheckManifest(update_url, socks5_proxy)
    local base = update_url:gsub("/*$", "")
    local body, code, err = doHttpGetString(base .. "/manifest.json", socks5_proxy, "[update]")
    if not body then
        return nil, code, err
            and T(_("Couldn't reach the update server at %1. It's only reachable on your home network or over Tailscale."), base)
            or T(_("Update server returned HTTP %1."), tostring(code))
    end
    local decode_ok, manifest = pcall(JSON.decode, body)
    manifest = decode_ok and stripJsonNull(manifest)
    if type(manifest) ~= "table" or type(manifest.files) ~= "table" then
        return nil, code, _("Update server's manifest.json couldn't be parsed.")
    end

    local plugin_dir = getPluginDir()
    local changed, unverifiable = {}, false
    -- Rebuilt as plain strings/numbers rather than handing back the decoded
    -- JSON object as-is. This table is returned across a Trapper subprocess
    -- boundary, and that pipe serializes with LuaJIT's string.buffer, which
    -- refuses functions, coroutines and userdata -- so anything a JSON
    -- decoder might hang off a table (sentinels, metatables) would turn a
    -- routine update check into a failure at the worst moment. Copying the
    -- two fields actually used removes that whole class of risk.
    local files = {}
    for idx = 1, #UPDATE_FILES do
        local fname = UPDATE_FILES[idx]
        local entry = manifest.files[fname]
        if type(entry) == "table" and type(entry.sha256) == "string" then
            files[fname] = { sha256 = entry.sha256:lower(), size = tonumber(entry.size) }
            local local_digest = sha256OfFile(plugin_dir .. "/" .. fname)
            if not local_digest then
                unverifiable = true
            elseif local_digest ~= entry.sha256:lower() then
                changed[#changed + 1] = fname
            end
        end
    end

    return {
        manifest = true,
        base = base,
        version = tostring(manifest.version or "?"),
        build = manifest.build and tostring(manifest.build) or nil,
        files = files,
        changed = changed,
        -- Couldn't hash locally (no sha2 library): fall back to the version
        -- number, the only other signal available.
        unverifiable = unverifiable,
    }, code
end

local function doCheckForUpdate(update_url, socks5_proxy)
    if update_url and update_url ~= "" then
        return doCheckManifest(update_url, socks5_proxy)
    end
    local url = "https://api.github.com/repos/" .. UPDATE_REPO .. "/releases/latest"
    debugLog("[update] -> GET " .. url)

    socketutil:set_timeout(15, 30)
    local sink, sink_table = socketutil.table_sink()
    local ok, code = pcall(function()
        return socket.skip(1, https.request{
            method = "GET",
            url = url,
            headers = {
                ["User-Agent"] = "bookbridge.koplugin",
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
-- `target` is either a release tag string (GitHub path) or the manifest
-- table from doCheckManifest (self-hosted path). Both download to temp
-- files, verify, and only then swap -- the manifest path additionally
-- checks each file's SHA-256, so a truncated or stale-manifest download is
-- refused outright rather than parse-checked and hoped for.
-- Fetches the settings the setup wizard staged under a short pairing code
-- (see shelfmark-stack/setup): GET <base>/claim/<code> returns
-- {"shelfmark": {...}} exactly once -- the wizard invalidates the code on
-- read -- so a failure here often just means the code was already used or
-- expired. Runs inside the caller's Trapper subprocess like every network call.
local function doClaimFromServer(base_url, code, socks5_proxy)
    local base = (base_url or ""):gsub("%s", ""):gsub("/*$", "")
    if base == "" then return nil, _("No server address given.") end
    if not base:match("^https?://") then base = "http://" .. base end
    local url = base .. "/claim/" .. (code or ""):gsub("%s", "")
    local body, http_code, err = doHttpGetString(url, socks5_proxy, "[pair]", 8, 15)
    if not body then
        if http_code == 404 then
            return nil, _("That code wasn't found -- it may have expired or already been used. Make a new one in the wizard.")
        end
        return nil, err or T(_("Couldn't reach the setup server (HTTP %1)."), tostring(http_code))
    end
    local ok, decoded = pcall(JSON.decode, body)
    local settings = ok and type(decoded) == "table" and decoded.shelfmark
    if type(settings) ~= "table" then
        return nil, _("The server's reply couldn't be read.")
    end
    return settings
end

-- Reachability probe for the connection-status screen: does this base URL
-- answer HTTP at all? Any status -- even 401/403 -- counts as "up"; we're
-- testing that the service is reachable, not that credentials are right.
local function doTestService(base_url, socks5_proxy)
    local base = (base_url or ""):gsub("%s", ""):gsub("/*$", "")
    if base == "" then return false end
    if not base:match("^https?://") then base = "http://" .. base end
    local body, http_code = doHttpGetString(base .. "/", socks5_proxy, "[status]", 5, 10)
    if body ~= nil then return true, http_code end          -- 2xx/3xx
    if type(http_code) == "number" then return true, http_code end  -- 4xx/5xx, still reachable
    return false                                            -- no connection
end

local function doApplyUpdate(target, socks5_proxy)
    local plugin_dir = getPluginDir()
    local is_manifest = type(target) == "table" and target.manifest
    local base, label
    if is_manifest then
        base = target.base .. "/"
        label = "v" .. tostring(target.version) .. (target.build and (" build " .. target.build) or "")
    else
        base = "https://raw.githubusercontent.com/" .. UPDATE_REPO .. "/" .. tostring(target) .. "/bookbridge.koplugin/"
        label = tostring(target)
    end
    local tmp_paths = {}
    local function cleanup()
        for j = 1, #tmp_paths do os.remove(tmp_paths[j]) end
    end

    for idx = 1, #UPDATE_FILES do
        local fname = UPDATE_FILES[idx]
        local tmp_path = plugin_dir .. "/" .. fname .. ".update-tmp"
        local ok, _dl_code, dl_err = doHttpDownloadToFile(base .. fname, tmp_path, "[update]", 15, 45,
            nil, is_manifest and proxyForUrl(base, socks5_proxy) or nil)
        if not ok then
            cleanup()
            return nil, dl_err or T(_("Couldn't download %1."), fname)
        end
        tmp_paths[#tmp_paths + 1] = tmp_path

        if is_manifest then
            local entry = target.files and target.files[fname]
            local want = type(entry) == "table" and type(entry.sha256) == "string" and entry.sha256:lower() or nil
            if want then
                local got = sha256OfFile(tmp_path)
                -- No local hashing available: the parse check below is the
                -- remaining guard, same as the GitHub path has always had.
                if got and got ~= want then
                    debugLog("[update] <- checksum mismatch for " .. fname .. ": got " .. got .. ", want " .. want)
                    cleanup()
                    return nil, T(_("%1 didn't match the manifest's checksum -- not installed. The update server's manifest is probably stale; regenerate it with tools/make-manifest.sh."), fname)
                end
            end
        end
    end

    -- loadfile compiles without executing, so a truncated or corrupt file
    -- can never leave the plugin unable to load on next start.
    for idx = 1, #UPDATE_FILES do
        local chunk, load_err = loadfile(plugin_dir .. "/" .. UPDATE_FILES[idx] .. ".update-tmp")
        if not chunk then
            cleanup()
            return nil, _("Downloaded update failed to parse, not installed: ") .. tostring(load_err)
        end
    end

    for idx = 1, #UPDATE_FILES do
        local fname = UPDATE_FILES[idx]
        os.rename(plugin_dir .. "/" .. fname .. ".update-tmp", plugin_dir .. "/" .. fname)
    end
    -- Leave a marker saying what was just installed. manifest.json is not
    -- one of the updated files, so on an updated device it still describes
    -- the build the plugin was originally zipped with -- which is what the
    -- debug-log header reported from a phone, months of updates later.
    local marker = io.open(plugin_dir .. "/installed-build", "w")
    if marker then marker:write(label, "\n"); marker:close() end
    debugLog("[update] <- installed " .. label .. " to " .. plugin_dir)
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

-- Ships the debug log to the pairing relay's POST /log, so a problem seen on
-- a phone or Kindle can be read on the homeserver without adb, screenshots of
-- the log viewer, or remoting into the device. Plain text; the relay files it
-- under a timestamped name and never serves it back.
local function doDebugLogUpload(relay_url, text, socks5_proxy)
    local headers = {
        ["Content-Type"] = "text/plain; charset=utf-8",
        ["Content-Length"] = tostring(#text),
    }
    local url = relay_url .. "/log"
    debugLog("[log] -> POST " .. url .. " (" .. #text .. " bytes)")
    socketutil:set_timeout(15, 60)
    local sink, sink_table = socketutil.table_sink()
    local request = { method = "POST", url = url, headers = headers, sink = sink, source = ltn12.source.string(text) }
    if socks5_proxy and socks5_proxy ~= "" then
        local proxy_host, proxy_port = socks5_proxy:match("^([^:]+):(%d+)$")
        if proxy_host then
            request.create = function() return makeSocks5Socket(proxy_host, tonumber(proxy_port)) end
        end
    end
    local ok, code = pcall(function() return socket.skip(1, http.request(request)) end)
    socketutil:reset_timeout()
    if not ok then
        debugLog("[log] <- connection error: " .. tostring(code))
        return nil, nil, _("Couldn't reach the server -- check the pairing relay URL under Settings > Connections > Server settings.")
    end
    local content = table.concat(sink_table)
    debugLog("[log] <- HTTP " .. tostring(code))
    if code == 404 then
        return nil, code, _("The server doesn't accept debug logs (its relay needs LOG_DIR set).")
    elseif code ~= 200 then
        return nil, code, T(_("Server refused the log (HTTP %1)."), tostring(code))
    end
    local decode_ok, decoded = pcall(JSON.decode, content)
    if not decode_ok or type(decoded) ~= "table" or type(decoded.id) ~= "string" then
        return nil, code, _("Server gave an unexpected response.")
    end
    return decoded.id, code
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

-- Structural scaffolding that shows up around a series volume number in a
-- filename ("Red Rising Book 2", "Vol. 2", "Part 3"). Deliberately NOT added
-- to SYNC_STOPWORDS: several of these are legitimate title words on their own
-- ("The Book Thief", "The Final Empire"), and dropping them globally would
-- weaken every strict comparison. They're only ever forgiven inside the
-- series-relaxation block, where title, author and series name have already
-- established the match.
local SERIES_STRUCTURE_WORDS = {
    book = true, books = true,
    vol = true, vols = true, volume = true,
    part = true, no = true, num = true,
}

-- The generic noun a filename attaches to a series name ("of the Red Rising
-- Saga", "The Wayward Pines Trilogy"). Like SERIES_STRUCTURE_WORDS, forgiven
-- only inside the series-relaxation block, never in strict matching.
local SERIES_SUFFIX_WORDS = {
    saga = true, series = true, trilogy = true, cycle = true,
    chronicles = true, sequence = true, collection = true,
}

-- "IV" -> 4. Returns nil for anything that isn't a well-formed roman numeral,
-- so ordinary words made of these letters ("civil", "lix") are never numbers.
local ROMAN_VALUES = { i = 1, v = 5, x = 10, l = 50, c = 100 }
local function romanToNumber(s)
    if type(s) ~= "string" or s == "" or s:find("[^ivxlc]") then return nil end
    local total, prev = 0, 0
    for k = #s, 1, -1 do
        local v = ROMAN_VALUES[s:sub(k, k)]
        if v < prev then total = total - v else total = total + v end
        prev = v
    end
    -- Reject malformed forms ("iiii", "vv", "ic") by round-tripping.
    local check, n = "", total
    for _, pair in ipairs({ {100, "c"}, {90, "xc"}, {50, "l"}, {40, "xl"}, {10, "x"}, {9, "ix"}, {5, "v"}, {4, "iv"}, {1, "i"} }) do
        while n >= pair[1] do check = check .. pair[2]; n = n - pair[1] end
    end
    if check ~= s then return nil end
    return total
end

-- The volume numbers a title or filename carries -- "Book 2", "(1)", "02",
-- "Vol. IV", "The Dark Tower I" -- as a set of numbers plus a token->number
-- map. Word matching can't see these: a single digit is shorter than the
-- two-character minimum for a word, a roman "I" is a single letter, and
-- "(Book 2)" is a parenthetical the normalizer strips, so "Dungeon Crawler
-- Carl Book 2" and book 1 compared equal and a "Book 2" file registered as
-- book 1 (caught by the negative-control sweep). Volume numbers are handled
-- explicitly instead, by the compatibility gate in doSyncLibrary.
--
-- Digits count from 1 to 999: a 4-digit number is a year or a title ("1984",
-- "2001"), never a volume. Roman numerals count when two or more letters
-- long ("II", "IV"); a lone "I"/"V"/"X" is also an English word or an
-- initial, so it counts only directly after a series label ("Book I") or at
-- the end of a segment ("The Dark Tower I: ...", "... Tower I - King").
local function volumeNumbersOf(text)
    local nums, by_token = {}, {}
    if type(text) ~= "string" then return nums, by_token end
    local lower = text:lower()
    local prev = nil
    for token, after in lower:gmatch("%f[%w](%w+)%f[%W]()") do
        local n = tonumber(token)
        if n then
            if n >= 1 and n <= 999 and token:find("^%d+$") then
                nums[n] = true; by_token[token] = n
            end
        else
            local r = romanToNumber(token)
            if r then
                local next_char = lower:sub(after):match("^%s*(.?)")
                local segment_end = (next_char == "" or next_char:find("[:_%(%)%[%]%-,]") ~= nil)
                if #token >= 2 or SERIES_STRUCTURE_WORDS[prev] or segment_end then
                    nums[r] = true; by_token[token] = r
                end
            end
        end
        prev = token
    end
    return nums, by_token
end

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

-- Folds accented Latin characters to their ASCII base so a title written
-- both ways compares equal.
--
-- Without this, "Les Miserables" in CWA and "Les Misérables" on disk produce
-- entirely different words, the matcher finds nothing, and the book is
-- UPLOADED AGAIN -- a silent duplicate, which is the costliest failure this
-- matcher has. Real risk here, not theoretical: this library already holds
-- titles with curly apostrophes and names like "Joandomènec Ros i Aragonès",
-- and sources disagree constantly about whether to keep the accents.
--
-- Keyed by UTF-8 byte sequence because LuaJIT has no unicode support; covers
-- Latin-1 Supplement and the common Latin Extended-A letters, which is what
-- Western-language book metadata actually uses.
local DIACRITIC_FOLD = {
    ["\xC3\xA0"]="a",["\xC3\xA1"]="a",["\xC3\xA2"]="a",["\xC3\xA3"]="a",["\xC3\xA4"]="a",["\xC3\xA5"]="a",
    ["\xC3\xA8"]="e",["\xC3\xA9"]="e",["\xC3\xAA"]="e",["\xC3\xAB"]="e",
    ["\xC3\xAC"]="i",["\xC3\xAD"]="i",["\xC3\xAE"]="i",["\xC3\xAF"]="i",
    ["\xC3\xB2"]="o",["\xC3\xB3"]="o",["\xC3\xB4"]="o",["\xC3\xB5"]="o",["\xC3\xB6"]="o",["\xC3\xB8"]="o",
    ["\xC3\xB9"]="u",["\xC3\xBA"]="u",["\xC3\xBB"]="u",["\xC3\xBC"]="u",
    ["\xC3\xA7"]="c",["\xC3\xB1"]="n",["\xC3\xBD"]="y",["\xC3\xBF"]="y",
    ["\xC3\x9F"]="ss",["\xC3\xA6"]="ae",["\xC5\x93"]="oe",
    ["\xC4\x81"]="a",["\xC4\x93"]="e",["\xC4\xAB"]="i",["\xC5\x8D"]="o",["\xC5\xAB"]="u",
    ["\xC5\x82"]="l",["\xC5\xA1"]="s",["\xC5\xBE"]="z",["\xC4\x8D"]="c",["\xC5\x99"]="r",
}
local function foldDiacritics(text)
    -- Lowercased first by the caller, so only the lowercase forms are needed.
    return (text:gsub("[\xC3\xC4\xC5][\x80-\xBF]", function(seq)
        return DIACRITIC_FOLD[seq] or seq
    end))
end

local function normalizeTitleWords(text)
    if not text then return {} end
    -- A "(...)" group directly before the " - author" separator is trailing
    -- on the TITLE, even though it isn't at the end of the whole filename.
    -- stripTrailingParenGroups only looks at the very end, so
    -- "The Dark Forest (The Three-Body Problem Series Book 2) - Cixin Liu"
    -- kept "problem/series/three/book/body" while CWA's own title -- where
    -- the same group IS at the end -- had them stripped. The words could
    -- never be explained, so the book never matched itself and was uploaded
    -- again on every sync. Found by generating filename shapes for every
    -- book in the library and checking each still matches itself.
    text = text:gsub("%s*%b()%s*(%s%-%s)", "%1")
    -- A parenthetical that names a series, volume or edition is annotation
    -- wherever it sits, not title content -- "(The Three-Body Problem Series
    -- Book 2)", "(Harry Potter, Book 6)", "(Royal Elite Special Edition)".
    -- Only stripped when it actually contains one of those markers, so a
    -- meaningful mid-title parenthetical (a year, a disambiguator) is left
    -- alone -- which is why stripTrailingParenGroups stays end-anchored.
    text = text:gsub("%s*(%b())", function(group)
        local inner = group:lower()
        if inner:find("book") or inner:find("series") or inner:find("edition")
                or inner:find("volume") or inner:find("trilogy") or inner:find("saga") then
            return " "
        end
        return group
    end)
    -- Parens optional: the tag shows up both as "(Z-Library)" and bare,
    -- as in "Recursion Blake Crouch Z-Library.epub". Only the
    -- parenthesized form used to be stripped, which left a stray
    -- "library" word behind for the bare form -- and since the matcher
    -- below requires every filename word to be explained by the
    -- candidate's own title+author, that one leftover word made a book
    -- fail to match *itself* (confirmed by a regression test: CWA title
    -- "Recursion" + author "Blake Crouch" vs. this exact filename).
    text = text:lower()
    -- Strip domain-like tokens ("z-library.sk", "1lib.sk", "z-lib.sk")
    -- before the bare-tag strip below, so a tag written as a domain is
    -- consumed whole rather than leaving its TLD behind. Confirmed live,
    -- and the cause of five books sitting in "returned results but none
    -- matched confidently -- skipped" on every single sync forever: these
    -- filenames end in a LIST of mirror domains, and stripping only the
    -- literal word "z-library" left "sk", "1lib" and "lib" as filename
    -- words. The matcher requires every filename word to be explained by
    -- the candidate's title+author, so those leftovers made each book fail
    -- to match ITSELF -- never a duplicate upload (the skip rule caught
    -- that), just permanently stuck.
    --
    -- Matched generically rather than by listing known mirrors: the domain
    -- list changes over time, and any "word.tld" token is junk for title
    -- matching regardless of which source added it. Safe against real
    -- titles -- a book title containing a bare domain is vanishingly rare,
    -- and the file extension is already stripped off before this is called.
    text = text:gsub("[%w%-]+%.%a%a+", " ")
    text = text:gsub("%(?z%-library%)?", "")
    text = stripTrailingParenGroups(text)
    text = foldDiacritics(text)
    -- Underscore first: Lua's %w counts "_" as a word character, so
    -- "Red Rising 4_ Iron Gold" tokenized to "4_" -- a word that appears in
    -- no CWA title, leaving it permanently unexplained and the book
    -- permanently unmatched (i.e. re-uploaded every sync). The underscore is
    -- only ever a stand-in for a colon in these filenames, never content.
    -- Typographic punctuation -> plain space, BEFORE the high-byte-preserving
    -- pass below. Keeping high bytes is what lets Cyrillic/CJK titles work at
    -- all, but it also means a curly apostrophe or en dash would count as a
    -- word character and fuse words together: "Handmaid\xE2\x80\x99s" became one
    -- token that no straight-quoted copy could ever equal. This library holds
    -- titles punctuated exactly that way ("The Handmaid's Tale", "Ender's
    -- Game"), so this is a live case, not a hypothetical.
    text = text:gsub("\xE2\x80[\x80-\xBF]", " ")   -- quotes, en/em dash, ellipsis
    text = text:gsub("\xC2[\xA0\xAD]", " ")        -- non-breaking space, soft hyphen
    text = text:gsub("\xEF\xAC\x81", "fi")          -- fi ligature
    text = text:gsub("\xEF\xAC\x82", "fl")          -- fl ligature
    -- Combining marks (NFD): "e" + U+0301 must equal the precomposed "e".
    -- foldDiacritics above only handles the precomposed forms.
    text = text:gsub("\xCC[\x80-\xBF]", "")
    text = text:gsub("\xCD[\x80-\xAF]", "")
    text = text:gsub("_", " ")
    -- A series label directly followed by a number -- "Book 2", "Vol. 3",
    -- "Part 1" -- is scaffolding around that number, not title content, and
    -- sources disagree about whether to parenthesize it. Confirmed live on
    -- this device, and it was a duplicate upload waiting to happen: the
    -- file "Carl's Doomsday Scenario_ Dungeon Crawler Carl (Book 2) - Matt
    -- Dinniman" lost its whole "(Book 2)" group to the paren strip above,
    -- while CWA's own title "Carl's Doomsday Scenario: Dungeon Crawler
    -- Carl Book 2" kept the bare word "book". One side had a word the
    -- other could never explain, so every matching tier rejected the
    -- book's own entry and the file fell through to upload. Dropping the
    -- label on BOTH sides (the number stays, so "Book 12" and "Book 13"
    -- remain distinct) makes the comparison symmetric again. Only the
    -- label-plus-number pair is touched: "The Book Thief" keeps its
    -- "book", exactly as the SERIES_STRUCTURE_WORDS note above requires.
    for label in pairs(SERIES_STRUCTURE_WORDS) do
        text = text:gsub("%f[%a]" .. label .. "%.?%s+(%d+)", "%1")
    end
    -- \128-\255 alongside %w: Lua patterns are byte-oriented and %w matches
    -- ASCII alphanumerics ONLY, so every non-Latin script -- Cyrillic, Greek,
    -- CJK, Arabic -- was treated as punctuation and erased. A Russian or
    -- Japanese title normalized to an EMPTY word set, which can never satisfy
    -- titleWordsSubsetOf, so such a book could never match itself and would
    -- be re-uploaded on every single sync. Keeping the high bytes lets those
    -- titles compare byte-for-byte, which is all that's needed here (both
    -- sides come from the same UTF-8 sources).
    text = text:gsub("[^%w\128-\255]+", " ")
    local words = {}
    local any_token = false
    for w in text:gmatch("%S+") do
        any_token = true
        if not SYNC_STOPWORDS[w] and #w > 1 then
            words[w] = true
        end
    end
    -- Degenerate titles: "S." (J.J. Abrams), "A", "It" written as "I.T."
    -- normalize to nothing, because every token is a single character. An
    -- empty word set can never satisfy titleWordsSubsetOf, so such a book
    -- could never match itself -- and a book that never matches is uploaded
    -- again on every single sync. Falling back to the short tokens keeps
    -- them comparable. Only ever runs when the normal pass found nothing,
    -- so it cannot loosen matching for any ordinary title.
    if next(words) == nil and any_token then
        for w in text:gmatch("%S+") do
            if not SYNC_STOPWORDS[w] then words[w] = true end
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
-- normalizeTitleWords returns a SET, whose iteration order is undefined --
-- so two identical titles could stringify differently. Sorting makes the
-- result a stable key, which the subtitle-uniqueness grouping below relies
-- on to decide whether two CWA rows really share a main title.
local function sortedWordList(word_set)
    local list = {}
    for w in pairs(word_set) do list[#list + 1] = w end
    table.sort(list)
    return list
end

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

-- Asks shelfmark-ai-relay which of CWA's own candidates is the same book as
-- a local file the deterministic matcher could not resolve.
--
-- Suggestion only: this returns a uuid for the UI to offer, and NOTHING here
-- registers, downloads or uploads anything. The relay is likewise incapable
-- of returning a book that wasn't in the candidate list this function sent
-- (it validates the model's answer against that list server-side), so the
-- worst case for a bad answer is a wrong suggestion the user declines --
-- never a duplicate upload or an overwritten file.
--
-- Generous timeouts: a locally-hosted model on CPU takes a few seconds per
-- book, which is fine for an explicitly-invoked review step but would be far
-- too slow to sit inside the sync loop itself -- which is exactly why this is
-- never called from there.
local function doAiSuggest(relay_url, relay_token, filename, candidates, socks5_proxy)
    if not relay_url or relay_url == "" or not relay_token or relay_token == "" then
        return nil, _("Match suggestions aren't set up -- add a relay URL under Settings.")
    end
    if type(candidates) ~= "table" or #candidates == 0 then
        return nil, _("No CWA candidates to compare against.")
    end

    -- The relay caps this at 10; trim here too so an oversized request is
    -- never sent in the first place.
    local trimmed = {}
    for i = 1, math.min(#candidates, 10) do
        local c = candidates[i]
        if c and c.uuid and c.title then
            trimmed[#trimmed + 1] = {
                uuid = tostring(c.uuid),
                title = tostring(c.title),
                author = c.author and tostring(c.author) or nil,
            }
        end
    end
    if #trimmed == 0 then
        return nil, _("No usable CWA candidates to compare against.")
    end

    local body_json = JSON.encode({ filename = filename, candidates = trimmed })
    local headers = {
        ["Content-Type"] = "application/json",
        ["Content-Length"] = tostring(#body_json),
        ["X-Relay-Token"] = relay_token,
    }
    local url = relay_url .. "/suggest"
    debugLog("[ai] -> POST " .. url .. " (" .. #trimmed .. " candidate(s))")

    socketutil:set_timeout(20, 120)
    local sink, sink_table = socketutil.table_sink()
    local request = {
        method = "POST", url = url, headers = headers,
        source = ltn12.source.string(body_json), sink = sink,
    }
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
        debugLog("[ai] <- connection error: " .. tostring(code))
        return nil, _("Couldn't reach the suggestion relay.")
    end
    if code == socketutil.TIMEOUT_CODE or code == socketutil.SINK_TIMEOUT_CODE then
        return nil, _("The suggestion relay timed out.")
    end
    local raw = table.concat(sink_table)
    debugLog("[ai] <- HTTP " .. tostring(code) .. ", body length " .. #raw)
    if code ~= 200 then
        if code == 401 then return nil, _("Relay rejected the token -- check Settings.") end
        if code == 429 then return nil, _("Relay is rate limited -- try again later.") end
        if code == 503 then return nil, _("Relay isn't configured on the server yet.") end
        return nil, T(_("Relay error (HTTP %1)."), tostring(code))
    end

    local decode_ok, decoded = pcall(JSON.decode, raw)
    if not decode_ok or type(decoded) ~= "table" then
        return nil, _("Couldn't understand the relay's reply.")
    end
    decoded = stripJsonNull(decoded)
    local choice = decoded.choice
    if type(choice) ~= "string" or choice == "" then
        return nil, decoded.reason and tostring(decoded.reason) or _("No confident match.")
    end

    -- Re-check the returned uuid against what we actually sent. The relay
    -- already does this, but it costs nothing to refuse to act on a uuid
    -- this device never offered.
    for _, c in ipairs(trimmed) do
        if c.uuid == choice then
            -- title/author come from OUR candidate list, not from the
            -- relay's echo of them. The relay does echo the values it was
            -- sent, so today they're identical -- but the title is what gets
            -- written into the sync registry on confirmation, and there's no
            -- reason for any of that to originate anywhere but here. Only
            -- confidence/reason (display-only) come from upstream.
            return {
                uuid = c.uuid,
                title = c.title,
                author = c.author,
                confidence = tonumber(decoded.confidence) or 0,
                reason = decoded.reason and tostring(decoded.reason) or "",
            }
        end
    end
    return nil, _("Relay returned an unknown book -- ignored.")
end

-- Fetches CWA's whole catalog as a uuid -> {updated=...} map, paginated.
--
-- Exists purely as a fast pre-filter for the tracked-book check below: that
-- check otherwise costs one /ajax/book request PER tracked book (measured on
-- device: ~0.40s each, so ~6.5s for 16 books, and it grows linearly with the
-- library). One catalog fetch covers all of them.
--
-- PAGINATION IS NOT OPTIONAL. CWA caps an OPDS feed at config_books_per_page
-- (60 here) and this library currently holds exactly 60 books, so a single
-- unpaginated request happens to look complete right now and would silently
-- start missing books the moment a 61st is added. Confirmed live:
-- ?offset=60 returns an empty feed, which is the loop's terminator.
--
-- Returns nil on any failure, and the caller then falls back to the
-- per-book check -- this is an optimization, never a source of truth.
local CATALOG_PAGE = 60
local CATALOG_MAX_PAGES = 60 -- 3600 books; a runaway loop guard, not a real limit
local function fetchCwaCatalog(cwa_url, cwa_username, cwa_password, socks5_proxy)
    local catalog, offset = { __authors = {} }, 0
    for _page = 1, CATALOG_MAX_PAGES do
        local body, code = doCwaRequest(cwa_url, cwa_username, cwa_password,
            "/opds/new?offset=" .. offset, socks5_proxy)
        if not body or code ~= 200 then
            return nil
        end
        local found = 0
        for entry_xml in body:gmatch("<entry>(.-)</entry>") do
            local uuid = entry_xml:match("<id>urn:uuid:(.-)</id>")
            local updated = entry_xml:match("<updated>(.-)</updated>")
            local author = decodeHtmlEntities(entry_xml:match("<author>%s*<name>(.-)</name>"))
            if uuid then
                found = found + 1
                catalog[uuid] = { updated = updated }
                -- Author names are collected into a normalized set on the
                -- side, used by the query builder to tell "Author - Title"
                -- from "Title - Author" -- see its note.
                if type(author) == "string" and author ~= "" then
                    local key = table.concat(sortedWordList(normalizeTitleWords(author)), " ")
                    if key ~= "" then catalog.__authors[key] = true end
                end
            end
        end
        if found == 0 then break end
        offset = offset + CATALOG_PAGE
    end
    return catalog
end

-- Checks one already-tracked registry entry against CWA's current
-- last_modified for its uuid, re-downloading the file if it changed.
-- Shared by doSyncLibrary's own "already tracked" loop below and
-- Bookbridge:refreshBookMetadata's single-book action, so the (already
-- fiddly -- see the 404 case) logic for what counts as "changed" vs "gone"
-- only exists once. Mutates entry.last_modified in place on success but
-- never touches the registry table itself -- the 404 case in particular
-- means "drop this row", which only the caller can actually do since it's
-- the one holding the uuid key.
-- Returns one of: "synced" (re-downloaded), "unchanged", "gone" (the uuid
-- no longer resolves in CWA at all -- caller should drop the row), "failed"
-- (found a change but the re-download itself failed), or "unreachable"
-- (couldn't get a usable response at all -- CWA down, network error, etc,
-- deliberately NOT treated the same as "gone": a transient failure is not
-- evidence the book was ever reassigned, and dropping tracking on one would
-- risk re-uploading a book that's still there under the same id).
local function checkTrackedBookAgainstCwa(cwa_url, cwa_username, cwa_password, socks5_proxy, uuid, entry)
    local body, code = doCwaRequest(cwa_url, cwa_username, cwa_password, "/ajax/book/" .. uuid, socks5_proxy)
    if code == 200 and body and body ~= "" then
        local decode_ok, decoded = pcall(JSON.decode, body)
        local book = decode_ok and stripJsonNull(decoded)
        local last_modified = book and book.last_modified
        if type(last_modified) == "string" then
            if not entry.last_modified then
                entry.last_modified = last_modified
                return "unchanged"
            elseif entry.last_modified ~= last_modified then
                local epub_path = book.main_format and book.main_format.epub
                if type(epub_path) == "string" then
                    local dl_ok = doCwaFileDownload(cwa_url, cwa_username, cwa_password, epub_path, socks5_proxy, entry.path)
                    if dl_ok then
                        entry.last_modified = last_modified
                        return "synced"
                    end
                    return "failed"
                end
            end
            return "unchanged"
        end
    end
    -- A deleted book's uuid doesn't necessarily 404 here -- confirmed live,
    -- the hard way: this CWA instance answers a deleted book's own
    -- /ajax/book/<uuid> with a plain HTTP 200 and a completely empty body,
    -- not a 404. That's indistinguishable from "reachable but nothing
    -- useful in it" by code alone, so an empty 200 body counts as "gone"
    -- here too -- silently falling through to "unreachable" (or worse,
    -- "unchanged", which this same case used to hit before body was
    -- checked at all) left "The Road" checked and reported as fine, sync
    -- after sync, for a book CWA had already deleted outright.
    if code == 404 or (code == 200 and (not body or body == "")) then
        return "gone"
    end
    return "unreachable"
end

-- Runs entirely inside a Trapper subprocess (see Bookbridge:syncLibrary
-- below) -- a real fork, so file writes it makes (downloaded books, the
-- registry itself) land on the real filesystem same as if done in the
-- parent; only in-memory Lua state doesn't cross back. Returns a list of
-- plain report-line strings for the parent to display -- deliberately
-- not the registry itself, avoiding the rapidjson-null string.buffer
-- serialization trap documented on stripJsonNull above.
-- only_path, when given, scopes the whole run to that single local file --
-- used by the per-book "Send to CWA" action. Deliberately implemented as a
-- filter on this function rather than as a separate single-book routine:
-- everything that makes the match decision safe (the query-candidate ladder,
-- the relevance filter, subtitle and series relaxation, the never-upload-on-
-- an-unreachable-CWA rule, the post-upload registration wait) lives here and
-- has the regression tests behind it. A parallel implementation would be a
-- second place for all of that to drift.
local function doSyncLibrary(cwa_url, cwa_username, cwa_password, socks5_proxy, download_dir, only_path, progress_path)
    local report = {}
    local function addLine(s) table.insert(report, s) end

    -- Progress is published by writing a percentage to a file the PARENT
    -- polls, which is the only channel available: this whole function runs
    -- in a forked subprocess, so it can't touch the parent's widgets, and
    -- its return value doesn't arrive until it's already finished. Exactly
    -- the trick the Anna's Archive download path uses to drive its progress
    -- bar (see the poll note there) -- the parent watches a file the child
    -- keeps updating.
    --
    -- A percentage rather than done/total counts because the total isn't
    -- knowable up front: how many books need uploading is only decided by
    -- the untracked pass, halfway through the run. Percent lets each phase
    -- own a slice of the bar and fill it at whatever granularity it has.
    -- nil progress_path (the regression harness, and any caller that just
    -- doesn't want progress) makes every one of these a no-op.
    local function reportProgress(pct)
        if not progress_path then return end
        local f = io.open(progress_path, "w")
        if not f then return end
        f:write(tostring(math.floor(pct)), "\n")
        f:close()
    end
    -- Phase slices, in the order the run executes them. Tracked checks get
    -- the largest share because on an established library that IS the sync
    -- -- most files are already tracked and the untracked pass has nothing
    -- to do.
    local PCT_TRACKED_START, PCT_TRACKED_END = 0, 45
    local PCT_UNTRACKED_START, PCT_UNTRACKED_END = 45, 85
    local PCT_UPLOAD_START, PCT_UPLOAD_END = 85, 100
    local function phasePct(from, to, done, total)
        if not total or total <= 0 then return to end
        return from + (to - from) * (done / total)
    end
    -- Paths this run actually overwrote, handed back to the caller so it
    -- can drop KOReader's cached metadata for them -- see
    -- invalidateBookInfoCache on why that can't happen here (this whole
    -- function runs inside a forked subprocess).
    local replaced_paths = {}
    -- Files the strict matcher could not resolve, together with the CWA rows
    -- it actually saw. Handed back so the caller can offer AI-assisted review
    -- -- collected unconditionally (it costs nothing) and simply unused when
    -- no relay is configured.
    local unmatched = {}

    if not cwa_url or cwa_url == "" then
        return { _("CWA URL isn't set -- add it under Bookbridge > Settings.") }
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
            local full = download_dir .. "/" .. name
            if not only_path or full == only_path then
                table.insert(local_files, full)
            end
        end
    end
    if only_path and #local_files == 0 then
        return { T(_("%1 isn't in the sync folder (%2)."),
            only_path:match("([^/]+)$") or only_path, download_dir) }
    end

    local registry = loadSyncRegistry()
    -- Files pushed on an earlier run that CWA hasn't matched back yet -- never
    -- re-uploaded, only re-matched (see loadPendingUploads).
    local pending_uploads = loadPendingUploads()

    -- Order matters here: prune, then check tracked books against CWA, and
    -- only THEN work out what's untracked. The tracked check is what
    -- discovers a book whose CWA-side entry is gone (deleted, or replaced
    -- under a new id by a metadata edit -- see checkTrackedBookAgainstCwa),
    -- and dropping its row makes its local file untracked. Running that
    -- first means the very same sync then picks the file up in the
    -- untracked pass below and re-matches or re-uploads it immediately.
    --
    -- This used to run the other way around -- untracked pass first,
    -- tracked check second -- which meant a book discovered "gone" couldn't
    -- be re-evaluated until the NEXT sync, and (because a re-upload only
    -- registers once CWA has imported it) a third after that. Three manual
    -- syncs to recover from one CWA-side deletion, for no reason other than
    -- phase ordering.

    -- Drop rows whose local file is gone before checking anything against
    -- CWA. Two reasons, one cosmetic and one not: stale rows otherwise
    -- accumulate forever (confirmed live -- a book re-downloaded under a
    -- cleaner filename left its old row pointing at a path that no longer
    -- existed), and more importantly the CWA-side check below re-downloads
    -- to entry.path without ever confirming the file is still there, so a
    -- book deliberately deleted off the device would silently reappear the
    -- next time its metadata changed in CWA.
    --
    -- Safe against a mass-prune: doSyncLibrary already returned early at
    -- the top if download_dir itself doesn't exist, so an unmounted or
    -- renamed books folder can't wipe the whole registry here. Setting an
    -- existing key to nil mid-pairs() is explicitly allowed in Lua (adding
    -- keys is not).
    -- Skipped entirely for a single-book run: pruning walks the WHOLE
    -- registry and drops rows whose file is missing, which is right for a
    -- full sync but has no business firing as a side effect of "send this
    -- one book" -- a books folder that happened to be unmounted would quietly
    -- untrack the entire library.
    local pruned = 0
    for uuid, entry in pairs(registry) do
        if not only_path and type(entry) == "table" and entry.path
                and not lfs.attributes(entry.path, "mode") then
            registry[uuid] = nil
            pruned = pruned + 1
            addLine(T(_("  [%1] no longer on this device -- stopped tracking."), entry.title or uuid))
        end
    end
    if pruned > 0 then saveSyncRegistry(registry) end
    -- Drop pending-upload rows whose local file is gone (same only_path guard
    -- as the registry prune above: a single-book run must not sweep the list).
    if not only_path then
        local pu_pruned = false
        for pu_path in pairs(pending_uploads) do
            if not lfs.attributes(pu_path, "mode") then pending_uploads[pu_path] = nil; pu_pruned = true end
        end
        if pu_pruned then savePendingUploads(pending_uploads) end
    end

    local tracked_count = 0
    for _uuid, _e in pairs(registry) do
        if not only_path or (type(_e) == "table" and _e.path == only_path) then
            tracked_count = tracked_count + 1
        end
    end
    if tracked_count > 0 then
        addLine(T(_("Checking %1 tracked book(s) for CWA-side changes..."), tracked_count))
    end
    -- Pre-filter: one paginated catalog fetch replaces a per-book request for
    -- every book that hasn't changed. Deliberately SKIP-ONLY -- a uuid absent
    -- from the catalog is NOT treated as deleted here, because a partial
    -- fetch would then look identical to a real deletion. Those still go
    -- through the per-book check, which distinguishes them properly.
    -- nil (fetch failed) simply disables the optimization for this run.
    local catalog = fetchCwaCatalog(cwa_url, cwa_username, cwa_password, socks5_proxy)
    local skipped_unchanged = 0

    local tracked_done = 0
    for uuid, entry in pairs(registry) do
        if type(entry) == "table" and entry.path
                and (not only_path or entry.path == only_path) then
            tracked_done = tracked_done + 1
            reportProgress(phasePct(PCT_TRACKED_START, PCT_TRACKED_END, tracked_done, tracked_count))
            local cat = catalog and catalog[uuid]
            if cat and cat.updated and entry.opds_updated == cat.updated then
                -- Unchanged since the last sync saw it: no request needed.
                skipped_unchanged = skipped_unchanged + 1
                goto continue_tracked
            end
            local status = checkTrackedBookAgainstCwa(cwa_url, cwa_username, cwa_password, socks5_proxy, uuid, entry)
            -- Record the catalog stamp only after a real check, so the next
            -- run can skip it. Stored separately from last_modified rather
            -- than replacing it: the two use different formats/precision
            -- (OPDS "2026-09-05T23:50:17+00:00" vs ajax
            -- "2026-09-05 23:50:17.226593+00:00"), and conflating them would
            -- make every book look changed once and re-download the library.
            if cat and cat.updated and status ~= "gone" and status ~= "unreachable" then
                entry.opds_updated = cat.updated
            end
            if status == "synced" then
                replaced_paths[#replaced_paths + 1] = entry.path
                addLine(T(_("  [%1] changed in CWA -- re-downloaded."), entry.title or uuid))
            elseif status == "failed" then
                addLine(T(_("  [%1] changed in CWA but re-download failed."), entry.title or uuid))
            elseif status == "gone" then
                -- Dropping the row here deliberately hands this book's local
                -- file to the untracked pass below, in this same run: it
                -- gets searched for under whatever CWA calls it now and
                -- either re-registered (a metadata edit that moved it to a
                -- new id) or re-uploaded (genuinely deleted from CWA).
                registry[uuid] = nil
                addLine(T(_("  [%1] no longer in CWA under its tracked ID -- re-checking it below."), entry.title or uuid))
            end
            -- "unchanged" and "unreachable" both report nothing here -- the
            -- per-tracked-book loop is meant to be quiet unless something
            -- actually happened, and a transient CWA failure isn't worth a
            -- line per book on every single sync.
            ::continue_tracked::
        end
    end
    if skipped_unchanged > 0 then
        addLine(T(_("  (%1 unchanged in CWA -- checked in one request)"), skipped_unchanged))
    end

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

    -- Series metadata, fetched lazily and at most once per sync -- see the
    -- series-relaxation block inside checkUntrackedPath for why it exists.
    -- CWA exposes series in an awkward split: /ajax/book/<uuid> carries
    -- series_index but reports the series NAME as null (confirmed live), and
    -- OPDS entries carry neither. The name only comes from the OPDS series
    -- feed -- one listing request for all series, then one request per
    -- series to learn which books belong to it. That's why this is lazy: it
    -- costs a handful of requests, and only a sync that actually hits an
    -- otherwise-unmatchable book ever pays for it.
    local series_map_cache = nil
    local function getSeriesMap()
        if series_map_cache then return series_map_cache end
        series_map_cache = {}
        -- "letter/00" is CWA's own all-series bucket, not a real letter --
        -- avoids walking A-Z separately.
        local list_body, list_code = doCwaRequest(cwa_url, cwa_username, cwa_password,
            "/opds/series/letter/00", socks5_proxy)
        if not list_body or list_code ~= 200 then return series_map_cache end
        for entry_xml in list_body:gmatch("<entry>(.-)</entry>") do
            local name = decodeHtmlEntities(entry_xml:match("<title>(.-)</title>"))
            local series_id = entry_xml:match('href="/opds/series/(%d+)"')
            if name and series_id then
                local books_body, books_code = doCwaRequest(cwa_url, cwa_username, cwa_password,
                    "/opds/series/" .. series_id, socks5_proxy)
                if books_body and books_code == 200 then
                    for book_xml in books_body:gmatch("<entry>(.-)</entry>") do
                        local uuid = book_xml:match("<id>urn:uuid:(.-)</id>")
                        if uuid then series_map_cache[uuid] = name end
                    end
                end
            end
        end
        return series_map_cache
    end

    -- One OPDS search per distinct query string per run, not per (file,
    -- query) pair. The candidate ladder derives its queries from the
    -- filename by progressive truncation, so files that share a prefix ask
    -- CWA the exact same question: every volume of a series shortens through
    -- the series name ("Wayward Pines - 01/02/03" all reach "Wayward
    -- Pines"), and on a first sync of a fresh library -- the run where
    -- nothing is tracked yet and every file walks its full ladder -- that
    -- repetition is most of the traffic.
    --
    -- Strictly response-preserving: the same query returns the same body, so
    -- every match decision is made on identical evidence, just without
    -- re-asking. Same run-snapshot assumption as fetchCwaCatalog.
    --
    -- SUCCESSES ONLY. Caching failures here would be a real change to what
    -- this matcher decides, not just to how it fetches: the uncached code
    -- re-issued a failed query for every file that derived it, so a
    -- transient CWA failure on one file's query cost that file its
    -- candidates and nothing more. Remembering the failure would spread one
    -- flaky response across every later file whose ladder reaches the same
    -- query, and a file that then matched nothing while OTHER queries did
    -- answer (so the never-upload-on-an-unreachable-CWA rule stays
    -- satisfied) would upload a duplicate of a book CWA actually holds --
    -- exactly the failure this matcher exists to prevent. A retried failure
    -- is cheap; a duplicate upload is not.
    local search_cache = {}
    local function searchCwa(q)
        local hit = search_cache[q]
        if hit then return hit, 200 end
        local resp_body, code = doCwaRequest(cwa_url, cwa_username, cwa_password,
            "/opds/search/" .. socketurl.escape(q), socks5_proxy)
        if resp_body and code == 200 then
            search_cache[q] = resp_body
        end
        return resp_body, code
    end

    -- One memoized fetch of /ajax/book/<uuid> for the whole run, shared by
    -- every caller that needs anything out of that response.
    --
    -- There used to be two independent readers of this exact URL: the
    -- series_index lookup below, memoized in its own cache, and the
    -- registration step further down (last_modified + main_format.epub),
    -- memoized nowhere at all. A candidate that went through series
    -- relaxation and then matched therefore fetched the same document
    -- twice, and a uuid registered twice in one run fetched it twice again.
    -- Same URL, same run, same immutable-for-this-run answer -- there was
    -- never a reason for more than one request.
    --
    -- Caching across the run is safe for the same reason fetchCwaCatalog's
    -- snapshot is: a sync already assumes CWA isn't being edited underneath
    -- it, and every decision here is made against that one snapshot.
    -- false is the negative cache (fetch failed / empty body) so a book that
    -- doesn't answer isn't re-requested once per candidate query.
    local book_ajax_cache = {}
    local function getBookAjax(uuid)
        if not uuid then return nil end
        local hit = book_ajax_cache[uuid]
        if hit ~= nil then
            if hit == false then return nil end
            return hit
        end
        book_ajax_cache[uuid] = false
        local body, code = doCwaRequest(cwa_url, cwa_username, cwa_password,
            "/ajax/book/" .. uuid, socks5_proxy)
        if body and body ~= "" and code == 200 then
            local decode_ok, decoded = pcall(JSON.decode, body)
            local book = decode_ok and stripJsonNull(decoded)
            if type(book) == "table" then
                book_ajax_cache[uuid] = book
                return book
            end
        end
        return nil
    end

    -- series_index comes from /ajax/book (the one place it IS populated).
    local function getSeriesIndex(uuid)
        local book = getBookAjax(uuid)
        return book and tonumber(book.series_index) or nil
    end

    -- The whole "is this local file already in CWA?" check, as a function so
    -- it can run a second time after an upload (see the post-upload pass
    -- below) without duplicating any of this carefully-tuned matching. Closes
    -- over registry/to_upload/addLine and the cwa_* connection details, so
    -- nothing had to be threaded through as arguments.
    --
    -- allow_upload=false is the post-upload call: the file was JUST uploaded,
    -- so if it still doesn't match, the right answer is "CWA hasn't imported
    -- it yet", never "upload it again" -- that would be the duplicate-upload
    -- bug this file has been fighting all along, just triggered by our own
    -- retry instead of a bad query.
    local function checkUntrackedPath(path, allow_upload)
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
            -- CWA's own OPDS search does an exact substring/phrase match
            -- against its stored title (confirmed live -- see the note
            -- below on the Dungeon Anarchist's Cookbook bug -- this
            -- comment used to say "AND across every word", which happened
            -- to predict the same outcome for the case that followed but
            -- was the wrong mental model). "Dune Messiah   Frank Herbert"
            -- (title+author combined, this file's own convention for
            -- z-library-sourced filenames) returned zero entries even
            -- though "Dune Messiah" alone finds the book immediately,
            -- simply because the real stored title doesn't contain "Frank
            -- Herbert" as literal title text -- caught the same way as the
            -- two fixes above, a genuine "Dune Messiah" duplicate. The
            -- word-matching step below still checks the FULL fname (title
            -- and author both) for precision, so this only broadens the
            -- initial CWA search, not the actual match decision -- a real
            -- different-book match still needs the author to show up in
            -- its own title too, same as before.
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
            -- (A natural-order "Author - Title" filename with no comma,
            -- e.g. "Cixin Liu - The Three-Body Problem", isn't caught by
            -- this and falls through to the "Title - Author" branch below,
            -- searching CWA for the author name instead of the title --
            -- no comma-independent way to tell the two conventions apart
            -- exists. Confirmed live this doesn't currently break anything:
            -- CWA's search also matches against the author field, so an
            -- accidentally-author-shaped query still usually finds the
            -- right book by author instead of title.)
            local before_sep, after_sep = cleaned_fname:match("^(.-)%s+%-%s+(.+)$")
            local search_title
            -- A comma ("Lastname, Firstname - Title") is a reliable marker
            -- that the pre-separator segment is an author. A natural-order
            -- "Author - Title" has no comma and used to be indistinguishable
            -- from "Title - Author", so it fell through to the wrong branch
            -- and searched CWA for the AUTHOR'S NAME.
            --
            -- That wasn't harmless. Confirmed live with "Pierce Brown - Iron
            -- Gold_ Book IV of the Red Rising Saga": the query became "Pierce
            -- Brown", CWA matched its author field and returned his OTHER
            -- books, and one of them ("Red Rising") shares words with the
            -- filename because the filename names the series -- so the
            -- relevance filter counted a different book as evidence this one
            -- already existed, and refused to upload a book CWA did not have.
            --
            -- The catalog fetched above knows every author in the library, so
            -- the ambiguity is now resolved with data instead of a guess: if
            -- the pre-separator segment IS a known CWA author, the title is
            -- on the other side.
            local function authorKeyOf(text)
                if not text or text == "" or not catalog or not catalog.__authors then return nil end
                local k = table.concat(sortedWordList(normalizeTitleWords(text)), " ")
                if k ~= "" and catalog.__authors[k] then return k end
                return nil
            end
            -- Does this segment CONTAIN a known author plus a little extra?
            -- Covers multi-author filenames ("Brian Herbert & Kevin J.
            -- Anderson - Dune"), where the combined string is no single
            -- catalog author. Bounded to a few leftover words so a title
            -- that merely mentions an author's name doesn't get mistaken
            -- for the author side.
            local function containsKnownAuthor(text)
                if not text or text == "" or not catalog or not catalog.__authors then return false end
                local words = normalizeTitleWords(text)
                local n_words = 0
                for _ in pairs(words) do n_words = n_words + 1 end
                for author_key in pairs(catalog.__authors) do
                    local all_in, n_author = true, 0
                    for w in author_key:gmatch("%S+") do
                        n_author = n_author + 1
                        if not words[w] then all_in = false break end
                    end
                    if all_in and n_author > 0 and n_words - n_author <= 3 then return true end
                end
                return false
            end

            local before_is_author = before_sep and authorKeyOf(before_sep) ~= nil
            local after_is_author = after_sep and authorKeyOf(after_sep) ~= nil

            if before_sep and after_sep and after_sep ~= "" and after_is_author and not before_is_author then
                -- "Title - Author". Checked FIRST, and it is what makes
                -- calibre's own default export work: its title_sort moves
                -- leading articles to the end, producing "Road, The - Cormac
                -- McCarthy". That comma used to look like a "Lastname,
                -- Firstname" author, so the title was taken from the other
                -- side and CWA was searched for "Cormac McCarthy". Asking
                -- whether the segment after the dash is a known author
                -- settles it directly.
                search_title = before_sep
            elseif before_sep and after_sep and after_sep ~= ""
                    and (before_is_author or containsKnownAuthor(before_sep) or before_sep:find(",")) then
                search_title = after_sep
            elseif before_sep and before_sep ~= "" then
                search_title = before_sep
            else
                search_title = cleaned_fname
            end

            -- Series-volume mangling: an "<Author> - <Series> <N>_ <Title>"
            -- download name (a "Book N" collapsed to "N_") leaves the SERIES
            -- name where the title should be. Searching or matching on it
            -- collides book N with book 1 of the same series -- they share the
            -- series name, and the number is the only thing telling them apart
            -- (found live: an ACOTAR book-2 file skipped as a maybe-duplicate
            -- of book 1). So take the title from AFTER the number, and drop the
            -- series+number from the relevance basis too. The digit right
            -- before the "_" is what separates this from the colon mangling
            -- ("Cookbook_ subtitle"), where the real title is BEFORE the "_".
            local series_volume_mangle = false
            do
                -- Whichever side carries the "<number>_ " marker IS the title
                -- side -- an author name never does -- so this deliberately
                -- does not trust the author-side detection above, which picks
                -- the AUTHOR as the search title whenever the CWA author
                -- catalog fails to recognise the name. After-separator side
                -- first (the usual "Author - Series N_ Title" shape), then
                -- the other, for "Series N_ Title - Author".
                local real_title = after_sep and after_sep:match("^.-%s+%d+_%s+(.+)$")
                if not (real_title and real_title ~= "") then
                    real_title = before_sep and before_sep:match("^.-%s+%d+_%s+(.+)$")
                end
                if real_title and real_title ~= "" then
                    search_title = real_title
                    series_volume_mangle = true
                end
            end
            -- Anna's Archive (and similar sources) can't put a literal
            -- colon in a filename, so it substitutes an underscore, and
            -- can't put a bracket-qualified annotation inline either
            -- without it looking like part of the title -- but CWA's OPDS
            -- search does an exact substring/phrase match against its
            -- stored title, not a tokenized word-AND match. Confirmed
            -- live, the hard way: CWA's catalog already had 3 duplicate
            -- copies of "The Dungeon Anarchist's Cookbook: Dungeon Crawler
            -- Carl Book 3" -- this exact bug re-uploading it every single
            -- sync run, because searching the exact stored title (colon
            -- intact) finds all 3 real entries, but searching anything
            -- else -- even just one extra or substituted word after
            -- "Cookbook" -- finds none at all, no matter how it's spelled
            -- or how many words overlap.
            --
            -- Truncating the query at the first underscore/bracket/paren,
            -- rather than turning those into spaces and continuing into
            -- whatever the real title said past that point, keeps the
            -- query to the one substring guaranteed unmangled: everything
            -- before wherever a colon or annotation most likely used to
            -- be. Deliberately does NOT touch "-": unlike those, a plain
            -- hyphen is routinely real title content once the spaced " - "
            -- separator has already been split off above (e.g.
            -- "Spider-Man", "The Three-Body Problem") -- blanking it here
            -- would silently reintroduce the exact same class of bug this
            -- whole fix exists to close, just via a different character.
            -- No currently-broken title in this library hits this
            -- specifically (every hyphenated filename found either has its
            -- hyphen removed by stripTrailingParenGroups first or falls on
            -- the author side of the split above), but it's a live,
            -- waiting failure for the next title where it doesn't.
            local query = search_title:match("^([^_%[%(]+)") or search_title

            -- A filename with no " - " separator at all (e.g. "Recursion
            -- Blake Crouch Z-Library.epub") leaves the whole thing --
            -- title, author and any source tag -- as the query, and since
            -- CWA matches an exact substring of the stored title, that
            -- finds nothing no matter how much of it is genuinely the
            -- title. Found by sweeping every book in the real library
            -- through this exact code path against live CWA: 39/40 found
            -- themselves, this shape was the lone holdout.
            --
            -- So: if the first query comes back empty, retry with
            -- progressively shorter leading word-prefixes. Only ever runs
            -- when the full query already failed, so it can't change the
            -- outcome for anything that currently works. Broadening the
            -- *search* is safe here in a way that loosening the *match*
            -- would not be -- titleWordsSubsetOf below still decides what
            -- actually counts as the same book, and it requires the
            -- candidate's whole title to appear in the filename AND every
            -- filename word to be explained by that candidate's own
            -- title+author. Unbounded -- narrows all the way to a single
            -- word when needed, however many prefixes that takes. A
            -- one-word title was the case that originally motivated this
            -- (confirmed live: "Recursion Blake Crouch" and "Recursion
            -- Blake" both return nothing, while "Recursion" returns that one
            -- book and nothing else); a since-fixed 3-attempt cap on this
            -- same loop later turned out to cut it off short for a filename
            -- with enough extra words (a multi-mirror source tag -- see the
            -- note at the loop itself), so titles that needed a 4th or 5th
            -- reduction to reach their working single word silently
            -- uploaded as duplicates instead. Each longer prefix is tried
            -- first, so a generic single word is only ever reached once
            -- everything more specific has already come back empty. Even
            -- then the worst case is
            -- "returned results but none matched confidently -- skipped,
            -- check manually" below, which is reported, not silent, and
            -- never a duplicate upload.
            local queries = { query }

            -- An apostrophe is another place the same title gets written
            -- two different ways, and an exact-substring search can't
            -- bridge that. Confirmed live: CWA stores this library's copy
            -- as "The Hitchhiker`s Guide to the Galaxy" -- a BACKTICK --
            -- while the local filename has a proper apostrophe, so
            -- searching the full title found only an unrelated "...Further
            -- Radio Scripts" edition and never the actual novel sitting
            -- right there in the catalog. Truncating at the apostrophe
            -- ("The hitchhiker") matches either spelling, same reasoning
            -- as the underscore/bracket/paren truncation above.
            local apos = query:find("['\148\145\146`]")
            if apos and apos > 1 then
                local trimmed = query:sub(1, apos - 1):gsub("%s+$", "")
                if trimmed ~= "" and trimmed ~= query then
                    queries[#queries + 1] = trimmed
                end
            end

            -- No attempt cap here (there used to be one, capped at 3): a
            -- source that appends a long multi-mirror tag -- confirmed live,
            -- "z-library.sk, 1lib.sk, z-lib.sk" splits into 3 extra words on
            -- its own -- pushed titles like "Pines"/"Upgrade"/"Come as You
            -- Are" past a 3-attempt budget before ever reaching the single
            -- short word that actually matches, so they silently re-uploaded
            -- as duplicates every run instead of ever reaching the query
            -- that would have found them. Uncapped is still safe: this loop
            -- only ever narrows the *search*, and titleWordsSubsetOf below
            -- is what actually decides a match either way, so trying every
            -- remaining prefix length just gives a long filename more
            -- chances to reach the one query that works, not more chances to
            -- false-positive.
            local words = {}
            for w in query:gmatch("%S+") do words[#words + 1] = w end
            -- A confidently-parsed "Series N_ Title" name (above) needs no
            -- prefix ladder: if the full real title isn't in CWA, the book
            -- genuinely isn't there. Shortening it only reaches a generic
            -- prefix that collides with a sibling volume (the series name
            -- book 1 shares) and blocks the upload as a maybe-duplicate. A
            -- 0..1 range with a -1 step is an empty loop.
            local shorten_from = series_volume_mangle and 0 or (#words - 1)
            for count = shorten_from, 1, -1 do
                local prefix = table.concat(words, " ", 1, count)
                -- Skip a prefix that is nothing but stopwords. "The Road"
                -- shortens to "The", which CWA happily answers with 28
                -- entries (65KB) -- and "A" returns 57, essentially the whole
                -- library. Those rows can never match or even count as
                -- relevant, because the matcher drops these words entirely,
                -- so such a query is pure transfer cost and pure noise: it
                -- can only ever drag unrelated books into the candidate set
                -- that later stages have to reject.
                if next(normalizeTitleWords(prefix)) ~= nil then
                    queries[#queries + 1] = prefix
                end
            end

            -- Try candidates until one actually yields a confident match,
            -- not merely until one yields any rows at all. The old
            -- stop-on-first-rows rule meant a query that surfaced only a
            -- *different* book (the Radio Scripts case above) ended the
            -- search, so the real book was never looked for. Matches are
            -- collected across candidates and de-duplicated by uuid, and
            -- relevant-row counts accumulate, so the skip/upload decision
            -- below sees everything that was actually found. Short-circuits
            -- as soon as a match exists, so the common case still costs a
            -- single request.
            local matches = {}
            local seen_uuids = {}
            local raw_entry_count = 0
            local any_response = false
            local fname_words = normalizeTitleWords(fname)
            -- Volume gate: a filename that names a volume ("Book 2", "02",
            -- "IV", "(1)") can only ever match a candidate that carries the
            -- same number, in its title or as its CWA series index. Applied
            -- to every matching tier below. It never adds a match, only
            -- refuses one, so a volume-numbered file that finds only the
            -- wrong volume lands in "check manually" instead of registering
            -- as its sibling (the "Dungeon Crawler Carl Book 2" -> book 1
            -- case). A filename with no volume number is unaffected.
            local fname_vols, fname_vol_tokens = volumeNumbersOf(fname)
            local function volumeCompatible(e)
                if next(fname_vols) == nil then return true end
                local cand_vols = volumeNumbersOf(e.title)
                for n in pairs(cand_vols) do
                    if fname_vols[n] then return true end
                end
                local idx = getSeriesIndex(e.uuid)
                return idx ~= nil and fname_vols[idx] == true
            end

            -- Drop EXTRA CONTRIBUTOR names from the words the matcher demands
            -- an explanation for.
            --
            -- A comma before the separator means one of two different things:
            -- "Orwell, George - 1984" is one person written surname-first,
            -- while "Cormac McCarthy, Tom Stechschulte - The Road" is the
            -- author plus a narrator. The catalog tells them apart -- the
            -- first resolves to a known CWA author, the second doesn't.
            --
            -- In the second shape the title is extracted correctly, the right
            -- book is found, and the strict matcher then refuses it anyway
            -- because "tom" and "stechschulte" aren't in CWA's title or
            -- author. Measured across every filename this plugin has handled,
            -- that shape is the ONLY one that fails: every other shape (and
            -- every modifier -- source tags, colon-underscores, brackets,
            -- series parentheticals) resolves cleanly.
            --
            -- So: when the author side contains a known CWA author plus extra
            -- words, those extras are contributor names and stop being
            -- required. Deliberately limited to the AUTHOR side -- extra
            -- words on the TITLE side still have to be explained, which is
            -- what keeps "Mistborn_ The Well of Ascension" from matching a
            -- bare "Mistborn".
            if catalog and catalog.__authors and before_sep and before_sep:find(",") then
                local before_words = normalizeTitleWords(before_sep)
                local matched_author = nil
                for author_key in pairs(catalog.__authors) do
                    local all_in, any = true, false
                    for w in author_key:gmatch("%S+") do
                        any = true
                        if not before_words[w] then all_in = false break end
                    end
                    -- A known author fully contained in, but shorter than,
                    -- the author-side text: the remainder is the extra
                    -- contributor.
                    if any and all_in then
                        local n_author, n_before = 0, 0
                        for _ in author_key:gmatch("%S+") do n_author = n_author + 1 end
                        for _ in pairs(before_words) do n_before = n_before + 1 end
                        if n_before > n_author then matched_author = author_key break end
                    end
                end
                if matched_author then
                    local keep = {}
                    for w in matched_author:gmatch("%S+") do keep[w] = true end
                    for w in pairs(before_words) do
                        if not keep[w] then fname_words[w] = nil end
                    end
                end
            end
            local candidates = {}

            -- seen_uuids tracks every row already examined, NOT just the
            -- ones that matched. The same book legitimately comes back from
            -- several of the candidate queries above, and counting it once
            -- per appearance would both inflate raw_entry_count and, worse,
            -- make the subtitle-uniqueness test below think one book was
            -- several -- silently disabling the relaxation it guards.
            for _, q in ipairs(queries) do
                local resp_body, code = searchCwa(q)
                if resp_body and code == 200 then
                    any_response = true
                    for _, e in ipairs(parseOpdsEntries(resp_body)) do
                        if e.uuid and not seen_uuids[e.uuid] then
                            seen_uuids[e.uuid] = true
                            local entry_words = normalizeTitleWords(e.title)
                            -- Relevance: a CWA row only counts as evidence
                            -- that this book might already exist if ALL of
                            -- its title words appear in the filename -- not
                            -- merely one of them.
                            --
                            -- "Shares at least one word" was far too weak.
                            -- Confirmed live with "Pierce Brown - Dark Age
                            -- (Red Rising Series Book 5)": that title isn't
                            -- in CWA, the query correctly became "Dark Age"
                            -- and returned nothing, then the prefix ladder
                            -- shortened it to "Dark" -- which returned The
                            -- Dark Forest, Dark Matter, The Dark Tower and A
                            -- Dark College Hockey Romance. Every one shares
                            -- the word "dark", so all four were counted as
                            -- evidence and a book CWA did not have was
                            -- refused upload.
                            --
                            -- Requiring full containment keeps the
                            -- protection this exists for: in the "Dune
                            -- Messiah" case that motivated it, CWA's row IS
                            -- "Dune Messiah", whose words are all present in
                            -- the filename, so it still counts and still
                            -- blocks a duplicate. It only stops a
                            -- coincidental single-word overlap from doing so.
                            local all_words_present = true
                            local any_entry_word = false
                            for w in pairs(entry_words) do
                                any_entry_word = true
                                if not fname_words[w] then
                                    all_words_present = false
                                    break
                                end
                            end
                            if any_entry_word and all_words_present then
                                raw_entry_count = raw_entry_count + 1
                            else
                                -- The other direction: a filename that is a
                                -- truncated form of this candidate's title
                                -- ("Hail Mary - Andy Weir" vs "Project Hail
                                -- Mary: A Novel", "The Dark Tower" vs "The
                                -- Dark Tower I: The Gunslinger") is at least
                                -- as likely to BE this book as to be a new
                                -- one, so it must not fall through to
                                -- upload. Counting it as relevant routes it
                                -- to "check manually", which is reported and
                                -- reversible; an upload is neither. Author
                                -- words are set aside first so a bare
                                -- "Title - Author" file compares title to
                                -- title. Found by the negative-control
                                -- sweep; only ever turns an upload into a
                                -- report, never into a match.
                                local author_words = normalizeTitleWords(e.author)
                                local any_fname_word, all_in_title = false, true
                                for w in pairs(fname_words) do
                                    if not author_words[w] then
                                        any_fname_word = true
                                        if not entry_words[w] then all_in_title = false break end
                                    end
                                end
                                if any_fname_word and all_in_title then
                                    raw_entry_count = raw_entry_count + 1
                                end
                            end
                            candidates[#candidates + 1] = e
                            if titleWordsSubsetOf(entry_words, normalizeTitleWords(e.author), fname_words)
                                    and volumeCompatible(e) then
                                table.insert(matches, e)
                            end
                        end
                    end
                end
                if #matches > 0 then break end
            end

            -- Second pass, only when nothing matched outright: allow a CWA
            -- title's subtitle (everything after a colon) to be absent from
            -- the local filename. That is the remaining common shape --
            -- CWA holds "Dungeon Crawler Carl: A LitRPG/Gamelit Adventure"
            -- while the file is just "Dungeon Crawler Carl - Matt
            -- Dinniman.epub", so the strict check fails on "litrpg" alone.
            --
            -- Blanket subtitle-stripping would be unsafe: for a series
            -- sharing one main title ("Mistborn: The Final Empire" vs
            -- "Mistborn: The Well of Ascension") the subtitle is the ONLY
            -- thing telling the volumes apart, and dropping it would
            -- recreate exactly the false-positive this matcher was
            -- tightened to prevent. So relax it only for a candidate whose
            -- pre-colon title is UNIQUE among everything this search
            -- returned -- if two candidates share a main title, the
            -- subtitle is carrying the distinction and stays required.
            --
            -- The reverse half of titleWordsSubsetOf is untouched: every
            -- filename word must still be explained by the candidate's own
            -- title+author, which is what keeps "Wayward Pines - 02
            -- Wayward" from matching a bare "Wayward" (the filename's
            -- extra series words are unexplained). That case is genuinely
            -- ambiguous -- structurally identical to the Mistborn
            -- false-positive -- and deliberately still skips.
            if #matches == 0 and #candidates > 0 then
                local function preColon(title)
                    if type(title) ~= "string" then return "" end
                    return (title:match("^([^:]+)") or title)
                end
                local stem_counts = {}
                for _, e in ipairs(candidates) do
                    local stem = table.concat(sortedWordList(normalizeTitleWords(preColon(e.title))), " ")
                    stem_counts[stem] = (stem_counts[stem] or 0) + 1
                end
                -- A volume marker inside the pre-colon stem itself ("The Dark
                -- Tower I: The Gunslinger") is the one part of the stem that
                -- says WHICH book, and a roman "I" is a single letter that
                -- normalizeTitleWords drops. Caught by the negative-control
                -- sweep: a file named just "The Dark Tower - Stephen King"
                -- registered as volume I. So: lift any volume token out of
                -- the stem, and if there is one, insist the filename carries
                -- the same number (as digits or roman) before the stem may
                -- match at all. The two sides are then compared with their
                -- volume tokens set aside, since "ii" and "2" have already
                -- been checked as numbers and could never match as words.
                for _, e in ipairs(candidates) do
                    local stem_text = preColon(e.title)
                    local stem_words = normalizeTitleWords(stem_text)
                    local stem = table.concat(sortedWordList(stem_words), " ")
                    if stem ~= "" and stem_counts[stem] == 1 and volumeCompatible(e) then
                        local stem_vols, stem_vol_tokens = volumeNumbersOf(stem_text)
                        local vol_ok = true
                        if next(stem_vols) ~= nil then
                            vol_ok = false
                            for n in pairs(stem_vols) do
                                if fname_vols[n] then vol_ok = true break end
                            end
                        end
                        if vol_ok then
                            local stem_cmp, fname_cmp = {}, {}
                            for w in pairs(stem_words) do
                                if not stem_vol_tokens[w] then stem_cmp[w] = true end
                            end
                            for w in pairs(fname_words) do
                                local n = fname_vol_tokens[w]
                                if not (n and stem_vols[n]) then fname_cmp[w] = true end
                            end
                            if next(stem_cmp) ~= nil
                                    and titleWordsSubsetOf(stem_cmp, normalizeTitleWords(e.author), fname_cmp) then
                                table.insert(matches, e)
                            end
                        end
                    end
                end
            end

            -- Last resort: explain the filename's leftover words using the
            -- candidate's SERIES name and volume number. A series-organized
            -- filename ("Wayward Pines - 02 Wayward - Blake Crouch") carries
            -- the series name and index that CWA keeps as separate metadata
            -- fields rather than in the title, so the strict check sees
            -- "pines" and "02" as unexplained words and refuses -- correctly,
            -- given what it knew, but the information to resolve it exists,
            -- just not in the title.
            --
            -- This is genuinely stricter than the subtitle relaxation above,
            -- not looser: it never drops a requirement, it only lets series
            -- metadata SATISFY one. Every filename word must still be
            -- accounted for -- now by title, author, series name, or the
            -- series index as a number. The Mistborn false-positive stays
            -- blocked for exactly that reason: matching "Mistborn_ The Well
            -- of Ascension" against CWA's "Mistborn" (series Mistborn #1)
            -- leaves "well" and "ascension" unexplained by ANY of those
            -- fields, so it still refuses. What it does resolve is the case
            -- where the leftovers ARE the series name and volume number.
            --
            -- Costs nothing on the common path: the series map is fetched
            -- lazily (and once per sync) only if execution ever reaches
            -- here, which needs both a failed strict match and a failed
            -- subtitle relaxation.
            if #matches == 0 and #candidates > 0 then
                local series_by_uuid = getSeriesMap()
                for _, e in ipairs(candidates) do
                    local series_name = e.uuid and series_by_uuid[e.uuid]
                    if series_name and volumeCompatible(e) then
                        local entry_words = normalizeTitleWords(e.title)
                        local author_words = normalizeTitleWords(e.author)
                        local series_words = normalizeTitleWords(series_name)
                        -- Forward half unchanged: the candidate's own title
                        -- must still appear in the filename.
                        local title_present = true
                        local any_title_word = false
                        for w in pairs(entry_words) do
                            any_title_word = true
                            if not fname_words[w] then title_present = false break end
                        end
                        if any_title_word and title_present then
                            local series_index = getSeriesIndex(e.uuid)

                            -- When the candidate's whole title is contained
                            -- in its own series name -- "Wayward" inside "The
                            -- Wayward Pines Trilogy" -- the forward check
                            -- above proves nothing: the series name appearing
                            -- in the filename satisfies it on its own, so
                            -- EVERY volume of that series looks equally
                            -- plausible. In that case the volume number is
                            -- the only real discriminator, so demand it: the
                            -- filename must carry a number and it must equal
                            -- this book's series_index. Without that,
                            -- "Wayward Pines - 01 Pines" would match the #2
                            -- volume just as happily as the #1 it names.
                            --
                            -- A title that contributes a word of its own
                            -- ("Golden Son" in "Red Rising Trilogy") is
                            -- already distinguishing, so it doesn't need one.
                            local title_is_subset_of_series = true
                            for w in pairs(entry_words) do
                                if not series_words[w] then
                                    title_is_subset_of_series = false
                                    break
                                end
                            end

                            -- Volume number is read off the RAW filename, not
                            -- the normalized word set: normalizeTitleWords
                            -- drops any token shorter than two characters, so
                            -- a single-digit volume ("Wayward Pines 2
                            -- Wayward", "#2") disappeared entirely before it
                            -- could be compared -- only zero-padded "02"
                            -- happened to survive. Scanning the filename
                            -- directly handles every numbering style.
                            local index_confirmed = false
                            if series_index then
                                for digits in fname:gmatch("%d+") do
                                    if tonumber(digits) == series_index then
                                        index_confirmed = true
                                        break
                                    end
                                end
                                -- "Book IV of the Red Rising Saga": the
                                -- volume number written as a roman numeral.
                                -- Only a standalone token counts, so a
                                -- title word like "vivid" can't be misread.
                                if not index_confirmed then
                                    for token in fname:lower():gmatch("%f[%a][ivxlc]+%f[%A]") do
                                        if romanToNumber(token) == series_index then
                                            index_confirmed = true
                                            break
                                        end
                                    end
                                end
                            end

                            local all_explained = true
                            for w in pairs(fname_words) do
                                local as_number = tonumber(w)
                                if as_number and series_index and as_number == series_index then
                                    -- The volume number itself, already
                                    -- confirmed above.
                                elseif SERIES_STRUCTURE_WORDS[w] then
                                    -- Structural scaffolding around a volume
                                    -- number -- "Book 2", "Vol. 2", "Part 2".
                                    -- Forgiven only here, inside a match
                                    -- that's already established by title,
                                    -- author and series name; strict matching
                                    -- elsewhere still treats these as real
                                    -- words, so this can't loosen anything
                                    -- outside the series path.
                                elseif series_index and romanToNumber(w) == series_index then
                                    -- The volume number as a roman numeral
                                    -- ("IV"), already confirmed above.
                                elseif SERIES_SUFFIX_WORDS[w] then
                                    -- "...of the Red Rising SAGA": the generic
                                    -- word a filename hangs on a series name.
                                    -- CWA's own series field says "Red Rising
                                    -- Series", so the noun never lines up.
                                    -- Same guard as above: series path only.
                                elseif not entry_words[w] and not author_words[w] and not series_words[w] then
                                    all_explained = false
                                    break
                                end
                            end

                            if all_explained and (index_confirmed or not title_is_subset_of_series) then
                                table.insert(matches, e)
                            end
                        end
                    end
                end
            end
            -- raw_entry_count is deliberately separate from #matches. CWA
            -- genuinely returning nothing is the only case safe to treat
            -- as "not in CWA yet"; a search that DID return a plausible
            -- row, just none the strict word-matcher trusted, is a
            -- different situation and used to fall into the same "upload
            -- it" branch as a real zero-result search -- confirmed live as
            -- the cause of a genuine "Dune Messiah" duplicate.
            --
            -- Only rows plausibly ABOUT this book count toward it: a row
            -- sharing not one title word with the local filename cannot be
            -- the same book, so it is no evidence either way. That matters
            -- because the query is often the author's name rather than the
            -- title -- an "Author - Title" filename with no comma (e.g.
            -- "Stephen King - The Dark Tower 1_ The Gunslinger.epub") is
            -- indistinguishable from "Title - Author" by structure alone,
            -- so CWA searches the author field and returns that author's
            -- OTHER books. Counting those unfiltered kept a genuinely new
            -- book from ever uploading (confirmed live: The Gunslinger sat
            -- through five consecutive syncs). The protection itself is
            -- unchanged -- in the "Dune Messiah" case, CWA's response does
            -- contain the real same-titled book, which shares title words,
            -- still counts, and still forces a skip over a duplicate.
            if #matches == 1 then
                local m = matches[1]
                if registry[m.uuid] then
                    addLine(T(_("  [%1] matches already-tracked \"%2\" -- possible duplicate file, skipped."), fname, m.title))
                else
                    -- Force a real download here rather than just recording
                    -- CWA's current last_modified as an assumed-fresh
                    -- baseline -- confirmed live: matching an untracked
                    -- local file to an EXISTING CWA book says nothing about
                    -- whether that local copy is actually current. "The
                    -- Road" matched cleanly against CWA's entry here while
                    -- the local file still carried an old cover from before
                    -- a CWA-side edit; registering it as-is (the old
                    -- behavior) meant the outdated copy showed as
                    -- "unchanged" on every check from then on, since
                    -- last_modified was being baselined off whatever CWA
                    -- said *right now*, not off anything the local file had
                    -- ever actually reflected.
                    -- getBookAjax, not a fresh request: series relaxation may
                    -- already have fetched this exact uuid while deciding the
                    -- match that got us here (see its note above).
                    local book = getBookAjax(m.uuid)
                    local last_modified = book and book.last_modified
                    local epub_path = book and book.main_format and book.main_format.epub
                    if type(last_modified) == "string" and type(epub_path) == "string"
                            and doCwaFileDownload(cwa_url, cwa_username, cwa_password, epub_path, socks5_proxy, path) then
                        registry[m.uuid] = { path = path, title = m.title, last_modified = last_modified }
                        pending_uploads[path] = nil
                        replaced_paths[#replaced_paths + 1] = path
                        addLine(T(_("  [%1] matched existing CWA book \"%2\" -- downloaded current copy, registered."), fname, m.title))
                    else
                        -- Couldn't confirm/pull a fresh copy (CWA unreachable
                        -- just for this one extra request, etc) -- still
                        -- register the match itself, since title/author
                        -- already established it's the same book, just
                        -- without a last_modified baseline. Matches the old
                        -- behavior exactly, as a fallback rather than
                        -- leaving a confirmed match unregistered.
                        registry[m.uuid] = { path = path, title = m.title }
                        pending_uploads[path] = nil
                        addLine(T(_("  [%1] matched existing CWA book \"%2\" -- registered (couldn't confirm it's the current copy)."), fname, m.title))
                    end
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
                -- Both the report line and the review entry are gated on
                -- allow_upload, i.e. on this being the FIRST pass over this
                -- file. The post-upload pass re-runs this same function up
                -- to three times per uploaded book while waiting for CWA to
                -- import it; without this gate a book that didn't match
                -- immediately got its "check manually" line printed three
                -- times AND was queued for review three times, so the AI
                -- review then asked about the identical title three times in
                -- a row. Confirmed live.
                if allow_upload then
                    addLine(T(_("  [%1] CWA search returned %2 result(s) for this query but none matched confidently -- skipped, check manually."), fname, tostring(raw_entry_count)))
                    -- Keep only plain strings: this table crosses the fork
                    -- boundary back to the parent, and anything else (notably
                    -- a rapidjson null sentinel) does not survive
                    -- serialization -- see stripJsonNull's note.
                    local slim = {}
                    for _ci = 1, math.min(#candidates, 10) do
                        local c = candidates[_ci]
                        if c and c.uuid and c.title then
                            slim[#slim + 1] = {
                                uuid = tostring(c.uuid),
                                title = tostring(c.title),
                                author = c.author and tostring(c.author) or "",
                            }
                        end
                    end
                    -- Defence in depth: never queue the same path twice even
                    -- if some future caller re-enters this branch.
                    local already = false
                    for _ui = 1, #unmatched do
                        if unmatched[_ui].path == path then already = true break end
                    end
                    if #slim > 0 and not already then
                        unmatched[#unmatched + 1] = { path = path, fname = fname, candidates = slim }
                    end
                end
            elseif not any_response then
                -- Every search failed outright (CWA unreachable, auth
                -- rejected, 5xx...). "No results" and "couldn't ask" look
                -- identical from raw_entry_count alone, and treating the
                -- second as "not in CWA yet" would upload a book that may
                -- well already be there -- exactly the duplicate this
                -- whole path exists to avoid. Left untracked so the next
                -- sync retries it normally.
                addLine(T(_("  [%1] couldn't reach CWA to check -- skipped, will retry next sync."), fname))
            elseif allow_upload then
                if pending_uploads[path] then
                    -- Pushed on an earlier run and still not matched back --
                    -- async import, or embedded metadata that disagrees with
                    -- the filename. Re-uploading would just make a duplicate,
                    -- the exact failure this guards; keep retrying the match
                    -- instead, and never upload a second copy.
                    addLine(T(_("  [%1] already uploaded earlier -- CWA hasn't matched it back yet (its embedded author may differ from the filename); not re-uploading."), fname))
                else
                    table.insert(to_upload, path)
                end
            end
            -- allow_upload=false and no match: stay silent. This is the
            -- post-upload retry pass, which runs up to three times -- a line
            -- per attempt per book would bury the report in noise. The
            -- caller reports once, at the end, for whatever is still
            -- unregistered.
    end

    if #unregistered > 0 then
        addLine(T(_("Checking %1 untracked book(s) against CWA..."), #unregistered))
        -- Not "for _, path" -- that shadows gettext's _() for the rest of
        -- this loop body, which does call it (confirmed live: "attempt to
        -- call local '_' (a number value)" the first time this ran for
        -- real, thrown from the addLine(_(...)) calls below).
        for _idx, path in ipairs(unregistered) do
            reportProgress(phasePct(PCT_UNTRACKED_START, PCT_UNTRACKED_END, _idx - 1, #unregistered))
            checkUntrackedPath(path, true)
        end
        reportProgress(PCT_UNTRACKED_END)
        -- Cancelling this (a "dismissable" subprocess -- the user can
        -- back out mid-run) kills the child immediately
        -- (ffiutil.terminateSubProcess), and the only save was at the
        -- very end -- so any matches already found this run would be
        -- silently lost and have to be re-searched from scratch next
        -- time. Saving after each phase means a cancelled run only
        -- redoes what it hadn't finished yet, not everything.
        saveSyncRegistry(registry)
    end

    local uploaded = {}
    if #to_upload > 0 then
        addLine(T(_("Uploading %1 new book(s) to CWA..."), #to_upload))
        local cookie, login_err = doCwaLogin(cwa_url, cwa_username, cwa_password, socks5_proxy)
        if not cookie then
            addLine(T(_("  couldn't log in to CWA to upload: %1"), tostring(login_err)))
        else
            for _idx, path in ipairs(to_upload) do -- see note above on why not "_"
                reportProgress(phasePct(PCT_UPLOAD_START, PCT_UPLOAD_END, _idx - 1, #to_upload))
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
                        uploaded[#uploaded + 1] = path
                        -- Remember it so a slow/mismatched import never leads
                        -- to a re-upload on the next run.
                        pending_uploads[path] = { title = fname, at = os.time() }
                        addLine(T(_("  [%1] uploaded."), fname))
                    elseif up_err then
                        addLine(T(_("  [%1] upload failed: %2"), fname, up_err))
                    else
                        addLine(T(_("  [%1] upload failed (HTTP %2)."), fname, tostring(up_code)))
                    end
                end
            end
        end
    end

    -- Register what we just uploaded, in this same run. CWA's ingest is
    -- asynchronous -- the upload returns as soon as the file lands in the
    -- watched folder, and a separate watcher imports it a moment later --
    -- so a search fired immediately after the POST finds nothing. That
    -- timing is the only reason an upload used to need a whole second sync
    -- to register; waiting a few seconds and re-checking collapses it into
    -- one. Confirmed live from CWA's own ingest logs: an import completes
    -- roughly 2-4s after upload for a normal-sized epub (longer for a big
    -- one, hence more than one attempt).
    --
    -- Deliberately bounded and quiet: if CWA is slower than this, the book
    -- simply registers on the next sync exactly as it always did -- this is
    -- an optimization on top of the old behavior, never a new requirement.
    if #uploaded > 0 then
        addLine(T(_("Waiting for CWA to import %1 upload(s)..."), #uploaded))
        local still_pending = uploaded
        for attempt = 1, 3 do
            ffiUtil.sleep(attempt == 1 and 4 or 5)
            -- Forget everything the per-run caches learned about CWA before
            -- re-checking. Those caches (searchCwa, getBookAjax) exist on the
            -- assumption that CWA doesn't change during a run -- and the
            -- upload loop above just changed it. Without this, every query
            -- the re-check derives is one the first pass already asked, so
            -- it answers from cache, makes no request at all, never sees the
            -- book CWA has since imported, and every upload is reported as
            -- "CWA hadn't imported it yet" no matter how long the wait.
            -- Found live on KOReader Linux against a sandbox CWA: both
            -- uploads accepted, both present in CWA, registry still empty,
            -- not one HTTP request after the second upload. Invisible to the
            -- dry-run suite, where uploads can never happen. Reset per
            -- attempt, not once: attempt 2 has to see what attempt 1 didn't.
            search_cache, book_ajax_cache = {}, {}
            local pending_after = {}
            for _idx, path in ipairs(still_pending) do
                checkUntrackedPath(path, false)
                -- checkUntrackedPath registers into `registry` on a match;
                -- anything still absent from it needs another attempt.
                local registered = false
                for _uuid, entry in pairs(registry) do
                    if type(entry) == "table" and entry.path == path then
                        registered = true
                        break
                    end
                end
                if not registered then pending_after[#pending_after + 1] = path end
            end
            still_pending = pending_after
            if #still_pending == 0 then break end
        end
        for _idx, path in ipairs(still_pending) do
            local fname = path:match("([^/]+)$") or path
            addLine(T(_("  [%1] uploaded, but CWA hadn't imported it yet -- it'll register on the next sync."), fname))
        end
        saveSyncRegistry(registry)
        savePendingUploads(pending_uploads)
    end

    saveSyncRegistry(registry)
    savePendingUploads(pending_uploads)
    addLine(_("Done."))
    reportProgress(100)
    return report, replaced_paths, unmatched
end

-- Single-book counterpart to doSyncLibrary's "already tracked" loop above,
-- for Bookbridge:refreshBookMetadata -- added because a full syncLibrary()
-- run checks every tracked book's last_modified one at a time (one request
-- per book, plus a full local-folder scan for anything new), which is real
-- wall-clock cost on a library of any size just to see whether the ONE book
-- you just edited in CWA changed. Runs inside the same kind of Trapper
-- subprocess as syncLibrary -- see Bookbridge:refreshBookMetadata below --
-- so file/registry writes land the same way.
--
-- Only ever acts on a book this device has already synced at least once:
-- with no tracked uuid there's nothing to check yet, and replicating
-- doSyncLibrary's untracked search-and-match-or-upload logic here for a
-- single file would duplicate a large, carefully-hardened block of matching
-- logic for a case a single ordinary sync already covers -- run one full
-- sync to register a new book, then this works for it from then on.
local function doRefreshOneBook(cwa_url, cwa_username, cwa_password, socks5_proxy, file)
    local registry = loadSyncRegistry()
    local uuid, entry
    for u, e in pairs(registry) do
        if type(e) == "table" and e.path == file then
            uuid, entry = u, e
            break
        end
    end
    if not uuid then
        return "untracked", nil
    end

    local status = checkTrackedBookAgainstCwa(cwa_url, cwa_username, cwa_password, socks5_proxy, uuid, entry)
    if status == "gone" then
        registry[uuid] = nil
    end
    saveSyncRegistry(registry)
    return status, entry.title
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
function Bookbridge:apiRequest(method, path, body, progress_text, block_timeout, total_timeout)
    local Trapper = require("ui/trapper")
    local server_url, username, password, cookie, socks5_proxy =
        self.server_url, self.username, self.password, self.session_cookie, self.socks5_proxy

    -- `== nil`, not `or`: false is a meaningful value to pass through here
    -- (it selects Trapper's invisible trap widget -- run dismissably but
    -- show nothing, as the download path already relies on), and
    -- `progress_text or default` would quietly turn a deliberate false back
    -- into the visible dialog. Only an omitted argument gets the default.
    if progress_text == nil then progress_text = _("Talking to Shelfmark...") end

    local completed, resp, code, new_cookie, err = Trapper:dismissableRunInSubprocess(function()
        return doApiRequest(server_url, username, password, cookie, method, path, body, socks5_proxy, block_timeout, total_timeout)
    end, progress_text)

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
function Bookbridge:cwaRequest(path, progress_text)
    local Trapper = require("ui/trapper")
    local cwa_url, cwa_username, cwa_password, socks5_proxy =
        self.cwa_url, self.cwa_username, self.cwa_password, self.socks5_proxy

    local completed, body, code, err = Trapper:dismissableRunInSubprocess(function()
        return doCwaRequest(cwa_url, cwa_username, cwa_password, path, socks5_proxy)
    end, progress_text or _("Searching CWA..."))

    if not completed then return nil, nil, _("Cancelled.") end
    return body, code, err
end

function Bookbridge:cwaFileDownload(path, save_path, progress_text)
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
function Bookbridge:annasSearch(query, progress_text)
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
function Bookbridge:annasMirrorRefresh()
    local Trapper = require("ui/trapper")
    local annas_url, socks5_proxy = self.annas_url, self.socks5_proxy

    local completed, result, code, err = Trapper:dismissableRunInSubprocess(function()
        return doAnnasMirrorRefresh(annas_url, socks5_proxy)
    end, _("Looking for a working Anna's Archive mirror..."))

    if not completed then return nil, nil, _("Cancelled.") end
    return result, code, err
end

function Bookbridge:hardcoverFindBook(title, author)
    local Trapper = require("ui/trapper")
    local token, lang = self.hardcover_token, self.hardcover_language
    local completed, id, found_title, found_author, err = Trapper:dismissableRunInSubprocess(function()
        return doHardcoverFindBook(token, title, author, lang)
    end, _("Searching Hardcover..."))
    if not completed then return nil, nil, nil, _("Cancelled.") end
    return id, found_title, found_author, err
end

function Bookbridge:hardcoverSetStatus(book_id, status_id)
    local Trapper = require("ui/trapper")
    local token = self.hardcover_token
    local completed, ok, err = Trapper:dismissableRunInSubprocess(function()
        return doHardcoverSetStatus(token, book_id, status_id)
    end, _("Updating Hardcover..."))
    if not completed then return false, _("Cancelled.") end
    return ok, err
end

function Bookbridge:hardcoverFindAuthors(name)
    local Trapper = require("ui/trapper")
    local token = self.hardcover_token
    local completed, list, err = Trapper:dismissableRunInSubprocess(function()
        return doHardcoverFindAuthors(token, name)
    end, _("Searching Hardcover..."))
    if not completed then return nil, _("Cancelled.") end
    return list, err
end

function Bookbridge:hardcoverFollowAuthor(author_id)
    local Trapper = require("ui/trapper")
    local token = self.hardcover_token
    local completed, ok, err = Trapper:dismissableRunInSubprocess(function()
        return doHardcoverFollowAuthor(token, author_id)
    end, _("Following on Hardcover..."))
    if not completed then return false, _("Cancelled.") end
    return ok, err
end

function Bookbridge:hardcoverListFollowedAuthors()
    local Trapper = require("ui/trapper")
    local token = self.hardcover_token
    local completed, authors, err = Trapper:dismissableRunInSubprocess(function()
        return doHardcoverListFollowedAuthors(token)
    end, _("Loading followed authors..."))
    if not completed then return nil, _("Cancelled.") end
    return authors, err
end

function Bookbridge:hardcoverAuthorBibliography(author_id, limit, offset)
    local Trapper = require("ui/trapper")
    local token = self.hardcover_token
    local completed, books, total, author_name, err = Trapper:dismissableRunInSubprocess(function()
        return doHardcoverAuthorBibliography(token, author_id, limit, offset)
    end, _("Loading author's books..."))
    if not completed then return nil, nil, nil, _("Cancelled.") end
    return books, total, author_name, err
end

function Bookbridge:hardcoverBestEditions(provider_ids)
    local Trapper = require("ui/trapper")
    local token = self.hardcover_token
    local completed, result = Trapper:dismissableRunInSubprocess(function()
        return doHardcoverBestEditions(token, provider_ids)
    end, _("Checking for a more popular edition..."))
    if not completed then return {} end
    return result or {}
end

function Bookbridge:annasFetchDownloadUrl(md5, progress_text)
    local Trapper = require("ui/trapper")
    local annas_url, download_key, tld, socks5_proxy =
        self.annas_url, self.annas_download_key, self.annas_tld, self.socks5_proxy

    local completed, dl_url, code, err = Trapper:dismissableRunInSubprocess(function()
        return doAnnasFetchDownloadUrl(annas_url, download_key, tld, md5, socks5_proxy)
    end, progress_text or _("Fetching download link..."))

    if not completed then return nil, nil, _("Cancelled.") end
    return dl_url, code, err
end

-- Runs doSyncLibrary in a Trapper subprocess with a live progress bar.
--
-- Shared by both sync entry points ("Sync library" and the per-book "Send to
-- CWA") so the fork/poll/teardown plumbing exists once. Returns exactly what
-- the subprocess returned, plus the completed flag, leaving each caller to
-- do its own reporting.
--
-- The mechanism is the Anna's Archive download path's, for the same reason:
-- the child can't reach the parent's widgets, so it writes a percentage to a
-- file and the parent watches that file from out here. progress_text false
-- (not nil) suppresses Trapper's own static info message -- otherwise it
-- would sit on top of the progress bar saying the same thing less usefully.
--
-- Poll interval and the bar's own refresh_time_seconds are both 1s
-- deliberately: this runs on e-ink, where every repaint costs real power, and
-- the bar only actually redraws when the percentage it holds has changed.
local function runSyncWithProgress(title, subtitle, sync_args)
    local Trapper = require("ui/trapper")
    local progress_path = DataStorage:getSettingsDir() .. "/shelfmark-sync-progress"
    -- A killed run (cancelled, or a crash) leaves its last percentage behind;
    -- clearing first means the new run's bar can't start at the old one's
    -- high-water mark.
    pcall(os.remove, progress_path)

    local ProgressbarDialog = require("ui/widget/progressbardialog")
    local progress_dialog = ProgressbarDialog:new{
        title = title,
        subtitle = subtitle,
        progress_max = 100,
        refresh_time_seconds = 1,
    }
    progress_dialog:show()

    local stopped = false
    local last_pct = -1
    local function poll()
        if stopped then return end
        local f = io.open(progress_path, "r")
        if f then
            local pct = tonumber(f:read("*l"))
            f:close()
            -- Only report an actual change: reportProgress on an unchanged
            -- value is a wasted e-ink refresh, and this polls once a second
            -- through a sync that can run for minutes.
            if pct and pct ~= last_pct then
                last_pct = pct
                progress_dialog:reportProgress(math.min(math.max(pct, 0), 100))
            end
        end
        UIManager:scheduleIn(1, poll)
    end
    UIManager:scheduleIn(1, poll)

    local cwa_url, cwa_username, cwa_password, socks5_proxy, download_dir, only_path =
        sync_args[1], sync_args[2], sync_args[3], sync_args[4], sync_args[5], sync_args[6]
    local completed, report, replaced_paths, unmatched = Trapper:dismissableRunInSubprocess(function()
        return doSyncLibrary(cwa_url, cwa_username, cwa_password, socks5_proxy,
            download_dir, only_path, progress_path)
    end, false)

    stopped = true
    UIManager:unschedule(poll)
    progress_dialog:close()
    pcall(os.remove, progress_path)

    return completed, report, replaced_paths, unmatched
end

-- Manual trigger for doSyncLibrary above -- runs in a Trapper subprocess
-- since it can involve several network round-trips in sequence (OPDS
-- searches, a login, one or more uploads, then a check per tracked book),
-- same reasoning as every other network entry point in this file.
-- The sync report is only ever shown on screen, which made auditing what a
-- device's sync actually did (from the uploaded debug log) a matter of
-- inferring it from HTTP lines. Write the report into the log too, plus one
-- summary line with counts derived from the report's own lines.
local function logSyncReport(label, report, unmatched)
    if type(report) ~= "table" then return end
    local c = { found = "?", tracked = "?", matched = 0, uploaded = 0, importing = 0,
                failed = 0, ambiguous = 0, redownloaded = 0, unmatched = type(unmatched) == "table" and #unmatched or 0 }
    for _unused, line in ipairs(report) do
        debugLog("[sync] " .. tostring(line))
        local f, t = tostring(line):match("Found (%d+) book%(s%) locally, (%d+) already tracked")
        if f then c.found, c.tracked = f, t end
        if line:find("] matched existing CWA book", 1, true) or line:find("] matches already%-tracked") then c.matched = c.matched + 1 end
        if line:find("] uploaded.", 1, true) then c.uploaded = c.uploaded + 1 end
        if line:find("hadn't imported it yet", 1, true) then c.importing = c.importing + 1 end
        if line:find("upload failed", 1, true) or line:find("couldn't", 1, true) then c.failed = c.failed + 1 end
        if line:find("ambiguous", 1, true) then c.ambiguous = c.ambiguous + 1 end
        if line:find("re%-downloaded") then c.redownloaded = c.redownloaded + 1 end
    end
    debugLog(string.format("[sync] summary (%s): found=%s tracked=%s matched=%d uploaded=%d importing=%d unmatched=%d ambiguous=%d redownloaded=%d failed=%d",
        label, tostring(c.found), tostring(c.tracked), c.matched, c.uploaded, c.importing, c.unmatched, c.ambiguous, c.redownloaded, c.failed))
end

function Bookbridge:syncLibrary()
    local cwa_url, cwa_username, cwa_password, socks5_proxy =
        self.cwa_url, self.cwa_username, self.cwa_password, self.socks5_proxy
    local download_dir = (self.download_dir and self.download_dir ~= "") and self.download_dir
        or self:defaultDownloadDir()

    local completed, report, replaced_paths, unmatched = runSyncWithProgress(
        _("Syncing library with CWA..."), _("Checking books against CWA"),
        { cwa_url, cwa_username, cwa_password, socks5_proxy, download_dir, nil })

    if not completed then return end
    logSyncReport("library sync", report, unmatched)

    -- Back on the main process now that the fork has exited -- the only
    -- safe place to touch KOReader's own cache DB. See
    -- invalidateBookInfoCache for why this is needed at all.
    if type(replaced_paths) == "table" and #replaced_paths > 0 then
        for i = 1, #replaced_paths do
            invalidateBookInfoCache(replaced_paths[i])
        end

        -- Dropping the caches makes the NEXT render correct, but whatever
        -- is already on screen was painted before that and won't redraw on
        -- its own -- which is why a synced cover only appeared after
        -- navigating away and back. Both the file browser and the
        -- bookshelf look their covers up cache-first at paint time
        -- (bookshelf_spine_widget.lua's ScaledCoverCache:get in the paint
        -- path), so simply forcing a repaint is enough: the lookup misses
        -- the caches just cleared above and re-decodes from the freshly
        -- re-extracted data.
        --
        -- setDirty("all", ...) rather than reaching into the bookshelf
        -- plugin's own widget: its live-widget handle is a module-local
        -- with no public accessor, and its refresh helpers are private
        -- methods -- fine for it to call on itself, not something another
        -- plugin should bind to. This is a documented UIManager API that
        -- flags the whole window stack, so it works for whichever view
        -- happens to be showing.
        --
        -- The FileManager re-list stays as well: setDirty only repaints
        -- what the view already knows about, and the file browser needs to
        -- be told to re-read the folder if a sync added a file rather than
        -- replacing one.
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then
            pcall(function() FileManager.instance:onRefresh() end)
        end
        UIManager:setDirty("all", "full")
        debugLog("[cache] forced a full repaint after " .. #replaced_paths .. " replaced file(s)")
    end
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

    -- Offer AI-assisted review of whatever the strict matcher gave up on.
    -- Deliberately a ConfirmBox layered over the report rather than a button
    -- inside it: it keeps the report itself readable while the prompt sits
    -- on top. (An earlier version of this comment claimed TextViewer's
    -- buttons_table was unused in this plugin -- that was wrong;
    -- showDebugLog and showResilientTextViewer both use it.)
    --
    -- The list is also stashed on self so declining here doesn't throw it
    -- away -- the same review is reachable afterwards from the Shelfmark
    -- menu until the next sync replaces it.
    if type(unmatched) == "table" and #unmatched > 0
            and self.ai_relay_url and self.ai_relay_url ~= "" then
        self.pending_unmatched = unmatched
        local self_ref = self
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = T(_("%1 book(s) couldn't be matched automatically.\n\nReview suggestions now?"), #unmatched),
            ok_text = _("Review"),
            ok_callback = function()
                local Trapper2 = require("ui/trapper")
                Trapper2:wrap(function()
                    self_ref:reviewUnmatched(self_ref.pending_unmatched, 1)
                end)
            end,
            cancel_text = _("Later"),
        })
    end
end

-- Per-book "Send to CWA": the push counterpart to "Refresh from CWA".
--
-- Runs the ordinary sync, scoped to this one file (see doSyncLibrary's
-- only_path note on why it reuses that function rather than reimplementing
-- the matching). So it behaves exactly as a full sync would for this book --
-- matches it against CWA and registers it if it's already there, uploads it
-- if it genuinely isn't, waits for CWA's import and registers it, and
-- refuses to upload at all if CWA can't be reached -- just without walking
-- the rest of the library.
function Bookbridge:sendBookToCwa(file)
    local cwa_url, cwa_username, cwa_password, socks5_proxy =
        self.cwa_url, self.cwa_username, self.cwa_password, self.socks5_proxy
    local download_dir = (self.download_dir and self.download_dir ~= "") and self.download_dir
        or self:defaultDownloadDir()

    local completed, report, replaced_paths = runSyncWithProgress(
        _("Sending to CWA..."), file:match("([^/]+)$") or file,
        { cwa_url, cwa_username, cwa_password, socks5_proxy, download_dir, file })

    if not completed then return end
    logSyncReport("send to CWA", report, nil)

    if type(replaced_paths) == "table" and #replaced_paths > 0 then
        for i = 1, #replaced_paths do
            invalidateBookInfoCache(replaced_paths[i])
        end
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then
            pcall(function() FileManager.instance:onRefresh() end)
        end
        UIManager:setDirty("all", "full")
    end

    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{
        title = _("Send to CWA"),
        text = (type(report) == "table" and #report > 0)
            and table.concat(report, "\n") or _("Nothing to report."),
        justified = false,
    })
end

-- Per-file entry point for the long-press "Suggest match" button. Runs the
-- same CWA search doSyncLibrary would have run for this filename, then hands
-- whatever it finds to the same suggest-and-confirm flow used by the batch
-- review -- so a one-off gets identical treatment, including the requirement
-- that you confirm before anything is written.
function Bookbridge:suggestMatchForFile(file)
    local Trapper = require("ui/trapper")
    local cwa_url, cwa_username, cwa_password, socks5_proxy =
        self.cwa_url, self.cwa_username, self.cwa_password, self.socks5_proxy
    local fname = file:match("([^/]+)%.[Ee][Pp][Uu][Bb]$") or file:match("([^/]+)$") or file

    local completed, candidates = Trapper:dismissableRunInSubprocess(function()
        local seen, out = {}, {}
        local cleaned = stripTrailingParenGroups(fname)
        local before_sep, after_sep = cleaned:match("^(.-)%s+%-%s+(.+)$")
        local search_title
        if before_sep and before_sep:find(",") and after_sep and after_sep ~= "" then
            search_title = after_sep
        elseif before_sep and before_sep ~= "" then
            search_title = before_sep
        else
            search_title = cleaned
        end
        local query = search_title:match("^([^_%[%(]+)") or search_title
        local words = {}
        for w in query:gmatch("%S+") do words[#words + 1] = w end
        local queries = { query }
        for count = #words - 1, 1, -1 do
            queries[#queries + 1] = table.concat(words, " ", 1, count)
        end
        for _, q in ipairs(queries) do
            local body, code = doCwaRequest(cwa_url, cwa_username, cwa_password,
                "/opds/search/" .. socketurl.escape(q), socks5_proxy)
            if body and code == 200 then
                for _, e in ipairs(parseOpdsEntries(body)) do
                    if e.uuid and not seen[e.uuid] and #out < 10 then
                        seen[e.uuid] = true
                        out[#out + 1] = {
                            uuid = tostring(e.uuid),
                            title = tostring(e.title or ""),
                            author = e.author and tostring(e.author) or "",
                        }
                    end
                end
            end
            if #out > 0 then break end
        end
        return out
    end, _("Searching CWA for candidates..."))

    if not completed then return end
    if type(candidates) ~= "table" or #candidates == 0 then
        UIManager:show(InfoMessage:new{ text = _("CWA returned no candidates for this book.") })
        return
    end

    self:reviewUnmatched({ { path = file, fname = fname, candidates = candidates } }, 1)
end

-- Registers a book the user has explicitly confirmed, and pulls CWA's
-- current copy so the local file actually reflects what CWA holds -- the
-- same thing a normal first-time match does (see the note there on why a
-- match alone is not evidence the local copy is current).
--
-- Deliberately separate from the suggestion step: nothing in the AI path
-- writes anything until this is called, and this is only ever called from a
-- confirmation callback.
function Bookbridge:applyConfirmedMatch(path, uuid, title)
    local Trapper = require("ui/trapper")
    local cwa_url, cwa_username, cwa_password, socks5_proxy =
        self.cwa_url, self.cwa_username, self.cwa_password, self.socks5_proxy

    local completed, ok_result, refused_path = Trapper:dismissableRunInSubprocess(function()
        local registry = loadSyncRegistry()
        -- One CWA book maps to exactly one local file. If this uuid already
        -- tracks a DIFFERENT path, confirming here would silently reassign
        -- it and orphan that other file -- it would stop being checked for
        -- CWA-side changes, with nothing reported. The full-sync path
        -- already refuses this case ("matches already-tracked ... possible
        -- duplicate file, skipped"); this one used to overwrite it.
        local existing = registry[uuid]
        if type(existing) == "table" and existing.path and existing.path ~= path then
            return false, existing.path
        end
        local body, code = doCwaRequest(cwa_url, cwa_username, cwa_password,
            "/ajax/book/" .. uuid, socks5_proxy)
        local last_modified, epub_path
        if body and body ~= "" and code == 200 then
            local decode_ok, decoded = pcall(JSON.decode, body)
            local book = decode_ok and stripJsonNull(decoded)
            last_modified = book and book.last_modified
            epub_path = book and book.main_format and book.main_format.epub
        end
        if type(epub_path) == "string" and type(last_modified) == "string"
                and doCwaFileDownload(cwa_url, cwa_username, cwa_password, epub_path, socks5_proxy, path) then
            registry[uuid] = { path = path, title = title, last_modified = last_modified }
            saveSyncRegistry(registry)
            return true
        end
        return false
    end, _("Registering and downloading..."))

    if not completed then return false end
    if refused_path then
        UIManager:show(InfoMessage:new{
            text = T(_("That CWA book is already tracked for a different local file:\n%1\n\nNot changing it."),
                refused_path:match("([^/]+)$") or refused_path),
        })
        return false
    end
    if ok_result then
        invalidateBookInfoCache(path)
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then
            pcall(function() FileManager.instance:onRefresh() end)
        end
        UIManager:setDirty("all", "full")
        return true
    end
    return false
end

-- Walks the unmatched list one book at a time, asking the relay for a
-- suggestion and presenting it for confirmation.
--
-- Nothing is written without an explicit "Yes" per book. The suggestion is
-- shown with the model's own reason and confidence so the decision is yours
-- on visible evidence, not on trust -- and "No" simply moves on, leaving the
-- book exactly as the sync left it.
function Bookbridge:reviewUnmatched(list, index)
    if type(list) ~= "table" or index > #list then
        UIManager:show(InfoMessage:new{ text = _("Review finished."), timeout = 2 })
        return
    end

    local item = list[index]
    local Trapper = require("ui/trapper")
    local relay_url, relay_token, socks5_proxy =
        self.ai_relay_url, self.ai_relay_token, self.socks5_proxy
    local fname, candidates = item.fname, item.candidates

    local completed, suggestion, err = Trapper:dismissableRunInSubprocess(function()
        return doAiSuggest(relay_url, relay_token, fname, candidates, socks5_proxy)
    end, T(_("Asking for a suggestion (%1 of %2)..."), index, #list))

    if not completed then return end

    local self_ref = self

    local function nextBook()
        Trapper:wrap(function() self_ref:reviewUnmatched(list, index + 1) end)
    end

    if not suggestion then
        -- No suggestion is a normal outcome, not an error: the model is told
        -- to prefer "none" when unsure, and that is the safe answer.
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = T(_("%1\n\nNo confident match: %2"), fname, tostring(err or _("none"))),
            ok_text = index < #list and _("Next") or _("Done"),
            ok_callback = nextBook,
            cancel_text = _("Stop"),
        })
        return
    end

    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = T(_("%1\n\nSuggested match:\n%2%3\n\nConfidence: %4\n%5\n\nRegister this as the same book and download CWA's copy?"),
            fname,
            suggestion.title or "?",
            (suggestion.author and suggestion.author ~= "") and ("\n" .. suggestion.author) or "",
            string.format("%.0f%%", (suggestion.confidence or 0) * 100),
            suggestion.reason or ""),
        ok_text = _("Yes"),
        -- Wrapped, like every other entry into a forking call. A ConfirmBox
        -- callback fires from the UI loop, NOT from the coroutine that showed
        -- the box -- that one has long since returned -- so
        -- applyConfirmedMatch's Trapper:dismissableRunInSubprocess had nothing
        -- to yield to and blocked the UI outright until it finished. Same
        -- defect the sync menu entry had, just with a freeze instead of a
        -- missing progress bar as the symptom.
        --
        -- reviewUnmatched is called directly rather than through nextBook()
        -- because we are already inside a wrap by then: nextBook exists for
        -- the callbacks below, which are still reached unwrapped from the UI
        -- loop and so have to open a coroutine of their own.
        ok_callback = function()
            Trapper:wrap(function()
                local applied = self_ref:applyConfirmedMatch(item.path, suggestion.uuid, suggestion.title)
                UIManager:show(InfoMessage:new{
                    text = applied and T(_("Registered \"%1\"."), suggestion.title or fname)
                        or _("Couldn't download CWA's copy -- left unregistered."),
                    timeout = 2,
                })
                self_ref:reviewUnmatched(list, index + 1)
            end)
        end,
        cancel_text = _("No"),
        cancel_callback = nextBook,
    })
end

-- Single-book counterpart to syncLibrary above -- see doRefreshOneBook's own
-- note on why this exists: checking one book against CWA shouldn't cost a
-- request per *other* tracked book too. Hooked up as a per-file long-press
-- button in registerFileDialogButtons below, so "refresh this book" is
-- reachable without opening the sync menu at all.
function Bookbridge:refreshBookMetadata(file)
    local Trapper = require("ui/trapper")
    local cwa_url, cwa_username, cwa_password, socks5_proxy =
        self.cwa_url, self.cwa_username, self.cwa_password, self.socks5_proxy

    local completed, status, title = Trapper:dismissableRunInSubprocess(function()
        return doRefreshOneBook(cwa_url, cwa_username, cwa_password, socks5_proxy, file)
    end, _("Checking CWA for changes..."))

    if not completed then return end

    local label = title or require("apps/filemanager/filemanagerutil").splitFileNameType(file)

    if status == "synced" then
        -- Same cache-invalidate-then-repaint pattern as syncLibrary above,
        -- just for the one file instead of a replaced_paths list.
        invalidateBookInfoCache(file)
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then
            pcall(function() FileManager.instance:onRefresh() end)
        end
        UIManager:setDirty("all", "full")
        UIManager:show(InfoMessage:new{ text = T(_("Updated \"%1\" from CWA."), label) })
    elseif status == "unchanged" then
        UIManager:show(InfoMessage:new{ text = T(_("No changes in CWA for \"%1\"."), label) })
    elseif status == "failed" then
        UIManager:show(InfoMessage:new{ text = T(_("\"%1\" changed in CWA but the re-download failed."), label) })
    elseif status == "gone" then
        UIManager:show(InfoMessage:new{ text = T(_("\"%1\" is no longer found in CWA under its tracked ID -- run a full sync to re-link it."), label) })
    elseif status == "untracked" then
        UIManager:show(InfoMessage:new{ text = T(_("\"%1\" isn't tracked yet -- run a full library sync once to register it, then Refresh works for it here."), label) })
    else
        UIManager:show(InfoMessage:new{ text = _("Couldn't reach CWA to check.") })
    end
end

-- Mirrors syncLibrary's Trapper-subprocess wrapping above.
-- Two-field claim of a wizard-staged config (address + code). The counterpart
-- to the setup wizard's pairing screen: it fetches /claim/<code> and writes
-- whatever settings the server put there, closing the loop the wizard opens.
function Bookbridge:importFromServer()
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local prefill = self.server_url and self.server_url:match("^(https?://[^:/]+)") or ""
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Import from server"),
        description = _("Run the setup wizard on your computer, then enter this machine's address and the code it shows."),
        fields = {
            { text = prefill:gsub("^https?://", ""), hint = _("Server address, e.g. 100.90.18.11") },
            { text = "", hint = _("6-character code") },
        },
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Import"),
                is_enter_default = true,
                callback = function()
                    local fields = dialog:getFields()
                    local addr, code = fields[1], fields[2]
                    UIManager:close(dialog)
                    -- Wrapped: this fires from the UI loop, and applyServerClaim
                    -- runs a Trapper subprocess that needs a coroutine to yield
                    -- to (see the Trapper audit).
                    local Trapper = require("ui/trapper")
                    Trapper:wrap(function() self:applyServerClaim(addr, code) end)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Bookbridge:applyServerClaim(addr, code)
    if not addr or addr:gsub("%s", "") == "" or not code or code:gsub("%s", "") == "" then
        UIManager:show(InfoMessage:new{ text = _("Enter both the address and the code.") })
        return
    end
    local socks5_proxy = self.socks5_proxy
    local Trapper = require("ui/trapper")
    local completed, settings, err = Trapper:dismissableRunInSubprocess(function()
        return doClaimFromServer(addr, code, socks5_proxy)
    end, _("Fetching settings..."))
    if not completed then return end
    if not settings then
        UIManager:show(InfoMessage:new{ text = err or _("Couldn't import.") })
        return
    end
    -- Only the keys the claim actually carries are written; anything already
    -- set that the claim doesn't mention is left alone.
    local fields = { "server_url", "cwa_url", "cwa_username", "cwa_password",
                     "annas_url", "ai_relay_url", "ai_relay_token" }
    local applied = 0
    for _, k in ipairs(fields) do
        if type(settings[k]) == "string" and settings[k] ~= "" then
            self[k] = settings[k]
            applied = applied + 1
        end
    end
    if applied == 0 then
        UIManager:show(InfoMessage:new{ text = _("The server sent nothing to import.") })
        return
    end
    self:saveAllSettings(T(_("Imported %1 setting(s) from the server."), tostring(applied)))
end

-- One screen: each configured service, whether it answers, and what it
-- enables. Read-only, run only when opened -- never on a timer (battery).
function Bookbridge:showConnectionStatus()
    local socks5_proxy = self.socks5_proxy
    local services = {}
    local function add(url, name, enables)
        if url and url ~= "" then services[#services + 1] = { url = url, name = name, enables = enables } end
    end
    add(self.server_url, _("Shelfmark server"), _("search & requests"))
    add(self.cwa_url, _("Calibre-Web-Automated"), _("library sync"))
    add(self.annas_url, _("Anna's Archive API"), _("Anna's Archive as primary source"))
    add(self.ai_relay_url, _("AI relay"), _("match suggestions"))
    if #services == 0 then
        UIManager:show(InfoMessage:new{ text = _("Nothing is configured yet -- use 'Import from server' or Settings.") })
        return
    end
    local Trapper = require("ui/trapper")
    local completed, results = Trapper:dismissableRunInSubprocess(function()
        local out = {}
        for i, sv in ipairs(services) do out[i] = doTestService(sv.url, socks5_proxy) and 1 or 0 end
        return out
    end, _("Checking services..."))
    if not completed then return end
    local lines = {}
    for i, sv in ipairs(services) do
        local up = results[i] == 1
        lines[#lines + 1] = string.format("%s  %s\n      %s -- %s",
            up and "[up]" or "[--]", sv.name,
            up and _("reachable") or _("no response"), sv.enables)
    end
    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{
        title = _("Connection status"),
        text = table.concat(lines, "\n\n"),
        justified = false,
    })
end

function Bookbridge:checkForUpdate()
    local Trapper = require("ui/trapper")
    local update_url, socks5_proxy = self.update_url, self.socks5_proxy
    local completed, info, code, err = Trapper:dismissableRunInSubprocess(function()
        return doCheckForUpdate(update_url, socks5_proxy)
    end, _("Checking for updates..."))

    if not completed then return end
    if not info then
        UIManager:show(InfoMessage:new{ text = err or T(_("Couldn't check for updates (HTTP %1)."), tostring(code)) })
        return
    end

    local ConfirmBox = require("ui/widget/confirmbox")

    -- Self-hosted manifest: content decides, not the version number. While
    -- the repo is private every build carries the same PLUGIN_VERSION, so a
    -- version comparison would say "up to date" for a file that changed
    -- minutes ago -- which is exactly the case this whole path exists for.
    if info.manifest then
        -- Phrased per case rather than by pasting a version and a build id
        -- together: "A different build of v0.3.0 build 8b58ef5 is
        -- available (you have v0.3.0)" says the version twice and reads
        -- like two different things are on offer.
        local build = info.build and tostring(info.build) or nil

        -- Nothing differs by checksum. That's a real "up to date" only when
        -- the checksums could actually be computed; if they couldn't, fall
        -- back to the version number, which is the only signal left.
        if #info.changed == 0
                and not (info.unverifiable and isNewerVersion(info.version, PLUGIN_VERSION)) then
            local text
            if info.unverifiable then
                text = T(_("No newer version offered (v%1). This device couldn't checksum its own files, so a same-version rebuild can't be detected."), info.version)
            elseif build then
                text = T(_("You're up to date (v%1, build %2)."), info.version, build)
            else
                text = T(_("You're up to date (v%1)."), info.version)
            end
            UIManager:show(InfoMessage:new{ text = text })
            return
        end

        local msg
        if isNewerVersion(info.version, PLUGIN_VERSION) then
            msg = build
                and T(_("v%1 (build %2) is available -- you have v%3."), info.version, build, PLUGIN_VERSION)
                or T(_("v%1 is available -- you have v%2."), info.version, PLUGIN_VERSION)
        else
            msg = build
                and T(_("A different build of v%1 is available (build %2)."), info.version, build)
                or T(_("A different build of v%1 is available."), info.version)
        end
        if #info.changed > 0 then
            msg = msg .. "\n\n" .. T(_("Changed: %1"), table.concat(info.changed, ", "))
        end
        msg = msg .. "\n\n" .. T(_("From %1"), info.base)
        UIManager:show(ConfirmBox:new{
            text = msg,
            ok_text = _("Install"),
            ok_callback = function()
                local Trapper2 = require("ui/trapper")
                Trapper2:wrap(function() self:applyUpdate(info) end)
            end,
        })
        return
    end

    local remote_version = info.tag_name
    if not isNewerVersion(remote_version, PLUGIN_VERSION) then
        UIManager:show(InfoMessage:new{ text = T(_("You're up to date (v%1)."), PLUGIN_VERSION) })
        return
    end

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

-- opts.auto: an unattended install (autoCheckForUpdate) -- no progress
-- dialog, failures go to the debug log instead of a popup, and the restart
-- offer says the update happened by itself.
function Bookbridge:applyUpdate(target, opts)
    opts = opts or {}
    local Trapper = require("ui/trapper")
    local socks5_proxy = self.socks5_proxy
    local completed, ok, err = Trapper:dismissableRunInSubprocess(function()
        return doApplyUpdate(target, socks5_proxy)
    end, not opts.auto and _("Downloading update...") or nil)

    if not completed then return end
    if not ok then
        if opts.auto then
            debugLog("[update] auto: install failed: " .. tostring(err or "?"))
        else
            UIManager:show(InfoMessage:new{ text = err or _("Update failed.") })
        end
        return false
    end
    local label = "v" .. tostring(target.version) .. (target.build and (" build " .. target.build) or "")
    if opts.auto then debugLog("[update] auto: installed " .. label) end
    -- Offer the restart right here: UIManager:restartKOReader() exits with
    -- code 85, which koreader.sh treats as "start again" on every platform.
    -- A clean quit, so settings and the reading position are saved first.
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = opts.auto
            and T(_("Bookbridge updated itself to %1. The new version takes effect when KOReader restarts.\n\nRestart now?"), label)
            or T(_("Updated to %1. The new version takes effect when KOReader restarts.\n\nRestart now?"), label),
        ok_text = _("Restart now"),
        cancel_text = _("Later"),
        ok_callback = function() UIManager:restartKOReader() end,
    })
    return true
end

-- ===== automatic updates =====
-- Shared across plugin instances (FileManager and Reader each get one) so
-- two instances can't double-check, and persisted so a reboot doesn't reset
-- the six-hour clock.
local auto_update_state = { last = nil, running = false, not_before = nil }
local AUTO_UPDATE_INTERVAL = 6 * 3600
local AUTO_UPDATE_RETRY = 10 * 60   -- after a check that couldn't reach the server

-- Quiet check-and-install from the self-hosted update source. Called with a
-- reason ("wake", "network", "startup") from the hooks below; safe to call
-- often -- the interval and the running flag make it a no-op almost always.
-- True when an automatic check could do anything at all: the switch is on
-- and a self-hosted source is set. The hooks test the same two fields inline
-- before scheduling (they are exercised on bare tables by the test suites),
-- so a device without an update source never runs a timer.
function Bookbridge:autoUpdateWanted()
    return self.auto_update and self.update_url and self.update_url ~= "" and true or false
end

function Bookbridge:autoCheckForUpdate(reason)
    reason = reason or "?"
    if not self:autoUpdateWanted() then return end
    if auto_update_state.running then return end
    local now = os.time()
    -- Only a check that actually reached the server starts the six-hour
    -- clock. A wake without Wi-Fi (or before Tailscale is back) fails fast
    -- and just holds off for ten minutes, so the next wake or network
    -- event inside the window gets another try instead of waiting hours.
    local last = auto_update_state.last or tonumber(self.last_auto_update_check) or 0
    if now - last < AUTO_UPDATE_INTERVAL then return end
    if auto_update_state.not_before and now < auto_update_state.not_before then return end
    auto_update_state.running = true
    debugLog("[update] auto (" .. reason .. "): checking " .. tostring(self.update_url))
    local Trapper = require("ui/trapper")
    Trapper:wrap(function()
        local update_url, socks5_proxy = self.update_url, self.socks5_proxy
        local completed, info, code, err = Trapper:dismissableRunInSubprocess(function()
            return doCheckForUpdate(update_url, socks5_proxy)
        end)  -- no widget: nothing on screen while it looks
        if not completed then auto_update_state.running = false; return end
        if not info then
            debugLog("[update] auto (" .. reason .. "): couldn't check: " .. tostring(err or code))
            auto_update_state.not_before = os.time() + AUTO_UPDATE_RETRY
            auto_update_state.running = false
            return
        end
        auto_update_state.last = now
        auto_update_state.not_before = nil
        self.last_auto_update_check = now
        self:saveAllSettings()
        if not info.manifest or #info.changed == 0 then
            debugLog("[update] auto (" .. reason .. "): up to date (build " .. tostring(info.build or info.version or "?") .. ")")
            auto_update_state.running = false
            return
        end
        debugLog("[update] auto (" .. reason .. "): build " .. tostring(info.build or "?")
            .. " available (" .. table.concat(info.changed, ", ") .. ") -- installing")
        self:applyUpdate(info, { auto = true })
        auto_update_state.running = false
    end)
end

-- ===== device-to-device settings transfer (QR code / paste) =====

-- Shared by showSetupQrCode/importSettingsFromText -- both need the
-- relay URL first and do the same "ask once, save it, then continue"
-- dance if it isn't set yet.
function Bookbridge:promptPairingRelayUrl(on_success)
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

function Bookbridge:showSetupQrCode()
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
function Bookbridge:generateAndShowPairingQr()
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

function Bookbridge:importSettingsFromText()
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

function Bookbridge:applyPairingText(pairing_text)
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
-- caller_menu, when given, is closed here rather than by the caller before
-- invoking this -- see the identical note on doSearch's own caller_menu.
function Bookbridge:downloadFromCwa(title, caller_menu)
    if caller_menu then UIManager:close(caller_menu) end

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
            local Trapper = require("ui/trapper")
            Trapper:wrap(function() self:saveCwaEntry(item.entry, results_menu) end)
        end,
    }
    UIManager:show(results_menu)
end

-- caller_menu, when given, is closed here rather than by the caller before
-- invoking this -- see the identical note on doSearch's own caller_menu.
function Bookbridge:saveCwaEntry(entry, caller_menu)
    if caller_menu then UIManager:close(caller_menu) end

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
    -- In case this overwrote an existing copy of the same book -- see
    -- invalidateBookInfoCache. Runs on the main process (cwaFileDownload
    -- did its own forking internally and has already returned).
    invalidateBookInfoCache(save_path)

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

-- ===== Bluetooth keyboard (Kindle) =====
-- A phone (or any Classic Bluetooth keyboard) typing into KOReader on a
-- jailbroken MediaTek Kindle, through Amazon's own Bluetooth stack
-- (btmanagerd, driven by ace_bt_cli). Facts this rests on, all found live:
--   * the stack has a full HID host; only a udev filter and the missing
--     pairing UI stop it from taking a keyboard (the rule below fixes both);
--   * pairing must be Kindle-initiated (phone-initiated dies before the
--     passkey stage); the numeric-comparison request must be answered from
--     the CLI ("passkey y") within 30 s -- done on a timer, because the
--     CLI's output is block-buffered when redirected;
--   * the keyboard link itself is always started by the phone's app -- the
--     Kindle cannot initiate it -- so "ready" means: radio on, HID host
--     callbacks registered, connectable, session held open;
--   * the CLI is never shown scan results (the daemon masks them for it),
--     so the phone's address is entered once (Settings > About phone) and kept;
--   * ace_bt_cli ignores a closed stdin and must be ended with "exit", never
--     killed (an abrupt client death coincided with the Wi-Fi radio dropping;
--     the two share the chip);
--   * the whole thing runs detached from KOReader (setsid, stdio to /dev/null)
--     and the plugin polls for a ".done" marker, so nothing ever blocks the UI.
-- The engine is a busybox sh script the plugin writes itself, so it ships
-- inside this one file and rides the normal update.
local BT_DIR = os.getenv("BOOKBRIDGE_BT_DIR") or "/mnt/us/btkeyboard"
local BT_RULE = "/etc/udev/rules.d/99-bt-keyboard.rules"
local BT_ENGINE = [==[#!/bin/sh
# Bookbridge Bluetooth keyboard engine (MediaTek Kindle). Written by the plugin.
STEP=${1:-status}; A=${2:-}
D=${BOOKBRIDGE_BT_DIR:-/mnt/us/btkeyboard}; mkdir -p "$D"
OUT="$D/$STEP.txt"; : > "$OUT"; rm -f "$D/$STEP.done"
trap 'touch "$D/$STEP.done"' EXIT
RULE=/etc/udev/rules.d/99-bt-keyboard.rules
HELPER=/usr/local/bin/dev_is_keyboard.sh
say() { echo "$@" >> "$OUT"; }
have() { command -v "$1" >/dev/null 2>&1; }
stamp() { date +%y%m%d:%H%M%S; }
session_end() { [ -p /tmp/ace.in ] && { echo "exit" > /tmp/ace.in; sleep 2; }; rm -f /tmp/ace.in; }
session_start() {
  session_end; rm -f /tmp/ace.out; mkfifo /tmp/ace.in
  setsid sh -c 'tail -f /tmp/ace.in | ace_bt_cli > /tmp/ace.out 2>&1' </dev/null >/dev/null 2>&1 &
  sleep 1
}
w() { echo "$1" > /tmp/ace.in; }
dump() { grep -v "No Input Parameters" /tmp/ace.out 2>/dev/null | grep -v "^\s*$\|^p_data\|^ *[0-9A-F][0-9A-F] " >> "$OUT"; }
keep() { ( sleep ${1:-600}; [ -p /tmp/ace.in ] && echo "exit" > /tmp/ace.in; sleep 2; rm -f /tmp/ace.in ) </dev/null >/dev/null 2>&1 & }
inputs() { say "--- input devices"; awk '/^N:/{n=$0} /^H:/{print n " | " $0}' /proc/bus/input/devices >> "$OUT" 2>/dev/null; }
LOG=/var/log/messages; LOGDIR=/var/local/log
# Daemon log lines stamped at or after $1 (yymmdd:HHMMSS). Reads the live
# syslog file (a few KB) instead of `showlog`, which gunzips every archived
# log (~250k lines: a second per call when idle, several on a busy wake).
# If tinyrot rotated the file inside the window, the youngest archive is
# included so nothing is missed.
logsince() {
  { first=$(head -n1 "$LOG" 2>/dev/null | cut -d' ' -f1)
    if [ -n "$first" ] && [ "${first%%:*}${first#*:}" -gt "${1%%:*}${1#*:}" ] 2>/dev/null; then
      zcat "$LOGDIR/messages_$(cat "$LOGDIR/messages_youngest" 2>/dev/null)_"*.gz 2>/dev/null
    fi
    cat "$LOG" 2>/dev/null; } | awk -v t="$1" '$1 >= t'
}
bonded_since() { logsince "$1" | grep -q "bondState:2"; }
# radio state via the daemon log ("Get RadioState status: 0 state: N"), ~1 s;
# "enable" on a radio that is already on waits 10 s for nothing, so ask first.
radio_on() {
  local t=$(stamp); w radiostate
  for i in 1 2 3 4 5 6; do sleep 1
    local st=$(logsince "$t" | grep -oE "Get RadioState status: 0 state: [0-9]" | tail -1 | grep -oE "[0-9]$")
    [ -n "$st" ] && { [ "$st" = "1" ] && return 0 || return 1; }
  done
  return 1
}
ensure_radio() {
  if radio_on; then say "radio already on"; return 0; fi
  local t=$(stamp); w enable
  for i in $(seq 1 15); do sleep 1; logsince "$t" | grep -qi "ADAPTER_STATE_CHANGED state:1\|Adapter state changing to 1\|Get RadioState status: 0 state: 1" && break; done
  say "radio switched on"
}
# keep the Kindle connectable (not discoverable) for as long as the session
# lives, renewing well inside the mode's own timeout; ends when the FIFO goes.
keepalive() {
  ( end=$(( $(cut -d. -f1 /proc/uptime) + ${1:-21600} ))
    while [ -p /tmp/ace.in ] && [ "$(cut -d. -f1 /proc/uptime)" -lt "$end" ]; do
      echo "classic discoverable n 600" > /tmp/ace.in 2>/dev/null; sleep 300
    done
    [ -p /tmp/ace.in ] && echo "exit" > /tmp/ace.in; sleep 2; rm -f /tmp/ace.in ) </dev/null >/dev/null 2>&1 &
  echo $! > "$D/keepalive.pid"
}
listening() { [ -p /tmp/ace.in ] && [ -f "$D/keepalive.pid" ] && kill -0 "$(cat "$D/keepalive.pid")" 2>/dev/null; }
say "Bookbridge Bluetooth: $STEP $A  $(date '+%F %T')"
case "$STEP" in
install)
  [ -f "$RULE" ] && [ -f "$HELPER" ] && { say "already installed"; exit 0; }
  have mntroot || { say "no mntroot on this device"; exit 1; }
  mntroot rw >> "$OUT" 2>&1 || { say "mntroot rw failed"; exit 1; }
  mkdir -p /usr/local/bin
  cat > "$HELPER" <<'SH'
#!/bin/sh
DEVICE=$1
if evtest info "$DEVICE" 2>/dev/null | grep -q 'Event type 1 (Key)'; then
  if evtest info "$DEVICE" 2>/dev/null | grep -q 'Event code 16 (Q)'; then
    echo ID_INPUT=1
    echo ID_INPUT_KEY=1
    echo ID_INPUT_KEYBOARD=1
  fi
fi
SH
  chmod 755 "$HELPER"
  cat > "$RULE" <<'RULES'
KERNEL=="uhid", MODE="0660", GROUP="bluetooth"
ACTION=="add", SUBSYSTEM=="input", IMPORT+="/usr/local/bin/dev_is_keyboard.sh %N"
RULES
  sync; mntroot ro >> "$OUT" 2>&1
  udevadm control --reload-rules >> "$OUT" 2>&1
  [ -e /dev/uhid ] && { chgrp bluetooth /dev/uhid 2>/dev/null; chmod 660 /dev/uhid 2>/dev/null; }
  say "INSTALLED"; ls -l "$HELPER" "$RULE" /dev/uhid >> "$OUT" 2>&1
  ;;
uninstall)
  mntroot rw >> "$OUT" 2>&1 && { rm -f "$RULE" "$HELPER"; sync; mntroot ro >> "$OUT" 2>&1; }
  udevadm control --reload-rules >> "$OUT" 2>&1; say "UNINSTALLED"
  ;;
pair)
  [ -n "$A" ] || { say "no address"; exit 1; }
  [ -f "$RULE" ] || { say "keyboard rule not installed"; exit 1; }
  FRESH=${3:-}   # "fresh": the phone forgot the Kindle -- drop our side of the bond and pair anew
  # Bond state first. Asked in the long session; the answer is read from the
  # daemon log, where the CLI's own "getBondState ... state: N" line appears
  # at once (its stdout is block-buffered, and piped commands never make it
  # exit, so the file can't be trusted mid-session). 2 = bonded: nothing to
  # pair, just listen. 1 = a stale half-bond: clear it. Unpairing a bonded,
  # connected phone stalled the CLI outright, so it is never done to a good bond.
  # "enable" makes the CLI wait ~10 s for the enable event before it reads
  # anything else, so the answer is polled for rather than expected at once.
  session_start; ensure_radio
  T0=$(stamp); w "bondstate $A"; bs=""
  for i in $(seq 1 25); do
    sleep 1
    bs=$(logsince "$T0" | grep -oE "getBondState status : 0 state: [0-9]" | tail -1 | grep -oE "[0-9]$")
    [ -n "$bs" ] && break
  done
  say "bond state before: ${bs:-?}"
  if [ "$bs" = "2" ] && [ -z "$FRESH" ]; then
    w "classic registerhid"; sleep 1; w "classic discoverable n 600"; sleep 1
    dump; say "BONDED $A (already paired)"; keepalive; exit 0
  fi
  w "classic discoverable y 120"; sleep 1
  if [ "$bs" = "1" ] || [ "$bs" = "2" ]; then
    # drop our side and wait for the daemon to say so (bondState:0), capped
    T1=$(stamp); w "unpair $A"
    for i in $(seq 1 15); do sleep 1; logsince "$T1" | grep -q "bondState:0" && break; done
    say "unpaired (bond state was $bs)"
  fi
  T=$(stamp); w "pair $A"; say "pairing started at $T -- confirm on the phone"
  sleep 4; bonded=0
  for i in $(seq 1 18); do
    w "passkey y"; sleep 2
    if bonded_since "$T"; then bonded=1; break; fi
  done
  if [ $bonded = 1 ]; then
    w "classic registerhid"; sleep 1; w "classic discoverable n 600"; sleep 1
    dump; say "BONDED $A"; keepalive
  else
    w "bondstate $A"; sleep 2; dump
    say "--- daemon"; logsince "$T" | grep -iE "ssp|bond|auth" | tail -6 | cut -c1-160 >> "$OUT"
    say "NOT BONDED"; session_end
  fi
  ;;
ready)
  if listening; then say "READY (already listening)"; exit 0; fi
  session_start; ensure_radio
  w "classic registerhid"; sleep 1; w "classic discoverable n 600"; sleep 1
  dump; say "READY"; keepalive
  ;;
status)
  # its own short session: must not end a "ready" session that is listening
  if have ace_bt_cli; then
    ( printf 'radiostate\nbondedlist\nconnectedlist\n'; [ -n "$A" ] && printf 'classic hidprofilestate %s\n' "$A"; printf 'exit\n'; sleep 3 ) | timeout 20 ace_bt_cli 2>&1 \
      | grep -v "No Input Parameters" | grep -v "^\s*$\|^p_data\|^ *[0-9A-F][0-9A-F] " >> "$OUT"
  else say "ace_bt_cli: not on this device"; fi
  say "rule installed: $([ -f "$RULE" ] && echo yes || echo no)"
  say "listening session: $([ -p /tmp/ace.in ] && echo open || echo none)"
  inputs
  ;;
off) session_start; w disable; sleep 2; dump; say "OFF"; session_end; rm -f "$D/keepalive.pid" ;;
unpair) [ -n "$A" ] || { say "no address"; exit 1; }; session_start; w enable; sleep 2; w "unpair $A"; sleep 2; dump; say "UNPAIRED $A"; session_end ;;
*) say "unknown step $STEP"; exit 1 ;;
esac
]==]

local function btOnKindle()
    if os.getenv("BOOKBRIDGE_BT_FORCE") then return true end
    local ok, Device = pcall(require, "device")
    return ok and Device and Device.isKindle and Device:isKindle() or false
end

-- Writes the engine to BT_DIR when missing or stale; returns its path.
local function btEnginePath()
    lfs.mkdir(BT_DIR)
    local path = BT_DIR .. "/engine.sh"
    local f = io.open(path, "r")
    local current = f and f:read("*a"); if f then f:close() end
    if current ~= BT_ENGINE then
        local out = io.open(path, "w")
        if not out then return nil end
        out:write(BT_ENGINE); out:close()
        os.execute("chmod +x '" .. path .. "'")
    end
    return path
end

local function btRuleInstalled()
    local f = io.open(BT_RULE, "r")
    if f then f:close(); return true end
    return false
end

-- Runs one engine step detached and polls for its ".done" marker once a
-- second; on_done(text, finished) gets the step's result file. Never blocks
-- KOReader: nothing here is a fork of it, and nothing waits on a pipe.
function Bookbridge:btRun(step, arg, wait_text, on_done, opts)
    opts = opts or {}
    if self._bt_running then
        -- A step left over from before a sleep is finished by now (its
        -- poll never ran while KOReader slept): let a wake-time step through.
        local f = io.open(BT_DIR .. "/" .. self._bt_running .. ".done", "r")
        if f then f:close(); self._bt_running = nil
        elseif opts.silent then
            -- a wake-time step arriving while the sleep-time one is still
            -- finishing (a quick sleep/wake): try again in a moment, a few times
            opts.retries = (opts.retries or 0) + 1
            if opts.retries <= 10 then UIManager:scheduleIn(3, function() self:btRun(step, arg, wait_text, on_done, opts) end) end
            return
        else UIManager:show(InfoMessage:new{ text = _("A Bluetooth step is still running; wait for it to finish."), timeout = 3 }); return end
    end
    local script = btEnginePath()
    if not script then UIManager:show(InfoMessage:new{ text = _("Couldn't write the Bluetooth helper script.") }); return end
    local done = BT_DIR .. "/" .. step .. ".done"
    os.remove(done)
    os.execute(string.format("BOOKBRIDGE_BT_DIR='%s' setsid sh '%s' %s %s </dev/null >/dev/null 2>&1 &", BT_DIR, script, step, arg or ""))
    if opts.fire_and_forget then debugLog("[bt] step " .. step .. " started (not tracked)"); return end
    self._bt_running = step
    debugLog("[bt] step " .. step .. (arg and (" " .. arg) or "") .. " started")
    local msg = wait_text and InfoMessage:new{ text = wait_text } or nil
    if msg then UIManager:show(msg) end
    local started = os.time()
    local function poll()
        local f = io.open(done, "r")
        local finished = f ~= nil
        if f then f:close() end
        if not finished and os.time() - started < 150 then
            UIManager:scheduleIn(1, poll)
            return
        end
        self._bt_running = nil
        if msg and UIManager:isWidgetShown(msg) then UIManager:close(msg) end
        local rf = io.open(BT_DIR .. "/" .. step .. ".txt", "r")
        local text = rf and rf:read("*a") or ""; if rf then rf:close() end
        debugLog("[bt] step " .. step .. (finished and " done" or " timed out"))
        if on_done then on_done(text, finished) end
    end
    UIManager:scheduleIn(1, poll)
end

function Bookbridge:btAskAddress(then_cb)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Phone / keyboard Bluetooth address"),
        input = self.bt_keyboard_addr or "",
        input_hint = "AA:BB:CC:DD:EE:FF",
        description = _("Entered once and kept. On the phone: Settings > About phone > Status > Bluetooth address. (The Kindle isn't shown scan results by its own Bluetooth stack, so it can't find the phone by name.)"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local a = (dialog:getInputText() or ""):upper():match("(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)")
                if not a then
                    UIManager:show(InfoMessage:new{ text = _("That doesn't look like a Bluetooth address (six pairs like AA:BB:CC:DD:EE:FF).") })
                    return
                end
                UIManager:close(dialog)
                self.bt_keyboard_addr = a
                self:saveAllSettings(T(_("Saved %1."), a))
                if then_cb then then_cb(a) end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- One tap: rule (installed once, with a confirmation), address (asked once),
-- then pair; the phone's prompt is confirmed from here; the moment the bond
-- lands the Kindle is already listening for the keyboard link.
function Bookbridge:btPair(fresh)
    local function pair(addr)
        self:btRun("pair", addr .. (fresh and " fresh" or ""), _("Pairing... when the phone shows \"Pair with Kindle?\", tap Pair.\n\nThis finishes by itself, usually within 15 seconds."), function(text, finished)
            if text:find("BONDED " .. addr, 1, true) then
                self:btWatchLink(180)
                local already = text:find("already paired", 1, true) ~= nil
                if already then
                    -- The Kindle holds a bond; if the phone no longer lists
                    -- "Kindle", that bond is one-sided and must be redone.
                    local ConfirmBox = require("ui/widget/confirmbox")
                    UIManager:show(ConfirmBox:new{
                        text = _("Already paired with this phone, and the Kindle is listening.\n\nOpen the keyboard app on the phone and choose \"Kindle\".\n\nIf the phone no longer lists Kindle in its Bluetooth settings, pair again from scratch instead."),
                        ok_text = _("OK"),
                        cancel_text = _("Pair from scratch"),
                        cancel_callback = function() self:btPair(true) end,
                    })
                else
                    UIManager:show(InfoMessage:new{ text = _("Paired, and the Kindle is listening.\n\nNow open the keyboard app on the phone and choose \"Kindle\". KOReader picks the keyboard up by itself.") })
                end
            else
                local TextViewer = require("ui/widget/textviewer")
                UIManager:show(TextViewer:new{ title = _("Pairing did not complete"), text = text, justified = false })
            end
        end)
    end
    local function with_rule(addr)
        if btRuleInstalled() then pair(addr); return end
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = _("First time: two small files are written to the system so the Bluetooth stack may take a keyboard (the root filesystem is made writable and set back to read-only). Reversible from this menu.\n\nContinue?"),
            ok_text = _("Install and pair"),
            ok_callback = function()
                self:btRun("install", nil, _("Installing the keyboard rule..."), function(text)
                    if text:find("INSTALLED", 1, true) then pair(addr)
                    else UIManager:show(InfoMessage:new{ text = _("The keyboard rule could not be installed:\n\n") .. text }) end
                end)
            end,
        })
    end
    -- Inherit the address the earlier stand-alone plugin kept in a file.
    if not self.bt_keyboard_addr then
        local f = io.open(BT_DIR .. "/address.txt", "r")
        local a = f and (f:read("*a") or ""):match("(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)")
        if f then f:close() end
        if a then self.bt_keyboard_addr = a:upper(); self:saveAllSettings(T(_("Using the saved phone address %1."), self.bt_keyboard_addr)) end
    end
    if self.bt_keyboard_addr then with_rule(self.bt_keyboard_addr) else self:btAskAddress(with_rule) end
end

-- After a ready/pair: say so the moment the keyboard link comes up (the
-- phone appears as a new /dev/input/eventN), once per link.
function Bookbridge:btWatchLink(seconds)
    local deadline = os.time() + (seconds or 120)
    local function present()
        local f = io.open("/proc/bus/input/devices", "r")
        if not f then return false end
        local t = f:read("*a"); f:close()
        return t:find("event[2-9]") ~= nil
    end
    if present() then self._bt_link_seen = true; return end
    self._bt_link_seen = false
    local function poll()
        if self._bt_link_seen then return end
        if present() then
            self._bt_link_seen = true
            debugLog("[bt] keyboard link up")
            UIManager:show(InfoMessage:new{ text = _("Keyboard connected."), timeout = 3 })
            return
        end
        if os.time() < deadline then UIManager:scheduleIn(2, poll) end
    end
    UIManager:scheduleIn(2, poll)
end

function Bookbridge:btReady(silent)
    if not self.bt_keyboard_addr and not silent then self:btAskAddress(function() self:btReady() end); return end
    self:btRun("ready", self.bt_keyboard_addr, (not silent) and _("Getting ready for the keyboard...") or nil, function(text)
        if text:find("READY", 1, true) then self:btWatchLink(180) end
        if silent then return end
        if text:find("READY", 1, true) then
            UIManager:show(InfoMessage:new{ text = _("Listening. Choose \"Kindle\" in the phone's keyboard app -- the Kindle stays connectable while it's awake."), timeout = 5 })
        else
            local TextViewer = require("ui/widget/textviewer")
            UIManager:show(TextViewer:new{ title = _("Bluetooth"), text = text, justified = false })
        end
    end, { silent = silent })
end

function Bookbridge:btMenuEntry()
    return {
        text = _("Bluetooth keyboard"),
        sub_item_table = {
            {
                text = _("Pair the phone (or a keyboard)"),
                help_text = _("Kindle-initiated pairing. The phone shows a code and asks to pair; tap Pair there. Nothing to type here after the first time."),
                callback = function() self:btPair() end,
            },
            {
                text = _("Ready for keyboard now"),
                help_text = _("Radio on and connectable for as long as the Kindle is awake (about 2 seconds when the radio is already on). Then choose Kindle in the phone's keyboard app -- the phone starts the link; the Kindle only listens."),
                enabled_func = function() return btRuleInstalled() end,
                callback = function() self:btReady(false) end,
            },
            {
                text = _("Keep Bluetooth ready when the Kindle wakes"),
                help_text = _("Radio on and connectable whenever KOReader is awake, off again when it sleeps -- reconnecting is just choosing Kindle in the phone's app. Costs a little battery while awake."),
                keep_menu_open = true,   -- the check mark flips in place, like the Hardcover sync toggle
                checked_func = function() return self.bt_ready_on_wake == true end,
                enabled_func = function() return btRuleInstalled() and self.bt_keyboard_addr ~= nil end,
                callback = function()
                    self.bt_ready_on_wake = not self.bt_ready_on_wake
                    self:saveAllSettings(self.bt_ready_on_wake and _("On: the Kindle listens for the keyboard whenever it wakes.") or _("Off."))
                end,
            },
            {
                text_func = function()
                    return self.bt_keyboard_addr and T(_("Phone address: %1"), self.bt_keyboard_addr) or _("Phone address: not set")
                end,
                keep_menu_open = true,
                callback = function() self:btAskAddress() end,
            },
            {
                text = _("Status"),
                keep_menu_open = true,
                callback = function()
                    self:btRun("status", self.bt_keyboard_addr, _("Checking..."), function(text)
                        local TextViewer = require("ui/widget/textviewer")
                        UIManager:show(TextViewer:new{ title = _("Bluetooth status"), text = text, justified = false })
                    end)
                end,
            },
            {
                text = _("Bluetooth off"),
                callback = function() self:btRun("off", nil, nil, function() UIManager:show(InfoMessage:new{ text = _("Bluetooth is off."), timeout = 2 }) end) end,
            },
            {
                text = _("Forget the paired phone"),
                enabled_func = function() return self.bt_keyboard_addr ~= nil end,
                callback = function()
                    local addr = self.bt_keyboard_addr
                    self:btRun("unpair", addr, _("Forgetting..."), function()
                        self.bt_keyboard_addr = nil; self.bt_ready_on_wake = nil
                        self:saveAllSettings(_("Forgotten. Also remove \"Kindle\" from the phone's Bluetooth list."))
                    end)
                end,
            },
            {
                text_func = function() return btRuleInstalled() and _("Uninstall keyboard rule") or _("Install keyboard rule (one time)") end,
                keep_menu_open = true,
                callback = function()
                    local step = btRuleInstalled() and "uninstall" or "install"
                    self:btRun(step, nil, nil, function(text)
                        local TextViewer = require("ui/widget/textviewer")
                        UIManager:show(TextViewer:new{ title = _("Keyboard rule"), text = text, justified = false })
                    end)
                end,
            },
        },
    }
end

function Bookbridge:addToMainMenu(menu_items)
    menu_items.bookbridge = {
        text = _("Bookbridge"),
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
                -- Trapper:wrap, like every other network entry point in this
                -- menu. This one was missing it, which meant syncLibrary ran
                -- on the main thread instead of in a coroutine, and
                -- Trapper:dismissableRunInSubprocess had nothing to yield to:
                -- the whole sync blocked the UI loop rather than running
                -- alongside it. Invisible while the sync only ever showed a
                -- static message -- a blocked loop still paints that once --
                -- but it meant the progress bar's poll was never serviced and
                -- its dialog never repainted until the run was already over,
                -- i.e. no bar at all. Cancelling was equally dead for the
                -- same reason.
                callback = function()
                    local Trapper = require("ui/trapper")
                    Trapper:wrap(function() self:syncLibrary() end)
                end,
            },
            {
                -- Only appears when a sync actually left something
                -- unresolved and a relay is configured, so it stays out of
                -- the way the rest of the time.
                text_func = function()
                    return T(_("Review %1 unmatched book(s)"),
                        self.pending_unmatched and #self.pending_unmatched or 0)
                end,
                enabled_func = function()
                    return self.pending_unmatched ~= nil and #self.pending_unmatched > 0
                        and self.ai_relay_url ~= nil and self.ai_relay_url ~= ""
                end,
                keep_menu_open = true,
                callback = function()
                    local Trapper = require("ui/trapper")
                    Trapper:wrap(function()
                        self:reviewUnmatched(self.pending_unmatched, 1)
                    end)
                end,
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
                    {
                        text = _("Hardcover settings"),
                        keep_menu_open = true,
                        callback = function() self:editHardcoverSettings() end,
                    },
                    {
                        text = _("Sync reading progress to Hardcover"),
                        keep_menu_open = true,
                        checked_func = function() return self.hardcover_progress_sync == true end,
                        callback = function()
                            self.hardcover_progress_sync = not self.hardcover_progress_sync
                            self:saveAllSettings(self.hardcover_progress_sync
                                and _("On. Progress syncs silently when you close a book or the device sleeps; anything Hardcover can't be sure of waits under Review matches.")
                                or _("Off."))
                        end,
                    },
                    {
                        text_func = function()
                            local n = 0
                            for _unused, e in pairs(loadHardcoverMap()) do if e.decision == "review" then n = n + 1 end end
                            return n > 0 and T(_("Review Hardcover matches (%1)"), n) or _("Review Hardcover matches")
                        end,
                        keep_menu_open = true,
                        callback = function()
                            local Trapper = require("ui/trapper")
                            Trapper:wrap(function() self:reviewHardcoverMatches() end)
                        end,
                    },
                    {
                        -- Answering "No" -- or, before build 9b45e72, a stray
                        -- tap that dismissed the dialog and fired its cancel
                        -- callback -- records a book as never-sync for good.
                        -- Without this there is no way back short of deleting
                        -- the map file by hand over USB.
                        text_func = function()
                            local n = 0
                            for _unused in pairs(loadHardcoverMap()) do n = n + 1 end
                            return n > 0 and T(_("Forget Hardcover book choices (%1)"), n)
                                or _("Forget Hardcover book choices")
                        end,
                        keep_menu_open = true,
                        enabled_func = function() return next(loadHardcoverMap()) ~= nil end,
                        callback = function()
                            local ConfirmBox = require("ui/widget/confirmbox")
                            local skipped, synced = 0, 0
                            for _unused, e in pairs(loadHardcoverMap()) do
                                if e.decision == "skip" then skipped = skipped + 1
                                elseif e.decision == "sync" then synced = synced + 1 end
                            end
                            UIManager:show(ConfirmBox:new{
                                text = T(_("Forget every remembered Hardcover choice?\n\n%1 set to never sync\n%2 matched to a book\n\nEach book asks again the next time you close it."),
                                    skipped, synced),
                                ok_text = _("Forget"),
                                ok_callback = function()
                                    saveHardcoverMap({})
                                    UIManager:show(InfoMessage:new{
                                        text = _("Hardcover choices cleared. Close a book to be asked again."),
                                    })
                                end,
                            })
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
                        text = _("Connections"),
                        sub_item_table = {
                            {
                                text = _("Shelfmark server settings"),
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
                                text = _("Match suggestions (AI)"),
                                keep_menu_open = true,
                                callback = function() self:editAiSettings() end,
                            },
                            {
                                text = _("Connection status"),
                                keep_menu_open = true,
                                callback = function()
                                    local Trapper = require("ui/trapper")
                                    Trapper:wrap(function() self:showConnectionStatus() end)
                                end,
                            },
                        },
                    },
                    {
                        text = _("Set up another device"),
                        separator = true,
                        sub_item_table = {
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
                                text = _("Import from server"),
                                keep_menu_open = true,
                                callback = function() self:importFromServer() end,
                            },
                        },
                    },
                    {
                        text_func = function()
                            return T(_("Download folder: %1"), self.download_dir or self:defaultDownloadDir())
                        end,
                        keep_menu_open = true,
                        callback = function() self:chooseDownloadDir() end,
                    },
                    {
                        text_func = function()
                            return T(_("Update source: %1"),
                                (self.update_url and self.update_url ~= "") and _("self-hosted") or _("GitHub"))
                        end,
                        keep_menu_open = true,
                        callback = function() self:editUpdateSettings() end,
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
                        text = _("Install updates automatically"),
                        help_text = _("Checks the self-hosted update source quietly when the device wakes, reconnects, or starts (at most every six hours) and installs what it finds. Only the restart is asked about."),
                        checked_func = function() return self.auto_update and true or false end,
                        enabled_func = function() return self.update_url and self.update_url ~= "" end,
                        keep_menu_open = true,
                        callback = function()
                            self.auto_update = not self.auto_update
                            self:saveAllSettings()
                        end,
                    },
                    {
                        text = _("View debug log"),
                        keep_menu_open = true,
                        callback = function() self:showDebugLog() end,
                    },
                    {
                        text = _("Send debug log to server"),
                        keep_menu_open = true,
                        callback = function()
                            local Trapper = require("ui/trapper")
                            Trapper:wrap(function() self:sendDebugLog() end)
                        end,
                    },
                },
            },
        },
    }
    if btOnKindle() then
        local items = menu_items.bookbridge.sub_item_table
        local at = #items + 1
        for k, it in ipairs(items) do if it.text == _("Settings") then at = k; break end end
        table.insert(items, at, self:btMenuEntry())
    end
end

-- "Send debug log to server". Must run inside a Trapper:wrap (the menu
-- callback provides one): the upload runs in a subprocess behind a
-- dismissable progress box, so a slow link never freezes the UI.
function Bookbridge:sendDebugLog()
    if not self.pairing_relay_url or self.pairing_relay_url == "" then
        -- The relay URL is only ever asked for on first use of pairing, so a
        -- device that never paired has none. Ask with the same prompt, then
        -- come back here -- inside a fresh wrap, since the prompt's button
        -- callback runs outside this one.
        self:promptPairingRelayUrl(function()
            local Trapper = require("ui/trapper")
            Trapper:wrap(function() self:sendDebugLog() end)
        end)
        return
    end
    -- A header the reader of the file will want before anything else: what
    -- device, what KOReader, which plugin build.
    local Device = require("device")
    local ok_v, Version = pcall(require, "version")
    local rev = (ok_v and type(Version) == "table" and Version.getCurrentRevision and Version:getCurrentRevision()) or "?"
    -- What the updater last installed, if it ever ran here; otherwise the
    -- manifest the plugin was originally zipped with.
    local build = "?"
    local marker = io.open(tostring(self.path or "") .. "/installed-build", "r")
    if marker then
        build = (marker:read("*l") or ""):gsub("^%s+", ""):gsub("%s+$", "")
        marker:close()
        if build == "" then build = "?" end
    else
        local mf = io.open(tostring(self.path or "") .. "/manifest.json", "r")
        if mf then
            local m = mf:read("*a"); mf:close()
            build = (m:match('"build"%s*:%s*"([^"]+)"') or build) .. " (original install)"
        end
    end
    local parts = { string.format(
        "# shelfmark debug log\n# sent: %s\n# device: %s (android=%s, eink=%s)\n# koreader: %s\n# plugin build: %s\n\n",
        os.date("%Y-%m-%d %H:%M:%S"), tostring(Device.model), tostring(Device:isAndroid()),
        tostring(Device:hasEinkScreen()), tostring(rev), build) }
    for _unused, path in ipairs({ DEBUG_LOG_PREV_PATH, DEBUG_LOG_PATH }) do
        local f = io.open(path, "r")
        if f then parts[#parts + 1] = f:read("*a"); f:close() end
    end
    local text = table.concat(parts)
    local max_bytes = 480 * 1024   -- the relay refuses over 512 KB
    if #text > max_bytes then text = parts[1] .. "...\n" .. text:sub(-max_bytes) end
    local relay_url, socks5_proxy = self.pairing_relay_url, self.socks5_proxy
    local Trapper = require("ui/trapper")
    local completed, id, _code, err = Trapper:dismissableRunInSubprocess(function()
        return doDebugLogUpload(relay_url, text, socks5_proxy)
    end, _("Sending debug log..."))
    if not completed then return end
    if id then
        UIManager:show(InfoMessage:new{ text = T(_("Debug log sent. It's filed on the server as %1"), id) })
    else
        UIManager:show(InfoMessage:new{ text = err or _("Couldn't send the debug log.") })
    end
end

function Bookbridge:showDebugLog()
    local TextViewer = require("ui/widget/textviewer")
    -- Reads the rotated .1 ahead of the live file (see debugLog's rotation
    -- note) and concatenates: right after a rotation the live file holds
    -- only a line or two, and a viewer that went nearly empty the moment the
    -- log filled up would be useless at exactly the wrong time. Reading both
    -- means the tail-trim below always has the real recent history to cut
    -- from, whichever side of a rotation we happen to be on.
    local parts = {}
    for _, path in ipairs({ DEBUG_LOG_PREV_PATH, DEBUG_LOG_PATH }) do
        local f = io.open(path, "r")
        if f then
            parts[#parts + 1] = f:read("*a")
            f:close()
        end
    end
    local content = table.concat(parts)
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
                                -- The rotated half too, or "clear" would
                                -- leave up to DEBUG_LOG_MAX_BYTES on disk
                                -- and the viewer would still show it.
                                pcall(os.remove, DEBUG_LOG_PREV_PATH)
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

function Bookbridge:startSearch()
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
-- caller_menu, when given, is closed here rather than by the caller before
-- invoking this -- keeps whatever menu the reader is coming from on screen
-- through this function's own synchronous setup, so the screen doesn't go
-- blank (revealing whatever's underneath) before apiRequest's own Trapper
-- progress dialog appears. The standalone "Searching..." toast that used to
-- be here was removed for the same reason: apiRequest already shows its own
-- "Talking to Shelfmark..." dialog for this exact wait, so it was a second,
-- redundant refresh announcing the same thing.
function Bookbridge:doSearch(params, existing_books, caller_menu)
    if caller_menu then UIManager:close(caller_menu) end

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

    -- Per explicit request: status lists (Currently Reading/Read/etc, via
    -- browseHardcoverLists) show whichever specific edition happens to be
    -- logged on Hardcover -- some of those carry no cover or a negligible
    -- reader count next to a far more popular edition of the exact same
    -- book (confirmed live: Blake Crouch's "Run" has three duplicate,
    -- unlogged editions with 0 readers each, while the one actually logged
    -- has 369). Substitutes the most-popular edition's title/cover for
    -- *display* only -- book.provider_id is left untouched, so
    -- browseReleases/downloading still act on the edition that's actually
    -- logged, not the one just being shown. Only ever set from
    -- browseHardcoverLists's own call, never for a plain keyword search.
    if params.prefer_popular_edition and self.hardcover_token and self.hardcover_token ~= "" then
        local ids = {}
        for _, book in ipairs(resp.books) do
            if book.provider == "hardcover" and book.provider_id then
                local id = tonumber(book.provider_id)
                if id then table.insert(ids, id) end
            end
        end
        if #ids > 0 then
            local substitutions = self:hardcoverBestEditions(ids)
            for _, book in ipairs(resp.books) do
                local id = tonumber(book.provider_id)
                local sub = id and substitutions[id]
                if sub then
                    book.title = sub.title
                    if sub.cover_url then book.cover_url = sub.cover_url end
                end
            end
        end
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

    -- Hardcover's own list labels already end in a count of their own
    -- (e.g. "Read (5)") -- confirmed live, appending another unconditionally
    -- produced "Read (5) (5)" on the browseHardcoverLists screen. Only add
    -- one when title_override doesn't already end with "(<number>)".
    local menu_title
    if params.title_override then
        if params.title_override:match("%(%d+%)%s*$") then
            menu_title = params.title_override
        else
            menu_title = T(_("%1 (%2)"), params.title_override, #books)
        end
    else
        menu_title = T(_("Search results (%1)"), #books)
    end

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
            if item.is_load_more then
                local Trapper = require("ui/trapper")
                Trapper:wrap(function()
                    self:doSearch({
                        query = params.query,
                        author = params.author,
                        fields = params.fields,
                        limit = params.limit,
                        title_override = params.title_override,
                        prefer_popular_edition = params.prefer_popular_edition,
                        page = (params.page or 1) + 1,
                    }, books, results_menu)
                end)
            else
                local Trapper = require("ui/trapper")
                Trapper:wrap(function()
                    self:browseReleases(item.book_data, defaultReleaseQuery(item.book_data), results_menu)
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

-- Full, scrollable rendering of one release for the confirm dialog -- the
-- list row above has to stay a single line, so it can only ever show a few
-- bullet-joined bits. This exists so a release can actually be judged before
-- committing to it (is this the copy with a real author and a sane format,
-- or the mangled one?).
--
-- Two rules that are easy to get wrong here:
--
--  * stripJsonNull turns JSON null into `false`, NOT nil (see its own note).
--    So a plain truthiness test would happily print the literal string
--    "false" as a field value. Everything below is type-gated to string or
--    number instead.
--  * Values are interpolated into a PTF (bold-markup) string, so a value
--    containing PTF bytes itself could corrupt the bold spans for the rest
--    of the dialog. They're stripped per value.
--
-- Unknown fields are deliberately surfaced rather than hidden: Shelfmark's
-- /api/releases schema isn't documented anywhere local, so anything scalar
-- that isn't already rendered above gets listed at the end. That way a field
-- this file has never heard of still shows up instead of being silently
-- dropped.
local RELEASE_DETAIL_KNOWN = {
    title = true, format = true, size = true, indexer = true, peers = true,
    seeders = true, source = true, md5 = true, extra = true,
    annas_author = true, annas_url = true, cover_url = true,
    year = true, language = true, content_type = true, meta_line = true,
}

-- Compact rendering of one release for the confirm dialog. Deliberately
-- short: this is a decision aid, not a record dump. Everything that helps
-- you choose between two copies of the same book is here; everything that
-- doesn't (md5, the raw AA url, internal ids) is not.
--
-- Layout is one bold title, then the author, then a single bullet-joined
-- specs line, then the source line, then the book's description -- rather
-- than a label-per-line list, which ran to a dozen mostly-empty rows.
--
-- book is optional and carries the Hardcover-sourced metadata Shelfmark
-- already fetched for the search results (description, publisher, series,
-- genres). It costs nothing extra -- it's in memory by the time a release
-- list exists -- and it's the only place a description is available at all:
-- Anna's Archive's search results genuinely don't carry one.
--
-- Two rules that are easy to get wrong:
--  * stripJsonNull turns JSON null into `false`, NOT nil, so a plain
--    truthiness test would print the literal "false". Everything is
--    type-gated to string/number instead.
--  * Values are interpolated into a PTF (bold-markup) string, so PTF bytes
--    inside a value would corrupt the bold spans for everything after it.
--    They're stripped per value.
local function describeReleaseDetail(release, book)
    local function clean(v, limit)
        if type(v) == "number" then v = tostring(v) end
        if type(v) ~= "string" then return nil end
        v = v:gsub("\xEF\xBF\xB1", ""):gsub("\xEF\xBF\xB2", ""):gsub("\xEF\xBF\xB3", "")
        v = v:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        if v == "" then return nil end
        -- truncate(), never sub() -- a mid-character cut on a multi-byte
        -- title caused native, untraceable crashes before.
        return truncate(v, limit or 300)
    end

    local lines = {}
    local function addLineRaw(text) lines[#lines + 1] = text end

    local title = clean(release.title, 200)
    if title then
        addLineRaw(PTF_BOLD_START .. title .. PTF_BOLD_END)
    end

    -- Author: the release's own (AA folds it into the title, so this is the
    -- only separated copy) falling back to the book's.
    local author = clean(release.annas_author, 120)
        or (book and clean(describeAuthor(book), 120))
    if author and author ~= "" then addLineRaw(author) end

    -- One specs line: the things you actually compare copies on.
    local specs = {}
    local function spec(v, suffix)
        local c = clean(v, 60)
        if c then specs[#specs + 1] = c .. (suffix or "") end
    end
    spec(release.format and tostring(release.format):upper())
    spec(release.size)
    spec(release.year or (book and book.publish_year))
    spec(release.language)
    spec(release.seeders, "S")
    spec(release.peers)
    spec(release.extra and release.extra.grabs, "G")
    if #specs > 0 then
        addLineRaw("")
        addLineRaw(table.concat(specs, " • "))
    end

    -- Provenance line.
    local src = {}
    local ind = clean(release.indexer, 60)
    if ind then src[#src + 1] = ind end
    local pub = book and clean(book.publisher, 60)
    if pub then src[#src + 1] = pub end
    if #src > 0 then addLineRaw(table.concat(src, " • ")) end

    -- Series, when the book is part of one.
    if book then
        local sname = clean(book.series_name, 80)
        if sname then
            local pos = clean(book.series_position, 10)
            addLineRaw(pos and (sname .. " #" .. pos) or sname)
        end
    end

    -- The description, last and longest. Kept to a readable excerpt rather
    -- than a full blurb -- the widget scrolls, but this dialog is meant to
    -- be skimmed before committing, not read.
    local desc = book and clean(book.description, 700)
    if desc then
        addLineRaw("")
        addLineRaw(desc)
    end

    if #lines == 0 then
        return PTF_HEADER .. _("No details available for this release.")
    end
    -- PTF_HEADER must be the literal first bytes of the string for
    -- TextBoxWidget to parse the bold markup at all.
    return PTF_HEADER .. table.concat(lines, "\n")
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
        -- Carried through purely for the detail view (describeReleaseDetail).
        -- The API returns exactly seven keys -- title, author, format,
        -- downloads, cover_url, url, md5 (confirmed live) -- and three of
        -- them used to be dropped here. author especially: it gets folded
        -- into `title` above for the list row, so without this there was no
        -- way to show it as its own field. Nothing else reads these, and AA
        -- releases never reach submitRequest (confirmReleaseRequest branches
        -- to downloadFromAnnasArchive first), so nothing new is sent
        -- anywhere.
        annas_author = (type(result.author) == "string" and result.author ~= "") and result.author or nil,
        -- size/year/language/content_type were being scraped by
        -- annas-archive-api and thrown away; it now keeps them (see
        -- parseMetaLine in lib/annas.js). All optional -- AA records are
        -- routinely missing a year or a language -- so each stays nil rather
        -- than becoming a guess, and describeReleaseDetail simply omits an
        -- absent field.
        size = (type(result.size) == "string" and result.size ~= "") and result.size or nil,
        year = (type(result.year) == "string" and result.year ~= "") and result.year or nil,
        language = (type(result.language) == "string" and result.language ~= "") and result.language or nil,
        content_type = (type(result.content_type) == "string" and result.content_type ~= "") and result.content_type or nil,
        annas_url = (type(result.url) == "string" and result.url ~= "") and result.url or nil,
        cover_url = (type(result.cover_url) == "string" and result.cover_url ~= "") and result.cover_url or nil,
    }
end

-- Entry point: runs the Anna's Archive search, and only when it fails
-- specifically because the mirror looks dead (err_code "MIRROR_DOWN", not a
-- bad key, a bot challenge, or a plain "no results") offers to look for a
-- working one before falling through to Prowlarr -- see mirror-watch.js in
-- annas-archive-api for why this is a manual, on-demand action rather than
-- something checked automatically in the background.
-- caller_menu, when given, is closed here rather than by the caller before
-- invoking this -- see the identical note on doSearch's own caller_menu.
-- Only needed on this, the entry point: annasSearch retries below already
-- run after caller_menu has been closed on the very first call.
function Bookbridge:browseReleases(book, manual_query, caller_menu)
    if caller_menu then UIManager:close(caller_menu) end

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
        -- Automatic mirror recovery (no prompt). The annas-archive-api
        -- service verifies a candidate is really Anna's Archive before
        -- switching (see isMirrorAlive in mirror-watch.js), so this never
        -- silently sends the donator key to a squatted parking page. We are
        -- already inside the caller's Trapper wrap, so annasMirrorRefresh's
        -- network round-trip doesn't need its own. A depth guard stops an
        -- endless switch/retry loop if a "working" mirror keeps failing.
        local attempt = (self._aa_mirror_attempt or 0) + 1
        self._aa_mirror_attempt = attempt
        if attempt <= 3 then
            local result = self:annasMirrorRefresh()
            if result and result.switched then
                UIManager:show(InfoMessage:new{
                    text = T(_("Anna's Archive mirror was down — switched to annas-archive.%1, searching again..."), result.activeTld),
                    timeout = 2,
                })
                self:browseReleases(book, manual_query)
                return
            elseif result and not result.allDead then
                -- The current mirror tested fine now: the failure was a blip.
                -- Retry the same search rather than bothering the user.
                self:browseReleases(book, manual_query)
                return
            end
        end
        -- Every known mirror is unreachable, or we have retried enough:
        -- fall through to the other sources rather than dead-ending.
        self._aa_mirror_attempt = nil
        UIManager:show(InfoMessage:new{
            text = _("Anna's Archive is unreachable right now — searching other sources."),
            timeout = 3,
        })
        self:browseReleasesContinue(book, manual_query, nil)
        return
    end

    self._aa_mirror_attempt = nil
    self:browseReleasesContinue(book, manual_query, aa_results)
end

function Bookbridge:browseReleasesContinue(book, manual_query, aa_results)
    local releases
    if aa_results and #aa_results > 0 then
        releases = {}
        for _, r in ipairs(aa_results) do
            table.insert(releases, annasResultToRelease(r))
        end
    end

    if not releases then
        -- No standalone "Searching..." toast here -- the apiRequest call
        -- below already shows its own Trapper progress dialog with a more
        -- specific message for this exact wait; a toast first would just be
        -- a second, redundant refresh announcing the same thing.
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
            -- releases_menu is deliberately NOT closed here any more. The
            -- detail dialog opens on top of it, so "Back" is just closing
            -- that dialog -- the list underneath keeps its scroll position,
            -- page and already-downloaded covers, because nothing re-runs
            -- updateItems (which is also what stops attachCoverSupport from
            -- re-fetching every cover on the way back). The commit paths
            -- close it themselves, via the caller_menu passed below.
            --
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
                    self:promptCustomReleaseQuery(book, manual_query, releases_menu)
                else
                    self:confirmReleaseRequest(book, item.release_data, releases_menu)
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
        -- Wrapped even though this function's own body already runs inside a
        -- coroutine: the note above ("both call sites ensure this") holds for
        -- the body, not for this callback. A ConfirmBox callback fires from
        -- the UI loop later, by which point that coroutine has returned, so
        -- hardcoverSetStatus's fork had nothing to yield to and froze the UI
        -- for the length of the write.
        ok_callback = function()
            local Trapper = require("ui/trapper")
            Trapper:wrap(function()
                local ok, set_err = self:hardcoverSetStatus(id, status_id)
                UIManager:show(InfoMessage:new{
                    text = ok and T(_("Marked as %1 on Hardcover."), status_label) or (set_err or _("Failed to update Hardcover.")),
                    timeout = ok and 2 or nil,
                })
            end)
        end,
    })
end

-- Shared by the manual "Follow an author..." menu flow and the long-press
-- action below -- same search/confirm/write shape as the function above.
local function confirmAndFollowAuthorOnHardcover(self, author_name)
    local candidates, err = self:hardcoverFindAuthors(author_name)
    if not candidates then
        UIManager:show(InfoMessage:new{ text = err or _("Search failed.") })
        return
    end
    if #candidates == 0 then
        UIManager:show(InfoMessage:new{ text = _("No matching author found on Hardcover.") })
        return
    end

    local function followById(id, name)
        local Trapper = require("ui/trapper")
        Trapper:wrap(function()
            local ok, follow_err = self:hardcoverFollowAuthor(id)
            UIManager:show(InfoMessage:new{
                text = ok and T(_("Now following %1 on Hardcover."), name) or (follow_err or _("Failed to follow.")),
                timeout = ok and 2 or nil,
            })
        end)
    end

    -- A lone match keeps the old one-tap confirm; no point showing a
    -- single-row picker.
    if #candidates == 1 then
        local a = candidates[1]
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = T(_("Found \"%1\" on Hardcover. Follow this author?"), a.name),
            ok_text = _("Follow"),
            ok_callback = function() followById(a.id, a.name) end,
        })
        return
    end

    -- Several matches: let the reader choose instead of guessing. The book
    -- count disambiguates the real author from summary/study-guide accounts
    -- that Hardcover's search ranks alongside them.
    local item_table = {}
    -- Not `for _, a` -- `_` is gettext, and shadowing it with the loop index
    -- would turn the _("...") calls just below into "call a number" errors.
    for _idx, a in ipairs(candidates) do
        local label = a.name
        if a.books_count and a.books_count > 0 then
            local count = a.books_count == 1
                and T(_("%1 book"), tostring(a.books_count))
                or T(_("%1 books"), tostring(a.books_count))
            label = T(_("%1  (%2)"), a.name, count)
        end
        item_table[#item_table + 1] = { text = label, author_id = a.id, author_name = a.name }
    end

    local menu
    menu = Menu:new{
        title = T(_("Authors matching \"%1\""), author_name),
        item_table = item_table,
        onMenuSelect = function(_menu_self, item)
            UIManager:close(menu)
            followById(item.author_id, item.author_name)
        end,
    }
    UIManager:show(menu)
end

-- Long-press-on-cover entry point (see registerFileDialogButtons below) --
-- the title is already known from the file itself, so this skips straight
-- to search+confirm with no typing at all.
function Bookbridge:promptHardcoverLogBookForFile(title, author, status_id, status_label)
    if not self.hardcover_token or self.hardcover_token == "" then
        UIManager:show(InfoMessage:new{ text = _("Set your Hardcover API token in Settings first.") })
        return
    end
    confirmAndLogBookOnHardcover(self, title, author, status_id, status_label)
end

function Bookbridge:promptHardcoverFollowAuthor()
    if not self.hardcover_token or self.hardcover_token == "" then
        UIManager:show(InfoMessage:new{ text = _("Set your Hardcover API token in Settings first.") })
        return
    end
    promptHardcoverText(_("Follow an author on Hardcover"), _("Author name"), function(name)
        confirmAndFollowAuthorOnHardcover(self, name)
    end)
end

-- Long-press-on-cover entry point -- see promptHardcoverLogBookForFile above.
function Bookbridge:promptHardcoverFollowAuthorForFile(author_name)
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
function Bookbridge:browseHardcoverLists()
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
            local Trapper = require("ui/trapper")
            Trapper:wrap(function()
                self:doSearch({
                    fields = { hardcover_list = item.value },
                    limit = 30,
                    title_override = item.label,
                    prefer_popular_edition = true,
                }, nil, lists_menu)
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
function Bookbridge:browseFollowedAuthors()
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
            local Trapper = require("ui/trapper")
            Trapper:wrap(function()
                self:browseAuthorBibliography(item.author_id, item.author_name, 0, nil, authors_menu)
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
-- caller_menu, when given, is closed here rather than by the caller before
-- invoking this -- see the identical note on doSearch's own caller_menu.
function Bookbridge:browseAuthorBibliography(author_id, author_name, offset, existing_books, caller_menu)
    if caller_menu then UIManager:close(caller_menu) end

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
            local Trapper = require("ui/trapper")
            if item.is_load_more then
                Trapper:wrap(function()
                    self:browseAuthorBibliography(author_id, author_name or resolved_name, #books, books, bibliography_menu)
                end)
            else
                Trapper:wrap(function()
                    self:browseReleases(item.book_data, defaultReleaseQuery(item.book_data), bibliography_menu)
                end)
            end
        end,
    }
    attachCoverSupport(bibliography_menu, self)
    UIManager:show(bibliography_menu)
end

-- caller_menu is the releases_menu this was opened from, now left open
-- underneath (see onMenuSelect). Cancelling therefore just reveals the list
-- again, and a submitted query hands it to browseReleases, which closes it
-- itself -- the same caller_menu contract used throughout this file.
function Bookbridge:promptCustomReleaseQuery(book, prefill, caller_menu)
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
                            Trapper:wrap(function() self:browseReleases(book, query, caller_menu) end)
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
function Bookbridge:showResilientConfirmBox(opts)
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

-- TextViewer counterpart to showResilientConfirmBox above, for dialogs that
-- need a scrollable multi-field body and more than two buttons (the release
-- detail view). Same external-close protection, same "always build a fresh
-- instance on retry" rule -- see that function's note on why re-showing a
-- torn-down widget crashes the app outright.
--
-- One difference that matters, and is easy to get wrong: TextViewer's own
-- onClose does UIManager:close(self) FIRST and only then calls
-- close_callback, so a close_callback-based dismissed flag would be set too
-- late -- onCloseWidget has already run and would read it as an external
-- close, re-showing a dialog the user deliberately dismissed. The flag is
-- therefore set by overriding the instance's onClose, which every legitimate
-- dismissal routes through (Close button, titlebar X, tap-outside,
-- multiswipe, and the Kindle's physical Back key).
--
-- opts.buttons is a list of { text = ..., callback = ... }; each callback is
-- wrapped to mark the dialog dismissed and close it before running, so a
-- button never has to remember to do either.
function Bookbridge:showResilientTextViewer(opts)
    local TextViewer = require("ui/widget/textviewer")
    local dismissed = false
    local retries = 0
    local MAX_RETRIES = 2

    local show_viewer
    show_viewer = function()
        local viewer
        -- Rebuilt per attempt: TextViewer mutates the buttons table it's
        -- given (it appends its own default row when asked to), so a shared
        -- table would accumulate rows across retries.
        local rows = {}
        for _, b in ipairs(opts.buttons or {}) do
            rows[#rows + 1] = {
                text = b.text,
                callback = function()
                    dismissed = true
                    UIManager:close(viewer)
                    if b.callback then b.callback() end
                end,
            }
        end

        viewer = TextViewer:new{
            title = opts.title,
            text = opts.text,
            justified = false,
            add_default_buttons = false,
            buttons_table = { rows },
        }

        local base_on_close = viewer.onClose
        viewer.onClose = function(self_v)
            dismissed = true
            return base_on_close(self_v)
        end

        local base_on_close_widget = viewer.onCloseWidget
        viewer.onCloseWidget = function(self_v)
            base_on_close_widget(self_v)
            if dismissed then return end
            debugLog("showResilientTextViewer: force-closed externally (retries=" .. retries .. "): "
                .. tostring(opts.title):sub(1, 60))
            if retries < MAX_RETRIES then
                retries = retries + 1
                UIManager:scheduleIn(0.2, show_viewer)
            else
                UIManager:show(InfoMessage:new{
                    text = _("This dialog kept getting closed by something else on this device."),
                })
            end
        end
        UIManager:show(viewer)
    end
    show_viewer()
end

-- release.source == "annasarchive" releases skip Shelfmark's own
-- request/fulfillment queue entirely -- there's nothing to wait for, the
-- file is fetched and saved right here, same as the standalone
-- annasarchive.koplugin's own download flow (see doAnnasFileDownload's
-- note on why). Landing in the same download_dir Shelfmark itself uses
-- means "Sync library with CWA" picks it up naturally on its next run,
-- same as any other externally-acquired book (Z-Library, the standalone
-- plugin, etc).
function Bookbridge:downloadFromAnnasArchive(release)
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

    -- In case this overwrote an existing copy of the same book -- see
    -- invalidateBookInfoCache.
    invalidateBookInfoCache(save_path)

    UIManager:show(InfoMessage:new{ text = T(_("Saved to %1"), save_path), timeout = 4 })
end

-- caller_menu, when given, is the releases_menu this was opened from. It is
-- deliberately left OPEN underneath this dialog so "Back to list" can simply
-- close the dialog and reveal it again -- with its scroll position, page and
-- already-fetched covers intact, because nothing re-runs the menu's item
-- builder. It is closed only on the paths that actually commit (download or
-- request), which is what preserves the previous end state.
function Bookbridge:confirmReleaseRequest(book, release, caller_menu)
    local is_annas = release.source == "annasarchive"
    local buttons = {}
    if caller_menu then
        buttons[#buttons + 1] = {
            text = _("Back"),
            callback = function() end, -- the wrapper already closed the dialog
        }
    end
    buttons[#buttons + 1] = {
        text = is_annas and _("Download") or _("Request"),
        callback = function()
            if caller_menu then UIManager:close(caller_menu) end
            local Trapper = require("ui/trapper")
            if is_annas then
                -- Immediate download, not a queued request -- see
                -- downloadFromAnnasArchive's note on why this branch exists.
                Trapper:wrap(function() self:downloadFromAnnasArchive(release) end)
            else
                Trapper:wrap(function() self:submitRequest(withAuthorField(book), release) end)
            end
        end,
    }

    self:showResilientTextViewer{
        title = is_annas and _("Download this release?") or _("Request this release?"),
        text = describeReleaseDetail(release, book),
        buttons = buttons,
    }
end

function Bookbridge:confirmBookLevelRequest(book)
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
function Bookbridge:submitRequest(book, release)
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
function Bookbridge:checkPendingRequestNotifications()
    local pending = loadPendingNotifyList()
    if next(pending) == nil then return end

    -- Explicit short timeouts, rather than apiRequest's 15s-block/45s-total
    -- defaults. Those defaults are sized for a search the user is sitting
    -- there waiting on; this call is unprompted background work nobody asked
    -- for, and the common failure is exactly the slow one -- woken on a
    -- Kindle with Wi-Fi still down or Tailscale not yet reconnected, where
    -- the connect just hangs until it times out. At the defaults that parks
    -- a forked subprocess on a dead socket for up to 45 seconds per wake,
    -- keeping the CPU out of deep idle for no benefit: there is nothing to
    -- salvage by waiting longer, since a failure here is silent and simply
    -- retried on the next wake anyway.
    -- progress_text false, not nil: nil takes apiRequest's default
    -- "Talking to Shelfmark..." dialog, which on this path would flash a
    -- popup -- and cost a full e-ink refresh -- on every single wake with a
    -- request outstanding, for a check the user never asked for. false is
    -- the invisible trap widget (same as the download path's own use of it),
    -- so the check stays completely silent unless it actually has news.
    local resp, code, err = self:apiRequest("GET", "/api/requests", nil, false, 8, 12)
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

-- ===== Hardcover reading-progress sync =====
-- Captured on close/suspend (instant, local), pushed from a calm context
-- (FileManager after close, or on resume). See doHardcoverPushProgress and the
-- map/pending stores above.

-- Reads the just-closed (or suspending) document's progress into the pending
-- file. Guarded so it is a no-op unless progress sync is on, a token is set,
-- and we are actually in the reader with a document.
function Bookbridge:captureReadingProgress()
    if not self.hardcover_progress_sync then debugLog("[hc] capture: progress sync off"); return end
    if not self.hardcover_token or self.hardcover_token == "" then debugLog("[hc] capture: no token"); return end
    local ui = self.ui
    if not ui or not ui.document or not ui.doc_settings then debugLog("[hc] capture: not in reader (no document)"); return end
    local md5 = ui.doc_settings:readSetting("partial_md5_checksum")
    if not md5 or md5 == "" then debugLog("[hc] capture: no partial_md5"); return end
    -- The number the footer shows is the one to record: ReaderFooter's
    -- percent_finished is page/pages for the book EXCLUDING hidden flows
    -- (front/back matter some EPUBs mark non-linear), it is what gets saved
    -- to the sidecar and what the home screen shows. The raw page ratio can
    -- read higher on such books. Fall back to the ratio when there is no
    -- footer value, and log whenever the two disagree.
    local ratio
    if ui.document.info and ui.document.info.has_pages then
        ratio = ui.paging and ui.paging:getLastPercent()
    else
        ratio = ui.rolling and ui.rolling:getLastPercent()
    end
    local footer = ui.view and ui.view.footer
    local shown = footer and footer.percent_finished
    local percent = (type(shown) == "number" and shown > 0) and shown or ratio
    if type(percent) ~= "number" then debugLog("[hc] capture: no percent"); return end
    if type(shown) == "number" and type(ratio) == "number" and math.abs(shown - ratio) >= 0.005 then
        debugLog(string.format("[hc] capture: footer shows %.1f%%, raw page ratio %.1f%% -- recording the footer's",
            shown * 100, ratio * 100))
    end
    local props = (ui.document.getProps and ui.document:getProps()) or {}
    local pending = loadHardcoverPending()
    pending[md5] = { title = props.title, author = props.authors, identifiers = props.identifiers, percent = percent, at = os.time() }
    saveHardcoverPending(pending)
    debugLog(string.format("[hc] captured %d%% for %s", math.floor((percent or 0) * 100 + 0.5), tostring(props.title)))
end

function Bookbridge:clearHardcoverPending(md5)
    local pending = loadHardcoverPending()
    if pending[md5] ~= nil then pending[md5] = nil; saveHardcoverPending(pending) end
end

-- Pushes every pending record it can: known books silently, and the FIRST
-- unmatched book through a one-time confirm (the rest wait for the next pass).
-- Must run inside a Trapper:wrap (both callers provide one).
function Bookbridge:processHardcoverPending()
    if not self.hardcover_progress_sync or not self.hardcover_token or self.hardcover_token == "" then return end
    local pending = loadHardcoverPending()
    if next(pending) == nil then
        self._hc_wait_tries = nil   -- queue drained; don't carry a count into the next book
        debugLog("[hc] process: nothing pending"); return
    end
    local map = loadHardcoverMap()
    local token = self.hardcover_token
    local Trapper = require("ui/trapper")
    local n = 0; for _ in pairs(pending) do n = n + 1 end
    debugLog("[hc] process: " .. n .. " pending")
    local unmapped
    for md5, rec in pairs(pending) do
        local entry = map[md5]
        if entry and entry.decision == "skip" then
            -- Dropping it silently is how "nothing happens, no dialog, no log"
            -- looked on-device: say which book, and how to undo it.
            debugLog(string.format(
                "[hc] skip: %s is marked never-sync; dropping. Undo with Bookbridge > Hardcover > Forget Hardcover book choices.",
                tostring(entry.title or rec.title)))
            pending[md5] = nil
        elseif entry and entry.decision == "review" then
            -- Waiting in Hardcover > Review matches: never pushed, never
            -- prompted, and the record keeps its progress for later.
        elseif entry and entry.decision == "sync" and entry.book_id
                and entry.last_percent and rec.percent and math.abs(entry.last_percent - rec.percent) < 0.0005 then
            -- Same position as the last successful push: a suspend/resume or
            -- a second close re-captured it. Nothing to tell Hardcover; the
            -- phone log showed every book pushed twice at the same page.
            pending[md5] = nil
        elseif entry and entry.decision == "sync" and entry.book_id then
            -- {} trap, not false/a string: a TrapWidget (visible or invisible)
            -- is dismissed by ANY queued gesture/keypress, and the reader ->
            -- FileManager close transition delivers exactly that -- which
            -- cancelled the call every time (see the debug log). A bare table
            -- is used as an already-shown trap that is never shown and never
            -- dismissed, so the subprocess runs to completion, non-blocking,
            -- with no widget to cancel.
            local completed, ok, a, b = Trapper:dismissableRunInSubprocess(function()
                return doHardcoverPushProgress(token, entry.book_id, rec.percent, entry.edition_id)
            end, {})
            if completed and ok then
                pending[md5] = nil
                entry.last_percent = rec.percent; map[md5] = entry; saveHardcoverMap(map)
                debugLog(string.format("[hc] pushed %s: page %s of %s", tostring(entry.title), tostring(a), tostring(b)))
                self:showAfterCloseNotice(T(_("Hardcover: \"%1\" -- page %2 of %3 (%4%)."),
                    tostring(entry.title), tostring(a), tostring(b), math.floor((rec.percent or 0) * 100 + 0.5)))
            else
                debugLog("[hc] push failed for " .. tostring(entry.title) .. ": " .. tostring(a))
            end
        elseif not unmapped then
            unmapped = { md5 = md5, rec = rec }
        end
    end
    saveHardcoverPending(pending)
    if unmapped then
        -- If the open-time lookup for this book is STILL running, wait for it
        -- instead of starting a competing second search. Hardcover throttles
        -- rapid requests by hanging the connection rather than answering 429
        -- (measured: two quick queries answer in ~0.2s, a third can hang past
        -- 30s), so racing ourselves is the slowest possible thing to do -- and
        -- it was: closing a book before the prefetch landed put two queries in
        -- flight and the dialog then took tens of seconds to appear.
        if self._hc_prefetch_inflight and self._hc_prefetch_inflight[unmapped.md5] then
            self._hc_wait_tries = (self._hc_wait_tries or 0) + 1
            if self._hc_wait_tries <= 20 then
                debugLog("[hc] process: open-time lookup still running, waiting for it")
                UIManager:scheduleIn(1, function()
                    local Trapper2 = require("ui/trapper")
                    Trapper2:wrap(function() self:processHardcoverPending() end)
                end)
                return
            end
            debugLog("[hc] process: lookup never landed; searching now")
        end
        self._hc_wait_tries = nil
        self:resolveHardcoverMatch(unmapped.md5, unmapped.rec)
    end
end

-- A brief note over whatever the close left on screen (the home screen,
-- usually). Shown the tick after the close, then -- the part that makes it
-- actually appear under Bookshelf -- the whole stack is repainted at +1 s
-- and +3 s after waiting for the panel's own refresh to finish: a widget
-- painted on top and refreshed alone did not reach either device's panel,
-- while a repaint from the home screen up always did.
function Bookbridge:showAfterCloseNotice(text)
    local ok_dev, Device = pcall(require, "device")
    -- Android: the OS's own toast. It is drawn by Android's window manager on
    -- top of every app surface, so it is on screen the moment it is posted --
    -- unlike anything painted into KOReader's framebuffer after a close,
    -- which the phone kept holding back until a touch no matter how it was
    -- refreshed. A long toast is ~3.5 s; falls through to the in-app notice
    -- if the launcher has no toast.
    if ok_dev and Device and Device.isAndroid and Device:isAndroid() then
        local ok_t, terr = pcall(function()
            local ok_a, android = pcall(require, "android")
            if not ok_a or type(android) ~= "table" then android = rawget(_G, "android") end
            assert(type(android.notification) == "function", "no android.notification")
            android.notification(text, true)
        end)
        if ok_t then debugLog("[hc] notice: system toast"); return end
        debugLog("[hc] notice: system toast failed (" .. tostring(terr) .. "); in-app notice instead")
    end
    local msg = InfoMessage:new{ text = text, timeout = 6 }
    UIManager:show(msg, "ui")
    if not ok_dev or not Device or (Device.isDesktop and Device:isDesktop()) then return end
    local function still_up()
        return type(UIManager.isWidgetShown) ~= "function" or UIManager:isWidgetShown(msg)
    end
    -- Kindle: the notice's own refresh reaches the driver and never shows;
    -- a repaint of the whole stack from the home screen up does.
    for _unused, delay in ipairs({ 1, 3 }) do
        UIManager:scheduleIn(delay, function()
            if not still_up() then return end
            pcall(function() if Device.screen and Device.screen.refreshWaitForLast then Device.screen:refreshWaitForLast() end end)
            UIManager:setDirty("all", "ui")
        end)
    end
    -- Android: the frame carrying the notice is posted (the blits lock and
    -- post fine) but not composited until a touch or a window event. The
    -- phone logs showed re-applying the current screen brightness -- a Java
    -- window-attribute change -- draws a WINDOW_RESIZED straight away, and
    -- the notice was on screen within a second; without it nothing shows
    -- until the menu is opened. Nothing visible changes. Then post the
    -- buffer again after the relayout has had its moment.
    if Device.isAndroid and Device:isAndroid() then
        for _unused, delay in ipairs({ 0.3, 2.0 }) do
            UIManager:scheduleIn(delay, function()
                if not still_up() then return end
                local ok_n, nerr = pcall(function()
                    local ok_a, android = pcall(require, "android")
                    if not ok_a or type(android) ~= "table" then android = rawget(_G, "android") end
                    local cur = android.getScreenBrightness()
                    android.setScreenBrightness(cur)
                    return cur
                end)
                debugLog("[hc] notice: window nudge at +" .. tostring(delay) .. "s "
                    .. (ok_n and ("ok (" .. tostring(nerr) .. ")") or ("failed: " .. tostring(nerr))))
            end)
        end
        for _unused, delay in ipairs({ 0.7, 2.3 }) do
            UIManager:scheduleIn(delay, function()
                if not still_up() then return end
                local ok_p, perr = pcall(function() Device.screen:_updateWindow() end)
                debugLog("[hc] notice: explicit post at +" .. tostring(delay) .. "s " .. (ok_p and "ok" or ("failed: " .. tostring(perr))))
            end)
        end
    end
end

-- Decides a book not yet mapped, with no UI beyond the after-close note. A confident match (see
-- doHardcoverFindBook) is recorded and pushed on the spot; anything else is
-- parked as "review" -- never synced, never prompted -- keeping its progress
-- so it pushes once picked in Hardcover > Review matches. Runs inside a
-- Trapper:wrap (both callers provide one).
function Bookbridge:resolveHardcoverMatch(md5, rec)
    local token = self.hardcover_token
    local Trapper = require("ui/trapper")
    local book_id, ft, fa, ranked, confident, edition
    local warm = self._hc_prefetch and self._hc_prefetch[md5]
    if warm and (warm.book_id or (warm.ranked and #warm.ranked > 0)) then
        book_id, ft, fa, ranked, confident, edition = warm.book_id, warm.title, warm.author, warm.ranked, warm.confident, warm.edition
    else
        local completed, _err, unreachable
        completed, book_id, ft, fa, _err, ranked, confident, unreachable, edition = Trapper:dismissableRunInSubprocess(function()
            return doHardcoverFindBook(token, rec.title or "", rec.author, self.hardcover_language, rec.identifiers)
        end, {})
        if not completed then return end
        if unreachable then
            -- Not a verdict: the book stays queued and is looked up again on
            -- the next reconnect/wake, like a queued progress push.
            debugLog("[hc] Hardcover unreachable (" .. tostring(_err) .. "); keeping " .. tostring(rec.title) .. " queued")
            return
        end
    end
    local map = loadHardcoverMap()
    if book_id and confident then
        map[md5] = { book_id = book_id, title = ft, decision = "sync", edition_id = edition and edition.id }; saveHardcoverMap(map)
        debugLog(string.format("[hc] auto-matched %s -> %s by %s", tostring(rec.title), tostring(ft), tostring(fa)))
        local edition_id = edition and edition.id
        local completed, ok, a, b = Trapper:dismissableRunInSubprocess(function()
            return doHardcoverPushProgress(token, book_id, rec.percent, edition_id)
        end, {})
        if completed and ok then
            self:clearHardcoverPending(md5)
            map[md5].last_percent = rec.percent; saveHardcoverMap(map)
            debugLog(string.format("[hc] pushed %s: page %s of %s", tostring(ft), tostring(a), tostring(b)))
            self:showAfterCloseNotice(T(_("Hardcover: synced as \"%1\" by %2 -- page %3 of %4 (%5%)."),
                ft, tostring(fa), tostring(a), tostring(b), math.floor((rec.percent or 0) * 100 + 0.5)))
        else
            debugLog("[hc] push failed for " .. tostring(ft) .. ": " .. tostring(a))   -- stays pending; retried later
            self:showAfterCloseNotice(T(_("Hardcover: matched \"%1\"; progress will sync when Hardcover answers."), ft))
        end
        return
    end
    map[md5] = { decision = "review", title = rec.title, author = rec.author, ranked = ranked or {}, book_id = book_id, found = ft }
    saveHardcoverMap(map)
    debugLog(string.format("[hc] needs review: %s (%s)", tostring(rec.title),
        book_id and ("best guess " .. tostring(ft)) or "no candidates"))
    self:showAfterCloseNotice(book_id
        and T(_("Hardcover isn't sure this is \"%1\" -- waiting under Hardcover > Review matches."), ft)
        or _("Hardcover has no match for this book -- waiting under Hardcover > Review matches."))
end

-- Hardcover > Review matches: the books parked as "review", one button each.
function Bookbridge:reviewHardcoverMatches()
    local ButtonDialog = require("ui/widget/buttondialog")
    local map = loadHardcoverMap()
    local items = {}
    for md5, e in pairs(map) do
        if e.decision == "review" then items[#items + 1] = { md5 = md5, e = e } end
    end
    table.sort(items, function(a, b) return tostring(a.e.title) < tostring(b.e.title) end)
    if #items == 0 then
        UIManager:show(InfoMessage:new{ text = _("Nothing to review -- every book has a Hardcover decision.") })
        return
    end
    local dialog
    local rows = {}
    for _unused, it in ipairs(items) do
        local e = it.e
        rows[#rows + 1] = {{
            text = (e.author and e.author ~= "") and T(_("%1 by %2"), e.title, e.author) or tostring(e.title),
            callback = function()
                UIManager:close(dialog)
                local pending = loadHardcoverPending()
                local rec = pending[it.md5] or { title = e.title, author = e.author }
                local Trapper = require("ui/trapper")
                Trapper:wrap(function()
                    local candidates = e.ranked or {}
                    if #candidates == 0 then
                        -- Parked with nothing to choose from (looked up while
                        -- offline, or a genuine miss): ask Hardcover again now.
                        local token = self.hardcover_token
                        local completed, _id, _t, _a, err, ranked, _c, unreachable = Trapper:dismissableRunInSubprocess(function()
                            return doHardcoverFindBook(token, rec.title or "", rec.author, self.hardcover_language, rec.identifiers)
                        end, _("Asking Hardcover again..."))
                        if not completed then return end
                        if unreachable then
                            UIManager:show(InfoMessage:new{ text = T(_("Hardcover can't be reached right now (%1). Try again when online."), tostring(err)) })
                            return
                        end
                        if ranked and #ranked > 0 then
                            candidates = ranked
                            local m = loadHardcoverMap(); if m[it.md5] then m[it.md5].ranked = ranked; saveHardcoverMap(m) end
                            debugLog("[hc] review: fresh lookup found " .. #ranked .. " candidate(s) for " .. tostring(rec.title))
                        end
                    end
                    self:pickHardcoverCandidate(it.md5, rec, candidates, self.hardcover_token)
                end)
            end,
        }}
    end
    dialog = ButtonDialog:new{
        title = T(_("Books waiting for a Hardcover match (%1)"), #items),
        title_align = "left",
        buttons = rows,
    }
    UIManager:show(dialog, "ui")
end

-- The picker for one reviewed book: one button per candidate (best guess
-- first), then "None of these" (recorded as never-sync) and "Not now"
-- (stays in the review list). Choosing a book records it as the match and,
-- if progress is waiting, pushes it at once.
function Bookbridge:pickHardcoverCandidate(md5, rec, candidates, token)
    local ButtonDialog = require("ui/widget/buttondialog")
    local map = loadHardcoverMap()
    local dialog
    local rows = {}
    for i = 1, math.min(#candidates, 5) do
        local c = candidates[i]
        rows[#rows + 1] = {{
            text = (c.author and c.author ~= "") and T(_("%1 by %2"), c.title, c.author) or c.title,
            callback = function()
                UIManager:close(dialog)
                debugLog("[hc] picked " .. tostring(c.id) .. " (" .. tostring(c.title) .. ") for " .. tostring(rec.title))
                map[md5] = { book_id = c.id, title = c.title, decision = "sync" }; saveHardcoverMap(map)
                if rec.percent then
                    local Trapper = require("ui/trapper")
                    Trapper:wrap(function()
                        Trapper:dismissableRunInSubprocess(function()
                            return doHardcoverPushProgress(token, c.id, rec.percent)
                        end, {})
                        self:clearHardcoverPending(md5)
                        UIManager:scheduleIn(1, function() Trapper:wrap(function() self:processHardcoverPending() end) end)
                    end)
                end
            end,
        }}
    end
    rows[#rows + 1] = {{
        text = _("None of these -- don't sync this book"),
        callback = function()
            UIManager:close(dialog)
            map[md5] = { decision = "skip", title = rec.title }; saveHardcoverMap(map); self:clearHardcoverPending(md5)
        end,
    }}
    rows[#rows + 1] = {{ text = _("Not now"), callback = function() UIManager:close(dialog) end }}
    dialog = ButtonDialog:new{
        title = T(_("Which Hardcover book is\n%1?"), rec.title or _("this book")),
        title_align = "left",
        buttons = rows,
    }
    UIManager:show(dialog, "ui")
end

-- Looks this book up on Hardcover while it is being OPENED, and keeps the
-- answer in memory for the close-time confirm.
--
-- The confirm dialog used to run the search itself, so it could not appear
-- until a network round trip finished -- at the exact moment the reader is
-- tearing down and (on a Kindle) the radio may still be waking. Doing it here
-- instead costs the same one request, but spends it while the book is opening,
-- the network is already up, and nobody is waiting on a dialog.
--
-- In-memory on purpose: a book is always opened before it is closed in the
-- same session, and nothing here is worth persisting or going stale.
function Bookbridge:prefetchHardcoverMatch()
    if not self.hardcover_progress_sync then return end
    if not self.hardcover_token or self.hardcover_token == "" then return end
    local ui = self.ui
    if not ui or not ui.document or not ui.doc_settings then return end
    local md5 = ui.doc_settings:readSetting("partial_md5_checksum")
    if not md5 or md5 == "" then return end

    self._hc_prefetch = self._hc_prefetch or {}
    self._hc_prefetch_inflight = self._hc_prefetch_inflight or {}
    if self._hc_prefetch[md5] then return end          -- already looked up this session
    if self._hc_prefetch_inflight[md5] then return end -- already looking
    local entry = loadHardcoverMap()[md5]
    if entry and entry.decision then return end        -- already decided; nothing to ask

    local props = (ui.document.getProps and ui.document:getProps()) or {}
    local title, author = props.title, props.authors
    if not title or title == "" then debugLog("[hc] prefetch: no title, skipping"); return end
    local token, lang = self.hardcover_token, self.hardcover_language
    local identifiers = props.identifiers
    debugLog("[hc] prefetch: looking up " .. tostring(title))
    local Trapper = require("ui/trapper")
    self._hc_prefetch_inflight[md5] = true
    Trapper:wrap(function()
        local completed, book_id, ft, fa, _err, ranked, confident, unreachable, edition = Trapper:dismissableRunInSubprocess(function()
            return doHardcoverFindBook(token, title, author, lang, identifiers)
        end, {})   -- invisible and non-dismissable; see the note in processHardcoverPending
        self._hc_prefetch_inflight[md5] = nil
        if not completed then debugLog("[hc] prefetch: interrupted"); return end
        -- A miss is cached too, so the close costs no network either way.
        if unreachable then
            -- Offline (or Hardcover down): cache nothing, so the close looks
            -- again -- a cached "nothing" here once sent a book straight to
            -- the review list with no candidates.
            debugLog("[hc] prefetch: Hardcover unreachable (" .. tostring(_err) .. "); will look up at close")
            return
        end
        self._hc_prefetch[md5] = { book_id = book_id, title = ft, author = fa, ranked = ranked, confident = confident, edition = edition }
        debugLog("[hc] prefetch: " .. (book_id
            and ((confident and "confident match " or "uncertain match ") .. tostring(ft) .. " by " .. tostring(fa))
            or "no match"))
    end)
end

-- Wi-Fi came back: push anything that piled up while offline.
--
-- The queue itself already exists and needs no network: closing a book writes
-- the percentage to the pending file locally, and a push that fails leaves the
-- record in place to retry. What was missing was a trigger -- until now
-- pending work only moved on the next close or resume, so progress read on a
-- plane sat there until you happened to close another book.
function Bookbridge:onNetworkConnected()
    if self.auto_update and self.update_url and self.update_url ~= "" then
        UIManager:scheduleIn(5, function() self:autoCheckForUpdate("network") end)
    end
    if not self.hardcover_progress_sync then return end
    if not self.hardcover_token or self.hardcover_token == "" then return end
    if next(loadHardcoverPending()) == nil then return end
    debugLog("[hc] network back: flushing queued reading progress")
    -- A moment for the connection to actually settle before using it.
    UIManager:scheduleIn(2, function()
        local Trapper = require("ui/trapper")
        Trapper:wrap(function() self:processHardcoverPending() end)
    end)
end

-- Book opened: warm the Hardcover match in the background. Delayed so it never
-- competes with rendering the first page.
function Bookbridge:onReaderReady()
    -- Bookshelf loads its parking module lazily; by reader-ready it has
    -- (the shelf opened this book), and if not there is nothing to park.
    if self:hookBookshelfPark() then debugLog("[hc] bookshelf parking hooked") end
    if not self.hardcover_progress_sync then return end
    UIManager:scheduleIn(3, function() self:prefetchHardcoverMatch() end)
end

-- Bookshelf's "hot parking" (on by default): closing a book from the shelf
-- does not close it. The shelf is lifted over the still-open reader, and the
-- real close -- the CloseDocument event above -- runs only after 30-40 s of
-- no input, or the moment the menu is opened. On both devices that was the
-- whole "the notice only shows when I open the menu / after 15 s" story:
-- nothing was hidden, the plugin had not been told the book was closed. So
-- the park IS the close here: capture and sync at that instant. The later
-- real close captures the same position and pushes nothing (see
-- processHardcoverPending's same-position branch).
--
-- Two ways to hear about it: wrap Park.park itself once Bookshelf has loaded
-- that module (precise), and the CloseConfigMenu event Park.park sends
-- just before it raises the shelf (reaches plugins; CloseReaderMenu does
-- not), checked a tick later against Park.isParked().
local function bookshelfPark()
    local Park = package.loaded["lib/bookshelf_reader_park"]
    return type(Park) == "table" and Park or nil
end

function Bookbridge:hookBookshelfPark()
    local Park = bookshelfPark()
    if not Park or type(Park.park) ~= "function" or Park._shelfmark_hooked then return Park ~= nil end
    local orig = Park.park
    Park.park = function(...)
        local parked = orig(...)
        if parked then
            local ok, rui = pcall(function() return require("apps/reader/readerui").instance end)
            local sm = ok and rui and rui.shelfmark
            if sm and sm.onBookshelfParked then pcall(function() sm:onBookshelfParked() end) end
        end
        return parked
    end
    Park._shelfmark_hooked = true
    return true
end

function Bookbridge:onCloseConfigMenu()
    UIManager:nextTick(function()
        -- The module may not have existed at reader-ready (Bookshelf loads it
        -- on first use, and on the desktop that first use WAS this park); hook
        -- it now so the next park is caught by the wrap rather than this path.
        self:hookBookshelfPark()
        local Park = bookshelfPark()
        if Park and type(Park.isParked) == "function" and Park.isParked() then self:onBookshelfParked() end
    end)
end

function Bookbridge:onBookshelfParked()
    local now = os.time()
    if self._hc_park_at and now - self._hc_park_at < 5 then return end
    self._hc_park_at = now
    debugLog("[hc] parked under the shelf: treating it as the close")
    self:onCloseDocument()
end

-- Fires in the reader when a document closes (and, via onBookshelfParked,
-- when Bookshelf parks it): capture now, sync a moment later off the
-- teardown path.
function Bookbridge:onCloseDocument()
    self:captureReadingProgress()
    if self.hardcover_progress_sync and self.hardcover_token and self.hardcover_token ~= "" then
        -- A match prefetched at open costs no network: decide and push on the
        -- next tick, once the shelf/file manager is on the stack beneath the
        -- notice. Without one, wait for the file manager to finish painting.
        local ui = self.ui
        local md5 = ui and ui.doc_settings and ui.doc_settings:readSetting("partial_md5_checksum")
        local warm = md5 and self._hc_prefetch and self._hc_prefetch[md5]
        if warm then
            debugLog("[hc] close: prefetched match on hand, deciding next tick")
            UIManager:nextTick(function()
                local Trapper = require("ui/trapper")
                Trapper:wrap(function() self:processHardcoverPending() end)
            end)
            return
        end
        -- Just long enough for the FileManager to finish painting; the dialog
        -- no longer cares about stray input, so this needn't be generous.
        UIManager:scheduleIn(0.4, function()
            local Trapper = require("ui/trapper")
            Trapper:wrap(function() self:processHardcoverPending() end)
        end)
    end
end

-- Device sleeping: capture now, push on the next resume (a scheduled push
-- wouldn't survive the sleep). No-op in FileManager (no document).
-- ===== Clipboard receiver ("Send to Kindle") =====
-- A tiny always-on HTTP listener that lets a phone push text straight into
-- KOReader's clipboard, so you can paste instead of typing on the device.
-- Unlike the debug HTTP inspector, it does exactly one thing -- set the
-- clipboard -- and exposes nothing else about the device.
--
-- Send with a GET whose `text` query parameter carries the URL-encoded text:
--   GET /clip?text=hello%20scribe%20123
-- The query form accepts any content -- spaces, punctuation, URLs, slashes --
-- because the value is parsed here rather than routed through URL path
-- segments (which split on "/"). Then long-press any input field on the
-- device -> Clipboard -> paste.
local CLIPBOARD_RECEIVER_PORT = 8090

function Bookbridge:_clipboardSend(client, code, body)
    if not self.clipboard_server then return end
    local status = ({ [200] = "200 OK", [400] = "400 Bad Request", [404] = "404 Not Found" })[code] or "200 OK"
    body = body or ""
    local response = table.concat({
        "HTTP/1.1 " .. status,
        "Content-Type: text/plain; charset=utf-8",
        "Content-Length: " .. tostring(#body),
        "Access-Control-Allow-Origin: *",
        "Connection: close",
        "",
        body,
    }, "\r\n")
    pcall(function() self.clipboard_server:send(response, client) end)
end

function Bookbridge:_onClipboardRequest(data, client)
    local util = require("util")
    local uri = data and data:match("^%u+%s+([^%s]+)%s+HTTP/%d%.%d")
    if not uri then
        return self:_clipboardSend(client, 400, "Bad request")
    end
    local path, query = uri:match("^([^?]*)%??(.*)$")
    if path == "/" or path == "" then
        return self:_clipboardSend(client, 200,
            "Bookbridge clipboard receiver.\nUse: GET /clip?text=<your text>")
    end
    if path ~= "/clip" then
        return self:_clipboardSend(client, 404, "Not found")
    end
    local raw
    for pair in ((query or "") .. "&"):gmatch("([^&]*)&") do
        local k, v = pair:match("^([^=]*)=(.*)$")
        if k == "text" then raw = v break end
    end
    if not raw or raw == "" then
        return self:_clipboardSend(client, 400, "Missing text parameter")
    end
    -- application/x-www-form-urlencoded: '+' is a space, then decode %XX.
    local text = util.urlDecode((raw:gsub("%+", " "))) or ""
    local Device = require("device")
    if Device.input and Device.input.setClipboardText then
        Device.input.setClipboardText(text)
    end
    debugLog("[clipboard] received " .. tostring(#text) .. " chars")
    self:_clipboardSend(client, 200, "OK")
    -- Brief on-device confirmation.
    local preview = text
    if #preview > 60 then preview = preview:sub(1, 60) .. "..." end
    UIManager:nextTick(function()
        local ok = pcall(function()
            require("ui/widget/notification"):notify(T(_("Clipboard: %1"), preview))
        end)
        if not ok then
            UIManager:show(InfoMessage:new{ text = T(_("Clipboard: %1"), preview), timeout = 2 })
        end
    end)
end

function Bookbridge:startClipboardReceiver()
    if self.clipboard_server then return end
    local Device = require("device")
    if Device:isKindle() then
        os.execute("iptables -A INPUT -p tcp --dport " .. CLIPBOARD_RECEIVER_PORT ..
            " -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT 2>/dev/null")
        os.execute("iptables -A OUTPUT -p tcp --sport " .. CLIPBOARD_RECEIVER_PORT ..
            " -m conntrack --ctstate ESTABLISHED -j ACCEPT 2>/dev/null")
    end
    local ok_srv, SimpleTCPServer = pcall(require, "ui/message/simpletcpserver")
    if not ok_srv then
        debugLog("[clipboard] no simpletcpserver: " .. tostring(SimpleTCPServer))
        return
    end
    local server = SimpleTCPServer:new{
        host = "*",
        port = CLIPBOARD_RECEIVER_PORT,
        receiveCallback = function(d, c) return self:_onClipboardRequest(d, c) end,
    }
    local ok, err = server:start()
    if ok then
        self.clipboard_server = server
        self.clipboard_mq = UIManager:insertZMQ(server)
        debugLog("[clipboard] receiver listening on " .. CLIPBOARD_RECEIVER_PORT)
    else
        self.clipboard_server = nil
        debugLog("[clipboard] failed to start: " .. tostring(err))
    end
end

function Bookbridge:stopClipboardReceiver()
    local Device = require("device")
    if Device:isKindle() then
        os.execute("iptables -D INPUT -p tcp --dport " .. CLIPBOARD_RECEIVER_PORT ..
            " -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT 2>/dev/null")
        os.execute("iptables -D OUTPUT -p tcp --sport " .. CLIPBOARD_RECEIVER_PORT ..
            " -m conntrack --ctstate ESTABLISHED -j ACCEPT 2>/dev/null")
    end
    if self.clipboard_mq then
        UIManager:removeZMQ(self.clipboard_mq)
        self.clipboard_mq = nil
    end
    if self.clipboard_server then
        pcall(function() self.clipboard_server:stop() end)
        self.clipboard_server = nil
    end
end

function Bookbridge:onCloseWidget()
    self:stopClipboardReceiver()
end

function Bookbridge:onSuspend()
    self:stopClipboardReceiver()
    if self.bt_ready_on_wake and self.bt_keyboard_addr and btOnKindle() then
        -- radio off for the sleep; not tracked, so the wake-time "ready" is never blocked by it
        self:btRun("off", nil, nil, nil, { fire_and_forget = true })
    end
    self:captureReadingProgress()
end

function Bookbridge:onResume()
    -- Bring the clipboard receiver back up after a wake.
    UIManager:scheduleIn(1, function() self:startClipboardReceiver() end)
    -- Bluetooth keyboard: listen again after a wake, if asked to (Kindle).
    if self.bt_ready_on_wake and self.bt_keyboard_addr and btOnKindle() then
        UIManager:scheduleIn(2, function() self:btReady(true) end)
    end
    -- Updates: a quiet look at the self-hosted source once the network has
    -- had a moment to come back (throttled inside).
    if self.auto_update and self.update_url and self.update_url ~= "" then
        UIManager:scheduleIn(10, function() self:autoCheckForUpdate("wake") end)
    end
    -- Push any progress captured on suspend/close. No throttle needed -- at
    -- most one record per book, and processHardcoverPending is a cheap no-op
    -- when nothing is pending.
    if self.hardcover_progress_sync and self.hardcover_token and self.hardcover_token ~= "" then
        UIManager:scheduleIn(3, function()
            local Trapper = require("ui/trapper")
            Trapper:wrap(function() self:processHardcoverPending() end)
        end)
    end
    -- Delivered-request notifications. scheduleIn rather than checking
    -- immediately -- Tailscale's userspace daemon isn't necessarily reconnected
    -- the instant the device wakes. Throttled (self._last_notify_check) so a
    -- quick series of wake/sleep cycles doesn't spam requests.
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

function Bookbridge:showMyRequests()
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
            local Trapper = require("ui/trapper")
            Trapper:wrap(function() self:downloadFromCwa(item.title, requests_menu) end)
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
                                local Trapper = require("ui/trapper")
                                Trapper:wrap(function() self:downloadFromCwa(item.title, requests_menu) end)
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

return Bookbridge
