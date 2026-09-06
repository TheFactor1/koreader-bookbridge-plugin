#!/bin/bash
# Live end-to-end sync test: the REAL plugin, driven inside a REAL KOReader
# (the Linux build, identical frontend and luajit to the Kindle), against a
# throwaway CWA. The one suite that reaches the upload and post-upload
# registration path, which the dry-run cannot by design.
#
# Exists because of a bug found exactly this way on 2026-09-06: the per-run
# search cache made the post-upload "wait for CWA to import" pass answer from
# memory, so it never observed the import and every upload was reported as
# not yet imported. Uploads accepted, books in CWA, registry empty, and not
# one request after the last upload -- invisible to every other suite.
#
#   bash tests/live-sync/run.sh          # exit 0 = registered both uploads
#
# Needs: docker, a local KOReader Linux install (~/.local/opt/koreader-*/ or
# $KOREADER_DIR), and the server stack's compose file ($SHELFMARK_STACK_DIR,
# default ../shelfmark-stack beside this repo). Uses ports 19083/19084 for
# the sandbox and 8181 for KOReader's HTTP inspector.
#
# It stops any running local KOReader to launch its own -- matched only on
# KOReader's own argv (`./luajit reader.lua`, anchored), never on a shell
# that happens to mention the name -- and it swaps the local install's
# plugin settings/registry/log for the duration,
# restoring the originals on exit. Never touches a Kindle, never touches
# production, never touches this checkout's plugin files.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
STACK=${SHELFMARK_STACK_DIR:-$REPO/../shelfmark-stack}
KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
[ -x "${KDIR:-/nonexistent}/luajit" ] || { echo "SKIP  no local KOReader (set KOREADER_DIR)"; exit 3; }
[ -f "$STACK/docker-compose.yml" ] || { echo "SKIP  no stack compose at $STACK (set SHELFMARK_STACK_DIR)"; exit 3; }
command -v docker >/dev/null || { echo "SKIP  no docker"; exit 3; }
[ -e "$KDIR/plugins/shelfmark.koplugin" ] || { echo "FAIL  $KDIR/plugins/shelfmark.koplugin missing -- symlink this checkout's shelfmark.koplugin there"; exit 1; }

P=shelfmark-livetest; CWA_PORT=19083; INSPECT=8181; I="http://127.0.0.1:$INSPECT/koreader"
CFG=~/.config/koreader; SET=$CFG/settings
W=$(mktemp -d); BOOKS="$W/books"; LIB="$W/lib"; mkdir -p "$BOOKS" "$LIB" "$W/bak"
fail=0; say() { printf '%-6s%s\n' "$1" "$2"; }

# --- backups, restored on exit no matter what --------------------------
for f in "$SET/shelfmark.lua" "$SET/shelfmark_synced_books.json" "$SET/shelfmark-debug.log" "$CFG/settings.reader.lua"; do
  [ -f "$f" ] && cp -a "$f" "$W/bak/$(basename "$f")"
done
# KOReader's real argv is `./luajit ./reader.lua` under a `/bin/sh ./koreader.sh`
# parent. Both the launch and every kill run in their own session (setsid):
# a KOReader started as a plain background job of whatever shell runs this
# script becomes that shell's lineage, and killing it took the calling shell
# down with it -- three times, while this test was being written. Detached
# on both sides, neither direction can propagate.
KPID=""
stop_koreader() {
  # `setsid` WITHOUT -f: a new session (so a kill here can never reach the
  # shell running this script -- that took the tool shell down three times
  # during development) but SYNCHRONOUS. -f detaches, and a detached killer
  # returned before it fired, then killed the KOReader the launch below had
  # just started -- a clean run's most baffling failure. Blocking is the fix.
  setsid sh -c '
    for p in $(ss -ltnp "( sport = :'"$INSPECT"' )" 2>/dev/null | grep -oE "pid=[0-9]+" | cut -d= -f2 | sort -u); do kill "$p" 2>/dev/null; done
    pkill -f "^\./luajit \./reader\.lua" 2>/dev/null
    pkill -f "^/bin/sh \./koreader\.sh" 2>/dev/null
    true' >/dev/null 2>&1
  for i in $(seq 1 10); do ss -ltn "( sport = :$INSPECT )" | tail -n +2 | grep -q . || break; sleep 1; done
  KPID=""
}
cleanup() {
  stop_koreader
  (cd "$STACK" && COMPOSE_PROFILES=sync CWA_PORT=$CWA_PORT SHELFMARK_PORT=19084 CALIBRE_LIBRARY="$LIB" docker compose -p $P down -v >/dev/null 2>&1)
  rm -f "$SET/shelfmark.lua" "$SET/shelfmark_synced_books.json" "$SET/shelfmark-debug.log"
  for f in "$W"/bak/*; do [ -e "$f" ] || continue; case "$(basename "$f")" in settings.reader.lua) cp -a "$f" "$CFG/";; *) cp -a "$f" "$SET/";; esac; done
  rm -rf "$W"
}
trap cleanup EXIT

# --- sandbox CWA ----------------------------------------------------------
(cd "$STACK" && COMPOSE_PROFILES=sync CWA_PORT=$CWA_PORT SHELFMARK_PORT=19084 CALIBRE_LIBRARY="$LIB" docker compose -p $P up -d >/dev/null 2>&1) || { say FAIL "sandbox compose up"; exit 1; }
for i in $(seq 1 40); do [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 -u admin:admin123 http://127.0.0.1:$CWA_PORT/opds)" = 200 ] && break; sleep 3; done
[ "$(curl -s --max-time 5 -u admin:admin123 http://127.0.0.1:$CWA_PORT/opds/new | grep -c '<entry>')" = 0 ] && say PASS "sandbox CWA up, library empty" || { say FAIL "sandbox CWA not up/empty"; exit 1; }

# --- two books nothing in CWA could match ---------------------------------
python3 "$HERE/make-epub.py" "$BOOKS/Emerald Harbor Mystery - Alice Example.epub" "Emerald Harbor Mystery" "Alice Example"
python3 "$HERE/make-epub.py" "$BOOKS/Granite Tower Chronicle - Bob Sample.epub" "Granite Tower Chronicle" "Bob Sample"

# --- plugin settings for the local install, pointed at the sandbox ------
mkdir -p "$SET"
cat > "$SET/shelfmark.lua" <<LUA
return { ["shelfmark"] = { ["cwa_url"] = "http://127.0.0.1:$CWA_PORT", ["cwa_username"] = "admin", ["cwa_password"] = "admin123", ["download_dir"] = "$BOOKS" } }
LUA
rm -f "$SET/shelfmark_synced_books.json"; : > "$SET/shelfmark-debug.log"
# httpinspector autostart -- add the key, leave every other global setting alone
"$KDIR/luajit" -e "
local p=os.getenv('HOME')..'/.config/koreader/settings.reader.lua'
local ok,t=pcall(dofile,p); if not ok or type(t)~='table' then t={} end
t.httpinspector={port=$INSPECT,autostart=true}
local function ser(v,ind) ind=ind or '' if type(v)=='table' then local o={'{\n'} for k,x in pairs(v) do o[#o+1]=ind..'    ['..(type(k)=='string' and string.format('%q',k) or tostring(k))..'] = '..ser(x,ind..'    ')..',\n' end o[#o+1]=ind..'}' return table.concat(o) elseif type(v)=='string' then return string.format('%q',v) else return tostring(v) end end
local f=assert(io.open(p,'w')) f:write('return '..ser(t)..'\n') f:close()"

# --- KOReader -------------------------------------------------------------
stop_koreader
# Fail fast rather than drive whatever is already listening: a stale
# instance loaded someone else's settings and code, and every assertion
# below would be about the wrong KOReader.
ss -ltn "( sport = :$INSPECT )" | tail -n +2 | grep -q . && { say FAIL ":$INSPECT already bound -- a stale KOReader is running and could not be stopped"; exit 1; }
(cd "$KDIR" && setsid -f ./koreader.sh > "$W/koreader.log" 2>&1)
for i in $(seq 1 30); do curl -s -o /dev/null --max-time 2 "$I/" && break; sleep 1; done
curl -s -o /dev/null --max-time 2 "$I/" && say PASS "KOReader up, inspector answering on :$INSPECT" || { say FAIL "inspector never answered"; exit 1; }
KPID=$(pgrep -f '^\./luajit \./reader\.lua' | tail -1)
# Identity: the instance answering must be the one THIS run launched, i.e.
# it read this run's settings. Its download_dir is unique to this run.
got=$(curl -s --max-time 5 "$I/ui/shelfmark/download_dir" | tr -d '"')
[ "$got" = "$BOOKS" ] && say PASS "driving the KOReader this run launched (pid ${KPID:-?})" || { say FAIL "inspector belongs to a different KOReader (download_dir=$got)"; exit 1; }
curl -s --max-time 8 "$I/ui/menu/onShowMenu/" >/dev/null; sleep 1
idx=""; for i in $(seq 1 24); do t=$(curl -s --max-time 5 "$I/ui/menu/menu_items/shelfmark/sub_item_table/$i/text"); [ "$t" = "Sync library with CWA" ] && { idx=$i; break; }; done
[ -n "$idx" ] && say PASS "found 'Sync library with CWA' at submenu index $idx" || { say FAIL "sync menu item not found"; exit 1; }

# --- drive it, exactly as a tap: the item's own Trapper-wrapped callback ---
curl -s --max-time 8 "$I/ui/menu/menu_items/shelfmark/sub_item_table/$idx/callback/" >/dev/null
reg=0; for i in $(seq 1 45); do
  reg=$(python3 -c "import json;print(len(json.load(open('$SET/shelfmark_synced_books.json'))))" 2>/dev/null || echo 0)
  [ "$reg" = 2 ] && break; sleep 2
done

# --- assertions -----------------------------------------------------------
[ "$reg" = 2 ] && say PASS "registry holds both books" || { say FAIL "registry holds $reg book(s), expected 2"; fail=1; }
cwa=$(curl -s --max-time 5 -u admin:admin123 http://127.0.0.1:$CWA_PORT/opds/new | grep -c '<entry>')
[ "$cwa" = 2 ] && say PASS "sandbox CWA imported both uploads" || { say FAIL "sandbox CWA has $cwa book(s)"; fail=1; }
# The regression itself: at least one search AFTER the last upload line.
after=$(awk '/POST .*\/upload/{n=NR} END{print n+0}' "$SET/shelfmark-debug.log")
searches=$(awk -v n="$after" 'NR>n && /-> GET .*\/opds\/search\//' "$SET/shelfmark-debug.log" | wc -l)
[ "$after" -gt 0 ] && [ "$searches" -gt 0 ] && say PASS "post-upload pass re-asked CWA ($searches search request(s) after the last upload)" || { say FAIL "no search request after the last upload -- the import wait is answering from cache"; fail=1; }
grep -qE "ERROR|Traceback|attempt to" "$W/koreader.log" && { say FAIL "KOReader logged an error:"; grep -E "ERROR|Traceback|attempt to" "$W/koreader.log" | head -3; fail=1; } || say PASS "no KOReader errors"
[ $fail -eq 0 ] && echo "=== LIVE SYNC PASS" || echo "=== LIVE SYNC FAIL"
exit $fail
