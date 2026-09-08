#!/bin/bash
# Regenerates bookbridge.koplugin/manifest.json -- the file the plugin's
# "Check for updates" reads to decide whether the served build differs from
# the installed one, and to verify each download.
#
# RUN THIS AFTER ANY CHANGE to main.lua or _meta.lua. The plugin checks every
# downloaded file against these checksums and refuses to install on a
# mismatch, so a stale manifest doesn't corrupt anything -- it just makes
# updates stop working, quietly. The served directory IS this working tree,
# so the manifest and the files must be regenerated together.
#
# The format is deliberately host-agnostic: the same manifest.json works
# served from the homeserver today and from raw.githubusercontent.com once
# the repo goes public. Migrating is a URL change in the plugin's settings,
# not a code change.
set -euo pipefail
cd "$(dirname "$0")/.."
DIR=bookbridge.koplugin
FILES="main.lua _meta.lua"

VERSION=$(grep -oE 'local PLUGIN_VERSION = "[^"]+"' "$DIR/main.lua" | head -1 | cut -d'"' -f2)
[ -n "$VERSION" ] || { echo "couldn't read PLUGIN_VERSION from $DIR/main.lua" >&2; exit 1; }
BUILD=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
# Uncommitted edits to the served files get flagged -- while testing, the
# build id is the only thing that distinguishes two builds of one version.
git diff --quiet -- $(for f in $FILES; do echo "$DIR/$f"; done) 2>/dev/null || BUILD="$BUILD+dirty"

{
  printf '{\n  "schema": 1,\n'
  printf '  "version": "%s",\n' "$VERSION"
  printf '  "build": "%s",\n' "$BUILD"
  printf '  "generated": "%s",\n' "$(date -Is)"
  printf '  "files": {\n'
  first=1
  for f in $FILES; do
    [ $first -eq 1 ] || printf ',\n'
    first=0
    printf '    "%s": { "sha256": "%s", "size": %s }' \
      "$f" "$(sha256sum "$DIR/$f" | cut -d' ' -f1)" "$(stat -c%s "$DIR/$f")"
  done
  printf '\n  }\n}\n'
} > "$DIR/manifest.json"

echo "wrote $DIR/manifest.json (v$VERSION build $BUILD)"
