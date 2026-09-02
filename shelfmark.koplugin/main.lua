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

local function doRawRequest(server_url, cookie, method, path, body)
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
local function doLogin(server_url, username, password)
    local resp, code, cookie = doRawRequest(server_url, nil, "POST", "/api/auth/login", {
        username = username,
        password = password,
    })
    if code == 200 and resp and resp.success ~= false then
        return true, cookie
    end
    local err = resp and resp.error or _("Login failed -- check your Shelfmark username/password in Settings.")
    return false, nil, err
end

-- The full operation: log in first if we don't have a session yet, do the
-- request, retry once on 401 in case the session expired mid-use. Returns
-- (decoded_body, http_code, cookie_to_remember, error_string).
local function doApiRequest(server_url, username, password, cookie, method, path, body)
    if not cookie then
        if not username or username == "" then
            return nil, nil, nil, _("No Shelfmark username set -- check Settings.")
        end
        local ok, new_cookie, login_err = doLogin(server_url, username, password)
        if not ok then return nil, nil, nil, login_err end
        cookie = new_cookie
    end

    local resp, code, new_cookie, err = doRawRequest(server_url, cookie, method, path, body)
    if err then return nil, nil, cookie, err end
    cookie = new_cookie

    if code == 401 then
        local ok, relog_cookie, login_err = doLogin(server_url, username, password)
        if not ok then return nil, nil, nil, login_err end
        cookie = relog_cookie
        resp, code, new_cookie, err = doRawRequest(server_url, cookie, method, path, body)
        if err then return nil, nil, cookie, err end
        cookie = new_cookie
    end

    return resp, code, cookie
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
    local server_url, username, password, cookie = self.server_url, self.username, self.password, self.session_cookie

    local completed, resp, code, new_cookie, err = Trapper:dismissableRunInSubprocess(function()
        return doApiRequest(server_url, username, password, cookie, method, path, body)
    end, progress_text or _("Talking to Shelfmark..."))

    if not completed then
        return nil, nil, _("Cancelled.")
    end
    if new_cookie then
        self.session_cookie = new_cookie
    end
    return resp, code, err
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
                callback = function()
                    local Trapper = require("ui/trapper")
                    Trapper:wrap(function() self:showMyRequests() end)
                end,
            },
            {
                text = _("Settings"),
                keep_menu_open = true,
                callback = function() self:editServerSettings() end,
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
    UIManager:show(TextViewer:new{
        title = _("Shelfmark debug log"),
        text = content,
        justified = false,
    })
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
local function truncate(text, maxlen)
    if type(text) ~= "string" or #text <= maxlen then return text end
    return text:sub(1, maxlen - 1) .. "…" -- raw UTF-8, not \u{} -- see bullet note above
end

local function describeAuthor(book)
    if book.authors and #book.authors > 0 then
        return table.concat(book.authors, ", ")
    end
    return ""
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
    local text = book.title or _("Untitled")
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

-- params: {query=, author=, page=}. existing_books, when given, is the
-- accumulated result list so far (used by "Load more" to append rather
-- than replace).
function Shelfmark:doSearch(params, existing_books)
    UIManager:show(InfoMessage:new{ text = _("Searching..."), timeout = 1 })

    local qs = { "limit=100", "sort=popularity", "page=" .. tostring(params.page or 1) }
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
        local metrics = describeMetrics(book)
        local byline = describeAuthor(book) .. describeYear(book)
        item_table[i] = {
            text = truncate(book.title, 80) or _("Untitled"),
            -- Metrics first (what was actually asked for: how popular is
            -- it), byline after -- both truncated together within one
            -- bounded budget so a book with a long rating string can't
            -- crowd out its author entirely.
            mandatory = truncate(metrics ~= "" and (metrics .. "  " .. byline) or byline, 55),
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
                    self:doSearch({ query = params.query, author = params.author, page = (params.page or 1) + 1 }, books)
                end)
            else
                local Trapper = require("ui/trapper")
                Trapper:wrap(function() self:browseReleases(item.book_data) end)
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

    -- EPUB first, otherwise keep the server's own ordering (a plain
    -- table.sort isn't guaranteed stable, so the original index is used
    -- as an explicit tiebreaker rather than leaving that to chance).
    local releases = resp.releases
    for i, r in ipairs(releases) do r._orig_index = i end
    table.sort(releases, function(a, b)
        local a_epub = (a.format and a.format:lower() == "epub") and 0 or 1
        local b_epub = (b.format and b.format:lower() == "epub") and 0 or 1
        if a_epub ~= b_epub then return a_epub < b_epub end
        return a._orig_index < b._orig_index
    end)
    for _, r in ipairs(releases) do r._orig_index = nil end

    local item_table = {}
    for i, release in ipairs(releases) do
        item_table[i] = {
            text = truncate(release.title, 90) or _("Untitled release"),
            mandatory = truncate(describeRelease(release), 40),
            release_data = release,
        }
    end

    local releases_menu
    releases_menu = Menu:new{
        title = T(_("Releases for: %1"), truncate(book.title, 40) or _("this book")),
        item_table = item_table,
        multilines_forced = true,
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
        item_table[i] = { text = truncate(title, 70) .. "  [" .. status .. "]" }
    end

    UIManager:show(Menu:new{
        title = _("My Shelfmark requests"),
        item_table = item_table,
        multilines_forced = true,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
    })
end

return Shelfmark
