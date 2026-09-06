#!/bin/bash
# End-to-end test of "Check for updates" against a real update server, run on
# a real Kindle using KOReader's own LuaJIT/sockets/SHA-256. The live plugin
# install is never touched -- everything happens in /tmp on the device.
#
#   bash tests/update-check/run.sh [ssh-alias] [base-url]
# defaults: kindle  http://100.90.18.11:8092
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
DEV=${1:-kindle}; BASE=${2:-http://100.90.18.11:8092}
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
bash "$HERE/build-harness.sh" "$REPO/shelfmark.koplugin/main.lua" "$TMP/harness.lua"
scp -q "$TMP/harness.lua" "$DEV:/tmp/shelfmark-update-test.lua"
# Seed the scratch plugin dir from whatever that device currently runs, so
# "an older build" is a real older build, not a synthetic one.
ssh "$DEV" "rm -rf /tmp/upd-test && mkdir -p /tmp/upd-test \
  && cp /mnt/us/koreader/plugins/shelfmark.koplugin/main.lua /mnt/us/koreader/plugins/shelfmark.koplugin/_meta.lua /tmp/upd-test/"
ssh "$DEV" "cd /mnt/us/koreader && BASE='$BASE' PLUGIN_DIR=/tmp/upd-test ${VERBOSE:+VERBOSE=1} ./luajit /tmp/shelfmark-update-test.lua"
rc=$?
ssh "$DEV" "rm -rf /tmp/upd-test /tmp/shelfmark-update-test.lua" || true
exit $rc
