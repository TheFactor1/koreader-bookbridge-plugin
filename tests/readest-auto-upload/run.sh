#!/bin/bash
# Reading a book puts it in Readest (Bookbridge > Readest sync, "upload books
# I read"): after five page turns, the book and its cover go up. Readest's
# upload holds the screen while it works (~3 s on a Kindle: the cover, then
# each file sent), so it must never run inside a page turn: checks that it
# waits until the page is drawn, takes the cover from the open book (not a
# second copy opened from disk), comes apart in two steps, and drops out
# when the book is closed meanwhile. Offline: the Readest plugin, its store
# and upload are stand-ins; the cover is a real image written to disk.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
[ -x "${KDIR:-/nonexistent}/luajit" ] || { echo "SKIP  no local KOReader (set KOREADER_DIR)"; exit 3; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
M="$REPO/bookbridge.koplugin/main.lua"
awk '/^local READEST_AUTO_UPLOAD_PAGES/{f=1} f{print} f&&/^function Bookbridge:autoUploadToReadest\(/{g=1} g&&/^end$/{exit}' "$M" > "$W/fns.lua"
grep -q "function Bookbridge:readestCoverFromOpenBook" "$W/fns.lua" && grep -q "function Bookbridge:autoUploadToReadest" "$W/fns.lua" \
  || { echo "FAIL  extraction failed"; exit 1; }
head -c 4000 /dev/urandom > "$W/book.epub"
cd "$KDIR" || exit 1
W="$W" ./luajit - <<'LUA'
package.path = "frontend/?.lua;common/?.lua;" .. package.path
package.cpath = "common/?.so;libs/?.so;" .. package.cpath
require("ffi/loadlib")
local W = os.getenv("W")
local Blitbuffer = require("ffi/blitbuffer")
lfs = require("libs/libkoreader-lfs")
DataStorage = { getSettingsDir = function() return W end }
local LOG = {}
debugLog = function(m) LOG[#LOG + 1] = m end
local Q = {}   -- scheduled: { delay, fn }
UIManager = { scheduleIn = function(_s, d, f) Q[#Q + 1] = { d, f } end }
local function run1() local t = table.remove(Q, 1); if t then t[2]() end return t end
package.loaded["ui/network/manager"] = { isOnline = function() return true end }
package.loaded["library.exts"] = { EPUB = "epub" }
package.loaded["readest_syncauth"] = {}
package.loaded["readest_syncconfig"] = { getMetaHash = function() return "mh" end }
local UP = {}
package.loaded["library.syncbooks"] = { uploadAndRecord = function(row, opts, cb)
    UP[#UP + 1] = { row = row, opts = opts, cover_there = lfs.attributes(opts.covers_dir .. "/" .. row.hash .. ".png", "mode") == "file" }
    cb(true)
end }
local COVER = { calls = 0, docs = {}, fail = false, write_fails = false }
package.loaded["apps/filemanager/filemanagerbookinfo"] = { getCoverImage = function(_s, doc, file)
    COVER.calls = COVER.calls + 1
    COVER.docs[#COVER.docs + 1] = { doc = doc, file = file }
    if COVER.fail then error("no cover in this book") end
    local bb = Blitbuffer.new(60, 90, Blitbuffer.TYPE_BB8)
    bb:fill(Blitbuffer.COLOR_GRAY)
    if COVER.write_fails then bb.writeToFile = function(self, path) io.open(path, "w"):close(); return false end end
    return bb
end }
Bookbridge = {}
assert(load(io.open(W .. "/fns.lua"):read("*a")))()
local pass, fail = 0, 0
local function ck(c, m) if c then pass = pass + 1; print("PASS  " .. m) else fail = fail + 1; print("FAIL  " .. m) end end

local n_book = 0
local function newBook(opts)
    opts = opts or {}
    n_book = n_book + 1
    local hash = "h" .. n_book
    local st = { rows = {} }
    function st:_getRowRaw(h) return self.rows[h] end
    function st:upsertBook(r) self.rows[r.hash] = r end
    local rs = { settings = { access_token = "t", user_id = "u", auto_sync = true }, path = "/rp" }
    function rs:getLibraryStore() return st end
    local doc = { file = W .. "/book.epub" }
    local ui = { document = doc, readest = rs,
        doc_settings = { readSetting = function(_s, k)
            if k == "partial_md5_checksum" then return hash end
            if k == "doc_props" then return { title = "A Book" } end
        end } }
    local b = setmetatable({ ui = ui, readest_upload = opts.upload ~= false }, { __index = Bookbridge })
    return b, hash, ui
end
local function reset() Q, UP, LOG = {}, {}, {}; COVER.calls, COVER.docs, COVER.fail, COVER.write_fails = 0, {}, false, false end
local function cover(hash) return W .. "/readest_covers/" .. hash .. ".png" end

-- 1. the fifth page: nothing happens inside the page turn
reset()
local b, hash, ui = newBook()
for _ = 1, 4 do b:onPageUpdate() end
ck(#Q == 0 and #UP == 0, "pages 1-4: nothing")
b:onPageUpdate()
ck(#UP == 0 and COVER.calls == 0, "page 5: no upload and no cover inside the page turn")
ck(#Q == 1 and Q[1][1] >= 1, "...one step scheduled for after the page is drawn (+" .. tostring(Q[1] and Q[1][1]) .. " s)")
-- 2. step one: the cover, from the open book, written where Readest looks
run1()
ck(COVER.calls == 1 and COVER.docs[1].doc == ui.document and COVER.docs[1].file == nil, "step 1: the cover comes from the open book (not a second copy from disk)")
local f = io.open(cover(hash), "rb"); local head = f and f:read(8); if f then f:close() end
ck(head == "\137PNG\r\n\26\n", "...written as a PNG in readest_covers/<hash>.png")
ck(lfs.attributes(cover(hash) .. ".part", "mode") == nil, "...no .part file left")
ck(#UP == 0 and #Q == 1, "...and the upload is a separate, later step")
-- 3. step two: the upload, which finds the cover in place
run1()
ck(#UP == 1 and UP[1].row.hash == hash and UP[1].cover_there, "step 2: the upload, with the cover already there (Readest won't open the book again)")
ck(UP[1].opts.covers_dir == W .. "/readest_covers", "...Readest is pointed at the same covers folder")
for _ = 1, 10 do b:onPageUpdate() end
ck(#Q == 0, "once per sitting: later pages schedule nothing")

-- 4. the book closed (or another opened) before the steps run: nothing
reset()
b, hash, ui = newBook()
for _ = 1, 5 do b:onPageUpdate() end
ui.document = nil
run1()
ck(COVER.calls == 0 and #Q == 0 and #UP == 0, "book closed before step 1: no cover, no upload")
reset()
b, hash, ui = newBook()
for _ = 1, 5 do b:onPageUpdate() end
run1()
ui.document = { file = W .. "/other.epub" }
run1()
ck(COVER.calls == 1 and #UP == 0, "another book open by step 2: no upload of the wrong book")

-- 5. a cover already on hand (a book that came down from Readest): left alone
reset()
b, hash, ui = newBook()
io.open(cover(hash), "w"):close()
for _ = 1, 5 do b:onPageUpdate() end
run1(); run1()
ck(COVER.calls == 0 and #UP == 1, "cover already there: not rendered again; uploaded")

-- 6. no cover to be had: the book still goes up
reset()
b, hash, ui = newBook()
COVER.fail = true
for _ = 1, 5 do b:onPageUpdate() end
run1(); run1()
ck(#UP == 1 and not UP[1].cover_there, "cover fails: the book still uploads")
ck(LOG[1] and LOG[1]:find("cover from the open book failed", 1, true), "...and the failure is logged")
reset()
b, hash, ui = newBook()
COVER.write_fails = true
for _ = 1, 5 do b:onPageUpdate() end
run1()
ck(lfs.attributes(cover(hash), "mode") == nil and lfs.attributes(cover(hash) .. ".part", "mode") == nil, "cover write fails: no half-written file left, in place or .part")

-- 7. switched off: nothing at all
reset()
b = newBook({ upload = false })
for _ = 1, 8 do b:onPageUpdate() end
ck(#Q == 0, "upload switched off: nothing scheduled")

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
LUA
