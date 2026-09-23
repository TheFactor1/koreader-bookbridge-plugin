#!/bin/bash
# saveAllSettings shows a confirmation only when it is given one.
#
# Found 2026-09-23: the automatic update check saves its timestamp through
# saveAllSettings() with no message, and InfoMessage's default text is "", so
# every check -- startup, wake, reconnect, up to ~4 a day -- flashed an empty
# box with just an icon. tests/auto-update stubs saveAllSettings, so nothing
# caught it. Runs the REAL function from main.lua. Offline; KOReader's luajit.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
M=${1:-$REPO/bookbridge.koplugin/main.lua}
KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
[ -x "${KDIR:-/nonexistent}/luajit" ] || { echo "SKIP  no local KOReader (set KOREADER_DIR)"; exit 3; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
awk '/^function Bookbridge:saveAllSettings/{f=1} f{print} f&&/^end$/{exit}' "$M" > "$W/fns.lua"
grep -q "saveAllSettings" "$W/fns.lua" || { echo "FAIL  extraction failed"; exit 1; }
cd "$KDIR" || exit 1
SRC="$W/fns.lua" ./luajit - <<'LUA'
local shown = {}
UIManager = { show = function(_s, w) shown[#shown + 1] = w end }
InfoMessage = { new = function(_s, t) return t end }
_ = function(s) return s end
Bookbridge = {}
assert(load(io.open(os.getenv("SRC")):read("*a")))()
local saved = 0
local s = { sm_settings = { saveSetting = function() saved = saved + 1 end, flush = function() end }, session_cookie = "c" }
local pass, fail = 0, 0
local function ck(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end
Bookbridge.saveAllSettings(s)
ck(saved == 1 and #shown == 0, "no message (the automatic update check): settings saved, nothing shown (shown " .. #shown .. ")")
ck(s.session_cookie == "c", "...and the Shelfmark session is kept (no needless re-login every few hours)")
Bookbridge.saveAllSettings(s, "Saved.")
ck(#shown == 1 and shown[1].text == "Saved.", "a message (every settings dialog): shown as before")
ck(s.session_cookie == nil, "...and the session is dropped, so new credentials are used on the next request")
print(string.format("=== %d passed, %d failure(s)", pass, fail))
os.exit(fail == 0 and 0 or 1)
LUA
