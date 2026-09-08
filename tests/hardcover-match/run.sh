#!/bin/bash
# Hardcover book-matching regression test.
#
# doHardcoverFindBook used to make SIX sequential requests (a search, then five
# books_by_pk detail queries one at a time) -- six TLS round trips from a
# Kindle, which is why the progress-sync confirm took several seconds to show.
# It now makes ONE: Hardcover's search returns the full documents inline.
#
# That rewrite swapped the matching input from books_by_pk `contributions`
# (author objects carrying a role) to the search document's flat
# `author_names`, so this pins the behaviour that swap could silently break:
#
#   - the narrator trap: "Run" lists Phil Gigante (Reading) alongside Blake
#     Crouch (Author); the author must win
#   - author disambiguation among five identically-titled books
#   - "Crouch, Blake" (embedded EPUB metadata order) matching "Blake Crouch"
#   - no author, or an author that matches nothing -> top search hit
#
# The stubbed transport RAISES if a second round trip is attempted, so this
# also asserts the one-request property, not just the match results.
#
# Fixtures are real captured API responses (fixtures/*.json, no credentials).
# Offline: needs only KOReader's luajit for rapidjson.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
[ -x "${KDIR:-/nonexistent}/luajit" ] || { echo "SKIP  no local KOReader (set KOREADER_DIR)"; exit 3; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
# Pull the live function out of main.lua so the test can never drift from it.
awk '/^-- HARDCOVER MATCH BLOCK/{f=1} f{print} /^-- END HARDCOVER MATCH BLOCK/{exit}' \
    "$REPO/shelfmark.koplugin/main.lua" > "$W/fn.lua"
[ -s "$W/fn.lua" ] || { echo "FAIL  could not extract doHardcoverFindBook from main.lua"; exit 1; }
grep -q "^local function doHardcoverFindBook" "$W/fn.lua" || { echo "FAIL  extracted block is not doHardcoverFindBook"; exit 1; }

KDIR="$KDIR" FIX="$HERE/fixtures" LUA_FN="$W/fn.lua" "$KDIR/luajit" - <<'LUA'
local KDIR, FIX, LUA_FN = os.getenv("KDIR"), os.getenv("FIX"), os.getenv("LUA_FN")
package.path = KDIR.."/frontend/?.lua;"..KDIR.."/common/?.lua;"..package.path
package.cpath = KDIR.."/common/?.so;"..KDIR.."/libs/?.so;"..package.cpath
local JSON = require("rapidjson")
_ = function(s) return s end
debugLog = function() end

local FIXTURE
-- The language check is the one extra query allowed (and only when a
-- preference is passed); LANG_HAS says which ids have an edition in it.
LANG_HAS = nil
LANG_QUERIES = 0
-- Identifier lookups answer from IDENT_RESULT (nil = nothing on Hardcover);
-- Open Library answers from OL_RESULT. Both count their calls.
IDENT_RESULT, IDENT_QUERIES, OL_RESULT, OL_CALLS = nil, 0, nil, 0
fetchJsonUrl = function() OL_CALLS = OL_CALLS + 1; return OL_RESULT end
doHardcoverGraphQL = function(_t, query, vars)
    if query:find("ByIdentifiers", 1, true) then
        IDENT_QUERIES = IDENT_QUERIES + 1
        return IDENT_RESULT or { editions = {} }, nil
    end
    if query:find("editions(where", 1, true) then
        LANG_QUERIES = LANG_QUERIES + 1
        local books = {}
        for _, id in ipairs(vars.ids) do
            books[#books + 1] = { id = id, editions = (LANG_HAS and LANG_HAS[id]) and { { id = 1 } } or {} }
        end
        return { books = books }, nil
    end
    if query:find("books_by_pk", 1, true) or query:find("books(where", 1, true) then
        error("made a SECOND round trip -- the search must answer in one")
    end
    return FIXTURE.data, nil
end
local src = io.open(LUA_FN):read("*a")
local fn = assert(load("local doHardcoverGraphQL, fetchJsonUrl = doHardcoverGraphQL, fetchJsonUrl\n"..src.."\nreturn doHardcoverFindBook"))()

local pass, fail = 0, 0
local function load_fix(n)
    local f = assert(io.open(FIX.."/"..n..".json")); FIXTURE = JSON.decode(f:read("*a")); f:close()
end
ck_simple = function(c, m) if c then pass = pass + 1; print("PASS  " .. m) else fail = fail + 1; print("FAIL  " .. m) end end
local function check(what, fixture, title, author, want_id, want_author)
    load_fix(fixture)
    local ok, id, ft, fa = pcall(fn, "tok", title, author)
    if not ok then fail = fail + 1; print("FAIL  "..what..": "..tostring(id)); return end
    if id == want_id and fa == want_author then
        pass = pass + 1; print(string.format("PASS  %-46s -> %s by %s", what, tostring(ft), tostring(fa)))
    else
        fail = fail + 1
        print(string.format("FAIL  %s -> id=%s by %s (wanted id=%s by %s)",
            what, tostring(id), tostring(fa), tostring(want_id), tostring(want_author)))
    end
end

check("Red Rising / Pierce Brown",            "red_rising", "Red Rising", "Pierce Brown", 427473, "Pierce Brown")
check("Run: author beats narrator",           "run", "Run", "Blake Crouch",   427957, "Blake Crouch")
check("Run: 'Crouch, Blake' metadata order",  "run", "Run", "Crouch, Blake",  427957, "Blake Crouch")
check("Run: disambiguate (Ann Patchett)",     "run", "Run", "Ann Patchett",   375036, "Ann Patchett")
check("Run: disambiguate (Kody Keplinger)",   "run", "Run", "Kody Keplinger", 154842, "Kody Keplinger")
check("Upgrade / Blake Crouch",               "upgrade", "Upgrade", "Blake Crouch", 480253, "Blake Crouch")
check("Upgrade: unknown author -> top hit",   "upgrade", "Upgrade", "Nobody Here",  480253, "Blake Crouch")
check("Hunger Games / Suzanne Collins",       "hunger", "The Hunger Games", "Suzanne Collins", 88639, "Suzanne Collins")

-- the ranked alternatives ride along as a fifth value, in search order
load_fix("run")
local _i, _t, _a, _e, ranked = fn("tok", "Run", "Blake Crouch")
if type(ranked) == "table" and #ranked == 5 and ranked[1].id == 427957 and ranked[1].author == "Blake Crouch" then
    pass = pass + 1; print("PASS  ranked candidates returned best-first (5, the author match on top)")
else fail = fail + 1; print("FAIL  ranked candidates: " .. tostring(ranked and #ranked)) end

local best_early, bu = nil, -1
load_fix("run"); for _, h in ipairs(FIXTURE.data.search.results.hits) do local d=h.document; if d.title=="Run" and (tonumber(d.users_count) or 0) > bu then best_early, bu = tonumber(d.id), tonumber(d.users_count) or 0 end end
-- language preference: drops candidates without an edition in it...
load_fix("run"); LANG_HAS = { [427957] = true, [375036] = true }; LANG_QUERIES = 0
local lid, _lt, la = fn("tok", "Run", nil, "en")
ck_simple(LANG_QUERIES == 1, "a language preference costs exactly one extra batched query")
ck_simple(lid == 427957 or lid == 375036, "candidates without an English edition are dropped; an English one wins")
-- ...but never all of them
load_fix("run"); LANG_HAS = {}; LANG_QUERIES = 0
local lid2 = fn("tok", "Run", nil, "en")
ck_simple(lid2 == best_early, "no candidate in the language -> keep them all, usual pick stands")
-- ...and no preference means no extra query at all
load_fix("run"); LANG_QUERIES = 0
fn("tok", "Run", nil, "")
ck_simple(LANG_QUERIES == 0, "blank preference -> search stays one round trip")

-- no author: the most-read exact-title match wins (not merely the top hit)
load_fix("run")
local best, best_users = nil, -1
for _, h in ipairs(FIXTURE.data.search.results.hits) do
    local d = h.document
    if d.title == "Run" and (tonumber(d.users_count) or 0) > best_users then best, best_users = tonumber(d.id), tonumber(d.users_count) or 0 end
end
local id = fn("tok", "Run", nil)
if id == best then pass = pass + 1; print("PASS  no author -> most-read exact-title match ("..tostring(best)..")")
else fail = fail + 1; print("FAIL  no author -> "..tostring(id).." (wanted "..tostring(best)..")") end

-- confidence: what may sync silently and what must go to review
local function conf(fixture, title, author)
    load_fix(fixture); local cid, _t, _a, _e, _r, c = fn("tok", title, author); return cid, c
end
local cid, c = conf("red_rising", "Red Rising", "Pierce Brown")
ck_simple(cid == 427473 and c == true, "Red Rising / Pierce Brown -> confident")
cid, c = conf("threebody", "The Three-Body Problem", "Cixin Liu")
ck_simple(cid == 208339 and c == true, "Three-Body: real entry beats four near-empty duplicates, confident")
cid, c = conf("murderbot", "All Systems Red", "Martha Wells")
ck_simple(cid == 427971 and c == true, "All Systems Red: the novella, not the omnibus; confident")
cid, c = conf("hitchhiker", "The Ultimate Hitchhiker's Guide to the Galaxy", "Douglas Adams")
ck_simple(c == false, "Hitchhiker: title only contains a candidate -> NOT confident (review)")
ck_simple(cid == 427798, "  ...and the novel outranks the omnibus for a non-omnibus title")
cid, c = conf("hitchhiker", "The Ultimate Hitchhiker's Guide: Five Complete Novels and One Story", "Douglas Adams")
ck_simple(cid == 205829 and c == true, "  ...but an omnibus-titled file matches the omnibus, confident")
cid, c = conf("run", "Run", "Blake Crouch")
ck_simple(cid == 427957 and c == true, "Run / Blake Crouch -> confident")
-- metadata as devices actually hand it over
cid, c = conf("1984", "1984", "George Orwell\nPeter Hobley Davison")
ck_simple(cid == 379760 and c == true, "1984 with a newline-joined editor credit -> still confident")
cid, c = conf("1984", "1984", "George Orwell\nunknown author")
ck_simple(cid == 379760 and c == true, "1984 exactly as the Kindle credits it (\"unknown author\" second line) -> confident")
cid, c = conf("1984", "1984", "George Orwell; Shepard Fairey")
ck_simple(cid == 379760 and c == true, "  ...semicolon-joined too")
cid, c = conf("summerfrost", "Summer Frost (Forward collection)", "Blake Crouch")
ck_simple(cid == 427934 and c == true, "Summer Frost (Forward collection): parenthetical tag ignored -> confident")
cid, c = conf("run", "Run", "Nobody Here")
ck_simple(c == false, "author that matches nothing -> not confident")


-- identifiers: an ISBN in the file is an exact answer -- no title search at all
do
    IDENT_RESULT = { editions = { { id = 2670216, book_id = 208339, pages = 399, title = "The Three-Body Problem", language = { code2 = "en" },
        book = { id = 208339, title = "The Three-Body Problem", users_count = 9892, contributions = { { contribution = "Author", author = { name = "Cixin Liu" } } } } } } }
    IDENT_QUERIES = 0; FIXTURE = { data = { search = { ids = {}, results = { hits = {} } } } }
    local id, ft, fa, _e, ranked, c, _u, ed = fn("tok", "Three Body Problem (Z-Library)", "Liu", "en", "isbn:9780765382030\ncalibre:12")
    ck_simple(id == 208339 and c == true and fa == "Cixin Liu", "ISBN in the file -> confident match, whatever the title looks like")
    ck_simple(IDENT_QUERIES == 1 and ed and ed.id == 2670216 and ed.pages == 399, "  ...one identifier query; the file's own edition (399 pages) comes back")
    -- ASIN and hardcover-id parse too; hyphenated ISBN; garbage ignored
    local id2 = fn("tok", "Whatever", nil, "en", "mobi-asin:B00GUU9262 hardcover-id:669164 978-0-7653-8203-0")
    ck_simple(id2 == 208339 and IDENT_QUERIES == 2, "ASIN / hardcover-id / hyphenated ISBN all reach the identifier query")
    -- identifiers Hardcover doesn't know fall through to the normal title search
    IDENT_RESULT = nil; load_fix("upgrade")
    local id3, _t3, _a3, _e3, _r3, c3 = fn("tok", "Upgrade", "Blake Crouch", nil, "isbn:9999999999999")
    ck_simple(id3 == 480253 and c3 == true, "unknown ISBN -> falls back to the title search (still confident)")
end

-- Open Library second opinion: an unsure title search becomes exact via ISBN
do
    IDENT_RESULT = nil; OL_RESULT = nil; OL_CALLS = 0
    load_fix("hitchhiker")
    local _i, _t, _a, _e, _r, c = fn("tok", "The Ultimate Hitchhiker's Guide to the Galaxy", "Douglas Adams")
    ck_simple(c == false and OL_CALLS == 1, "not confident -> Open Library is asked once")
    OL_RESULT = { docs = { { title = "The Ultimate Hitchhiker's Guide to the Galaxy", author_name = { "Douglas Adams" }, isbn = { "9780345453747", "0345453743" } } } }
    IDENT_RESULT = { editions = { { id = 5, book_id = 427798, pages = 815, title = "The Ultimate Hitchhiker's Guide to the Galaxy", language = { code2 = "en" },
        book = { id = 427798, title = "The Ultimate Hitchhiker's Guide to the Galaxy", users_count = 3000, contributions = { { contribution = "Author", author = { name = "Douglas Adams" } } } } } } }
    IDENT_QUERIES = 0; OL_CALLS = 0; load_fix("hitchhiker")
    local id, _t2, fa, _e2, _r2, c2, _u, ed = fn("tok", "The Ultimate Hitchhiker's Guide to the Galaxy", "Douglas Adams")
    ck_simple(id == 427798 and c2 == true and fa == "Douglas Adams", "Open Library's ISBNs settle it on Hardcover -> confident")
    ck_simple(OL_CALLS == 1 and IDENT_QUERIES == 1 and ed and ed.pages == 815, "  ...one Open Library call, one identifier query, the edition's pages")
    -- a wrong Open Library hit (different author) is ignored
    OL_RESULT = { docs = { { title = "The Ultimate Hitchhiker's Guide to the Galaxy", author_name = { "Someone Else" }, isbn = { "9780000000000" } } } }
    IDENT_QUERIES = 0; load_fix("hitchhiker")
    local _i3, _t3, _a3, _e3, _r3, c3 = fn("tok", "The Ultimate Hitchhiker's Guide to the Galaxy", "Douglas Adams")
    ck_simple(c3 == false and IDENT_QUERIES == 0, "Open Library hit by another author is ignored -> stays review")
    -- confident title matches never consult Open Library
    OL_CALLS = 0; load_fix("red_rising"); fn("tok", "Red Rising", "Pierce Brown")
    ck_simple(OL_CALLS == 0, "a confident title match asks nobody else")
    OL_RESULT = nil; IDENT_RESULT = nil
end

print(pass.." passed, "..fail.." failed")
os.exit(fail == 0 and 0 or 1)
LUA
