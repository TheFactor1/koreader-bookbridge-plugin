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
local InputDialog = require("ui/widget/inputdialog")
local JSON = require("json")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local http = require("socket.http")
local ltn12 = require("ltn12")
local logger = require("logger")
local socket = require("socket")
local socketurl = require("socket.url")
local _ = require("gettext")

local Shelfmark = WidgetContainer:extend{
    name = "shelfmark",
    settings_file = DataStorage:getSettingsDir() .. "/shelfmark.lua",
    sm_settings = nil,
    session_cookie = nil,
}

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
end

function Shelfmark:init()
    self:loadSettings()
    self.ui.menu:registerToMainMenu(self)
end

function Shelfmark:editServerSettings()
    self.settings_dialog = MultiInputDialog:new{
        title = _("Shelfmark settings"),
        fields = {
            { text = self.server_url, hint = _("Server URL, e.g. http://shelfmark:8084") },
            { text = self.username, hint = _("Username") },
            { text = self.password, text_type = "password", hint = _("Password") },
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
                        self.sm_settings:saveSetting("shelfmark", {
                            server_url = self.server_url,
                            username = self.username,
                            password = self.password,
                        })
                        self.sm_settings:flush()
                        self.session_cookie = nil -- force re-login with new creds
                        UIManager:close(self.settings_dialog)
                        UIManager:show(InfoMessage:new{
                            text = _("Saved. You'll be logged in on your next search or request."),
                            timeout = 2,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(self.settings_dialog)
    self.settings_dialog:onShowKeyboard()
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

-- Low-level request. `body` (if given) is a Lua table, JSON-encoded and
-- sent with Content-Type: application/json. Returns decoded JSON body (or
-- nil), plus the HTTP status code (or nil on a connection-level failure).
function Shelfmark:rawRequest(method, path, body)
    if not self.server_url or self.server_url == "" then
        return nil, nil, _("Shelfmark server URL isn't set -- check Settings.")
    end

    local headers = { ["Accept"] = "application/json" }
    if self.session_cookie then
        headers["Cookie"] = self.session_cookie
    end

    local body_json
    if body then
        body_json = JSON.encode(body)
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#body_json)
    end

    local sink = {}
    local request = {
        method = method,
        url = self.server_url .. path,
        headers = headers,
        sink = ltn12.sink.table(sink),
    }
    if body_json then
        request.source = ltn12.source.string(body_json)
    end

    local ok, code, resp_headers = pcall(function()
        return socket.skip(1, http.request(request))
    end)
    if not ok then
        logger.warn("Shelfmark: request failed", code)
        return nil, nil, _("Couldn't reach the Shelfmark server -- are you on your home network?")
    end

    local cookie = extractSessionCookie(resp_headers)
    if cookie then
        self.session_cookie = cookie
    end

    local content = table.concat(sink)
    local decoded
    if content ~= "" then
        local decode_ok, result = pcall(JSON.decode, content)
        if decode_ok then decoded = result end
    end

    return decoded, code
end

function Shelfmark:login()
    local resp, code = self:rawRequest("POST", "/api/auth/login", {
        username = self.username,
        password = self.password,
    })
    if code == 200 and resp and resp.success ~= false then
        return true
    end
    local err = resp and resp.error or _("Login failed -- check your Shelfmark username/password in Settings.")
    return false, err
end

-- Ensures we have a session, logging in first if needed. Returns true, or
-- false plus a user-facing error string.
function Shelfmark:ensureLoggedIn()
    if self.session_cookie then return true end
    if not self.username or self.username == "" then
        return false, _("No Shelfmark username set -- check Settings.")
    end
    return self:login()
end

-- Authenticated request wrapper: logs in first if needed, and retries once
-- on a 401 in case the session expired mid-use.
function Shelfmark:apiRequest(method, path, body)
    local ok, login_err = self:ensureLoggedIn()
    if not ok then return nil, nil, login_err end

    local resp, code, err = self:rawRequest(method, path, body)
    if err then return nil, nil, err end

    if code == 401 then
        self.session_cookie = nil
        local relog_ok, relog_err = self:login()
        if not relog_ok then return nil, nil, relog_err end
        resp, code, err = self:rawRequest(method, path, body)
        if err then return nil, nil, err end
    end

    return resp, code
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
                text = _("My requests"),
                keep_menu_open = true,
                callback = function() self:showMyRequests() end,
            },
            {
                text = _("Settings"),
                keep_menu_open = true,
                callback = function() self:editServerSettings() end,
                separator = true,
            },
        },
    }
end

-- ===== search + request flow =====

function Shelfmark:startSearch()
    self.search_dialog = InputDialog:new{
        title = _("Search Shelfmark"),
        input = "",
        input_hint = _("Title, author, ISBN..."),
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
                        local query = self.search_dialog:getInputText()
                        UIManager:close(self.search_dialog)
                        if query and query ~= "" then
                            self:doSearch(query)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(self.search_dialog)
    self.search_dialog:onShowKeyboard()
end

local function describeBook(book)
    local author = ""
    if book.authors and #book.authors > 0 then
        author = table.concat(book.authors, ", ")
    end
    local text = book.title or _("Untitled")
    if author ~= "" then
        text = text .. " -- " .. author
    end
    if book.publish_year then
        text = text .. " (" .. tostring(book.publish_year) .. ")"
    end
    return text
end

function Shelfmark:doSearch(query)
    UIManager:show(InfoMessage:new{ text = _("Searching..."), timeout = 1 })

    local resp, code, err = self:apiRequest(
        "GET",
        "/api/metadata/search?query=" .. socketurl.escape(query)
    )
    if err then
        UIManager:show(InfoMessage:new{ text = err })
        return
    end
    if code ~= 200 or not resp or not resp.books then
        local msg = (resp and (resp.message or resp.error)) or _("Search failed.")
        UIManager:show(InfoMessage:new{ text = msg })
        return
    end
    if #resp.books == 0 then
        UIManager:show(InfoMessage:new{ text = _("No results.") })
        return
    end

    local item_table = {}
    for i, book in ipairs(resp.books) do
        item_table[i] = {
            text = describeBook(book),
            book_data = book,
        }
    end

    local results_menu
    results_menu = Menu:new{
        title = _("Search results"),
        item_table = item_table,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        onMenuSelect = function(_menu_self, item)
            UIManager:close(results_menu)
            self:confirmRequest(item.book_data)
        end,
    }
    UIManager:show(results_menu)
end

function Shelfmark:confirmRequest(book)
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = describeBook(book) .. "\n\n" .. _("Request this book?"),
        ok_text = _("Request"),
        ok_callback = function()
            self:submitRequest(book)
        end,
    })
end

function Shelfmark:submitRequest(book)
    local resp, code, err = self:apiRequest("POST", "/api/requests", {
        book_data = book,
        context = { content_type = "ebook" },
    })
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
        item_table[i] = { text = title .. "  [" .. status .. "]" }
    end

    UIManager:show(Menu:new{
        title = _("My Shelfmark requests"),
        item_table = item_table,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
    })
end

return Shelfmark
