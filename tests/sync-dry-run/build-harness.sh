#!/bin/bash
# Builds dryrun.lua: the REAL doSyncLibrary + its pure helpers, extracted from main.lua by anchor,
# with only I/O shimmed (virtual filesystem, registry file, cached HTTP, uploads impossible).
set -euo pipefail
M="$1"; OUT="$2"
extract() { local s=$(grep -n "^local function $1(" "$M" | head -1 | cut -d: -f1); local e=$(awk -v s="$s" 'NR>s && /^end$/ {print NR; exit}' "$M"); sed -n "${s},${e}p" "$M"; }
range() { local s=$(grep -n "$1" "$M" | head -1 | cut -d: -f1); local e=$(awk -v s="$(grep -n "$2" "$M" | head -1 | cut -d: -f1)" 'NR>s && /^end$/ {print NR; exit}' "$M"); sed -n "${s},${e}p" "$M"; }
{
cat <<'LUA'
package.cpath = "/usr/local/openresty/lualib/?.so;" .. package.cpath
local cjson = require("cjson")
local JSON = { decode = cjson.decode, encode = cjson.encode, null = cjson.null }
local _ = function(s) return s end
local function T(str, ...) local a = {...}; return (str:gsub("%%(%d+)", function(n) return tostring(a[tonumber(n)]) end)) end
local function debugLog() end
local ffiUtil = { sleep = function() end }
local socketurl = { escape = function(s) return (s:gsub("([^A-Za-z0-9_])", function(c) return string.format("%%%02x", c:byte()) end)) end }
local DOWNLOAD_DIR = os.getenv("DOWNLOAD_DIR")
local VFILES = {}
for line in io.lines(os.getenv("FILES")) do
  local dir, name = line:match("^(.*)/([^/]+)$")
  if dir then VFILES[dir] = VFILES[dir] or {}; table.insert(VFILES[dir], name) end
end
local lfs = {
  dir = function(d) local i = 0; local list = VFILES[d] or {}; return function() i = i + 1; return list[i] end, nil end,
  attributes = function(p, what)
    if VFILES[p] then return "directory" end
    local dir, name = p:match("^(.*)/([^/]+)$")
    for _, n in ipairs(VFILES[dir] or {}) do if n == name then return "file" end end
    return nil
  end,
}
local function loadSyncRegistry()
  local f = io.open(os.getenv("REG_IN")); if not f then return {} end
  local s = f:read("*a"); f:close(); if s == "" then return {} end
  local ok, t = pcall(cjson.decode, s); return ok and t or {}
end
local function saveSyncRegistry(r) local f = io.open(os.getenv("REG_OUT"), "w"); f:write(cjson.encode(r)); f:close() end
-- Pending-uploads list: the dry-run can never upload (uploads are stubbed to
-- error), so this list is always empty here. Stubs keep doSyncLibrary's
-- references resolvable without changing any match decision.
local function loadPendingUploads() return {} end
local function savePendingUploads() end
local CACHE = os.getenv("CACHE")
local function keyOf(path) return (path:gsub("[^%w]", function(c) return string.format("_%02x", c:byte()) end)) end
local REQUESTS = 0
local function doCwaRequest(cwa_url, u, p, path)
  REQUESTS = REQUESTS + 1
  local f = io.open(CACHE .. "/" .. keyOf(path))
  if not f then local m = io.open(CACHE .. "/MISSING", "a"); m:write(path, "\n"); m:close(); return nil, 0 end
  local s = f:read("*a"); f:close()
  local code, body = s:match("^(%d+)\n(.*)$")
  return body, tonumber(code)
end
local function doCwaFileDownload() return false end
local function doCwaLogin() return "stub-cookie" end
local function doCwaMultipartUpload() error("upload must never be reached in a dry run") end
LUA
grep -E '^local (CATALOG_PAGE|CATALOG_MAX_PAGES) ' "$M"
extract stripJsonNull
extract decodeHtmlEntities
extract parseOpdsEntries
range '^local SYNC_STOPWORDS = ' '^local function titleWordsSubsetOf'
extract fetchCwaCatalog
extract checkTrackedBookAgainstCwa
extract doSyncLibrary
cat <<'LUA'
local report, replaced, unmatched = doSyncLibrary("http://cwa", "u", "p", nil, DOWNLOAD_DIR, nil)
for _, l in ipairs(report) do print(l) end
io.stderr:write("requests=" .. REQUESTS .. "\n")
LUA
} > "$OUT"
