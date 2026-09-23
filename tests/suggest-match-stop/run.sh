#!/bin/bash
# "Suggest match" stops at the first refusal instead of trying every shorter
# version of the title. It used to send one query per word of the filename
# whatever came back -- each a failed CWA login with a wrong password (CWA
# locks after 3 a minute), or a 15-45 s timeout each with the server down --
# then say "no candidates" (found 2026-09-23). Runs the REAL
# suggestMatchForFile from main.lua. Offline; KOReader's luajit.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
M=${1:-$REPO/bookbridge.koplugin/main.lua}
KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
[ -x "${KDIR:-/nonexistent}/luajit" ] || { echo "SKIP  no local KOReader (set KOREADER_DIR)"; exit 3; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
{ awk '/^local function stripTrailingParenGroups/{f=1} f{print} f&&/^end$/{exit}' "$M"
  awk '/^function Bookbridge:suggestMatchForFile/{f=1} f{print} f&&/^end$/{exit}' "$M"; } > "$W/fns.lua"
grep -q "suggestMatchForFile" "$W/fns.lua" || { echo "FAIL  extraction failed"; exit 1; }
cd "$KDIR" || exit 1
SRC="$W/fns.lua" ./luajit - <<'LUA'
_ = function(s) return s end
T = function(s, ...) local a = {...}; return (s:gsub("%%(%d+)", function(n) return tostring(a[tonumber(n)]) end)) end
socketurl = { escape = function(s) return s end }
parseOpdsEntries = function(body) return body == "HIT" and { { uuid = "u1", title = "Found", author = "A" } } or {} end
local Q, ANSWER = 0, nil
doCwaRequest = function() Q = Q + 1; return ANSWER() end
local shown, reviewed = {}, 0
UIManager = { show = function(_s, w) shown[#shown + 1] = w end }
InfoMessage = { new = function(_s, t) return t end }
package.loaded["ui/trapper"] = { dismissableRunInSubprocess = function(_s, f) return true, f() end }
Bookbridge = {}
assert(load(io.open(os.getenv("SRC")):read("*a")))()
local k = setmetatable({ cwa_url = "http://cwa", reviewUnmatched = function() reviewed = reviewed + 1 end }, { __index = Bookbridge })
local FILE = "/books/One Two Three Four Five Six - Some Author.epub"   -- 6 words: 6 queries on the full ladder
local pass, fail = 0, 0
local function ck(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end
local function run(answer) Q = 0; shown = {}; reviewed = 0; ANSWER = answer; k:suggestMatchForFile(FILE) end
run(function() return nil, 401 end)
ck(Q == 1, "wrong password: one request, not one per word (sent " .. Q .. "; the old code: 6)")
ck(shown[1] and tostring(shown[1].text):find("rejected the login", 1, true), "...and says the login was rejected, not \"no candidates\"")
run(function() return nil, 429 end)
ck(Q == 1 and tostring(shown[1].text):find("Wait a minute", 1, true), "locked out (429): one request, says to wait")
run(function() return nil, nil, "Couldn't reach Calibre-Web" end)
ck(Q == 1 and tostring(shown[1].text):find("Couldn't reach", 1, true), "server unreachable: one attempt, not a 15-45 s timeout per word")
-- unchanged: an ordinary 200 with no results still walks the ladder, and a hit still opens the review
local n = 0
run(function() n = n + 1; if n < 3 then return "", 200 end; return "HIT", 200 end)
ck(Q == 3 and reviewed == 1, "no results for the full title: shorter queries still tried, and a hit opens the review")
print(string.format("=== %d passed, %d failure(s)", pass, fail))
os.exit(fail == 0 and 0 or 1)
LUA
