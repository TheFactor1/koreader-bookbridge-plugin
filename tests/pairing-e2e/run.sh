#!/bin/bash
# Two desktop KOReaders on one machine (separate KO_HOMEs, separate ports):
# reader A shows a setup code, reader B imports it over the loopback "Wi-Fi"
# -- the real plugin, the real HTTP receiver, the real inspector-driven UI.
# Checks B ends up with A's keys and sources but its own download folder,
# that the code works once, and that neither log has an error.
# Needs a display (SDL) and a local KOReader; exits 3 (SKIP) otherwise.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
[ -x "${KDIR:-/nonexistent}/luajit" ] || { echo "SKIP  no local KOReader (set KOREADER_DIR)"; exit 3; }
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP  no display for the desktop KOReader"; exit 3; }
[ -e "$KDIR/plugins/bookbridge.koplugin/main.lua" ] || { echo "SKIP  the local KOReader has no bookbridge.koplugin"; exit 3; }
CLIP_A=${PAIR_E2E_CLIP_A:-8120}; CLIP_B=${PAIR_E2E_CLIP_B:-8123}; INS_A=${PAIR_E2E_INS_A:-8193}; INS_B=${PAIR_E2E_INS_B:-8196}
for p in $CLIP_A $CLIP_B $INS_A $INS_B; do ss -ltn "( sport = :$p )" | tail -n +2 | grep -q . && { echo "SKIP  port $p is busy"; exit 3; }; done
W=$(mktemp -d)
A="$W/A"; B="$W/B"; IA="http://127.0.0.1:$INS_A/koreader"; IB="http://127.0.0.1:$INS_B/koreader"
pass=0; fail=0
ck() { if [ "$1" = 0 ]; then pass=$((pass+1)); echo "PASS  $2"; else fail=$((fail+1)); echo "FAIL  $2"; fi; }
stop_all() {
  for h in "$A" "$B"; do
    for p in $(ps -eo pid=); do grep -qz "KO_HOME=$h" /proc/$p/environ 2>/dev/null && kill "$p" 2>/dev/null; done
  done
  sleep 1
}
trap 'stop_all; rm -rf "$W"' EXIT

seed() { # home clip_port inspector_port extra-settings-lua
  mkdir -p "$1/books" "$1/settings" "$1/plugins"
  cat > "$1/settings.reader.lua" <<EOS
return { ["httpinspector"] = { ["port"] = $3, ["autostart"] = true }, ["home_dir"] = "$1/books", ["lastdir"] = "$1/books",
  ["bookbridge_first_run_shown"] = true, ["plugins_disabled"] = { ["ledger"] = true, ["zzledgertest"] = true } }
EOS
  cat > "$1/settings/shelfmark.lua" <<EOS
return { ["shelfmark"] = { ["download_dir"] = "$1/books", ["auto_update"] = false, $4 } }
EOS
}
seed "$A" $CLIP_A $INS_A '["server_url"] = "http://sm.example:8084", ["username"] = "alice", ["password"] = "pw-a", ["hardcover_token"] = "e2e-hardcover-token-'"$(head -c 300 /dev/zero | tr "\0" x)"'", ["annas_download_key"] = "e2e-annas-key", ["annas_tld"] = "gl", ["sources_order"] = { "annasarchive", "zlibrary", "shelfmark" }, ["sources_enabled"] = { ["shelfmark"] = false }, ["sources_stop_first"] = true'
seed "$B" $CLIP_B $INS_B '["hardcover_token"] = "b-own-token"'

launch() { # home clip_port inspector_url log
  (cd "$KDIR" && setsid -f env KO_HOME="$1" BOOKBRIDGE_CLIPBOARD_PORT=$2 ./koreader.sh "$1/books" > "$4" 2>&1)
  for i in $(seq 1 40); do curl -s -o /dev/null --max-time 2 "$3/" && return 0; sleep 1; done
  return 1
}
launch "$A" $CLIP_A "$IA" "$W/A.log"; ck $? "reader A up (inspector :$INS_A, receiver :$CLIP_A)"
launch "$B" $CLIP_B "$IB" "$W/B.log"; ck $? "reader B up (inspector :$INS_B, receiver :$CLIP_B)"
sleep 3
[ "$(curl -s --max-time 5 "$IA/ui/bookbridge/download_dir" | tr -d '"')" = "$A/books" ]; ck $? "A is the sandbox this run launched"
[ "$(curl -s --max-time 5 "$IB/ui/bookbridge/hardcover_token" | tr -d '"')" = "b-own-token" ]; ck $? "B starts with its own Hardcover token"

# 1. A shows a code (straight to the QR: the confirm is a tap away in real life)
curl -s --max-time 20 -g "$IA/ui/bookbridge/generateAndShowPairingQr/'lan'" >/dev/null; sleep 2
TEXT=""
for n in $(seq 1 8); do
  t=$(curl -s --max-time 5 "$IA/UIManager/_window_stack/$n/widget/text" | tr -d '"')
  case "$t" in bookbridge-pair:*) TEXT="$t"; break;; esac
done
echo "$TEXT" | grep -qE '^bookbridge-pair:[0-9.]+:'"$CLIP_A"':[0-9a-f]{8}:[A-Za-z0-9_-]+$'; ck $? "A: a bookbridge-pair code is on screen ($(echo "$TEXT" | cut -c1-40)...)"
CODE=$(echo "$TEXT" | cut -d: -f4)

# 2. B imports it
curl -s --max-time 30 -g "$IB/ui/bookbridge/applyPairingText/'$TEXT'" >/dev/null; sleep 3
IDX=""
for n in $(seq 1 8); do
  t=$(curl -s --max-time 5 "$IB/UIManager/_window_stack/$n/widget/text")
  case "$t" in *"Import these settings?"*) IDX=$n; echo "$t" | tr -d '\n' | cut -c1-200; break;; esac
done
[ -n "$IDX" ]; ck $? "B: the import question is up"
echo "$t" | grep -q "Anna's Archive key: yes" && echo "$t" | grep -q "Hardcover token: yes"; ck $? "...listing the key and the token as present"
curl -s --max-time 30 -g "$IB/UIManager/_window_stack/$IDX/widget/ok_callback/" >/dev/null; sleep 3
[ "$(curl -s --max-time 5 "$IB/ui/bookbridge/hardcover_token" | tr -d '"')" = "$(curl -s --max-time 5 "$IA/ui/bookbridge/hardcover_token" | tr -d '"')" ]; ck $? "B: Hardcover token is A's"
[ "$(curl -s --max-time 5 "$IB/ui/bookbridge/annas_download_key" | tr -d '"')" = "e2e-annas-key" ]; ck $? "B: Anna's key is A's"
[ "$(curl -s --max-time 5 "$IB/ui/bookbridge/server_url" | tr -d '"')" = "http://sm.example:8084" ]; ck $? "B: server address is A's"
[ "$(curl -s --max-time 5 "$IB/ui/bookbridge/sources_order/1" | tr -d '"')" = "annasarchive" ]; ck $? "B: sources order is A's"
[ "$(curl -s --max-time 5 "$IB/ui/bookbridge/download_dir" | tr -d '"')" = "$B/books" ]; ck $? "B: its own download folder stays"
grep -q 'e2e-annas-key' "$B/settings/shelfmark.lua" && grep -q "\"$B/books\"" "$B/settings/shelfmark.lua"; ck $? "B: saved to its settings file"

# 3. the code worked once
[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$CLIP_A/pair/$CODE")" = "404" ]; ck $? "A: the same code again is gone (404)"
[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$CLIP_A/clip?text=still+here")" = "200" ]; ck $? "A: the phone clipboard route still answers"

# 4. clean logs
! grep -qE "ERROR|Traceback|attempt to|stack traceback" "$W/A.log" "$W/B.log" "$A/settings/shelfmark-debug.log" "$B/settings/shelfmark-debug.log" 2>/dev/null; ck $? "no error or traceback in either reader's logs"
grep -q "\[pair\] settings handed to the other reader" "$A/settings/shelfmark-debug.log" && grep -q "\[pair\] imported .* over lan" "$B/settings/shelfmark-debug.log"; ck $? "both debug logs tell the story"

echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
