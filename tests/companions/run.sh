#!/bin/bash
# Companion plugins (CO): a release zip is verified by size and SHA-256,
# unpacked with its folder prefix stripped, parse-checked, swapped in with
# the old folder kept as .prev and the user's own files carried over; a
# bad digest, a broken Lua file or a wrong folder never replaces a working
# plugin; rollback restores .prev. Offline: the "release" is a local zip
# and GitHub's answer is a scripted table.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd); M="$REPO/bookbridge.koplugin/main.lua"
KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
[ -x "${KDIR:-/nonexistent}/luajit" ] || { echo "SKIP  no local KOReader (set KOREADER_DIR)"; exit 3; }
command -v zip >/dev/null || { echo "SKIP  no zip"; exit 3; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
awk '/^-- ===== CO begin/{f=1} f{print} f&&/^-- ===== CO end/{exit}' "$M" > "$W/co.lua"
grep -q "function CO.install" "$W/co.lua" || { echo "FAIL  extraction failed"; exit 1; }
sed -i "s/^local CO = {}/CO = {}/" "$W/co.lua"   # (global, so the harness can reach it)

# A fake Z-Library release: the real zip layout (plugins/zlibrary.koplugin/...)
mkdir -p "$W/src/plugins/zlibrary.koplugin/zlibrary" "$W/plugins/zlibrary.koplugin"
cat > "$W/src/plugins/zlibrary.koplugin/_meta.lua" <<'EOF'
return { fullname = "Z-library", version = "1.0.99" }
EOF
echo 'return { ok = true }' > "$W/src/plugins/zlibrary.koplugin/main.lua"
echo 'local Api = {} function Api.search() return { results = {} } end return Api' > "$W/src/plugins/zlibrary.koplugin/zlibrary/api.lua"
(cd "$W/src" && zip -qr ../good.zip plugins)
# the same, with one broken file
cp -r "$W/src" "$W/src2"; echo 'this is not lua (' > "$W/src2/plugins/zlibrary.koplugin/zlibrary/api.lua"
(cd "$W/src2" && zip -qr ../broken.zip plugins)
# a zip with the wrong top folder
mkdir -p "$W/src3/other"; cp "$W/src/plugins/zlibrary.koplugin/main.lua" "$W/src3/other/"
(cd "$W/src3" && zip -qr ../wrong.zip other)
# a zip whose entries use backslashes (made on Windows) and one that tries to climb out
python3 - "$W" <<'PY2'
import sys, zipfile
w = sys.argv[1]
with zipfile.ZipFile(w + "/backslash.zip", "w") as z:
    z.writestr("plugins\\zlibrary.koplugin\\_meta.lua", 'return { fullname = "Z-library", version = "1.0.99" }')
    z.writestr("plugins\\zlibrary.koplugin\\main.lua", "return { ok = true }")
    z.writestr("plugins\\zlibrary.koplugin\\zlibrary\\api.lua", "return {}")
    z.writestr("plugins/zlibrary.koplugin/../escaped.lua", "return 1")
PY2
# an "installed" older copy with the user's credentials file
echo 'return { fullname = "Z-library", version = "1.0.50" }' > "$W/plugins/zlibrary.koplugin/_meta.lua"
echo 'return 1' > "$W/plugins/zlibrary.koplugin/main.lua"
echo 'return { email = "me@example.com" }' > "$W/plugins/zlibrary.koplugin/zlibrary_credentials.lua"
mkdir -p "$W/plugins/bookbridge.koplugin"
sha() { sha256sum "$1" | cut -d' ' -f1; }
GOOD_SHA=$(sha "$W/good.zip"); GOOD_SIZE=$(stat -c %s "$W/good.zip")
BROKEN_SHA=$(sha "$W/broken.zip"); BROKEN_SIZE=$(stat -c %s "$W/broken.zip")
WRONG_SHA=$(sha "$W/wrong.zip"); WRONG_SIZE=$(stat -c %s "$W/wrong.zip")
BS_SHA=$(sha "$W/backslash.zip"); BS_SIZE=$(stat -c %s "$W/backslash.zip")

cd "$KDIR" || exit 1
W="$W" GOOD_SHA="$GOOD_SHA" GOOD_SIZE="$GOOD_SIZE" BROKEN_SHA="$BROKEN_SHA" BROKEN_SIZE="$BROKEN_SIZE" WRONG_SHA="$WRONG_SHA" WRONG_SIZE="$WRONG_SIZE" BS_SHA="$BS_SHA" BS_SIZE="$BS_SIZE" ./luajit - <<'LUA'
package.path = "frontend/?.lua;common/?.lua;" .. package.path
package.cpath = "common/?.so;libs/?.so;" .. package.cpath
local W = os.getenv("W")
_ = function(s) return s end
T = require("ffi/util").template
JSON = require("json")
lfs = require("libs/libkoreader-lfs")
require("ffi/loadlib")   -- (KOReader sets this up at start; ffi/archiver needs it)
local LOG = {}
debugLog = function(m) LOG[#LOG + 1] = m end
stripJsonNull = function(v) return v end
getPluginDir = function() return W .. "/plugins/bookbridge.koplugin" end
local sha = require("ffi/sha2")
sha256OfFile = function(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local d = f:read("*a"); f:close(); return sha.sha256(d):lower()
end
-- "GitHub": a scripted answer; "download": a local file copy
GITHUB = nil
doHttpGetString = function(url) return JSON.encode(GITHUB), 200 end
doHttpDownloadToFile = function(url, save_path)
    local src = url:gsub("^file://", "")
    local f = io.open(src, "rb"); if not f then return nil, nil, "no such file" end
    local d = f:read("*a"); f:close()
    local g = io.open(save_path, "wb"); g:write(d); g:close()
    return true, 200
end
dofile(W .. "/co.lua")
local pass, fail = 0, 0
local function ck(c, m) if c then pass = pass + 1; print("PASS  " .. m) else fail = fail + 1; print("FAIL  " .. m) end end
local function exists(p) return lfs.attributes(p, "mode") ~= nil end
local function read(p) local f = io.open(p); if not f then return nil end local d = f:read("*a"); f:close(); return d end
local function release(name, sha, size)
    return { tag_name = "v1.0.99-abc", assets = {
        { name = "zlibrary_plugin_v1.0.99.zip", browser_download_url = "file://" .. W .. "/" .. name,
          size = tonumber(size), digest = "sha256:" .. sha },
        { name = "source.zip", browser_download_url = "x", size = 1, digest = "sha256:00" },
    } }
end

ck(CO.installedVersion("zlibrary") == "1.0.50", "installed version read from _meta.lua")

-- 1. latest(): the plugin zip is picked, version from its name, digest parsed
GITHUB = release("good.zip", os.getenv("GOOD_SHA"), os.getenv("GOOD_SIZE"))
local info, err = CO.latest("zlibrary")
ck(info and info.version == "1.0.99" and info.digest == os.getenv("GOOD_SHA") and info.size == tonumber(os.getenv("GOOD_SIZE")), "latest(): zip asset, version, digest, size")

-- 2. a wrong digest is refused, nothing changes
local ok, e = CO.install("zlibrary", { url = info.url, size = info.size, digest = string.rep("0", 64), version = "1.0.99", tag = "t", name = "z.zip" })
ck(not ok and tostring(e):find("checksum"), "bad digest: refused (" .. tostring(e) .. ")")
ck(read(W .. "/plugins/zlibrary.koplugin/_meta.lua"):find("1.0.50"), "...and the old folder is untouched")
ck(not exists(W .. "/plugins/zlibrary.koplugin.new") and not exists(W .. "/plugins/.companion-zlibrary.zip"), "...no leftovers")

-- 3. a wrong size is refused
ok, e = CO.install("zlibrary", { url = info.url, size = info.size + 1, digest = info.digest, version = "1.0.99", tag = "t", name = "z.zip" })
ck(not ok and tostring(e):find("size"), "bad size: refused")

-- 4. a zip with a broken Lua file is refused
GITHUB = release("broken.zip", os.getenv("BROKEN_SHA"), os.getenv("BROKEN_SIZE"))
info = CO.latest("zlibrary")
ok, e = CO.install("zlibrary", info)
ck(not ok and tostring(e):find("parse"), "broken Lua inside: refused (" .. tostring(e) .. ")")
ck(read(W .. "/plugins/zlibrary.koplugin/_meta.lua"):find("1.0.50") and not exists(W .. "/plugins/zlibrary.koplugin.new"), "...old folder kept, .new removed")

-- 5. a zip without the expected folder is refused
GITHUB = release("wrong.zip", os.getenv("WRONG_SHA"), os.getenv("WRONG_SIZE"))
info = CO.latest("zlibrary")
ok, e = CO.install("zlibrary", info)
ck(not ok and tostring(e):find("folder"), "wrong top folder: refused")

-- 6. the good zip installs: prefix stripped, credentials kept, .prev kept
GITHUB = release("good.zip", os.getenv("GOOD_SHA"), os.getenv("GOOD_SIZE"))
info = CO.latest("zlibrary")
local rec
ok, rec = CO.install("zlibrary", info)
ck(ok == true and type(rec) == "table" and rec.version == "1.0.99", "good zip: unpacked and checked, record " .. tostring(rec and rec.version))
ck(read(W .. "/plugins/zlibrary.koplugin/_meta.lua"):find("1.0.50") and read(W .. "/plugins/zlibrary.koplugin.new/_meta.lua"):find("1.0.99"),
    "...the live folder is untouched until the parent swaps (a cancel can't land mid-swap)")
ok, e = CO.swapIn("zlibrary")
ck(ok == true, "swapIn: " .. tostring(e))
ck(read(W .. "/plugins/zlibrary.koplugin/_meta.lua"):find("1.0.99"), "live folder is the new version")
ck(exists(W .. "/plugins/zlibrary.koplugin/zlibrary/api.lua") and not exists(W .. "/plugins/zlibrary.koplugin/plugins"), "prefix plugins/zlibrary.koplugin/ stripped")
ck(read(W .. "/plugins/zlibrary.koplugin/zlibrary_credentials.lua"):find("me@example.com"), "zlibrary_credentials.lua carried over")
ck(read(W .. "/plugins/zlibrary.koplugin.prev/_meta.lua"):find("1.0.50"), "previous version kept as .prev")
ck(not exists(W .. "/plugins/.companion-zlibrary.zip"), "zip removed afterwards")

-- 7. rollback puts .prev back
ok, e = CO.rollback("zlibrary")
ck(ok and read(W .. "/plugins/zlibrary.koplugin/_meta.lua"):find("1.0.50"), "rollback restores the previous version")
ck(not exists(W .. "/plugins/zlibrary.koplugin.prev"), "...and consumes .prev")

-- 8. a Windows-made zip (backslashes) unpacks; its "../" entry is skipped
GITHUB = release("backslash.zip", os.getenv("BS_SHA"), os.getenv("BS_SIZE"))
info = CO.latest("zlibrary")
ok, e = CO.install("zlibrary", info)
ck(ok == true, "backslash entry names: unpacked (" .. tostring(e) .. ")")
ck(exists(W .. "/plugins/zlibrary.koplugin.new/zlibrary/api.lua"), "...with real folders")
ck(not exists(W .. "/plugins/escaped.lua") and not exists(W .. "/plugins/zlibrary.koplugin.new/escaped.lua"), "...and the ../ entry went nowhere")
CO.rmrf(W .. "/plugins/zlibrary.koplugin.new")

-- 9. a symlinked plugin folder is removed as a link, never emptied
lfs.mkdir(W .. "/devcopy"); local f = io.open(W .. "/devcopy/keep.lua", "w"); f:write("return 1"); f:close()
os.execute("ln -s '" .. W .. "/devcopy' '" .. W .. "/plugins/linked'")
ck(CO.isLink(W .. "/plugins/linked"), "a symlink is recognised")
CO.rmrf(W .. "/plugins/linked")
ck(not exists(W .. "/plugins/linked") and exists(W .. "/devcopy/keep.lua"), "rmrf on a symlink: link gone, target intact")

-- 10. swapIn without a verified .new refuses and leaves the live folder
ok, e = CO.swapIn("zlibrary")
ck(not ok and read(W .. "/plugins/zlibrary.koplugin/_meta.lua"):find("1.0.50"), "swapIn with no .new: refused, live folder kept")

-- 11. Readest's re-uploads: -10 beats -9 (a number, not a string)
GITHUB = { tag_name = "v0.12.12", assets = {
    { name = "Readest-0.12.12-9.koplugin.zip", browser_download_url = "x9", size = 9, digest = "sha256:" .. string.rep("9", 64) },
    { name = "Readest-0.12.12-10.koplugin.zip", browser_download_url = "x10", size = 10, digest = "sha256:" .. string.rep("a", 64) },
    { name = "Readest-0.12.12-2.koplugin.zip", browser_download_url = "x2", size = 2, digest = "sha256:" .. string.rep("2", 64) },
} }
info = CO.latest("readest")
ck(info and info.name == "Readest-0.12.12-10.koplugin.zip", "highest re-upload number wins: " .. tostring(info and info.name))

-- 12. the Reading Ledger is a companion too: its release asset is recognised, and it is never tucked
GITHUB = { tag_name = "v0.1.0", assets = {
    { name = "reading-ledger-0.1.0.zip", browser_download_url = "bundle", size = 5, digest = "sha256:" .. string.rep("b", 64) },
    { name = "reading-ledger-0.1.0.koplugin.zip", browser_download_url = "plugin", size = 7, digest = "sha256:" .. string.rep("c", 64) },
} }
info = CO.latest("ledger")
ck(info and info.name == "reading-ledger-0.1.0.koplugin.zip" and info.version == "0.1.0", "ledger: the plugin-only asset is picked, not the bundle (" .. tostring(info and info.name) .. ")")
ck(CO.DEF.ledger.tuck == false and CO.DEF.ledger.folder == "ledger.koplugin" and CO.ORDER[3] == "ledger", "ledger: its own KOReader menu entry stays (tuck = false)")


print(string.format("=== %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
LUA
