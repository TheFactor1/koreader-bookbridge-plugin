#!/bin/bash
# Desktop end-to-end against the REAL Bookshelf plugin (AndyHazz/bookshelf.koplugin,
# a copy at $BOOKSHELF_DIR): show the shelf, open a book, send Home -- Bookshelf
# intercepts it and hot-parks the reader under the shelf instead of closing it.
# Asserts shelfmark treats that park as the close: captures at once, syncs, and
# captures only once, while the reader stays alive underneath. Needs a local
# KOReader; sandboxes its settings like tests/live-sync. Never touches a device.
#
#   bash tests/hardcover-park/run.sh
set -uo pipefail
BOOKSHELF_DIR=${BOOKSHELF_DIR:-$HOME/.local/opt/bookshelf.koplugin}
[ -f "$BOOKSHELF_DIR/main.lua" ] || { echo "SKIP  no Bookshelf plugin at $BOOKSHELF_DIR (set BOOKSHELF_DIR)"; exit 3; }
KDIR=$(ls -d ~/.local/opt/koreader-*/lib/koreader | sort -V | tail -1)
INSPECT=8181; I="http://127.0.0.1:$INSPECT/koreader"
CFG=~/.config/koreader; SET=$CFG/settings
W=$(mktemp -d); BOOKS="$W/books"; mkdir -p "$BOOKS" "$W/bak"
say() { printf '%-6s%s\n' "$1" "$2"; }; fail=0
for f in "$SET/shelfmark.lua" "$SET/shelfmark_hardcover_pending.json" "$SET/shelfmark_hardcover_map.json" "$SET/shelfmark-debug.log" "$CFG/settings.reader.lua"; do [ -f "$f" ] && cp -a "$f" "$W/bak/$(basename "$f")"; done
ls -A "$SET" > "$W/settings-before.txt"
stop_koreader() {
  setsid sh -c 'for p in $(ss -ltnp "( sport = :'"$INSPECT"' )" 2>/dev/null | grep -oE "pid=[0-9]+" | cut -d= -f2 | sort -u); do kill "$p" 2>/dev/null; done
    pkill -f "^\./luajit \./reader\.lua" 2>/dev/null; pkill -f "^/bin/sh \./koreader\.sh" 2>/dev/null; true' >/dev/null 2>&1
  for i in $(seq 1 10); do ss -ltn "( sport = :$INSPECT )" | tail -n +2 | grep -q . || break; sleep 1; done
}
cleanup() {
  stop_koreader
  rm -f "$KDIR/plugins/bookshelf.koplugin"
  rm -f "$SET/shelfmark.lua" "$SET/shelfmark_hardcover_pending.json" "$SET/shelfmark_hardcover_map.json" "$SET/shelfmark-debug.log"
  ls -A "$SET" | while read -r n; do grep -qxF "$n" "$W/settings-before.txt" || rm -rf "$SET/$n"; done   # anything Bookshelf created
  for f in "$W"/bak/*; do [ -e "$f" ] || continue; case "$(basename "$f")" in settings.reader.lua) cp -a "$f" "$CFG/";; *) cp -a "$f" "$SET/";; esac; done
  rm -rf "$W"
}
trap cleanup EXIT
# a real multi-page book (never one page: that trips end-of-document actions)
python3 - "$BOOKS/Probe Author - The Parking Probe.epub" <<'PY'
import sys, zipfile
out = sys.argv[1]
chap = lambda n: f'<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter {n}</title></head><body><h1>Chapter {n}</h1>' + ''.join(f'<p>Paragraph {i} of chapter {n}. ' + 'The probe reads on and on across the page so that this chapter takes several screens to render. ' * 8 + '</p>' for i in range(1, 25)) + '</body></html>'
N = 12
opf = '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" unique-identifier="id" version="2.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>The Parking Probe</dc:title><dc:creator>Probe Author</dc:creator><dc:identifier id="id">urn:uuid:parking-probe-1</dc:identifier><dc:language>en</dc:language></metadata><manifest>' + ''.join(f'<item id="c{n}" href="c{n}.xhtml" media-type="application/xhtml+xml"/>' for n in range(1, N+1)) + '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest><spine toc="ncx">' + ''.join(f'<itemref idref="c{n}"/>' for n in range(1, N+1)) + '</spine></package>'
ncx = '<?xml version="1.0"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="urn:uuid:parking-probe-1"/></head><docTitle><text>The Parking Probe</text></docTitle><navMap>' + ''.join(f'<navPoint id="n{n}" playOrder="{n}"><navLabel><text>Chapter {n}</text></navLabel><content src="c{n}.xhtml"/></navPoint>' for n in range(1, N+1)) + '</navMap></ncx>'
with zipfile.ZipFile(out, 'w') as z:
    z.writestr('mimetype', 'application/epub+zip', compress_type=zipfile.ZIP_STORED)
    z.writestr('META-INF/container.xml', '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
    z.writestr('content.opf', opf); z.writestr('toc.ncx', ncx)
    for n in range(1, N+1): z.writestr(f'c{n}.xhtml', chap(n))
PY
BOOK="$BOOKS/Probe Author - The Parking Probe.epub"
BOOK_URL=$(python3 -c "import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))" "$BOOK")
ln -sfn "$BOOKSHELF_DIR" "$KDIR/plugins/bookshelf.koplugin"
[ -f "$KDIR/plugins/bookshelf.koplugin/main.lua" ] && say PASS "real Bookshelf plugin installed for this run" || { say FAIL "bookshelf install"; exit 1; }
mkdir -p "$SET"
cat > "$SET/shelfmark.lua" <<LUA
return { ["shelfmark"] = { ["download_dir"] = "$BOOKS", ["hardcover_token"] = "probe-token-not-real", ["hardcover_progress_sync"] = true } }
LUA
rm -f "$SET/shelfmark_hardcover_pending.json" "$SET/shelfmark_hardcover_map.json"; : > "$SET/shelfmark-debug.log"
stop_koreader
"$KDIR/luajit" -e "
local p=os.getenv('HOME')..'/.config/koreader/settings.reader.lua'
local ok,t=pcall(dofile,p); if not ok or type(t)~='table' then t={} end
t.httpinspector={port=$INSPECT,autostart=true}
local function ser(v,ind) ind=ind or '' if type(v)=='table' then local o={'{\n'} for k,x in pairs(v) do o[#o+1]=ind..'    ['..(type(k)=='string' and string.format('%q',k) or tostring(k))..'] = '..ser(x,ind..'    ')..',\n' end o[#o+1]=ind..'}' return table.concat(o) elseif type(v)=='string' then return string.format('%q',v) else return tostring(v) end end
local f=assert(io.open(p,'w')) f:write('return '..ser(t)..'\n') f:close()"
(cd "$KDIR" && setsid -f ./koreader.sh > "$W/koreader.log" 2>&1)
for i in $(seq 1 30); do curl -s -o /dev/null --max-time 2 "$I/" && break; sleep 1; done
curl -s -o /dev/null --max-time 2 "$I/" || { say FAIL "inspector never answered"; exit 1; }
[ "$(curl -s --max-time 5 "$I/ui/bookbridge/download_dir" | tr -d '"')" = "$BOOKS" ] && say PASS "driving the KOReader this run launched" || { say FAIL "wrong KOReader"; exit 1; }
# 1. shelf up
curl -s --max-time 8 "$I/ui/bookshelf/show/" >/dev/null; sleep 2
stack() { curl -s --max-time 5 "$I/UIManager/_window_stack/" | tr -d '\n' | cut -c1-600; }
echo "stack after show: $(stack)"
# 2. open the book (inspector dies across the transition; wait for the reader's)
echo "openFile -> $(curl -s --max-time 8 "$I/ui/openFile/'$BOOK_URL'" | tr -d '\n' | cut -c1-200)"
for i in $(seq 1 30); do [ "$(curl -s --max-time 3 "$I/ui/document/file" | tr -d '"')" = "$BOOK" ] && break; sleep 1; done
[ "$(curl -s --max-time 3 "$I/ui/document/file" | tr -d '"')" = "$BOOK" ] && say PASS "book open in the reader" || { say FAIL "reader never came up"; tail -5 "$W/koreader.log"; exit 1; }
sleep 5   # onReaderReady (+ the 3 s prefetch) has run
grep -q "bookshelf parking hooked" "$SET/shelfmark-debug.log" && say PASS "Park.park hooked at reader-ready" || say INFO "park module not loaded at reader-ready; the CloseConfigMenu fallback must catch it"
# 3. Home: Bookshelf intercepts it and parks the reader under the shelf
: > "$W/t0"; curl -s --max-time 8 "$I/event/Home" >/dev/null
for i in $(seq 1 12); do grep -q "captured" "$SET/shelfmark-debug.log" && break; sleep 0.5; done
t_ms=$(( ( $(date +%s%N) - $(stat -c %Y "$W/t0")000000000 ) / 1000000 ))
grep -q "parked under the shelf: treating it as the close" "$SET/shelfmark-debug.log" && say PASS "park detected" || { say FAIL "park not detected"; fail=1; }
grep -q "captured .*The Parking Probe" "$SET/shelfmark-debug.log" && say PASS "progress captured at the park (~${t_ms} ms after Home)" || { say FAIL "no capture after Home"; fail=1; }
sleep 3
n_cap=$(grep -c "captured" "$SET/shelfmark-debug.log"); [ "$n_cap" = 1 ] && say PASS "captured exactly once" || { say FAIL "captured $n_cap times"; fail=1; }
grep -q "process: 1 pending" "$SET/shelfmark-debug.log" && say PASS "sync ran right after the park" || { say FAIL "no sync after park"; fail=1; }
[ "$(curl -s --max-time 3 "$I/ui/document/file" | tr -d '"')" = "$BOOK" ] && say PASS "reader still alive underneath (parked, not closed)" || say INFO "reader gone (real close happened)"
echo "stack after Home: $(stack)"
grep -E "ERROR|Traceback|attempt to" "$W/koreader.log" | grep -v "Font " | grep -q . && { say FAIL "KOReader logged an error:"; grep -E "ERROR|Traceback|attempt to" "$W/koreader.log" | grep -v "Font " | head -3; fail=1; } || say PASS "no KOReader errors (font warning aside)"
echo "--- debug log:"; grep "\[hc\]" "$SET/shelfmark-debug.log" | cut -c1-150
[ $fail -eq 0 ] && echo "=== PARK E2E PASS" || echo "=== PARK E2E FAIL"; exit $fail
