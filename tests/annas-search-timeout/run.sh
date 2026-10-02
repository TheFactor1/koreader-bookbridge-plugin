#!/bin/bash
# Anna's search waits long enough for a slow service. annas-archive-api sends
# its whole answer at once after searching and fetching download counts; on
# 2026-10-02 that took ~10.5 s for 20 results and Bookbridge's 10 s silence
# limit gave up first ("no results" after picking a book). Runs the REAL
# doAnnasSearch with KOReader's real socket/http stack against a local server
# that answers after 12 s. Offline (127.0.0.1); KOReader's luajit; ~15 s.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
M=${1:-$REPO/bookbridge.koplugin/main.lua}
KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
[ -x "${KDIR:-/nonexistent}/luajit" ] || { echo "SKIP  no local KOReader (set KOREADER_DIR)"; exit 3; }
W=$(mktemp -d); PORT=18877
trap 'kill $SRV 2>/dev/null; rm -rf "$W"' EXIT
python3 - $PORT <<'PY' & SRV=$!
import http.server, sys, time, json
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        time.sleep(12)
        b = json.dumps({"query": "x", "count": 1, "results": [{"title": "Slow Book", "md5": "abc"}]}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
sleep 1
{ echo 'debugLog = function() end; _ = function(s) return s end; T = function(s) return s end; makeSocks5Socket = function() end'
  echo 'stripJsonNull = function(v) return v end'
  awk 'index($0, "local function doAnnasSearch(") == 1 {f=1} f{print} f&&/^end$/{exit}' "$M"
  echo 'SEARCH = doAnnasSearch'; } > "$W/fn.lua"
cd "$KDIR" || exit 1
SRC="$W/fn.lua" PORT=$PORT ./luajit - <<'LUA'
package.path = "common/?.lua;frontend/?.lua;" .. package.path
package.cpath = "common/?.so;common/?/?.so;libs/?.so;" .. package.cpath
require("ffi/loadlib")
package.loaded["device"] = { model = "test" }
socket = require("socket"); http = require("socket.http"); socketurl = require("socket.url")
socketutil = require("socketutil"); JSON = require("json")
assert(load(io.open(os.getenv("SRC")):read("*a")))()
local t0 = socket.gettime()
local results, _, err = SEARCH("http://127.0.0.1:" .. os.getenv("PORT"), "query", "key", "gd")
local took = socket.gettime() - t0
local n = type(results) == "table" and #(results.results or results) or 0
local ok = n > 0
print((ok and "PASS" or "FAIL") .. string.format("  a 12 s answer still arrives (%.1f s, %s)", took, ok and (n .. " result") or tostring(err)))
os.exit(ok and 0 or 1)
LUA
