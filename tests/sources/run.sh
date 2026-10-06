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
  for f in browseReleases browseReleasesContinue sortReleases getBook sourcesInOrder sourcesConfigured sourcesSummary companionState confirmReleaseRequest; do
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

-- 4. order and on/off
b = bb({ server_url = "http://s", _shelf = { { title = "Emma.epub", source = "prowlarr", indexer = "x" } } })
b:browseReleases({ title = "Emma" })
ck(#CONT.tried == 2 and CONT.tried[1] == "Z-Library" and CONT.tried[2] == "Shelfmark" and #CONT.releases == 3, "default order: Z-Library then Shelfmark, results merged")
b.sources_order = { "shelfmark", "zlibrary" }
b:browseReleases({ title = "Emma" })
ck(CONT.tried[1] == "Shelfmark" and CONT.tried[2] == "Z-Library", "order setting honoured")
b.sources_stop_first = true
b:browseReleases({ title = "Emma" })
ck(#CONT.tried == 1 and CONT.tried[1] == "Shelfmark" and #CONT.releases == 1, "stop at the first source with results")
b.sources_stop_first = false
b.sources_enabled = { zlibrary = false }
b:browseReleases({ title = "Emma" })
ck(#CONT.tried == 1 and CONT.tried[1] == "Shelfmark", "a switched-off source is skipped")
do
    local b2 = bb({}); b2.sources_enabled = { zlibrary = false }
    SHOWN = {}
    b2:browseReleases({ title = "Emma" })
    ck(SHOWN[#SHOWN] and SHOWN[#SHOWN].kind == "confirm" and SHOWN[#SHOWN].text:find("Z%-Library is turned off"), "the only source switched off: says so, not 'install it'")
end
ck(b:sourcesSummary() == "Shelfmark", "summary lists only enabled, configured sources")

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

print(string.format("=== %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
LUA
