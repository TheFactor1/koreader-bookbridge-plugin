#!/bin/bash
# Release matching (SRC.match, sortReleases) and stopping at the source that
# has the book itself. The Z-Library answers in fixtures/ are real: what its
# search returned for "The Kaiju Preservation Society John Scalzi" and "Dust
# Hugh Howey" on 2026-10-07 (Matt: the right book came up lower in the list;
# the English "Kaiju Preservation Society", without "The", sat under two
# Italian editions). Offline.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd); M="$REPO/bookbridge.koplugin/main.lua"
KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
[ -x "${KDIR:-/nonexistent}/luajit" ] || { echo "SKIP  no local KOReader (set KOREADER_DIR)"; exit 3; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
{ awk '/^-- ===== CO begin/{f=1} f{print} f&&/^-- ===== CO end/{exit}' "$M"
  awk 'index($0, "local function annasResultToRelease(") == 1 {f=1} f{print} f&&/^end$/{exit}' "$M"
  awk '/^-- ===== SRC begin/{f=1} f{print} f&&/^-- ===== SRC end/{exit}' "$M"
  for f in browseReleases browseReleasesContinue sortReleases sourcesInOrder companionState; do
      awk "/^function Bookbridge:$f\\(/{f=1} f{print} f&&/^end\$/{exit}" "$M"
  done
} > "$W/fns.lua"
grep -q "function SRC.match" "$W/fns.lua" || { echo "FAIL  extraction failed"; exit 1; }
sed -i 's/^local CO = {}/CO = {}/; s/^local SRC = {}/SRC = {}/' "$W/fns.lua"

cd "$KDIR" || exit 1
W="$W" FIX="$HERE/fixtures" ./luajit - <<'LUA'
package.path = "frontend/?.lua;common/?.lua;" .. package.path
package.cpath = "common/?.so;" .. package.cpath
local W, FIX = os.getenv("W"), os.getenv("FIX")
local json = require("json")
_ = function(s) return s end
T = require("ffi/util").template
lfs = { attributes = function() return nil end, mkdir = function() end, dir = function() return function() end end }
G_reader_settings = { readSetting = function() return nil end, saveSetting = function() end }
getPluginDir = function() return "/nonexistent/plugins/bookbridge.koplugin" end
Bookbridge = {}
STATUS_CHECK_MAX_AGE = 600
local LOG = {}
debugLog = function(m) LOG[#LOG + 1] = m end
truncate = function(s) return s end
socketurl = { escape = function(s) return s end }
describeAuthor = function(book) return (book.authors and book.authors[1]) or "" end
defaultReleaseQuery = function(book) return ((book.title or "") .. " " .. describeAuthor(book)):gsub("^%s+", ""):gsub("%s+$", "") end
decodeHtmlEntities = function(s) return s end
describeRelease = function() return "" end
PTF_HEADER, PTF_BOLD_START, PTF_BOLD_END = "", "", ""
attachCoverSupport = function() end
local SHOWN, MENU = {}, nil
UIManager = { show = function(_s, w) SHOWN[#SHOWN + 1] = w end, close = function() end, scheduleIn = function() end }
InfoMessage = { new = function(_s, t) t.kind = "info"; return t end }
Menu = { new = function(_s, t) MENU = t; return t end }
package.loaded["ui/trapper"] = { wrap = function(_s, f) f() end, dismissableRunInSubprocess = function(_s, f) return true, f() end }
dofile(W .. "/fns.lua")
local pass, fail = 0, 0
local function ck(c, m) if c then pass = pass + 1; print("PASS  " .. m) else fail = fail + 1; print("FAIL  " .. m) end end
local function load(name) local f = io.open(FIX .. "/" .. name); local d = json.decode(f:read("*a")); f:close(); return d end

-- a Z-Library plugin answering from a fixture; Anna's and Shelfmark counted
local ZL = { books = {} }
package.loaded["zlibrary.api"] = { search = function() ZL.calls = (ZL.calls or 0) + 1; return { results = ZL.books } end }
package.loaded["zlibrary.config"] = { getUserSession = function() return {} end }
local function bb(t)
    t = t or {}
    t.hardcover_language = t.hardcover_language or "en"
    t.asked = {}
    t.prefetchCovers = function() end
    t.annasSearch = function(self) self.asked[#self.asked + 1] = "annas"; return t._annas or {} end
    t.apiRequest = function(self, _m, path)
        if path:find("release%-sources") then return { { name = "prowlarr", enabled = true, supported_content_types = { "ebook" } } }, 200 end
        self.asked[#self.asked + 1] = "shelfmark"; return { releases = t._shelf or {} }, 200
    end
    return setmetatable(t, { __index = Bookbridge })
end
local KAIJU = { title = "The Kaiju Preservation Society", authors = { "John Scalzi" } }
local DUST = { title = "Dust", authors = { "Hugh Howey" } }
local function zlist(book, fixture)
    ZL.books = load(fixture)
    local b = bb({})
    local got = SRC.DEF.zlibrary.search(b, "q")
    b:sortReleases(got, book)
    return got
end
local function show(list, n)
    for i = 1, n do local r = list[i]; print(string.format("      %d. %s [%s %s]%s", i, r.title, r.format, tostring(r.language), r.exact_match and " =" or "")) end
end

-- 1. Kaiju: the English book first, Italian and Chinese editions below every English one
local k = zlist(KAIJU, "zlib-kaiju.json")
show(k, 8)
ck(k[1].language == "English" and k[1].format == "epub" and k[1].exact_match, "Kaiju: an English EPUB of the book on top, marked exact")
local last_english, first_other = 0, nil
for i, r in ipairs(k) do
    if r.language == "English" and r.exact_match then last_english = i end
    if r.language ~= "English" and not first_other then first_other = i end
end
ck(first_other and first_other > last_english, "Kaiju: every exact English copy above the first Italian/Chinese edition")
local found_no_the = false
for i = 1, 8 do if k[i].book_title == "Kaiju Preservation Society" then found_no_the = true end end
ck(found_no_the, "Kaiju: 'Kaiju Preservation Society' (no 'The') counts as the book")
local isbn = false
for i = 1, 10 do if k[i].book_title == "Kaiju Preservation Society (9780765389138)" and k[i].format == "epub" then isbn = true end end
ck(isbn, "Kaiju: a title with an ISBN in brackets counts as the book")
local junk_at
for i, r in ipairs(k) do if r.book_title and r.book_title:find("Preservation of paper") then junk_at = junk_at or i end end
ck(junk_at and junk_at > 20, "Kaiju: unrelated 'Preservation of paper...' at the bottom (" .. tostring(junk_at) .. ")")

-- 2. Dust: English EPUBs first; the Silo collection and Italian editions below them
local d = zlist(DUST, "zlib-dust.json")
show(d, 8)
ck(d[1].language == "English" and d[1].format == "epub" and d[1].exact_match, "Dust: an English EPUB of the book on top")
local coll, ita, eng_exact = nil, nil, 0
for i, r in ipairs(d) do
    if r.book_title and r.book_title:find("Collection") and not coll then coll = i end
    if r.language == "Italian" and not ita then ita = i end
    if r.exact_match then eng_exact = i end
end
ck(coll and coll > eng_exact, "Dust: 'The Silo Series Collection: ...Dust...' below every exact copy (" .. tostring(coll) .. ")")
ck(ita and ita > eng_exact, "Dust: Italian editions below every exact copy")
local series_prefix = false
for _u, r in ipairs(d) do if r.book_title == "Howey, Hugh - Silo 03 - Dust" then series_prefix = r.exact_match end end
ck(series_prefix, "Dust: 'Howey, Hugh - Silo 03 - Dust' counts as the book")
local pdf_exact = false
for _u, r in ipairs(d) do if r.format == "pdf" and r.exact_match then pdf_exact = true end end
ck(not pdf_exact, "a PDF is never 'exact' (doesn't end the search)")
local en_pdf_at, en_mobi_at
for i, r in ipairs(d) do
    if r.format == "pdf" and r.book_title == "Dust" and not en_pdf_at then en_pdf_at = i end
    if r.format == "mobi" and r.book_title == "Dust" and not en_mobi_at then en_mobi_at = i end
end
ck(en_mobi_at and en_pdf_at and en_mobi_at < en_pdf_at, "the same book: MOBI above PDF")

-- 3. the other kinds of names (Anna's, Shelfmark/Prowlarr)
local function m(r, book, lang) return SRC.match(r, book, lang or "en") end
ck(m({ title = "Hugh Howey - Dust (Silo #3) (epub)", format = "epub" }, DUST).exact, "Prowlarr 'Author - Title (Series) (epub)': exact")
ck(not m({ title = "Hugh Howey - Dust (Silo #3)", format = "epub", language = "de" }, DUST).exact, "...but not in German")
ck(m({ title = "Hugh Howey - Dust", book_title = "Dust", annas_author = "Hugh Howey", format = "epub", language = "English [en]" }, DUST).exact, "Anna's 'English [en]': exact")
local stand = { title = "The Stand", authors = { "Stephen King" } }
ck(m({ title = "Stephen King - The Stand", format = "epub" }, stand).score > m({ title = "Jack Reacher - Last Stand", format = "epub" }, stand).score + 900, "'Last Stand' is not The Stand")
local hhg = { title = "The Hitchhiker's Guide to the Galaxy", authors = { "Douglas Adams" } }
local panic = m({ title = "Neil Gaiman - Don't Panic: Douglas Adams and The Hitchhiker's Guide to the Galaxy", format = "epub" }, hhg)
local real = m({ title = "Douglas Adams - The Hitchhiker's Guide to the Galaxy", format = "epub" }, hhg)
ck(real.exact and not panic.exact and real.score > panic.score, "'Don't Panic' (about Adams, by Gaiman) below the novel; the novel's apostrophe matches")
ck(m({ title = "George Orwell - 1984 (2021) epub", format = "epub" }, { title = "1984", authors = { "George Orwell" } }).exact, "a year-titled book keeps its year")
ck(not m({ title = "Summary of Dust by Hugh Howey", format = "epub" }, DUST).exact, "a summary isn't the book")
ck(not m({ title = "Hugh Howey - Dust", format = "epub" }, DUST, "").exact == false, "no preferred language: any language may be exact")
ck(m({ title = "Hugh Howey - Dust", format = "epub", language = "Italian" }, DUST, "").exact, "...even one that says Italian")

-- 4. stopping: Z-Library has the book -> Anna's and Shelfmark aren't asked; the list offers them
local CONT
local real_cont = Bookbridge.browseReleasesContinue
local b = bb({ annas_download_key = "k", server_url = "http://s", sources_stop_exact = true })
ZL.books = load("zlib-kaiju.json")
SHOWN, MENU = {}, nil
b:browseReleases({ title = KAIJU.title, authors = KAIJU.authors, provider = "hardcover", provider_id = "1" })
ck(#b.asked == 0, "Z-Library had the book: Anna's and Shelfmark not asked (" .. table.concat(b.asked, ",") .. ")")
ck(MENU and MENU.item_table[2] and MENU.item_table[2].is_ask_rest and MENU.item_table[2].text:find("Anna's Archive, Shelfmark", 1, true), "the list offers 'Also ask Anna's Archive, Shelfmark'")
ck(MENU.item_table[3].release_data.exact_match, "...and the book itself right under it")
-- tapping it asks every source
local ask_menu = MENU
ask_menu.onMenuSelect(nil, ask_menu.item_table[2])
ck(#b.asked == 2 and b.asked[1] == "annas" and b.asked[2] == "shelfmark", "'Also ask': every source, in order")
ck(MENU ~= ask_menu and not MENU.item_table[2].is_ask_rest, "...and the new list has nothing left to offer")

-- 5. only foreign editions at Z-Library: it goes on to Anna's
local it_only = {}
for _u, r in ipairs(load("zlib-kaiju.json")) do if r.lang == "Italian" then it_only[#it_only + 1] = r end end
ZL.books = it_only
b = bb({ annas_download_key = "k", sources_stop_exact = true })
b:browseReleases(KAIJU)
ck(#b.asked == 1 and b.asked[1] == "annas", "no exact copy at Z-Library (Italian only): Anna's asked")
-- 6. switched off: everything asked
ZL.books = load("zlib-kaiju.json")
b = bb({ annas_download_key = "k", sources_stop_exact = false })
b:browseReleases(KAIJU)
ck(#b.asked == 1 and b.asked[1] == "annas", "'Stop at the exact book' off: every source asked")
local stopped_logged = false
for _u, l in ipairs(LOG) do if l:find("stopped at Z-Library", 1, true) then stopped_logged = true end end
ck(stopped_logged, "the stop is logged (which source, which weren't asked)")

print(string.format("=== %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
LUA
