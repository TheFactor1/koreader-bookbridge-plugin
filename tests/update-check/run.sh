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
# Seed the scratch plugin dir from what the device actually runs, then append
# a comment so the copy is guaranteed to differ from the server. Seeding it
# unmodified made the test depend on the device happening to be out of date --
# once it caught up, "detects the stale file" failed for the wrong reason. The
# appended line keeps the copy valid Lua, so the parse check stays meaningful.
ssh "$DEV" "rm -rf /tmp/upd-test && mkdir -p /tmp/upd-test \
  && cp /mnt/us/koreader/plugins/shelfmark.koplugin/main.lua /mnt/us/koreader/plugins/shelfmark.koplugin/_meta.lua /tmp/upd-test/ \
  && printf '\n-- harness: deliberately-stale seed copy\n' >> /tmp/upd-test/main.lua"
# CHECK_ONLY=1 reports what the menu would say for a given plugin dir without
# writing anything -- e.g. against the LIVE install:
#   CHECK_ONLY=1 LIVE=1 bash tests/update-check/run.sh
DIR=/tmp/upd-test
[ -n "${LIVE:-}" ] && DIR=/mnt/us/koreader/plugins/shelfmark.koplugin
ssh "$DEV" "cd /mnt/us/koreader && BASE='$BASE' PLUGIN_DIR=$DIR ${VERBOSE:+VERBOSE=1} ${CHECK_ONLY:+CHECK_ONLY=1} ./luajit /tmp/shelfmark-update-test.lua"
rc=$?
ssh "$DEV" "rm -rf /tmp/upd-test /tmp/shelfmark-update-test.lua" || true
exit $rc
