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
awk '/^-- ONE round trip\./{f=1} f{print} f&&/^end$/{exit}' \
    "$REPO/shelfmark.koplugin/main.lua" > "$W/fn.lua"
[ -s "$W/fn.lua" ] || { echo "FAIL  could not extract doHardcoverFindBook from main.lua"; exit 1; }
grep -q "^local function doHardcoverFindBook" "$W/fn.lua" || { echo "FAIL  extracted block is not doHardcoverFindBook"; exit 1; }

KDIR="$KDIR" FIX="$HERE/fixtures" LUA_FN="$W/fn.lua" "$KDIR/luajit" - <<'LUA'
local KDIR, FIX, LUA_FN = os.getenv("KDIR"), os.getenv("FIX"), os.getenv("LUA_FN")
package.path = KDIR.."/frontend/?.lua;"..KDIR.."/common/?.lua;"..package.path
package.cpath = KDIR.."/common/?.so;"..KDIR.."/libs/?.so;"..package.cpath
local JSON = require("rapidjson")
_ = function(s) return s end

local FIXTURE
doHardcoverGraphQL = function(_t, query)
    if query:find("books_by_pk", 1, true) or query:find("books(where", 1, true) then
        error("made a SECOND round trip -- the search must answer in one")
    end
    return FIXTURE.data, nil
end
local src = io.open(LUA_FN):read("*a")
local fn = assert(load("local doHardcoverGraphQL = doHardcoverGraphQL\n"..src.."\nreturn doHardcoverFindBook"))()

local pass, fail = 0, 0
local function load_fix(n)
    local f = assert(io.open(FIX.."/"..n..".json")); FIXTURE = JSON.decode(f:read("*a")); f:close()
end
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

load_fix("run")
local id = fn("tok", "Run", nil)
if id == 444340 then pass = pass + 1; print("PASS  no author -> top search hit")
else fail = fail + 1; print("FAIL  no author -> "..tostring(id)) end

print(pass.." passed, "..fail.." failed")
os.exit(fail == 0 and 0 or 1)
LUA
