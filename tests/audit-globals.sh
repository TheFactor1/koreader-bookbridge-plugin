#!/bin/bash
# Globals audit: a function that uses a top-level local declared further
# down the file compiles to a GLOBAL read (nil at runtime), and a local
# assigned inside its own declaration's closure compiles to a global write.
# Both slipped through tests that never reached those lines (2026-10-07:
# SRC in doSearch, CO in openLibraryFolder, `what` in installCompanion).
# LuaJIT's bytecode listing names every global access, so: fail on any
# global write, and on any global read outside a short whitelist.
# Usage: tests/audit-globals.sh [file.lua ...]   (default: every .lua in bookbridge.koplugin)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/.." && pwd)
KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
[ -x "${KDIR:-/nonexistent}/luajit" ] || { echo "SKIP  no local KOReader (set KOREADER_DIR)"; exit 3; }
[ $# -gt 0 ] || set -- $(find "$REPO/bookbridge.koplugin" -name "*.lua" | sort)
# Lua's own names, KOReader's few globals, and what plugins legitimately touch
ALLOWED=" assert collectgarbage debug dofile error getmetatable io ipairs jit load loadfile loadstring math next os package pairs pcall print rawequal rawget rawlen rawset require select setmetatable string table tonumber tostring type unpack xpcall _G _ G_reader_settings G_defaults bit "
fail=0
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
for f in "$@"; do
    f=$(realpath "$f")
    # (to a file, not a pipe: a reader that stops early would SIGPIPE the
    # writer, and pipefail would call that a failure)
    (cd "$KDIR" && ./luajit -bl "$f") > "$TMP" 2>&1 || { echo "FAIL  $f doesn't compile"; fail=1; continue; }
    grep -aq -- "-- BYTECODE --" "$TMP" || { echo "FAIL  $f: no bytecode listed (empty file?)"; fail=1; continue; }
    bad=$(LC_ALL=C awk -v allowed="$ALLOWED" '
        /^-- BYTECODE --/ { fn = $4 }
        /GSET/ { if (match($0, /"[^"]+"/)) { n = substr($0, RSTART + 1, RLENGTH - 2); print "write " n " (" fn ")" } }
        /GGET/ { if (match($0, /"[^"]+"/)) { n = substr($0, RSTART + 1, RLENGTH - 2); if (index(allowed, " " n " ") == 0) print "read  " n " (" fn ")" } }
    ' "$TMP" | sort -u)
    if [ -n "$bad" ]; then
        echo "FAIL  $(basename "$(dirname "$f")")/$(basename "$f"): globals that should be locals:"
        printf '%s\n' "$bad" | sed 's/^/        /'
        fail=1
    else
        echo "PASS  $(basename "$(dirname "$f")")/$(basename "$f"): no stray global reads or writes"
    fi
done
exit $fail
