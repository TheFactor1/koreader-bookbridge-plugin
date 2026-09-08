#!/bin/bash
# The rename on a device, end to end on the desktop KOReader.
#
# The updater installs into the folder the plugin runs from, so the first
# Bookbridge build lands inside the old shelfmark.koplugin folder on every
# device. This stages exactly that -- Bookbridge's files in a real directory
# named shelfmark.koplugin, no bookbridge.koplugin present -- launches
# KOReader, and asserts that the plugin copies itself into bookbridge.koplugin,
# disables the old folder in plugins_disabled, offers a restart; then, on a
# second launch (running from bookbridge.koplugin), removes the old folder.
#
#   bash tests/rename-migration/run.sh     # exit 0 = migration works, 3 = skipped
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
[ -x "${KDIR:-/nonexistent}/luajit" ] || { echo "SKIP  no local KOReader (set KOREADER_DIR)"; exit 3; }
INSPECT=8181; I="http://127.0.0.1:$INSPECT/koreader"
CFG=~/.config/koreader; SET=$CFG/settings
W=$(mktemp -d); mkdir -p "$W/bak"; fail=0
say() { printf '%-6s%s\n' "$1" "$2"; }
P="$KDIR/plugins"
[ -f "$CFG/settings.reader.lua" ] && cp -a "$CFG/settings.reader.lua" "$W/bak/"
[ -f "$SET/shelfmark.lua" ] && cp -a "$SET/shelfmark.lua" "$W/bak/"
# the real bookbridge.koplugin symlink is parked for the duration
had_link=0; [ -L "$P/bookbridge.koplugin" ] && { had_link=1; mv "$P/bookbridge.koplugin" "$W/bookbridge.link"; }
[ -e "$P/bookbridge.koplugin" ] && { say FAIL "a real $P/bookbridge.koplugin is in the way"; exit 1; }
[ -e "$P/shelfmark.koplugin" ] && { say FAIL "$P/shelfmark.koplugin already exists"; exit 1; }
stop_koreader() {
  setsid sh -c 'for p in $(ss -ltnp "( sport = :'"$INSPECT"' )" 2>/dev/null | grep -oE "pid=[0-9]+" | cut -d= -f2 | sort -u); do kill "$p" 2>/dev/null; done
    pkill -f "^\./luajit \./reader\.lua" 2>/dev/null; pkill -f "^/bin/sh \./koreader\.sh" 2>/dev/null; true' >/dev/null 2>&1
  for i in $(seq 1 10); do ss -ltn "( sport = :$INSPECT )" | tail -n +2 | grep -q . || break; sleep 1; done
}
cleanup() {
  stop_koreader
  rm -rf "$P/shelfmark.koplugin" "$P/bookbridge.koplugin"
  [ $had_link = 1 ] && mv "$W/bookbridge.link" "$P/bookbridge.koplugin"
  rm -f "$SET/shelfmark.lua"
  for f in "$W"/bak/*; do [ -e "$f" ] || continue; case "$(basename "$f")" in settings.reader.lua) cp -a "$f" "$CFG/";; *) cp -a "$f" "$SET/";; esac; done
  rm -rf "$W"
}
trap cleanup EXIT
# stage: Bookbridge's files inside a folder still called shelfmark.koplugin
mkdir -p "$P/shelfmark.koplugin"
cp "$REPO/bookbridge.koplugin/main.lua" "$REPO/bookbridge.koplugin/_meta.lua" "$REPO/bookbridge.koplugin/manifest.json" "$P/shelfmark.koplugin/"
mkdir -p "$SET"; cat > "$SET/shelfmark.lua" <<LUA
return { ["shelfmark"] = { ["download_dir"] = "$W" } }
LUA
stop_koreader
"$KDIR/luajit" -e "
local p=os.getenv('HOME')..'/.config/koreader/settings.reader.lua'
local ok,t=pcall(dofile,p); if not ok or type(t)~='table' then t={} end
t.httpinspector={port=$INSPECT,autostart=true}; t.plugins_disabled = {}
local function ser(v,ind) ind=ind or '' if type(v)=='table' then local o={'{\n'} for k,x in pairs(v) do o[#o+1]=ind..'    ['..(type(k)=='string' and string.format('%q',k) or tostring(k))..'] = '..ser(x,ind..'    ')..',\n' end o[#o+1]=ind..'}' return table.concat(o) elseif type(v)=='string' then return string.format('%q',v) else return tostring(v) end end
local f=assert(io.open(p,'w')) f:write('return '..ser(t)..'\n') f:close()"
launch() { (cd "$KDIR" && setsid -f ./koreader.sh > "$W/koreader-$1.log" 2>&1); for i in $(seq 1 30); do curl -s -o /dev/null --max-time 2 "$I/" && return 0; sleep 1; done; return 1; }
# --- first start: running from the OLD folder
launch 1 || { say FAIL "inspector never answered (first start)"; exit 1; }
sleep 4
[ -f "$P/bookbridge.koplugin/main.lua" ] && say PASS "copied itself into plugins/bookbridge.koplugin" || { say FAIL "no bookbridge.koplugin created"; fail=1; }
cmp -s "$P/bookbridge.koplugin/main.lua" "$REPO/bookbridge.koplugin/main.lua" && say PASS "the copy is byte-identical" || { say FAIL "copied main.lua differs"; fail=1; }
shown=0; for i in $(seq 1 8); do curl -s --max-time 3 "$I/UIManager/_window_stack/$i/widget/text" 2>/dev/null | grep -q "Bookbridge" && shown=1; done
[ $shown = 1 ] && say PASS "restart offer on screen ('Shelfmark is now Bookbridge ... Restart now?')" || { say FAIL "no restart confirmation on the window stack"; fail=1; }
# a clean exit flushes settings
curl -s --max-time 8 "$I/event/Close" >/dev/null 2>&1; sleep 1; curl -s --max-time 8 "$I/UIManager/quit/" >/dev/null 2>&1; stop_koreader
grep -q 'plugins_disabled' "$CFG/settings.reader.lua" && "$KDIR/luajit" -e "local t=dofile(os.getenv('HOME')..'/.config/koreader/settings.reader.lua'); os.exit((t.plugins_disabled and t.plugins_disabled.shelfmark==true) and 0 or 1)" \
  && say PASS "old folder disabled in plugins_disabled (shelfmark = true)" || { say FAIL "plugins_disabled.shelfmark not set"; fail=1; }
grep -E "ERROR|Traceback|attempt to" "$W/koreader-1.log" | grep -v "Font " | grep -q . && { say FAIL "KOReader errors (first start):"; grep -E "ERROR|Traceback|attempt to" "$W/koreader-1.log" | grep -v "Font " | head -3; fail=1; } || say PASS "no KOReader errors on the first start"
# --- second start: now loads from bookbridge.koplugin (old folder disabled)
launch 2 || { say FAIL "inspector never answered (second start)"; exit 1; }
sleep 4
[ "$(curl -s --max-time 5 "$I/ui/bookbridge/download_dir" | tr -d '"')" = "$W" ] && say PASS "second start: the plugin answers as 'bookbridge'" || { say FAIL "second start: no bookbridge module (got '$(curl -s --max-time 5 "$I/ui/bookbridge/download_dir")')"; fail=1; }
[ -d "$P/shelfmark.koplugin" ] && { say FAIL "old shelfmark.koplugin folder still present after the second start"; fail=1; } || say PASS "old shelfmark.koplugin folder removed"
"$KDIR/luajit" -e "local t=dofile(os.getenv('HOME')..'/.config/koreader/settings.reader.lua'); os.exit((t.plugins_disabled and t.plugins_disabled.shelfmark) and 1 or 0)" 2>/dev/null \
  && say PASS "plugins_disabled entry cleared" || say INFO "plugins_disabled.shelfmark still set (cleared on exit flush)"
grep -E "ERROR|Traceback|attempt to" "$W/koreader-2.log" | grep -v "Font " | grep -q . && { say FAIL "KOReader errors (second start):"; grep -E "ERROR|Traceback|attempt to" "$W/koreader-2.log" | grep -v "Font " | head -3; fail=1; } || say PASS "no KOReader errors on the second start"
[ $fail -eq 0 ] && echo "=== RENAME MIGRATION PASS" || echo "=== RENAME MIGRATION FAIL"; exit $fail
