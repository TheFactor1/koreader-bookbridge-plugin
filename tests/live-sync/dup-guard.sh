#!/bin/bash
# Regression test for the duplicate-upload bug found on-device 2026-09-06.
#
# A real "Suzanne Collins - The Hunger Games.epub" whose EMBEDDED author was
# "David Wheeler" got uploaded, imported by CWA under the embedded metadata,
# and then -- because the filename-based matcher searches "Suzanne Collins" and
# CWA has it under "David Wheeler" -- never matched back. Every sync saw it as
# untracked and uploaded it again: one duplicate per run.
#
# The fix: a persistent pending-uploads list. A file this device already
# pushed is never pushed again; it only keeps retrying the match. This test
# reproduces the exact shape -- a book whose embedded author disagrees with its
# filename -- syncs TWICE, and asserts CWA ends with exactly one copy.
#
#   bash tests/live-sync/dup-guard.sh        # exit 0 = no duplicate created
#
# Same needs and lifecycle as run.sh (docker, a local KOReader, the stack's
# compose file). Never touches a Kindle or production; sandbox CWA on 19093.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
STACK=${SHELFMARK_STACK_DIR:-$REPO/../shelfmark-stack}
KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
[ -x "${KDIR:-/nonexistent}/luajit" ] || { echo "SKIP  no local KOReader (set KOREADER_DIR)"; exit 3; }
[ -f "$STACK/docker-compose.yml" ] || { echo "SKIP  no stack compose at $STACK"; exit 3; }
command -v docker >/dev/null || { echo "SKIP  no docker"; exit 3; }
[ -e "$KDIR/plugins/bookbridge.koplugin" ] || { echo "FAIL  $KDIR/plugins/bookbridge.koplugin missing"; exit 1; }

P=shelfmark-dupguard; CWA_PORT=19093; INSPECT=8181; I="http://127.0.0.1:$INSPECT/koreader"
CFG=~/.config/koreader; SET=$CFG/settings
W=$(mktemp -d); BOOKS="$W/books"; LIB="$W/lib"; mkdir -p "$BOOKS" "$LIB" "$W/bak"
fail=0; say() { printf '%-6s%s\n' "$1" "$2"; }
cwa_count() { curl -s --max-time 6 -u admin:admin123 "http://127.0.0.1:$CWA_PORT/opds/search/Silent%20Echo" | grep -c '<entry>'; }

for f in "$SET/shelfmark.lua" "$SET/shelfmark_synced_books.json" "$SET/shelfmark_pending_uploads.json" "$SET/shelfmark-debug.log" "$CFG/settings.reader.lua"; do
  [ -f "$f" ] && cp -a "$f" "$W/bak/$(basename "$f")"
done
stop_koreader() {
  setsid sh -c '
    for p in $(ss -ltnp "( sport = :'"$INSPECT"' )" 2>/dev/null | grep -oE "pid=[0-9]+" | cut -d= -f2 | sort -u); do kill "$p" 2>/dev/null; done
    pkill -f "^\./luajit \./reader\.lua" 2>/dev/null
    pkill -f "^/bin/sh \./koreader\.sh" 2>/dev/null
    true' >/dev/null 2>&1
  for i in $(seq 1 10); do ss -ltn "( sport = :$INSPECT )" | tail -n +2 | grep -q . || break; sleep 1; done
}
cleanup() {
  stop_koreader
  (cd "$STACK" && COMPOSE_PROFILES=sync CWA_PORT=$CWA_PORT SHELFMARK_PORT=19094 CALIBRE_LIBRARY="$LIB" docker compose -p $P down -v >/dev/null 2>&1)
  rm -f "$SET/shelfmark.lua" "$SET/shelfmark_synced_books.json" "$SET/shelfmark_pending_uploads.json" "$SET/shelfmark-debug.log"
  for f in "$W"/bak/*; do [ -e "$f" ] || continue; case "$(basename "$f")" in settings.reader.lua) cp -a "$f" "$CFG/";; *) cp -a "$f" "$SET/";; esac; done
  rm -rf "$W"
}
trap cleanup EXIT

# --- sandbox CWA ---
(cd "$STACK" && COMPOSE_PROFILES=sync CWA_PORT=$CWA_PORT SHELFMARK_PORT=19094 CALIBRE_LIBRARY="$LIB" docker compose -p $P up -d >/dev/null 2>&1) || { say FAIL "sandbox up"; exit 1; }
for i in $(seq 1 40); do [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 -u admin:admin123 http://127.0.0.1:$CWA_PORT/opds)" = 200 ] && break; sleep 3; done
[ "$(cwa_count)" = 0 ] && say PASS "sandbox CWA up, no Silent Echo yet" || { say FAIL "sandbox not clean"; exit 1; }

# --- the mismatched book: FILENAME says "Ghostwriter Jones", the EMBEDDED
#     metadata (what CWA indexes) says "Anonymous Scribe". The matcher will
#     search the filename's pre-dash text and never find the CWA copy. ---
python3 "$HERE/make-epub.py" "$BOOKS/Ghostwriter Jones - The Silent Echo.epub" "The Silent Echo" "Anonymous Scribe"

mkdir -p "$SET"
cat > "$SET/shelfmark.lua" <<LUA
return { ["shelfmark"] = { ["cwa_url"] = "http://127.0.0.1:$CWA_PORT", ["cwa_username"] = "admin", ["cwa_password"] = "admin123", ["download_dir"] = "$BOOKS" } }
LUA
rm -f "$SET/shelfmark_synced_books.json" "$SET/shelfmark_pending_uploads.json"; : > "$SET/shelfmark-debug.log"
"$KDIR/luajit" -e "
local p=os.getenv('HOME')..'/.config/koreader/settings.reader.lua'
local ok,t=pcall(dofile,p); if not ok or type(t)~='table' then t={} end
t.httpinspector={port=$INSPECT,autostart=true}
local function ser(v,ind) ind=ind or '' if type(v)=='table' then local o={'{\n'} for k,x in pairs(v) do o[#o+1]=ind..'    ['..(type(k)=='string' and string.format('%q',k) or tostring(k))..'] = '..ser(x,ind..'    ')..',\n' end o[#o+1]=ind..'}' return table.concat(o) elseif type(v)=='string' then return string.format('%q',v) else return tostring(v) end end
local f=assert(io.open(p,'w')) f:write('return '..ser(t)..'\n') f:close()"

# --- KOReader ---
stop_koreader
ss -ltn "( sport = :$INSPECT )" | tail -n +2 | grep -q . && { say FAIL ":$INSPECT still bound"; exit 1; }
(cd "$KDIR" && setsid -f ./koreader.sh > "$W/koreader.log" 2>&1)
for i in $(seq 1 30); do curl -s -o /dev/null --max-time 2 "$I/" && break; sleep 1; done
curl -s -o /dev/null --max-time 2 "$I/" || { say FAIL "inspector never answered"; exit 1; }
got=$(curl -s --max-time 5 "$I/ui/bookbridge/download_dir" | tr -d '"')
[ "$got" = "$BOOKS" ] && say PASS "driving the KOReader this run launched" || { say FAIL "wrong KOReader (download_dir=$got)"; exit 1; }
curl -s --max-time 8 "$I/ui/menu/onShowMenu/" >/dev/null; sleep 1
idx=""; for i in $(seq 1 24); do [ "$(curl -s --max-time 5 "$I/ui/menu/menu_items/bookbridge/sub_item_table/$i/text")" = "Sync library with CWA" ] && { idx=$i; break; }; done
[ -n "$idx" ] || { say FAIL "sync menu item not found"; exit 1; }
fire_sync() { curl -s --max-time 8 "$I/ui/menu/menu_items/bookbridge/sub_item_table/$idx/callback/" >/dev/null; }

# --- sync #1: uploads the book ---
fire_sync
for i in $(seq 1 45); do [ -f "$SET/shelfmark_pending_uploads.json" ] && python3 -c "import json,sys;sys.exit(0 if json.load(open('$SET/shelfmark_pending_uploads.json')) else 1)" 2>/dev/null && break; sleep 2; done
pend=$(python3 -c "import json;print(len(json.load(open('$SET/shelfmark_pending_uploads.json'))))" 2>/dev/null || echo 0)
[ "$pend" -ge 1 ] && say PASS "sync #1 uploaded and recorded it as pending (couldn't match -- mismatched metadata)" || { say FAIL "sync #1 didn't record a pending upload (pending=$pend)"; fail=1; }
# wait for CWA to actually import it
for i in $(seq 1 30); do [ "$(cwa_count)" -ge 1 ] && break; sleep 2; done
c1=$(cwa_count); [ "$c1" = 1 ] && say PASS "CWA imported exactly one copy after sync #1" || { say FAIL "CWA has $c1 copies after sync #1 (expected 1)"; fail=1; }

# --- sync #2: MUST NOT upload again ---
: > "$SET/shelfmark-debug.log"   # isolate sync #2's traffic
fire_sync
sleep 8
c2=$(cwa_count)
[ "$c2" = 1 ] && say PASS "CWA STILL has exactly one copy after sync #2 -- no duplicate" || { say FAIL "CWA has $c2 copies after sync #2 -- DUPLICATE CREATED"; fail=1; }
uploads2=$(grep -c "POST .*/upload" "$SET/shelfmark-debug.log" 2>/dev/null || true); uploads2=${uploads2:-0}
[ "$uploads2" = 0 ] && say PASS "sync #2 made no upload request at all" || { say FAIL "sync #2 issued $uploads2 upload(s) -- should be 0"; fail=1; }
grep -qE "ERROR|Traceback|attempt to" "$W/koreader.log" && { say FAIL "KOReader logged an error:"; grep -E "ERROR|Traceback|attempt to" "$W/koreader.log" | head -3; fail=1; } || say PASS "no KOReader errors"

[ $fail -eq 0 ] && echo "=== DUP-GUARD PASS" || echo "=== DUP-GUARD FAIL"
exit $fail
