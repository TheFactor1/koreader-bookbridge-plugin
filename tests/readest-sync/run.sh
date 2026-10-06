#!/bin/bash
# Devices in step through Readest (SYNC): statistics up then down, the cloud
# list refreshed, every book in the library folder uploaded a few at a time
# (never while a book is open; "storage full" stops it for a day), books
# being read on another device downloaded, automatic runs throttled (not the
# sleep push). Offline: the Readest plugin, its store, uploads and download
# queue are stand-ins that record what they're asked; the book files are real.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
[ -x "${KDIR:-/nonexistent}/luajit" ] || { echo "SKIP  no local KOReader (set KOREADER_DIR)"; exit 3; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
M="$REPO/bookbridge.koplugin/main.lua"
{ awk '/^-- ===== SYNC begin/{f=1} f{print} f&&/^-- ===== SYNC end/{exit}' "$M" | sed 's/^local SYNC = {/SYNC = {/'
  for f in syncNow readestLibraryPasses; do awk "/^function Bookbridge:$f\\(/{f=1} f{print} f&&/^end\$/{exit}" "$M"; done
} > "$W/fns.lua"
grep -q "function Bookbridge:readestLibraryPasses" "$W/fns.lua" && grep -q "function SYNC.readingElsewhere" "$W/fns.lua" || { echo "FAIL  extraction failed"; exit 1; }
mkdir -p "$W/lib/sub/deeper.sdr" "$W/lib/.hidden"
for n in a b c d e f g; do head -c 2000 /dev/urandom > "$W/lib/book-$n.epub"; done
head -c 2000 /dev/urandom > "$W/lib/sub/nested.pdf"
head -c 10 /dev/urandom > "$W/lib/sub/deeper.sdr/metadata.epub"
head -c 10 /dev/urandom > "$W/lib/partial.epub.downloading"
head -c 10 /dev/urandom > "$W/lib/notes.txt.unknown"
cd "$KDIR" || exit 1
W="$W" ./luajit - <<'LUA'
package.path = "frontend/?.lua;common/?.lua;" .. package.path
package.cpath = "common/?.so;libs/?.so;" .. package.cpath
local W = os.getenv("W")
_ = function(s) return s end
T = require("ffi/util").template
JSON = require("json")
lfs = require("libs/libkoreader-lfs")
DataStorage = { getSettingsDir = function() return W end }
local LOG = {}
debugLog = function(m) LOG[#LOG + 1] = m end
local SHOWN = {}
InfoMessage = { new = function(_s, t) return t end }
local Q = {}   -- scheduled functions
UIManager = { show = function(_s, w) SHOWN[#SHOWN + 1] = w end, scheduleIn = function(_s, _d, f) Q[#Q + 1] = f end,
    broadcastEvent = function() end }
local function drain() local n = 0 while #Q > 0 and n < 200 do n = n + 1; table.remove(Q, 1)() end end
local ONLINE = true
package.loaded["ui/network/manager"] = { isOnline = function() return ONLINE end }
package.loaded["library.exts"] = { EPUB = "epub", PDF = "pdf" }
package.loaded["util"] = { partialMD5 = function(path) return "md5:" .. path:match("([^/]+)$") end }
package.loaded["readest_syncauth"] = { stub = true }
-- Readest's upload: records, then answers as scripted
local UP = { calls = {}, fail_from = nil, status = nil }
package.loaded["library.syncbooks"] = { uploadAndRecord = function(row, opts, cb)
    UP.calls[#UP.calls + 1] = row
    if UP.fail_from and #UP.calls >= UP.fail_from then return cb(false, "Insufficient storage quota", UP.status or 403) end
    row.uploaded_at = 1; opts.store.rows[row.hash] = row
    cb(true)
end }
local DQ = { started = {}, running = false }
package.loaded["library.downloadqueue"] = { isRunning = function() return DQ.running end,
    start = function(books, opts) DQ.started[#DQ.started + 1] = { books = books, opts = opts } end }
local function store(rows)
    local st = { rows = rows or {} }
    function st:_getRowRaw(h) return self.rows[h] end
    function st:upsertBook(r) local e = self.rows[r.hash] or {}; for k, v in pairs(r) do if k ~= "_clear_fields" then e[k] = v end end; self.rows[r.hash] = e end
    function st:listCloudOnlyBooks() local out = {} for _, r in pairs(self.rows) do if r.cloud_only then out[#out + 1] = r end end return out end
    return st
end
local CALLS = {}
local function readest(st, settings)
    local rs = { settings = settings or { access_token = "t", user_id = "u", auto_sync = true }, path = "/rp", st = st }
    function rs:pushBookStats() CALLS[#CALLS + 1] = "push" end
    function rs:pullBookStats() CALLS[#CALLS + 1] = "pull" end
    function rs:syncBooksLibrary(mode) CALLS[#CALLS + 1] = "books:" .. mode end
    function rs:getLibraryStore() return self.st end
    return rs
end
Bookbridge = {}
assert(load(io.open(W .. "/fns.lua"):read("*a")))()
local pass, fail = 0, 0
local function ck(c, m) if c then pass = pass + 1; print("PASS  " .. m) else fail = fail + 1; print("FAIL  " .. m) end end
local function bb(t)
    t = t or {}
    t.readest_library_upload = t.readest_library_upload or "all"
    t.readest_download = t.readest_download or "reading"
    t.libraryDir = function() return W .. "/lib" end
    t.saveAllSettings = function(self) self.saved = (self.saved or 0) + 1 end
    return setmetatable(t, { __index = Bookbridge })
end
local function reset() CALLS, SHOWN, LOG, Q = {}, {}, {}, {}; UP.calls = {}; DQ.started = {}; SYNC.last = 0; SYNC.uploading = false end

-- the scan: book files four levels down; not .sdr, partials, hidden or unknown
local found = SYNC.scan(W .. "/lib")
local names = {}
for _, f in ipairs(found) do names[f.path:match("([^/]+)$")] = f.format end
ck(names["book-a.epub"] == "EPUB" and names["nested.pdf"] == "PDF", "scan: books, in subfolders too, with their format")
ck(not names["metadata.epub"] and not names["partial.epub.downloading"] and not names["notes.txt.unknown"], "scan: not .sdr folders, partial downloads or unknown files")

-- 1. a run: statistics up, then down, then the cloud list
reset()
local st = store()
local b = bb({ ui = { readest = readest(st) } })
ck(b:syncNow("ledger") == true and CALLS[1] == "push" and CALLS[2] == "pull" and CALLS[3] == "books:both", "statistics up, then down, then the cloud list")
ck(b.readest_last_sync and b.saved, "...and when it last synced is kept")
drain()
ck(#UP.calls == SYNC.UPLOAD_BATCH, "upload: a batch of " .. SYNC.UPLOAD_BATCH .. " of the 8 books in the folder")
ck(UP.calls[1].file_path and UP.calls[1].format and UP.calls[1].local_present == 1, "...each as a Readest row with its file and format")

-- 2. throttled: a second automatic run within 10 minutes does nothing
reset(); SYNC.last = os.time() - 60
b:syncNow("wake")
ck(#CALLS == 0, "a wake 1 minute after the last run: nothing (throttled)")
b:syncNow("manual", true)
ck(#CALLS == 3, "...but Sync now always runs")
drain()
ck(#UP.calls == 3, "the next run uploads the remaining 3 (already-uploaded books skipped)")
ck(SHOWN[#SHOWN] and SHOWN[#SHOWN].text:find("3 book%(s%) uploaded"), "Sync now says what it did")

-- 3. sleep: statistics up only, not throttled
reset(); SYNC.last = os.time()
b:syncNow("sleep")
ck(#CALLS == 1 and CALLS[1] == "push" and #Q == 0, "before sleep: statistics up only, even right after a run")

-- 4. offline / not signed in / auto sync off: nothing, and Sync now says why
reset(); ONLINE = false
ck(b:syncNow("wake") == false and #CALLS == 0, "offline: nothing (it never turns Wi-Fi on)")
b:syncNow("manual", true)
ck(SHOWN[#SHOWN] and SHOWN[#SHOWN].text:find("Wi%-Fi"), "...Sync now asks for Wi-Fi")
ONLINE = true
reset()
local off = bb({ ui = { readest = readest(store(), { access_token = "t", user_id = "u", auto_sync = false }) } })
off:syncNow("manual", true)
ck(#CALLS == 0 and SHOWN[1] and SHOWN[1].text:find("auto sync is off"), "Readest auto sync off: nothing, and it says so")
reset()
local nobody = bb({ ui = { readest = readest(store(), {}) } })
nobody:syncNow("manual", true)
ck(#CALLS == 0 and SHOWN[1] and SHOWN[1].text:find("Sign in"), "not signed in to Readest: nothing, and it says so")
reset()
bb({ ui = {} }):syncNow("manual", true)
ck(#CALLS == 0 and SHOWN[1] and SHOWN[1].text:find("isn't installed"), "no Readest plugin: says so")

-- 5. never uploads while a book is open
reset()
local reading = bb({ ui = { readest = readest(store()), document = { file = "x" } } })
reading:syncNow("ledger"); drain()
ck(#CALLS == 3 and #UP.calls == 0, "a book open: statistics and list sync, no uploads")

-- 6. storage full: stops, says so once, waits a day
reset(); UP.fail_from = 2
local full = bb({ ui = { readest = readest(store()) } })
full:syncNow("ledger"); drain()
ck(#UP.calls == 2 and full.readest_quota_full_at and SHOWN[1] and SHOWN[1].text:find("500 MB"), "storage full: stops at the first refusal and says so")
reset(); UP.fail_from = nil
full:syncNow("manual", true); drain()
ck(#UP.calls == 0, "...and doesn't try again within the day")
full.readest_quota_full_at = os.time() - 25 * 3600
reset(); full:syncNow("manual", true); drain()
ck(#UP.calls > 0, "...a day later it tries again")

-- 7. upload choices
reset()
bb({ ui = { readest = readest(store()) }, readest_library_upload = "opened" }):syncNow("manual", true); drain()
ck(#UP.calls == 0, "'books I open': the folder isn't uploaded")

-- 8. downloads: only books being read on another device
reset()
local now_ms = os.time() * 1000
local rows = {
    reading = { hash = "r1", title = "Halfway", cloud_only = true, progress_lib = "[120,300]", updated_at = now_ms - 86400000 },
    done = { hash = "r2", title = "Finished", cloud_only = true, progress_lib = "[300,300]", updated_at = now_ms },
    untouched = { hash = "r3", title = "Never opened", cloud_only = true, updated_at = now_ms },
    stale = { hash = "r4", title = "Old", cloud_only = true, progress_lib = "[50,300]", updated_at = now_ms - 40 * 86400000 },
    marked = { hash = "r5", title = "Given up", cloud_only = true, progress_lib = "[50,300]", updated_at = now_ms, reading_status = "abandoned" },
}
local rs8 = readest(store({ r1 = rows.reading, r2 = rows.done, r3 = rows.untouched, r4 = rows.stale, r5 = rows.marked }))
bb({ ui = { readest = rs8 }, readest_library_upload = "off" }):syncNow("manual", true); drain()
ck(#DQ.started == 1 and #DQ.started[1].books == 1 and DQ.started[1].books[1].hash == "r1",
    "downloads: only the book partway through on another device lately (not finished, unopened, stale or given up)")
ck(rs8.settings.library_download_dir == W .. "/lib", "...into this device's library folder")
reset(); DQ.running = true
bb({ ui = { readest = rs8 }, readest_library_upload = "off" }):syncNow("manual", true); drain()
ck(#DQ.started == 0, "...not queued again while a download is running")
DQ.running = false
reset()
bb({ ui = { readest = rs8 }, readest_library_upload = "off", readest_download = "off" }):syncNow("manual", true); drain()
ck(#DQ.started == 0, "downloads switched off: nothing comes down")

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
LUA
