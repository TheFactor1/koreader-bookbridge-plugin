#!/bin/bash
# Extracts the update-path functions from main.lua (by name, so they keep
# tracking the real code as it moves) and wraps them in a prelude that
# supplies KOReader's own modules. The result runs under the Kindle's own
# LuaJIT against the real update server -- the same runtime, sockets, JSON
# and SHA-256 the plugin uses, with only the plugin directory redirected to
# a scratch copy so the live install is never touched.
set -euo pipefail
M="$1"; OUT="$2"
fn() { # extract `local function NAME(...)` through its closing top-level `end`
  local s e
  s=$(grep -n "^local function $1(" "$M" | head -1 | cut -d: -f1)
  [ -n "$s" ] || { echo "missing function: $1" >&2; exit 2; }
  e=$(awk -v s="$s" 'NR>s && /^end$/ {print NR; exit}' "$M")
  sed -n "${s},${e}p" "$M"
}
{
  cat <<'LUA'
package.path = "./?.lua;./common/?.lua;./common/?/init.lua;./frontend/?.lua;" .. package.path
package.cpath = "./common/?.so;./libs/?.so;" .. package.cpath
local JSON = require("json")
local socket = require("socket")
local http = require("socket.http")
local https = require("ssl.https")
-- KOReader's real socketutil pulls in the whole device/gesture stack and
-- needs a fully-initialised app (G_reader_settings), which can't exist in a
-- standalone script. Only its timeout wrapper and two sink constructors are
-- used by the code under test, so they're reimplemented here. Everything
-- that actually matters is real: LuaJIT, luasocket, TLS, KOReader's JSON,
-- and its ffi/sha2 -- so what's stubbed is timeout behaviour, not the
-- fetch, the checksum, or the install.
local socketutil = {
  TIMEOUT_CODE = "timeout",
  SINK_TIMEOUT_CODE = "sink timeout",
  SSL_HANDSHAKE_CODE = "ssl handshake",
  set_timeout = function(_self, block, total) http.TIMEOUT = total or block or 10 end,
  reset_timeout = function(_self) http.TIMEOUT = 60 end,
  table_sink = function()
    local t = {}
    return function(chunk) if chunk then t[#t + 1] = chunk end return 1 end, t
  end,
  file_sink = function(f)
    return function(chunk)
      if chunk == nil then f:close() return 1 end
      return f:write(chunk) and 1
    end
  end,
}
local _ = function(x) return x end
local function T(str, ...)
  local a = {...}
  return (tostring(str):gsub("%%(%d+)", function(n) return tostring(a[tonumber(n)]) end))
end
local VERBOSE = os.getenv("VERBOSE")
local function debugLog(m) if VERBOSE then io.stderr:write("    [dbg] " .. tostring(m) .. "\n") end end
-- The whole point of the harness: point the updater at a scratch directory
-- instead of the live plugin.
local function getPluginDir() return assert(os.getenv("PLUGIN_DIR"), "PLUGIN_DIR unset") end
local UPDATE_REPO = "TheFactor1/koreader-shelfmark-plugin"
LUA
  grep -E '^local UPDATE_FILES = ' "$M"
  for f in stripJsonNull makeSocks5Socket doHttpDownloadToFile isNewerVersion \
           sha256OfFile proxyForUrl doHttpGetString doCheckManifest doApplyUpdate; do
    fn "$f"
  done
  cat "$(dirname "$0")/cases.lua"
} > "$OUT"
