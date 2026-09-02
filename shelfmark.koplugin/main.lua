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
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local http = require("socket.http")
local ltn12 = require("ltn12")
local logger = require("logger")
local socket = require("socket")
local socketurl = require("socket.url")
local _ = require("gettext")
local T = ffiUtil.template

local Shelfmark = WidgetContainer:extend{
    name = "shelfmark",
    settings_file = DataStorage:getSettingsDir() .. "/shelfmark.lua",
    sm_settings = nil,
    session_cookie = nil,
}

-- A blocking network call (our HTTP requests aren't run through Trapper's
-- subprocess machinery -- that would need session_cookie mutations to
-- survive a fork, which they can't without a larger rework) run in the
-- same tick as UIManager:close() on a dialog/menu -- especially one that
-- was showing the on-screen keyboard -- is a known-fragile pattern on
-- Android. A native crash was observed here with an IME-hide event
-- immediately preceding it in both crash logs. This defers the actual
-- blocking call to the next UI tick, after any close/dismiss transition
-- has settled, which is a low-risk mitigation for that correlation -- not
-- a confirmed fix, since the crash log had no Lua-level traceback to
-- point at a definitive cause.
local function deferBlocking(fn)
    UIManager:scheduleIn(0.3, fn)
end

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
                            deferBlocking(function()
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

local function describeAuthor(book)
    if book.authors and #book.authors > 0 then
        return table.concat(book.authors, ", ")
    end
    return ""
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
    local text = book.title or _("Untitled")
    local author = describeAuthor(book)
    if author ~= "" then
        text = text .. "\n" .. author
    end
    return text .. describeYear(book)
end

-- params: {query=, author=, page=}. existing_books, when given, is the
-- accumulated result list so far (used by "Load more" to append rather
-- than replace).
function Shelfmark:doSearch(params, existing_books)
    UIManager:show(InfoMessage:new{ text = _("Searching..."), timeout = 1 })

    local qs = { "limit=100", "page=" .. tostring(params.page or 1) }
    if params.query and params.query ~= "" then
        table.insert(qs, "query=" .. socketurl.escape(params.query))
    end
    if params.author and params.author ~= "" then
        table.insert(qs, "author=" .. socketurl.escape(params.author))
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
        item_table[i] = {
            text = book.title or _("Untitled"),
            mandatory = describeAuthor(book) .. describeYear(book),
            book_data = book,
        }
    end
    if resp.has_more then
        item_table[#item_table + 1] = { text = _("-- Load more results --"), is_load_more = true }
    end

    local results_menu
    results_menu = Menu:new{
        title = T(_("Search results (%1)"), #books),
        item_table = item_table,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        onMenuSelect = function(_menu_self, item)
            UIManager:close(results_menu)
            if item.is_load_more then
                deferBlocking(function()
                    self:doSearch({ query = params.query, author = params.author, page = (params.page or 1) + 1 }, books)
                end)
            else
                deferBlocking(function() self:browseReleases(item.book_data) end)
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
    return table.concat(bits, " • ") -- bullet-separated (raw UTF-8, not \u{} -- LuaJIT/Lua 5.1 doesn't support that escape form)
end

-- Searches release sources (Prowlarr, direct download, etc.) for this one
-- specific book -- deliberately not run during the metadata search above,
-- so indexers only get queried for a book you've actually committed to.
function Shelfmark:browseReleases(book)
    UIManager:show(InfoMessage:new{ text = _("Searching release sources (Prowlarr etc.)..."), timeout = 2 })

    local qs = {
        "provider=" .. socketurl.escape(book.provider or ""),
        "book_id=" .. socketurl.escape(book.provider_id or ""),
        "content_type=ebook",
    }
    if book.title then table.insert(qs, "title=" .. socketurl.escape(book.title)) end
    local author = describeAuthor(book)
    if author ~= "" then table.insert(qs, "author=" .. socketurl.escape(author)) end

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

    local item_table = {}
    for i, release in ipairs(resp.releases) do
        item_table[i] = {
            text = release.title or _("Untitled release"),
            mandatory = describeRelease(release),
            release_data = release,
        }
    end

    local releases_menu
    releases_menu = Menu:new{
        title = T(_("Releases for: %1"), book.title or _("this book")),
        item_table = item_table,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        onMenuSelect = function(_menu_self, item)
            UIManager:close(releases_menu)
            self:confirmReleaseRequest(book, item.release_data)
        end,
    }
    UIManager:show(releases_menu)
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
    UIManager:show(ConfirmBox:new{
        text = (release.title or _("This release")) .. "\n\n" .. _("Request this release?"),
        ok_text = _("Request"),
        ok_callback = function()
            deferBlocking(function() self:submitRequest(withAuthorField(book), release) end)
        end,
    })
end

function Shelfmark:confirmBookLevelRequest(book)
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = describeBook(book) .. "\n\n" .. _("Submit a plain request for this book (no specific release found)?"),
        ok_text = _("Request"),
        ok_callback = function()
            deferBlocking(function() self:submitRequest(withAuthorField(book), nil) end)
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
