#!/bin/bash
# End-to-end test of "Check for updates" against a real update server, run on
# a real Kindle using KOReader's own LuaJIT/sockets/SHA-256. The live plugin
# install is never touched -- everything happens in /tmp on the device.
#
#   bash tests/update-check/run.sh [ssh-alias] [base-url]
#
# With no base-url, it asks the device which update source it is configured
# with. That is deliberate: no server address is hardcoded here, because this
# repo is meant to go public eventually and a hardcoded Tailscale address had
# to be scrubbed out of this history once already. A tailnet address is
# useless to anyone else, but it does not belong in a public repo.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
DEV=${1:-kindle}; BASE=${2:-}
if [ -z "$BASE" ]; then
  BASE=$(ssh "$DEV" "grep -o '\[\"update_url\"\] = \"[^\"]*\"' /mnt/us/koreader/settings/shelfmark.lua" 2>/dev/null \
    | sed 's/.*= "//; s/"$//') || true
fi
if [ -z "$BASE" ]; then
  echo "No update source. Pass one as the 2nd argument, or set \"Update source\" on $DEV." >&2
  exit 2
fi
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
