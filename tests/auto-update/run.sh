#!/bin/bash
# Automatic updates, end to end on the desktop KOReader.
#
# Stages a deliberately stale copy of the plugin in a real plugins/bookbridge.koplugin
# folder, serves this checkout's files (with a freshly computed manifest) from a
# local HTTP server as the "self-hosted update source", launches KOReader with
# auto-update on, and then fires a Resume event -- what the device sends when
# it wakes. Asserts that the plugin checks by itself, installs the served build
# without any prompt, offers only the restart, and that a second wake inside
# the six-hour interval does nothing.
#
#   bash tests/auto-update/run.sh     # exit 0 = auto-update works, 3 = skipped
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
[ -x "${KDIR:-/nonexistent}/luajit" ] || { echo "SKIP  no local KOReader (set KOREADER_DIR)"; exit 3; }
INSPECT=8181; I="http://127.0.0.1:$INSPECT/koreader"
SRV=$(python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1])")  # a free port: 8093 belongs to a container on this box
CFG=~/.config/koreader; SET=$CFG/settings
W=$(mktemp -d); mkdir -p "$W/bak" "$W/served"; fail=0
say() { printf '%-6s%s\n' "$1" "$2"; }
P="$KDIR/plugins"
[ -f "$CFG/settings.reader.lua" ] && cp -a "$CFG/settings.reader.lua" "$W/bak/"
for f in shelfmark.lua shelfmark-debug.log; do [ -f "$SET/$f" ] && cp -a "$SET/$f" "$W/bak/"; done
had_link=0; [ -L "$P/bookbridge.koplugin" ] && { had_link=1; mv "$P/bookbridge.koplugin" "$W/bookbridge.link"; }
[ -e "$P/bookbridge.koplugin" ] && { say FAIL "a real $P/bookbridge.koplugin is in the way"; exit 1; }
stop_koreader() {
  setsid sh -c 'for p in $(ss -ltnp "( sport = :'"$INSPECT"' )" 2>/dev/null | grep -oE "pid=[0-9]+" | cut -d= -f2 | sort -u); do kill "$p" 2>/dev/null; done
    pkill -f "^\./luajit \./reader\.lua" 2>/dev/null; pkill -f "^/bin/sh \./koreader\.sh" 2>/dev/null; true' >/dev/null 2>&1
  for i in $(seq 1 10); do ss -ltn "( sport = :$INSPECT )" | tail -n +2 | grep -q . || break; sleep 1; done
}
cleanup() {
  stop_koreader; [ -n "${SRVPID:-}" ] && kill "$SRVPID" 2>/dev/null
  rm -rf "$P/bookbridge.koplugin"
  [ $had_link = 1 ] && mv "$W/bookbridge.link" "$P/bookbridge.koplugin"
  rm -f "$SET/shelfmark.lua" "$SET/shelfmark-debug.log"
  for f in "$W"/bak/*; do [ -e "$f" ] || continue; case "$(basename "$f")" in settings.reader.lua) cp -a "$f" "$CFG/";; *) cp -a "$f" "$SET/";; esac; done
  rm -rf "$W"
}
trap cleanup EXIT
# the served build: this checkout, with a manifest computed right now
cp "$REPO/bookbridge.koplugin/main.lua" "$REPO/bookbridge.koplugin/_meta.lua" "$W/served/"
python3 - "$W/served" <<'PY'
import hashlib, json, os, sys, re
d = sys.argv[1]; files = {}
for f in ("main.lua", "_meta.lua"):
    b = open(os.path.join(d, f), "rb").read(); files[f] = {"sha256": hashlib.sha256(b).hexdigest(), "size": len(b)}
ver = re.search(r'local PLUGIN_VERSION = "([^"]+)"', open(os.path.join(d, "main.lua")).read()).group(1)
json.dump({"schema": 1, "version": ver, "build": "autotest", "generated": "now", "files": files}, open(os.path.join(d, "manifest.json"), "w"), indent=2)
PY
(cd "$W/served" && python3 -m http.server "$SRV" --bind 127.0.0.1 >/dev/null 2>&1) & SRVPID=$!
for i in $(seq 1 10); do curl -s -o /dev/null "http://127.0.0.1:$SRV/manifest.json" && break; sleep 1; done
curl -s --max-time 3 "http://127.0.0.1:$SRV/manifest.json" | grep -q '"autotest"' && say PASS "test update server up on :$SRV" || { say FAIL "test update server not serving the manifest"; exit 1; }
# the installed copy: stale by one comment line, so checksums differ
mkdir -p "$P/bookbridge.koplugin"
cp "$W/served/main.lua" "$W/served/_meta.lua" "$P/bookbridge.koplugin/"
printf '\n-- test: deliberately-stale installed copy\n' >> "$P/bookbridge.koplugin/main.lua"
mkdir -p "$SET"; rm -f "$SET/shelfmark-debug.log"; cat > "$SET/shelfmark.lua" <<LUA
return { ["shelfmark"] = { ["download_dir"] = "$W", ["update_url"] = "http://127.0.0.1:$SRV", ["debug_log"] = true } }
LUA
stop_koreader
"$KDIR/luajit" -e "
local p=os.getenv('HOME')..'/.config/koreader/settings.reader.lua'
local ok,t=pcall(dofile,p); if not ok or type(t)~='table' then t={} end
t.httpinspector={port=$INSPECT,autostart=true}; t.plugins_disabled = {}
local function ser(v,ind) ind=ind or '' if type(v)=='table' then local o={'{\n'} for k,x in pairs(v) do o[#o+1]=ind..'    ['..(type(k)=='string' and string.format('%q',k) or tostring(k))..'] = '..ser(x,ind..'    ')..',\n' end o[#o+1]=ind..'}' return table.concat(o) elseif type(v)=='string' then return string.format('%q',v) else return tostring(v) end end
local f=assert(io.open(p,'w')) f:write('return '..ser(t)..'\n') f:close()"
launch() { (cd "$KDIR" && setsid -f ./koreader.sh > "$W/koreader.log" 2>&1); for i in $(seq 1 30); do curl -s -o /dev/null --max-time 2 "$I/" && return 0; sleep 1; done; return 1; }
launch || { say FAIL "inspector never answered"; exit 1; }
[ "$(curl -s --max-time 5 "$I/ui/bookbridge/auto_update")" = "true" ] && say PASS "auto-update is on by default" || { say FAIL "auto_update default is '$(curl -s --max-time 5 "$I/ui/bookbridge/auto_update")'"; fail=1; }
cmp -s "$P/bookbridge.koplugin/main.lua" "$W/served/main.lua" && { say FAIL "installed copy is not stale (test setup)"; fail=1; }
# the device wakes
curl -s --max-time 5 "$I/event/Resume" >/dev/null 2>&1
LOG="$SET/shelfmark-debug.log"
for i in $(seq 1 40); do cmp -s "$P/bookbridge.koplugin/main.lua" "$W/served/main.lua" && break; sleep 1; done
cmp -s "$P/bookbridge.koplugin/main.lua" "$W/served/main.lua" && say PASS "installed the served build by itself after the wake (main.lua now matches the manifest)" || { say FAIL "main.lua not updated within 40 s"; fail=1; }
reason=$(grep -oE '\[update\] auto \((wake|network|startup)\): checking' "$LOG" 2>/dev/null | head -1 | grep -oE '\((wake|network|startup)\)')
[ -n "$reason" ] && say PASS "checked from a hook, unprompted $reason" || { say FAIL "no '[update] auto (...)' line in the debug log"; fail=1; }
grep -q '\[update\] auto: installed' "$LOG" 2>/dev/null && say PASS "install logged" || { say FAIL "no install line in the debug log"; fail=1; }
shown=0; for t in $(seq 1 10); do for i in $(seq 1 8); do curl -s --max-time 3 "$I/UIManager/_window_stack/$i/widget/text" 2>/dev/null | grep -q "updated itself" && shown=1; done; [ $shown = 1 ] && break; sleep 1; done
[ $shown = 1 ] && say PASS "only the restart is asked about ('Bookbridge updated itself ... Restart now?')" || { say FAIL "no restart offer on the window stack"; fail=1; }
grep -qE "Checking for updates|Downloading update" "$W/koreader.log" && { say FAIL "a progress dialog was shown"; fail=1; } || say PASS "no progress dialogs"
# a second wake inside the interval must do nothing
n1=$(grep -c '\[update\] auto (' "$LOG"); curl -s --max-time 5 "$I/event/Resume" >/dev/null 2>&1; sleep 14
n2=$(grep -c '\[update\] auto (' "$LOG")
[ "$n1" = "$n2" ] && say PASS "second wake within six hours: no second check" || { say FAIL "second wake checked again ($n1 -> $n2)"; fail=1; }
curl -s --max-time 8 "$I/UIManager/quit/" >/dev/null 2>&1; stop_koreader
"$KDIR/luajit" -e "local t=dofile(os.getenv('HOME')..'/.config/koreader/settings/shelfmark.lua'); os.exit((t.shelfmark and tonumber(t.shelfmark.last_auto_update_check)) and 0 or 1)" 2>/dev/null \
  && say PASS "last check time persisted (survives a restart)" || { say FAIL "last_auto_update_check not saved"; fail=1; }
grep -E "ERROR|Traceback|attempt to" "$W/koreader.log" | grep -v "Font " | grep -q . && { say FAIL "KOReader errors:"; grep -E "ERROR|Traceback|attempt to" "$W/koreader.log" | grep -v "Font " | head -3; fail=1; } || say PASS "no KOReader errors"
if [ $fail -ne 0 ]; then
  echo "--- debug log:"; tail -n 12 "$LOG" 2>/dev/null | cut -c1-160
  echo "--- koreader.log (bookbridge/update/error lines):"; grep -iE "bookbridge|update|error|trapper|resume" "$W/koreader.log" | grep -v "Font " | tail -n 20 | cut -c1-200
fi
[ $fail -eq 0 ] && echo "=== AUTO UPDATE PASS" || echo "=== AUTO UPDATE FAIL"; exit $fail
