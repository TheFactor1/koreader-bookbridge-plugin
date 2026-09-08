#!/bin/bash
# Bluetooth keyboard menu (Kindle-only feature) exercised on the desktop
# KOReader with BOOKBRIDGE_BT_FORCE=1: the submenu appears under Bookbridge,
# the engine script gets written, the Status step runs detached and its
# result opens in a viewer -- KOReader never blocked. Sandboxes settings like
# the other live tests; never touches a device.
#
#   bash tests/bt-keyboard/run.sh     # exit 0 = pass, 3 = skipped
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
[ -x "${KDIR:-/nonexistent}/luajit" ] || { echo "SKIP  no local KOReader (set KOREADER_DIR)"; exit 3; }
[ -e "$KDIR/plugins/bookbridge.koplugin" ] || { echo "FAIL  $KDIR/plugins/bookbridge.koplugin missing"; exit 1; }
INSPECT=8181; I="http://127.0.0.1:$INSPECT/koreader"
CFG=~/.config/koreader; SET=$CFG/settings
W=$(mktemp -d); mkdir -p "$W/bak" "$W/bt"; fail=0
say() { printf '%-6s%s\n' "$1" "$2"; }
for f in "$SET/shelfmark.lua" "$CFG/settings.reader.lua"; do [ -f "$f" ] && cp -a "$f" "$W/bak/$(basename "$f")"; done
stop_koreader() {
  setsid sh -c 'for p in $(ss -ltnp "( sport = :'"$INSPECT"' )" 2>/dev/null | grep -oE "pid=[0-9]+" | cut -d= -f2 | sort -u); do kill "$p" 2>/dev/null; done
    pkill -f "^\./luajit \./reader\.lua" 2>/dev/null; pkill -f "^/bin/sh \./koreader\.sh" 2>/dev/null; true' >/dev/null 2>&1
  for i in $(seq 1 10); do ss -ltn "( sport = :$INSPECT )" | tail -n +2 | grep -q . || break; sleep 1; done
}
cleanup() { stop_koreader; rm -f "$SET/shelfmark.lua"; for f in "$W"/bak/*; do [ -e "$f" ] || continue; case "$(basename "$f")" in settings.reader.lua) cp -a "$f" "$CFG/";; *) cp -a "$f" "$SET/";; esac; done; rm -rf "$W"; }
trap cleanup EXIT
mkdir -p "$SET"; cat > "$SET/shelfmark.lua" <<LUA
return { ["shelfmark"] = { ["download_dir"] = "$W", ["bt_keyboard_addr"] = "AA:BB:CC:DD:EE:FF" } }
LUA
stop_koreader
"$KDIR/luajit" -e "
local p=os.getenv('HOME')..'/.config/koreader/settings.reader.lua'
local ok,t=pcall(dofile,p); if not ok or type(t)~='table' then t={} end
t.httpinspector={port=$INSPECT,autostart=true}
local function ser(v,ind) ind=ind or '' if type(v)=='table' then local o={'{\n'} for k,x in pairs(v) do o[#o+1]=ind..'    ['..(type(k)=='string' and string.format('%q',k) or tostring(k))..'] = '..ser(x,ind..'    ')..',\n' end o[#o+1]=ind..'}' return table.concat(o) elseif type(v)=='string' then return string.format('%q',v) else return tostring(v) end end
local f=assert(io.open(p,'w')) f:write('return '..ser(t)..'\n') f:close()"
(cd "$KDIR" && BOOKBRIDGE_BT_FORCE=1 BOOKBRIDGE_BT_DIR="$W/bt" setsid -f ./koreader.sh > "$W/koreader.log" 2>&1)
for i in $(seq 1 30); do curl -s -o /dev/null --max-time 2 "$I/" && break; sleep 1; done
curl -s -o /dev/null --max-time 2 "$I/" && say PASS "KOReader up" || { say FAIL "inspector never answered"; exit 1; }
curl -s --max-time 8 "$I/ui/menu/onShowMenu/" >/dev/null; sleep 1
bt=""; for i in $(seq 1 16); do [ "$(curl -s --max-time 5 "$I/ui/menu/menu_items/bookbridge/sub_item_table/$i/text")" = "Bluetooth keyboard" ] && { bt=$i; break; }; done
[ -n "$bt" ] && say PASS "'Bluetooth keyboard' submenu is under Bookbridge (index $bt)" || { say FAIL "no Bluetooth keyboard submenu under Bookbridge"; fail=1; }
[ -n "$bt" ] && { nxt=$(curl -s --max-time 5 "$I/ui/menu/menu_items/bookbridge/sub_item_table/$((bt+1))/text"); [ "$nxt" = "Settings" ] && say PASS "  ...placed right before Settings" || say INFO "  ...next item is '$nxt'"; }
st=""; for i in $(seq 1 10); do [ "$(curl -s --max-time 5 "$I/ui/menu/menu_items/bookbridge/sub_item_table/$bt/sub_item_table/$i/text")" = "Status" ] && { st=$i; break; }; done
[ -n "$st" ] && say PASS "Status item present" || { say FAIL "no Status item"; fail=1; }
addr=$(curl -s --max-time 5 "$I/ui/bookbridge/bt_keyboard_addr" | tr -d '"'); [ "$addr" = "AA:BB:CC:DD:EE:FF" ] && say PASS "saved phone address loaded from settings" || { say FAIL "bt_keyboard_addr not loaded (got '$addr')"; fail=1; }
curl -s --max-time 8 "$I/ui/menu/menu_items/bookbridge/sub_item_table/$bt/sub_item_table/$st/callback/" >/dev/null
# KOReader must stay responsive while the step runs
t0=$(date +%s%N); curl -s -o /dev/null --max-time 5 "$I/ui/bookbridge/download_dir"; dt=$(( ( $(date +%s%N) - t0 ) / 1000000 ))
[ "$dt" -lt 3000 ] && say PASS "KOReader answered in ${dt} ms while the step was running (not blocked)" || { say FAIL "KOReader took ${dt} ms to answer during the step"; fail=1; }
for i in $(seq 1 40); do [ -f "$W/bt/status.done" ] && break; sleep 1; done
[ -f "$W/bt/engine.sh" ] && say PASS "engine script written by the plugin ($(wc -l < "$W/bt/engine.sh") lines)" || { say FAIL "engine.sh not written"; fail=1; }
[ -f "$W/bt/status.done" ] && [ -s "$W/bt/status.txt" ] && say PASS "status step ran detached and finished ($(wc -l < "$W/bt/status.txt") lines)" || { say FAIL "status step did not finish"; fail=1; }
sleep 3
shown=0; for i in $(seq 1 8); do curl -s --max-time 3 "$I/UIManager/_window_stack/$i/widget/title" 2>/dev/null | grep -q "Bluetooth status" && shown=1; done
[ $shown = 1 ] && say PASS "result shown in a 'Bluetooth status' viewer" || { say FAIL "no result viewer on the window stack"; fail=1; }
grep -E "ERROR|Traceback|attempt to" "$W/koreader.log" | grep -v "Font " | grep -q . && { say FAIL "KOReader errors:"; grep -E "ERROR|Traceback|attempt to" "$W/koreader.log" | grep -v "Font " | head -3; fail=1; } || say PASS "no KOReader errors (font warning aside)"
[ $fail -eq 0 ] && echo "=== BT KEYBOARD PASS" || echo "=== BT KEYBOARD FAIL"; exit $fail
