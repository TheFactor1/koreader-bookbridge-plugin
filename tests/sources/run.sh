#!/bin/bash
# Book sources (SRC) and the Z-Library source: results from a fake
# zlibrary.koplugin (its modules planted in package.loaded, as KOReader
# leaves them) become releases tagged with their source; the chosen order,
# on/off and "stop at the first" are honoured; a changed plugin degrades to
# "unavailable"; a quota refusal and a download go through the plugin's own
# functions. Offline.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd); M="$REPO/bookbridge.koplugin/main.lua"
KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
[ -x "${KDIR:-/nonexistent}/luajit" ] || { echo "SKIP  no local KOReader (set KOREADER_DIR)"; exit 3; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
{ awk '/^-- ===== CO begin/{f=1} f{print} f&&/^-- ===== CO end/{exit}' "$M"
  awk 'index($0, "local function annasResultToRelease(") == 1 {f=1} f{print} f&&/^end$/{exit}' "$M"
  awk '/^-- ===== SRC begin/{f=1} f{print} f&&/^-- ===== SRC end/{exit}' "$M"
  for f in browseReleases browseReleasesContinue sortReleases getBook sourcesInOrder sourcesConfigured sourcesSummary companionState confirmReleaseRequest zlibraryState annasState; do
      awk "/^function Bookbridge:$f\\(/{f=1} f{print} f&&/^end\$/{exit}" "$M"
  done
} > "$W/fns.lua"
grep -q "SRC.DEF.zlibrary" "$W/fns.lua" || { echo "FAIL  extraction failed"; exit 1; }
sed -i 's/^local CO = {}/CO = {}/; s/^local SRC = {}/SRC = {}/' "$W/fns.lua"

cd "$KDIR" || exit 1
W="$W" ./luajit - <<'LUA'
package.path = "frontend/?.lua;common/?.lua;" .. package.path
local W = os.getenv("W")
_ = function(s) return s end
T = require("ffi/util").template
lfs = { attributes = function() return nil end, mkdir = function() end, dir = function() return function() end end }
G_reader_settings = { readSetting = function() return nil end, saveSetting = function() end }
getPluginDir = function() return "/nonexistent/plugins/bookbridge.koplugin" end
Bookbridge = {}
STATUS_CHECK_MAX_AGE = 600   -- (a top-level local in main.lua; annasState reads it)
local LOG = {}
debugLog = function(m) LOG[#LOG + 1] = m end
truncate = function(s) return s end
socketurl = { escape = function(s) return s end }
describeAuthor = function(book) return (book.authors and book.authors[1]) or "" end
defaultReleaseQuery = function(book) return ((book.title or "") .. " " .. describeAuthor(book)):gsub("^%s+", ""):gsub("%s+$", "") end
decodeHtmlEntities = function(s) return s end
withAuthorField = function(b) return b end
describeReleaseDetail = function(r) return r.title end
local SHOWN = {}
UIManager = { show = function(_s, w) SHOWN[#SHOWN + 1] = w end, close = function() end, scheduleIn = function() end, unschedule = function() end }
InfoMessage = { new = function(_s, t) t.kind = "info"; return t end }
-- Trapper: the subprocess runs inline
package.loaded["ui/trapper"] = { wrap = function(_s, f) f() end, dismissableRunInSubprocess = function(_s, f) return true, f() end }
dofile(W .. "/fns.lua")
local pass, fail = 0, 0
local function ck(c, m) if c then pass = pass + 1; print("PASS  " .. m) else fail = fail + 1; print("FAIL  " .. m) end end

-- the fake plugin, planted the way KOReader leaves a loaded plugin's modules
local ZL = { search_calls = 0, session = nil, books = {} , link = nil, link_err = nil, downloaded = nil }
package.loaded["zlibrary.api"] = {
    search = function(query, uid, key, langs, exts, order, page)
        ZL.search_calls = ZL.search_calls + 1; ZL.last_query = query; ZL.last_uid = uid
        return { results = ZL.books, total_count = #ZL.books }
    end,
    getDownloadLink = function(uid, key, id, hash)
        ZL.link_args = { uid, key, id, hash }
        if ZL.link_err then return { error = ZL.link_err } end
        return { download_link = ZL.link }
    end,
    getDownloadTempPath = function(p) return p .. ".zl-part" end,
    downloadBook = function(url, path, uid, key, referer) ZL.downloaded = { url, path, uid, key, referer }; return { success = true } end,
}
package.loaded["zlibrary.config"] = {
    getUserSession = function() return ZL.session or {} end,
    hasCredentials = function() return ZL.session ~= nil and ZL.session.userId ~= nil end,
    getBaseUrl = function() return "https://z-lib.example" end,
}
local function bb(t)
    t = t or {}
    t.annasSearch = function() return nil, nil, "Anna's Archive API URL isn't set." end
    t.apiRequest = function() return { releases = t._shelf or {} }, 200 end
    t.showResilientConfirmBox = function(_s, o) SHOWN[#SHOWN + 1] = o; o.kind = "confirm" end
    t.showResilientTextViewer = function(_s, o) SHOWN[#SHOWN + 1] = o; o.kind = "viewer" end
    t.confirmBookLevelRequest = function() SHOWN[#SHOWN + 1] = { kind = "booklevel" } end
    t.showSourcesDialog = function() end
    t.saveAllSettings = function() end
    return setmetatable(t, { __index = Bookbridge })
end
local CONT = {}
local REAL_CONTINUE = Bookbridge.browseReleasesContinue   -- (its real "nothing found" branch, checked in 5b)
Bookbridge.browseReleasesContinue = function(self, book, q, releases, errors, tried)
    if #releases == 0 then return CONT_ORIG(self, book, q, releases, errors, tried) end
    CONT = { releases = releases, errors = errors, tried = tried }
end
-- (keep the real "nothing found" branch reachable)
local real_continue
do
    local src = io.open(W .. "/fns.lua"):read("*a")
end
CONT_ORIG = function(self, book, q, releases, errors, tried)
    CONT = { releases = releases, errors = errors, tried = tried, empty = true }
    if SRC.DEF.shelfmark.configured(self) and SRC.enabled(self, "shelfmark") then self:confirmBookLevelRequest(book) end
end

-- 1. nothing configured at all
local b = bb({})
package.loaded["zlibrary.api"], package.loaded["zlibrary.config"] = nil, nil
b:browseReleases({ title = "Persuasion", authors = { "Jane Austen" } })
ck(SHOWN[#SHOWN] and SHOWN[#SHOWN].kind == "confirm" and SHOWN[#SHOWN].text:find("No book source"), "no source set up: told, with a way to the Sources dialog")
ck(b:sourcesConfigured() == false and b:sourcesSummary() == "None set up", "sourcesConfigured false, summary 'None set up'")

-- 2. Z-Library present: results become releases tagged zlibrary, in the default order first
local Api = { search = nil }
package.loaded["zlibrary.api"] = {
    search = function(query, uid, key) ZL.search_calls = ZL.search_calls + 1; ZL.last_query = query; ZL.last_uid = uid; return { results = ZL.books } end,
    getDownloadLink = function(uid, key, id, hash) ZL.link_args = { uid, key, id, hash }; if ZL.link_err then return { error = ZL.link_err } end; return { download_link = ZL.link } end,
    getDownloadTempPath = function(p) return p .. ".zl-part" end,
    downloadBook = function(url, path, uid, key, referer) ZL.downloaded = { url, path, uid, key, referer }; return { success = true } end,
}
package.loaded["zlibrary.config"] = { getUserSession = function() return ZL.session or {} end, getBaseUrl = function() return "https://z-lib.example" end }
ZL.books = {
    { id = 101, hash = "abc", title = "Persuasion", author = "Jane Austen", format = "epub", size = "0.4 MB", year = 1817, lang = "English", cover = "https://c/1.jpg" },
    { id = 102, hash = "def", title = "Persuasion (Illustrated)", author = "Unknown Author", format = "N/A", size = "N/A", year = "N/A" },
}
b = bb({})
ck(b:sourcesConfigured() == true and b:sourcesSummary() == "Z-Library", "Z-Library counts as a configured source")
b:browseReleases({ title = "Persuasion", authors = { "Jane Austen" } })
ck(ZL.search_calls == 1 and ZL.last_query == "Persuasion Jane Austen" and ZL.last_uid == nil, "searched Z-Library with title + author, no session")
ck(#CONT.releases == 2 and CONT.releases[1].source == "zlibrary" and CONT.releases[1].indexer == "Z-Library", "2 releases tagged zlibrary")
ck(CONT.releases[1].title == "Jane Austen - Persuasion" and CONT.releases[1].format == "epub" and CONT.releases[1].year == "1817" and CONT.releases[1].zl_id == "101" and CONT.releases[1].zl_hash == "abc", "fields mapped (Author - Title, format, year, id/hash)")
ck(CONT.releases[2].title == "Persuasion (Illustrated)" and CONT.releases[2].format == nil and CONT.releases[2].size == nil, "N/A and Unknown Author become nothing")
ck(CONT.tried[1] == "Z-Library" and #CONT.tried == 1, "only the configured source was asked")

-- 3. getBook builds the same book
ZL.search_calls = 0
b:getBook("Emma", "Jane Austen")
ck(ZL.search_calls == 1 and ZL.last_query == "Emma Jane Austen", "getBook(title, author) searches the sources directly")
b:getBook("Emma", "")
ck(ZL.last_query == "Emma", "getBook without an author")

-- 4. order and on/off (a book picked in Shelfmark's catalogue: it carries
-- the catalogue's provider + id, which Shelfmark's release search needs)
local PICKED = { title = "Emma", provider = "openlibrary", provider_id = "OL1W" }
b = bb({ server_url = "http://s", _shelf = { { title = "Emma.epub", source = "prowlarr", indexer = "x" } } })
b:browseReleases(PICKED)
ck(#CONT.tried == 2 and CONT.tried[1] == "Z-Library" and CONT.tried[2] == "Shelfmark" and #CONT.releases == 3, "default order: Z-Library then Shelfmark, results merged")
b.sources_order = { "shelfmark", "zlibrary" }
b:browseReleases(PICKED)
ck(CONT.tried[1] == "Shelfmark" and CONT.tried[2] == "Z-Library", "order setting honoured")
b.sources_stop_first = true
b:browseReleases(PICKED)
ck(#CONT.tried == 1 and CONT.tried[1] == "Shelfmark" and #CONT.releases == 1, "stop at the first source with results")
b.sources_stop_first = false
b.sources_enabled = { zlibrary = false }
b:browseReleases(PICKED)
ck(#CONT.tried == 1 and CONT.tried[1] == "Shelfmark", "a switched-off source is skipped")
do
    local b2 = bb({}); b2.sources_enabled = { zlibrary = false }
    SHOWN = {}
    b2:browseReleases({ title = "Emma" })
    ck(SHOWN[#SHOWN] and SHOWN[#SHOWN].kind == "confirm" and SHOWN[#SHOWN].text:find("Z%-Library is turned off"), "the only source switched off: says so, not 'install it'")
end
ck(b:sourcesSummary() == "Shelfmark", "summary lists only enabled, configured sources")
-- 4c. words only ("Files from your sources", the Ledger's "Get it"): Shelfmark
-- isn't asked -- its release search refuses a book without provider + id
-- ("Parameters 'provider' and 'book_id' are required", seen live)
do
    local asked = 0
    local b4 = bb({ server_url = "http://s", _shelf = { { title = "Emma.epub", source = "prowlarr", indexer = "x" } } })
    b4.apiRequest = function() asked = asked + 1; return { error = "Parameters 'provider' and 'book_id' are required" }, 400 end
    b4:getBook("Emma", "Jane Austen")
    local said = table.concat(CONT.errors or {}, " ")
    ck(asked == 0 and not said:find("Shelfmark", 1, true) and #CONT.releases == 2, "words only: Shelfmark isn't asked, no Shelfmark error, the other sources' files shown")
    ck(not table.concat(CONT.tried or {}, ","):find("Shelfmark", 1, true), "words only: Shelfmark isn't named as searched")
    -- Shelfmark the only source: pointed at its catalogue, not "no source set up"
    local b5 = bb({ server_url = "http://s" }); b5.sources_enabled = { zlibrary = false }
    SHOWN = {}
    b5:getBook("Emma", "Jane Austen")
    local last = SHOWN[#SHOWN]
    ck(last and last.kind == "info" and tostring(last.text):find("catalogue", 1, true), "words only, Shelfmark the only source: told to pick the book in its catalogue")
end
-- 4d. a source that's switched on but not set up (Anna's without a key) is
-- named only when nothing came back -- not on every search that found files
do
    local b6 = bb({})          -- Z-Library present (above), Anna's on by default, no key
    b6:browseReleases({ title = "Persuasion", authors = { "Jane Austen" } })
    ck(#CONT.releases > 0 and not table.concat(CONT.errors or {}, " "):find("Anna's Archive", 1, true), "results from Z-Library: no 'Anna's isn't set up' note")
    local keep = ZL.books; ZL.books = {}
    b6:browseReleases({ title = "Nothing here" })
    ck(CONT.empty and table.concat(CONT.errors or {}, " "):find("Anna's Archive", 1, true), "nothing found anywhere: the note says why")
    ZL.books = keep
end
-- Anna's Archive direct (a key, no helper): every domain was already tried
-- inside one search, so MIRROR_DOWN ends it; through the helper the
-- mirror refresh gets up to three more tries.
do
    local calls, refreshes = 0, 0
    local b3 = bb({ annas_download_key = "k" })
    b3.annasSearch = function() calls = calls + 1; return nil, nil, "down", "MIRROR_DOWN" end
    b3.annasMirrorRefresh = function() refreshes = refreshes + 1; return { switched = false, allDead = false } end
    local got, err = SRC.DEF.annasarchive.search(b3, "emma")
    ck(got == nil and calls == 1 and refreshes == 0 and err:find("domains"), "direct: one search on MIRROR_DOWN, no refresh loop")
    calls, refreshes = 0, 0
    b3.annas_url = "http://helper.example"
    got, err = SRC.DEF.annasarchive.search(b3, "emma")
    ck(got == nil and calls == 4 and refreshes == 3, "via the helper: three mirror refreshes, then gives up")
end

-- 4b. in the merged list the preferred source's copy sorts first (before download counts)
b = bb({ server_url = "http://s" })
local function merged()
    return {
        { title = "Jane Austen - Emma", format = "epub", source = "prowlarr", extra = { grabs = 500 } },
        { title = "Jane Austen - Emma", format = "epub", source = "zlibrary", extra = {} },
    }
end
b.sources_order = { "zlibrary", "shelfmark" }
local list = merged(); b:sortReleases(list, { title = "Emma", authors = { "Jane Austen" } })
ck(list[1].source == "zlibrary", "same relevance and format: the preferred source (Z-Library) sorts before a 500-grab copy from Shelfmark")
b.sources_order = { "shelfmark", "zlibrary" }
list = merged(); b:sortReleases(list, { title = "Emma", authors = { "Jane Austen" } })
ck(list[1].source == "prowlarr", "...and the other way round when Shelfmark is preferred")
list = { { title = "Making of Emma", format = "epub", source = "zlibrary", extra = {} }, { title = "Jane Austen - Emma", format = "pdf", source = "prowlarr", extra = {} } }
b:sortReleases(list, { title = "Emma", authors = { "Jane Austen" } })
ck(list[1].source == "prowlarr", "relevance still wins over source order (a 'making of' sinks)")

-- 5. nothing found: a plain request only when Shelfmark is there
ZL.books = {}
b = bb({ server_url = "http://s", _shelf = {} })
SHOWN = {}
b:browseReleases({ title = "Nothing" })
ck(CONT.empty and SHOWN[#SHOWN] and SHOWN[#SHOWN].kind == "booklevel", "nothing anywhere + Shelfmark: plain request offered")
b = bb({})
SHOWN = {}
b:browseReleases({ title = "Nothing" })
ck(CONT.empty and not (SHOWN[#SHOWN] and SHOWN[#SHOWN].kind == "booklevel"), "nothing anywhere, no server: no request offered")

-- 5b. the real "nothing found" branch: a plain request names a book from
-- Shelfmark's catalogue (provider + id); words only, Shelfmark refuses one
-- ("book_data missing required field(s): author, provider, provider_id",
-- seen live), so it isn't offered -- the message points at the catalogue
do
    local b8 = bb({ server_url = "http://s" })
    SHOWN = {}
    REAL_CONTINUE(b8, { title = "Qzx" }, nil, {}, {}, { "Z-Library" })
    local kinds = {}
    for _u, w in ipairs(SHOWN) do kinds[#kinds + 1] = tostring(w.kind) end
    ck(not table.concat(kinds, ","):find("booklevel", 1, true) and SHOWN[#SHOWN] and SHOWN[#SHOWN].kind == "info"
        and tostring(SHOWN[#SHOWN].text):find("Search & request", 1, true), "words only, nothing found: no plain request; pointed at Search & request")
    SHOWN = {}
    REAL_CONTINUE(b8, { title = "Qzx", provider = "openlibrary", provider_id = "OL9W" }, nil, {}, {}, { "Shelfmark" })
    ck(SHOWN[#SHOWN] and SHOWN[#SHOWN].kind == "booklevel", "a catalogue pick, nothing found: plain request offered")
    SHOWN = {}
    REAL_CONTINUE(bb({}), { title = "Qzx" }, nil, {}, {}, { "Z-Library" })
    ck(SHOWN[#SHOWN] and SHOWN[#SHOWN].kind == "info" and not tostring(SHOWN[#SHOWN].text):find("Shelfmark", 1, true), "no server, nothing found: no Shelfmark hint")
end

-- 6. a changed plugin degrades, never crashes
package.loaded["zlibrary.api"].search = function() error("boom: signature changed") end
b = bb({})
local got, err = SRC.DEF.zlibrary.search(b, "x")
ck(got == nil and err:find("unavailable") and LOG[#LOG]:find("boom"), "plugin error -> 'unavailable', logged")
package.loaded["zlibrary.api"].search = function() return "not a table" end
got, err = SRC.DEF.zlibrary.search(b, "x")
ck(got == nil and err:find("unavailable"), "non-table answer -> 'unavailable'")
package.loaded["zlibrary.api"].search = function() return { error = "Search API error: rate limited" } end
got, err = SRC.DEF.zlibrary.search(b, "x")
ck(got == nil and err == "Search API error: rate limited", "the plugin's own error text is shown as is")

-- 7. downloads need a session; quota and link go through the plugin
local rel = { source = "zlibrary", zl_id = "101", zl_hash = "abc", title = "Jane Austen - Persuasion" }
ZL.session = nil
local url, uerr = SRC.DEF.zlibrary.fetchUrl(b, rel)
ck(url == nil and uerr:find("sign in"), "no session: asked to sign in under Bookbridge > Z-Library")
ZL.session = { user_id = "7", user_key = "k" }
ZL.link_err = "Download limit reached. Please try again later or check your account."
url, uerr = SRC.DEF.zlibrary.fetchUrl(b, rel)
ck(url == nil and uerr:find("limit") and ZL.link_args[1] == "7" and ZL.link_args[3] == "101" and ZL.link_args[4] == "abc", "quota refusal passed through; link asked with session + id/hash")
ZL.link_err = nil; ZL.link = "https://dl.example/book.epub"
url = SRC.DEF.zlibrary.fetchUrl(b, rel)
ck(url == "https://dl.example/book.epub", "download link from the plugin")
local ok = SRC.DEF.zlibrary.download(b, url, "/tmp/x/Persuasion.epub")
ck(ok == true and ZL.downloaded[2] == "/tmp/x/Persuasion.epub" and ZL.downloaded[3] == "7" and ZL.downloaded[5] == "https://z-lib.example", "download goes through Api.downloadBook with session and referer")
ck(SRC.DEF.zlibrary.tempPath("/tmp/x/Persuasion.epub") == "/tmp/x/Persuasion.epub.zl-part", "the plugin's temp file is what the progress poll watches")

-- 8. confirmReleaseRequest: Download for a source with fetchUrl, Request for Shelfmark's
SHOWN = {}
b:confirmReleaseRequest({ title = "P" }, rel, nil)
ck(SHOWN[#SHOWN].kind == "viewer" and SHOWN[#SHOWN].buttons[1].text == "Download", "Z-Library release: Download button")
b:confirmReleaseRequest({ title = "P" }, { source = "prowlarr", title = "x" }, nil)
ck(SHOWN[#SHOWN].buttons[1].text == "Request", "server release: Request button")

-- a source switched on but not ready is named, never skipped in silence
do
    local api_mod, cfg_mod = package.loaded["zlibrary.api"], package.loaded["zlibrary.config"]
    package.loaded["zlibrary.api"], package.loaded["zlibrary.config"] = nil, nil   -- (plugin not loaded: restart needed)
    local b7 = bb({ annas_download_key = "k", _shelf = {} })
    b7.annasSearch = function() return { { md5 = "a1", title = "Emma", format = "epub" } }, 200 end
    local old_attr = lfs.attributes
    lfs.attributes = function(path) if tostring(path):find("zlibrary.koplugin", 1, true) then return "directory" end end
    CONT = {}
    b7:browseReleases({ title = "Emma" })
    lfs.attributes = old_attr
    local note = table.concat(CONT.errors or {}, "|")
    ck(#(CONT.releases or {}) == 1 and note:find("Z%-Library is installed %-%- restart") and not note:find("Z%-Library: Z%-Library"), "Z-Library installed, not loaded: results from Anna's, and a 'restart KOReader' note (" .. note .. ")")
    package.loaded["zlibrary.api"], package.loaded["zlibrary.config"] = api_mod, cfg_mod
end
-- the Ledger's one-glance states
do
    local b5 = bb({ ui = { zlibrary = {} } })
    -- (the config module was re-planted above without the credentials check)
    package.loaded["zlibrary.config"].hasCredentials = function() return ZL.session ~= nil and (ZL.session.userId or ZL.session.user_id) ~= nil end
    local old_attr = lfs.attributes
    lfs.attributes = function(path) if tostring(path):find("zlibrary.koplugin", 1, true) then return "directory" end end
    ZL.session = nil
    local z = b5:zlibraryState()
    ck(z.loaded and not z.signed_in and z.label == "Not signed in", "zlibraryState: plugin loaded, no account -> Not signed in")
    ZL.session = { userId = "1", userKey = "k" }
    ck(b5:zlibraryState().signed_in and b5:zlibraryState().label == "Signed in", "zlibraryState: with an account -> Signed in")
    package.loaded["zlibrary.api"], package.loaded["zlibrary.config"] = nil, nil
    lfs.attributes = old_attr
    ck(bb({ ui = {} }):zlibraryState().label == "Not installed", "zlibraryState: no plugin -> Not installed")
    local a = bb({}):annasState()
    ck(not a.set and a.label == "No key", "annasState: nothing set -> No key")
    local b6 = bb({ annas_download_key = "k" })
    ck(b6:annasState().set and b6:annasState().label == "Key set", "annasState: a key, not yet checked -> Key set")
    b6._status_checks = { at = os.time(), annas = { state = "token" } }
    ck(b6:annasState().label == "Key refused", "annasState: a refused key says so")
end
-- 4e. Anna's Archive asked by Bookbridge itself: Shelfmark isn't made to
-- search it again (its route starts a headless browser for a bot check:
-- 25 of 29 s on Matt's Kindle) -- its other release sources, one by one
do
    local PICK = { title = "Tomorrow", provider = "hardcover", provider_id = "479910" }
    local function stub(b, sources)
        b.asked = {}
        b.apiRequest = function(self, method, path, body, text, block, total)
            self.asked[#self.asked + 1] = { path = path, body = body, text = text, block = block, total = total }
            if path == "/api/release-sources" then
                if sources == "fail" then return nil, 500 end
                return sources, 200
            end
            return { releases = { { title = path:match("source=(%w+)") or "all" } } }, 200
        end
    end
    local SOURCES = { { name = "direct_download", enabled = true, supported_content_types = { "ebook", "audiobook" } },
        { name = "prowlarr", enabled = true, supported_content_types = { "ebook", "audiobook" } },
        { name = "irc", enabled = false }, { name = "audiobookbay", enabled = true, supported_content_types = { "audiobook" } } }
    local b7 = bb({ server_url = "http://s", annas_download_key = "k" }); stub(b7, SOURCES)
    local got = SRC.DEF.shelfmark.search(b7, "Tomorrow", PICK)
    local paths = {}
    for _, a in ipairs(b7.asked) do paths[#paths + 1] = a.path end
    ck(#b7.asked == 2 and paths[1] == "/api/release-sources" and paths[2]:find("source=prowlarr", 1, true), "Anna's set up here: Shelfmark asked for Prowlarr only (" .. table.concat(paths, " | ") .. ")")
    ck(got and #got == 1 and got[1].title == "prowlarr", "...and its results come back")
    ck(b7.asked[2].body == nil and type(b7.asked[2].text) == "string" and b7.asked[2].block == 30 and b7.asked[2].total == 150,
        "the request's message and timeouts in their places (the message was passed as the body)")
    SRC.DEF.shelfmark.search(b7, "Tomorrow", PICK)
    ck(#b7.asked == 3, "Shelfmark's source list asked once a session")
    local b8 = bb({ server_url = "http://s" }); stub(b8, SOURCES)       -- no Anna's here
    SRC.DEF.shelfmark.search(b8, "Tomorrow", PICK)
    ck(#b8.asked == 1 and not b8.asked[1].path:find("source=", 1, true), "Anna's not set up here: Shelfmark searches all its sources")
    local b9 = bb({ server_url = "http://s", annas_download_key = "k" }); stub(b9, "fail")
    SRC.DEF.shelfmark.search(b9, "Tomorrow", PICK)
    ck(#b9.asked == 2 and not b9.asked[2].path:find("source=", 1, true), "Shelfmark doesn't list its sources: all of them, as before")
    local b10 = bb({ server_url = "http://s", annas_download_key = "k" }); stub(b10, { SOURCES[1] })
    local _r, _e, _c, skipped = SRC.DEF.shelfmark.search(b10, "Tomorrow", PICK)
    ck(skipped == true and #b10.asked == 1, "Shelfmark's only source is Anna's: it sits out (not named as searched)")
end

print(string.format("=== %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
LUA
