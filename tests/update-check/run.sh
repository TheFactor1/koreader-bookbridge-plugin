#!/bin/bash
# End-to-end test of "Check for updates" against a real update server, run
# with KOReader's own LuaJIT/sockets/SHA-256 -- on a real Kindle over ssh, or
# on a local KOReader Linux install, which runs the identical frontend. The
# plugin install under test is never touched: everything happens in /tmp.
#
#   bash tests/update-check/run.sh [ssh-alias|local] [base-url]
#
# `local` uses $KOREADER_DIR, or the newest ~/.local/opt/koreader-*/lib/koreader
# it can find, and seeds the scratch copy from this checkout's own
# bookbridge.koplugin. With no base-url, it asks the target which update source
# it is configured with -- the device's settings file over ssh, or the local
# install's ~/.config/koreader/settings/shelfmark.lua. That is deliberate: no server address is hardcoded here, because this
# repo is meant to go public eventually and a hardcoded Tailscale address had
# to be scrubbed out of this history once already. A tailnet address is
# useless to anyone else, but it does not belong in a public repo.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
DEV=${1:-kindle}; BASE=${2:-}
SETTINGS_GREP="grep -o '\[\"update_url\"\] = \"[^\"]*\"'"
if [ "$DEV" = local ]; then
  KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
  [ -x "$KDIR/luajit" ] || { echo "No local KOReader: set KOREADER_DIR to a dir containing luajit." >&2; exit 2; }
  [ -n "$BASE" ] || BASE=$(eval "$SETTINGS_GREP" ~/.config/koreader/settings/shelfmark.lua 2>/dev/null | sed 's/.*= "//; s/"$//') || true
else
  [ -n "$BASE" ] || BASE=$(ssh "$DEV" "$SETTINGS_GREP /mnt/us/koreader/settings/shelfmark.lua" 2>/dev/null | sed 's/.*= "//; s/"$//') || true
fi
if [ -z "$BASE" ]; then
  echo "No update source. Pass one as the 2nd argument, or set \"Update source\" on $DEV." >&2
  exit 2
fi
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
bash "$HERE/build-harness.sh" "$REPO/bookbridge.koplugin/main.lua" "$TMP/harness.lua"
if [ "$DEV" = local ]; then
  # Same seeding as the device path below, from this checkout instead of the
  # device's install, and the same deliberately-stale marker.
  SEED="$TMP/upd-test"; mkdir -p "$SEED"
  cp "$REPO/bookbridge.koplugin/main.lua" "$REPO/bookbridge.koplugin/_meta.lua" "$SEED/"
  printf '\n-- harness: deliberately-stale seed copy\n' >> "$SEED/main.lua"
  DIR=$SEED; [ -n "${LIVE:-}" ] && DIR="$KDIR/plugins/bookbridge.koplugin"
  (cd "$KDIR" && BASE="$BASE" PLUGIN_DIR="$DIR" ${VERBOSE:+VERBOSE=1} ${CHECK_ONLY:+CHECK_ONLY=1} ./luajit "$TMP/harness.lua")
  exit $?
fi
scp -q "$TMP/harness.lua" "$DEV:/tmp/shelfmark-update-test.lua"
# Seed the scratch plugin dir from what the device actually runs, then append
# a comment so the copy is guaranteed to differ from the server. Seeding it
# unmodified made the test depend on the device happening to be out of date --
# once it caught up, "detects the stale file" failed for the wrong reason. The
# appended line keeps the copy valid Lua, so the parse check stays meaningful.
ssh "$DEV" "rm -rf /tmp/upd-test && mkdir -p /tmp/upd-test \
  && cp /mnt/us/koreader/plugins/bookbridge.koplugin/main.lua /mnt/us/koreader/plugins/bookbridge.koplugin/_meta.lua /tmp/upd-test/ \
  && printf '\n-- harness: deliberately-stale seed copy\n' >> /tmp/upd-test/main.lua"
# CHECK_ONLY=1 reports what the menu would say for a given plugin dir without
# writing anything -- e.g. against the LIVE install:
#   CHECK_ONLY=1 LIVE=1 bash tests/update-check/run.sh
DIR=/tmp/upd-test
[ -n "${LIVE:-}" ] && DIR=/mnt/us/koreader/plugins/bookbridge.koplugin
ssh "$DEV" "cd /mnt/us/koreader && BASE='$BASE' PLUGIN_DIR=$DIR ${VERBOSE:+VERBOSE=1} ${CHECK_ONLY:+CHECK_ONLY=1} ./luajit /tmp/shelfmark-update-test.lua"
rc=$?
ssh "$DEV" "rm -rf /tmp/upd-test /tmp/shelfmark-update-test.lua" || true
exit $rc
