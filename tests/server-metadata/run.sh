#!/bin/bash
# A book from Calibre-Web gets its series (and summary) in KOReader's own
# record of it -- custom_metadata.lua beside it -- since the file arrives
# without them (CWA's "embed metadata" is off on purpose). Real KOReader
# DocSettings, DocumentRegistry and crengine on a real EPUB; the feed entry
# is laid out as CWA-NextGen's templates/feed.xml writes it. Offline.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd); M="$REPO/bookbridge.koplugin/main.lua"
KDIR=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
[ -x "${KDIR:-/nonexistent}/luajit" ] || { echo "SKIP  no local KOReader (set KOREADER_DIR)"; exit 3; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
{ awk 'index($0, "local function decodeHtmlEntities(") == 1 {f=1} f{print} f&&/^end$/{exit}' "$M"
  awk 'index($0, "local function parseOpdsEntries(") == 1 {f=1} f{print} f&&/^end$/{exit}' "$M"
  for f in applyServerMetadata serverMetadataFor; do
      awk "/^function Bookbridge:$f\\(/{f=1} f{print} f&&/^end\$/{exit}" "$M"
  done
  echo 'return { parse = parseOpdsEntries }'
} > "$W/fns.lua"
grep -q "function Bookbridge:applyServerMetadata" "$W/fns.lua" || { echo "FAIL  extraction failed"; exit 1; }
mkdir -p "$W/books" "$W/home"
python3 "$REPO/tests/live-sync/make-epub.py" "$W/books/Heir to the Empire.epub" "Heir to the Empire" "Timothy Zahn"
python3 "$REPO/tests/live-sync/make-epub.py" "$W/books/Own Series.epub" "Own Series" "Some Author"

cd "$KDIR" || exit 1
W="$W" ./luajit - <<'LUA' 2>&1 | grep -E "^(PASS|FAIL|===)|attempt|rror"
package.path = "frontend/?.lua;common/?.lua;" .. package.path
package.cpath = "common/?.so;libs/?.so;" .. package.cpath
local W = os.getenv("W")
require("setupkoenv")
-- (a device that is none in particular: what the document code asks of it)
package.loaded["device"] = setmetatable({ screen = setmetatable({}, { __index = function() return function() return 0 end end }),
    home_dir = os.getenv("W") }, { __index = function() return function() return false end end })
pcall(function() require("document/canvascontext"):init(package.loaded["device"]) end)
G_reader_settings = require("luasettings"):open(W .. "/home/settings.reader.lua")
G_defaults = require("luadefaults"):open(W .. "/home/defaults.custom.lua")
G_reader_settings:saveSetting("document_metadata_folder", "doc")
_ = function(s) return s end
T = require("ffi/util").template
local LOG, EVENTS = {}, {}
debugLog = function(m) LOG[#LOG + 1] = m end
invalidateBookInfoCache = function() end
UIManager = { broadcastEvent = function(_s, e) EVENTS[#EVENTS + 1] = e.handler end }
socketurl = { escape = function(s) return s end }
Bookbridge = {}
local F = dofile(W .. "/fns.lua")
local pass, fail = 0, 0
local function ck(c, m) if c then pass = pass + 1; print("PASS  " .. m) else fail = fail + 1; print("FAIL  " .. m) end end

-- an OPDS search answer as CWA-NextGen writes it (templates/feed.xml)
local FEED = [[<feed><entry>
    <title>Heir to the Empire</title>
    <id>urn:uuid:5f1c0d2e-aaaa-bbbb-cccc-0123456789ab</id>
    <author><name>Timothy Zahn</name></author>
    <published>1991-05-01T00:00:00+00:00</published>
    <calibre:series>Star Wars: The Thrawn Trilogy</calibre:series>
    <calibre:series_index>1.00</calibre:series_index>
    <dcterms:isPartOf>Star Wars: The Thrawn Trilogy</dcterms:isPartOf>
    <summary type="text">It&#39;s five years after Return of the Jedi.</summary>
    <link type="application/epub+zip" rel="http://opds-spec.org/acquisition" href="/opds/download/118/epub/"/>
  </entry><entry>
    <title>A Standalone</title>
    <id>urn:uuid:11111111-2222-3333-4444-555555555555</id>
    <author><name>Nobody</name></author>
    <published>0101-01-01T00:00:00+00:00</published>
    <link type="application/epub+zip" rel="http://opds-spec.org/acquisition" href="/opds/download/7/epub/"/>
  </entry></feed>]]
local e = F.parse(FEED)
ck(#e == 2 and e[1].series == "Star Wars: The Thrawn Trilogy" and e[1].series_index == 1, "the feed's series and number are read")
ck(e[1].description == "It's five years after Return of the Jedi." and e[1].year == "1991", "...and its summary and year")
ck(e[2].series == nil and e[2].year == nil, "a book in no series: none; Calibre's 0101 'no date': no year")

local DocSettings = require("docsettings")
local heir = W .. "/books/Heir to the Empire.epub"
local bb = setmetatable({}, { __index = Bookbridge })
ck(bb:applyServerMetadata(heir, e[1]) == true, "applied to a book that has never been opened")
local cf = DocSettings:findCustomMetadataFile(heir)
local cs = cf and DocSettings.openSettingsFile(cf)
local custom = cs and cs:readSetting("custom_props") or {}
local orig = cs and cs:readSetting("doc_props") or {}
ck(custom.series == "Star Wars: The Thrawn Trilogy" and custom.series_index == 1, "KOReader's record has the series and number")
ck(orig.title == "Heir to the Empire" and orig.authors == "Timothy Zahn", "...and keeps the book's own details (Reset to original works)")
-- (what Book information shows: the custom props over the book's own)
local shown = {}
for k, v in pairs(orig) do shown[k] = v end
for k, v in pairs(custom) do shown[k] = v end
ck(shown.series == "Star Wars: The Thrawn Trilogy" and shown.title == "Heir to the Empire",
    "what KOReader shows: the series, the book's own title")
ck(EVENTS[1] == "onInvalidateMetadataCache", "KOReader is told the book's details changed")
ck(bb:applyServerMetadata(heir, e[1]) == false, "a second time: nothing to add")
-- never over what was set by hand
cs:saveSetting("custom_props", { series = "My Own Name" }); cs:flushCustomMetadata(heir)
ck(bb:applyServerMetadata(heir, { series = "Server Name", series_index = 3 }) == false
    and DocSettings.openSettingsFile(DocSettings:findCustomMetadataFile(heir)):readSetting("custom_props").series == "My Own Name",
    "a series set by hand stays")
ck(bb:applyServerMetadata(W .. "/books/Own Series.epub", { title = "Own Series" }) == false, "nothing from the server: nothing written")
ck(DocSettings:findCustomMetadataFile(W .. "/books/Own Series.epub") == nil, "...not even an empty record")
ck(bb:applyServerMetadata(W .. "/books/missing.epub", e[1]) == false, "a file that isn't there: no error")

-- Refresh from Calibre-Web: found by title in the server's search
local own = W .. "/books/Own Series.epub"
bb.cwa_url = "http://cwa"
bb.cwaRequest = function(_s, path) bb.asked = path; return FEED:gsub("Heir to the Empire", "Own Series"), 200 end
local added = bb:serverMetadataFor(own, "Own Series")
ck(bb.asked == "/opds/search/Own Series" and added == "Star Wars: The Thrawn Trilogy #1", "Refresh: found by its title, series added (" .. tostring(added) .. ")")
bb.cwaRequest = function() return FEED, 200 end
ck(bb:serverMetadataFor(W .. "/books/Heir to the Empire.epub", "Heir to the Empire") == nil, "Refresh: a book that already has a series is left alone")

print(string.format("=== %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
LUA
exit ${PIPESTATUS[0]}
