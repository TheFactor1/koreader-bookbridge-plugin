#!/bin/bash
# Anna's Archive straight from the reader (AA): the search page is read
# right (real capture, 50 results), the sign-in cookie is picked out of a
# comma-joined Set-Cookie, a bot check and a parked domain are told apart
# from a bad key, a challenged domain is skipped for the next one and the
# working one remembered, a stale session signs in once more, the seam in
# doAnnasSearch routes to AA when no helper URL is set. Offline: every
# request is answered by a script.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd); M="$REPO/bookbridge.koplugin/main.lua"
KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
[ -x "${KDIR:-/nonexistent}/luajit" ] || { echo "SKIP  no local KOReader (set KOREADER_DIR)"; exit 3; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
{ awk '/^-- ===== AA begin/{f=1} f{print} f&&/^-- ===== AA end/{exit}' "$M"
  awk 'index($0, "local function doAnnasSearch(") == 1 {f=1} f{print} f&&/^end$/{exit}' "$M"
} > "$W/aa.lua"
grep -q "function AA.search" "$W/aa.lua" || { echo "FAIL  extraction failed"; exit 1; }
sed -i 's/^local AA = {}/AA = {}/; s/^local function doAnnasSearch(/function doAnnasSearch(/' "$W/aa.lua"
F="$HERE/fixtures"

cd "$KDIR" || exit 1
W="$W" F="$F" ./luajit - <<'LUA'
package.path = "frontend/?.lua;common/?.lua;" .. package.path
package.cpath = "common/?.so;libs/?.so;" .. package.cpath
local W, F = os.getenv("W"), os.getenv("F")
_ = function(s) return s end
T = require("ffi/util").template
JSON = require("json")
socketurl = require("socket.url"); ltn12 = require("ltn12"); socket = require("socket")
socketutil = { set_timeout = function() end, reset_timeout = function() end, table_sink = function() local t = {} return ltn12.sink.table(t), t end,
               TIMEOUT_CODE = "timeout", SINK_TIMEOUT_CODE = "sink_timeout" }
local LOG = {}
debugLog = function(m) LOG[#LOG + 1] = m end
stripJsonNull = function(v) return v end
makeSocks5Socket = function() end
local function read(p) local f = assert(io.open(p, "rb")); local d = f:read("*a"); f:close(); return d end
local function hdrs(p) local h = {} for l in io.lines(p) do local k, v = l:match("^([%w%-]+):%s*(.-)\r?$"); if k then h[k:lower()] = v end end return h end
local SEARCH = read(F .. "/search-signed-in.html")
local CHALLENGE, CHALLENGE_H = read(F .. "/challenge.html"), hdrs(F .. "/challenge.headers.txt")
local PARKED = read(F .. "/parked.html")
local SETCOOKIE = {}
for l in io.lines(F .. "/login.set-cookie.txt") do SETCOOKIE[#SETCOOKIE + 1] = l end
local SETCOOKIE_JOINED = table.concat(SETCOOKIE, ", ")   -- (as LuaSocket hands several headers over)

-- the scripted web: a table of host -> function(method, url, headers, body) -> code, headers, body
local WEB = {}
local CALLS = {}
https = { request = function(req)
    local host = req.url:match("^https://([^/]+)")
    local path = req.url:match("^https://[^/]+(.*)$") or "/"
    local body
    if req.source then local parts = {} while true do local c = req.source() if not c then break end parts[#parts + 1] = c end body = table.concat(parts) end
    CALLS[#CALLS + 1] = { host = host, path = path, method = req.method, cookie = req.headers and req.headers["Cookie"], body = body }
    local f = WEB[host]
    if not f then return nil, "host not found" end
    local code, headers, rbody = f(req.method, path, req.headers, body)
    if rbody and req.sink then req.sink(rbody); req.sink(nil) end
    return 1, code, headers or {}, ""
end }
dofile(W .. "/aa.lua")
local pass, fail = 0, 0
local function ck(c, m) if c then pass = pass + 1; print("PASS  " .. m) else fail = fail + 1; print("FAIL  " .. m) end end
local function good_site(opts)
    opts = opts or {}
    return function(method, path, headers, body)
        if method == "POST" and path == "/account/" then
            if body and body:find("key=good") then return 302, { ["set-cookie"] = SETCOOKIE_JOINED, location = "/account/" }, "" end
            return 200, {}, "<html><title>Anna\226\128\153s Archive</title>Log in</html>"
        end
        if path:match("^/search") then
            if headers and headers["Cookie"] and headers["Cookie"]:find("aa_account_id2=") then return 200, {}, opts.search or SEARCH end
            return 403, CHALLENGE_H, CHALLENGE
        end
        if path:match("^/dyn/api/fast_download%.json") then
            if path:find("key=good") then return 200, {}, '{"download_url":"https://files.example/book.epub","account_fast_download_info":{"downloads_left":41}}' end
            return 200, {}, '{"error":"Invalid secret key","account_fast_download_info":null}'
        end
        if path:match("^/md5/") then return 200, {}, "<html>ISBN-13: <b>9780141439686</b></html>" end
        if path == "/" then return 200, { server = "ddos-guard" }, "<html>Anna\226\128\153s Archive</html>" end
        return 404, {}, ""
    end
end
WEB["raw.githubusercontent.com"] = function() return 200, {}, '{"tlds":["gd","gl","pk"]}' end

-- 1. the search page
local r = AA.parseSearch(SEARCH, "https://annas-archive.gl")
ck(#r == 50, "50 results parsed from the real page (" .. #r .. ")")
ck(r[1].md5 == "4bde41a3634c90cded297a9b98e9ead4" and r[1].title == "Persuasion" and r[1].author == "Austen, Jane", "first result: md5, title, author")
ck(r[1].format == "mobi" and r[1].size == "1.8MB" and r[1].year == "1818" and r[1].language == "English [en]" and r[1].content_type == "Book (fiction)", "first result: format, size, year, language, type")
ck(r[1].cover_url and r[1].cover_url:match("^https://covers%."), "first result: cover URL")
ck(r[2].format == "epub" and r[2].year == "2018", "second result: epub, 2018")
local bad = 0
for _, x in ipairs(r) do if not x.md5:match("^%x+$") or #x.md5 ~= 32 or x.title == "" then bad = bad + 1 end end
ck(bad == 0, "every result has a 32-hex md5 and a title")
ck(AA.parseSearch("<html>nothing here</html>", "https://x")[1] == nil, "a page without results parses to none")

-- 2. metadata line by shape, entities
local m = AA.parseMeta("Spanish [es] \194\183 PDF \194\183 12.3 MB \194\183 \240\159\147\152 Book (non-fiction)")
ck(m.language == "Spanish [es]" and m.format == "pdf" and m.size == "12.3 MB" and m.year == nil and m.content_type == "Book (non-fiction)", "meta without a year")
m = AA.parseMeta("EPUB \194\183 0.4MB \194\183 2014")
ck(m.format == "epub" and m.size == "0.4MB" and m.year == "2014" and m.language == nil, "meta without a language")
ck(AA.decodeEntities("Tom &amp; Jerry&#8217;s &quot;book&quot; &#x1F4D5;") == "Tom & Jerry\226\128\153s \"book\" \240\159\147\149", "entities: named, decimal, hex")
ck(AA.clean("<b>A</b>&nbsp;B<script>x</script>  C") == "A B C", "clean: tags, nbsp, scripts, whitespace")

-- 3. cookies, challenge, parking
local cookie = AA.parseSetCookies({ ["set-cookie"] = SETCOOKIE_JOINED })
ck(cookie == "aa_account_id2=SCRUBBED-SESSION-VALUE", "the aa_ cookie out of a comma-joined Set-Cookie (dates with commas intact)")
ck(AA.parseSetCookies({ ["set-cookie"] = "__ddg1_=x; Path=/, aa_account_id2=abc; Path=/, aa_other=def; Path=/" }) == "aa_account_id2=abc; aa_other=def", "several aa_ cookies joined")
ck(AA.isChallenge(403, CHALLENGE_H) == true and AA.isChallenge(200, CHALLENGE_H) == false, "DDoS-Guard 403 is a challenge; a 200 isn't")
ck(AA.isChallenge(302, { location = "/search?q=x&check=1" }) == true, "a redirect to ?check=1 is a challenge")
ck(AA.looksLikeAnnas(SEARCH) == true and AA.looksLikeAnnas(PARKED) == false and AA.looksLikeAnnas(CHALLENGE) == false, "the real site is recognised; a parked domain and the bot check aren't")

-- 4. sign-in
WEB["annas-archive.gd"] = good_site()
local c, code, err, ecode = AA.login("https://annas-archive.gd", "good")
ck(c == "aa_account_id2=SCRUBBED-SESSION-VALUE", "login with a good key: the session cookie")
c, code, err, ecode = AA.login("https://annas-archive.gd", "bad")
ck(c == nil and code == 401 and err == AA.KEY_REJECTED and ecode == "KEY", "a bad key: 401 with the exact text the status screen looks for")
WEB["annas-archive.li"] = function() return 200, { server = "Apache" }, PARKED end
c, code, err, ecode = AA.login("https://annas-archive.li", "good")
ck(c == nil and ecode == "MIRROR_DOWN", "a parked domain: MIRROR_DOWN, not a key problem")
WEB["annas-archive.xx"] = nil
c, code, err, ecode = AA.login("https://annas-archive.xx", "good")
ck(c == nil and ecode == "MIRROR_DOWN", "no connection: MIRROR_DOWN")

-- 5. a search, the session reused, then a stale session signed in again
CALLS = {}
local results, code2, err2, ecode2, extra = AA.search("gd", "good", "persuasion austen", nil, { tlds = { "gd" }, at = os.time() })
ck(results and #results == 20 and code2 == 200, "search: 20 results (the page's 50, capped)")
ck(extra and extra.session and extra.session.cookie and extra.tld == "gd" and extra.switched == false, "search returns the session and the domain it used")
local n_login = 0; for _, call in ipairs(CALLS) do if call.path == "/account/" then n_login = n_login + 1 end end
ck(n_login == 1, "signed in once")
CALLS = {}
results, code2, err2, ecode2, extra = AA.search("gd", "good", "emma", extra.session, extra.mirrors)
n_login = 0; for _, call in ipairs(CALLS) do if call.path == "/account/" then n_login = n_login + 1 end end
ck(results and n_login == 0, "a fresh session is reused: no second sign-in")
-- a stale cookie: the site challenges, the client signs in once and retries
local stale = { cookie = "aa_account_id2=OLD", at = os.time(), tld = "gd" }
WEB["annas-archive.gd"] = function(method, path, headers, body)
    if path:match("^/search") and headers["Cookie"] == "aa_account_id2=OLD" then return 403, CHALLENGE_H, CHALLENGE end
    return good_site()(method, path, headers, body)
end
CALLS = {}
results, code2, err2, ecode2, extra = AA.search("gd", "good", "emma", stale, { tlds = { "gd" }, at = os.time() })
n_login = 0; for _, call in ipairs(CALLS) do if call.path == "/account/" then n_login = n_login + 1 end end
ck(results and n_login == 1 and extra.session.cookie ~= "aa_account_id2=OLD", "a stale session: challenged once, signed in again, results")
-- a probe: one result
results = AA.search("gd", "good", "the", nil, { tlds = { "gd" }, at = os.time() }, { probe = true })
ck(results and #results == 1, "probe: one result")
-- a session for another domain isn't reused
local other = { cookie = "aa_account_id2=GL", at = os.time(), tld = "gl" }
CALLS = {}
results = AA.search("gd", "good", "emma", other, { tlds = { "gd" }, at = os.time() })
n_login = 0; for _, call in ipairs(CALLS) do if call.path == "/account/" then n_login = n_login + 1 end end
ck(results and n_login == 1, "a session from another domain is not reused")
-- an expired session
local old = { cookie = "aa_account_id2=X", at = os.time() - 7 * 3600, tld = "gd" }
CALLS = {}
results = AA.search("gd", "good", "emma", old, { tlds = { "gd" }, at = os.time() })
n_login = 0; for _, call in ipairs(CALLS) do if call.path == "/account/" then n_login = n_login + 1 end end
ck(results and n_login == 1, "a session older than six hours signs in again")

-- 6. domains: a challenged one is skipped, the working one remembered; all dead; a bad key stops the hunt
WEB["annas-archive.gd"] = function(method, path, headers, body)
    if method == "POST" then return good_site()(method, path, headers, body) end
    return 403, CHALLENGE_H, CHALLENGE   -- (signed in or not: this domain challenges everything)
end
WEB["annas-archive.gl"] = good_site()
WEB["annas-archive.pk"] = good_site()
CALLS = {}
results, code2, err2, ecode2, extra = AA.search("gd", "good", "emma", nil, nil)
ck(results and extra.tld == "gl" and extra.switched == true, "gd challenges even signed in -> gl answers, reported as switched")
local fetched_list = false; for _, call in ipairs(CALLS) do if call.host == "raw.githubusercontent.com" then fetched_list = true end end
ck(fetched_list and extra.mirrors and extra.mirrors.tlds[2] == "gl", "the domain list was fetched from the repository and comes back for caching")
CALLS = {}
results, code2, err2, ecode2, extra = AA.search("gl", "good", "emma", extra.session, extra.mirrors)
fetched_list = false; for _, call in ipairs(CALLS) do if call.host == "raw.githubusercontent.com" then fetched_list = true end end
ck(results and not fetched_list, "a day-fresh domain list is not fetched again")
WEB["annas-archive.gl"] = nil; WEB["annas-archive.pk"] = nil
results, code2, err2, ecode2, extra = AA.search("gd", "good", "emma", nil, { tlds = { "gd", "gl", "pk" }, at = os.time() })
ck(results == nil and ecode2 == "CHALLENGE", "every domain down or challenged: the last reason (CHALLENGE) is reported")
WEB["annas-archive.gl"] = good_site()
results, code2, err2, ecode2, extra = AA.search("gd", "bad", "emma", nil, { tlds = { "gd", "gl" }, at = os.time() })
ck(results == nil and code2 == 401 and err2 == AA.KEY_REJECTED, "a bad key: reported at once (another domain won't help)")
-- too many redirects
WEB["annas-archive.pk"] = function(method, path) if method == "POST" then return 302, { ["set-cookie"] = SETCOOKIE_JOINED }, "" end return 302, { location = "/search?q=x&r=" .. tostring(math.random()) }, "" end
results, code2, err2, ecode2 = AA.searchOn("pk", "good", "emma", nil)
ck(results == nil and ecode2 == "MIRROR_DOWN" and err2:find("redirects"), "a redirect loop: MIRROR_DOWN after 5 hops")

-- 7. mirror refresh, download link, isbn
WEB["annas-archive.gd"] = function(method, path, headers, body) return 403, CHALLENGE_H, CHALLENGE end
WEB["annas-archive.gl"] = good_site()
local ref = AA.refreshMirror("gd", "good", nil)
ck(ref.previousTld == "gd" and ref.activeTld == "gd" and ref.allDead == false, "refresh: a challenged domain still counts as alive (the site is there)")
WEB["annas-archive.gd"] = nil; WEB["annas-archive.pk"] = nil
ref = AA.refreshMirror("gd", "good", { tlds = { "gd", "gl", "pk" }, at = os.time() })
ck(ref.activeTld == "gl" and ref.switched == true, "refresh: gd unreachable -> gl")
WEB["annas-archive.gl"] = nil
ref = AA.refreshMirror("gd", "good", { tlds = { "gd", "gl", "pk" }, at = os.time() })
ck(ref.allDead == true, "refresh: nothing answers -> allDead")
WEB["annas-archive.gl"] = good_site()
local url, ucode, uerr = AA.fastDownload("gl", "good", "4bde41a3634c90cded297a9b98e9ead4")
ck(url == "https://files.example/book.epub", "download link from fast_download.json")
url, ucode, uerr = AA.fastDownload("gl", "bad", "4bde41a3634c90cded297a9b98e9ead4")
ck(url == nil and uerr:find("Invalid secret key"), "a refused download: the site's own reason")
local isbn, sess = AA.fetchIsbn("gl", "good", "4bde41a3634c90cded297a9b98e9ead4", nil)
ck(isbn == "9780141439686" and sess and sess.cookie, "isbn off the book page, with the session")

-- 8. the seam: no helper URL + a key -> AA; no key -> told
WEB["annas-archive.gd"] = good_site()
results, code2, err2, ecode2, extra = doAnnasSearch("", "good", "gd", "persuasion", nil, { probe = true, mirrors = { tlds = { "gd" }, at = os.time() } })
ck(results and #results == 1 and extra and extra.session, "doAnnasSearch with no helper URL goes direct (probe: 1 result, session back)")
results, code2, err2 = doAnnasSearch("", "", "gd", "persuasion", nil, {})
ck(results == nil and err2:find("key"), "no helper URL and no key: asked for the key")
ck(doAnnasSearch(nil, nil, "gd", "x", nil, {}) == nil, "nil everywhere: no crash")

print(string.format("=== %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
LUA
