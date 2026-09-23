#!/bin/bash
# The Shelfmark -> Bookbridge rename asks "Restart now?" once per KOReader
# session, not on every plugin start. init runs for every FileManager and
# Reader instance, so after "Later" the files were copied again and the dialog
# came back on the next book open (found 2026-09-23). Runs the REAL
# migratePluginFolder from main.lua in a temp folder. Offline; KOReader's luajit.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
M=${1:-$REPO/bookbridge.koplugin/main.lua}
KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
[ -x "${KDIR:-/nonexistent}/luajit" ] || { echo "SKIP  no local KOReader (set KOREADER_DIR)"; exit 3; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
{ grep -E '^local rename_prompted = ' "$M"; awk '/^function Bookbridge:migratePluginFolder/{f=1} f{print} f&&/^end$/{exit}' "$M"; } > "$W/fns.lua"
mkdir -p "$W/plugins/shelfmark.koplugin"; echo "-- main" > "$W/plugins/shelfmark.koplugin/main.lua"; echo "-- meta" > "$W/plugins/shelfmark.koplugin/_meta.lua"
cd "$KDIR" || exit 1
SRC="$W/fns.lua" OLD="$W/plugins/shelfmark.koplugin" ./luajit - <<'LUA'
_ = function(s) return s end
debugLog = function() end
lfs = require("libs/libkoreader-lfs")
local SETTINGS = {}
G_reader_settings = { readSetting = function(_s, k) return SETTINGS[k] end, saveSetting = function(_s, k, v) SETTINGS[k] = v end, flush = function() end }
local dialogs = 0
UIManager = { nextTick = function(_s, f) f() end, show = function() dialogs = dialogs + 1 end }
package.loaded["ui/widget/confirmbox"] = { new = function(_s, t) return t end }
Bookbridge = {}
assert(load(io.open(os.getenv("SRC")):read("*a")))()
local pass, fail = 0, 0
local function ck(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end
-- first start from the old folder: copies, disables the old one, asks once
Bookbridge.migratePluginFolder({ path = os.getenv("OLD") })
local new_main = io.open(os.getenv("OLD"):gsub("shelfmark", "bookbridge") .. "/main.lua")
ck(new_main ~= nil and SETTINGS.plugins_disabled and SETTINGS.plugins_disabled.shelfmark == true, "first start: copied into bookbridge.koplugin, old folder disabled")
if new_main then new_main:close() end
ck(dialogs == 1, "...and asks \"Restart now?\" once")
-- "Later", then more plugin starts in the same session (library, each book opened)
for _ = 1, 4 do Bookbridge.migratePluginFolder({ path = os.getenv("OLD") }) end
ck(dialogs == 1, "4 more starts in the same session (after \"Later\"): not asked again (asked " .. dialogs .. " times)")
print(string.format("=== %d passed, %d failure(s)", pass, fail))
os.exit(fail == 0 and 0 or 1)
LUA
