#!/bin/bash
# Full-pipeline dry run of doSyncLibrary against the REAL CWA library.
#
# Runs the actual doSyncLibrary from main.lua (extracted by anchor, see
# build-harness.sh) under LuaJIT with only I/O shimmed: a virtual sync folder,
# a registry file, cached read-only HTTP against the local CWA, and uploads
# made impossible (an attempted upload shows up as "couldn't open local file
# to upload" -- i.e. WOULD UPLOAD). Nothing touches the Kindle, the registry
# on it, or CWA's data.
#
# Scenarios (all generated from the live calibre metadata.db):
#   positive  every book x {Title - Author, Author - Title, Last, First - Title,
#             Title (Author) (Z-Library), bare Title, "(Book N)" parenthesized,
#             CWA-style "(Series Book N)" tag, "Book IV of the <Series> Saga"}
#             -> must register to its own uuid: 0 wrong, 0 unmatched, 0 upload
#   negative  books NOT in CWA that share words/series with ones that are
#             -> must NEVER register; upload or "check manually" are both fine
#   device    (optional) a real file list + registry pulled from a Kindle
#             -> every tracked file resolves to its uuid, 0 uploads
#
# Usage:
#   bash tests/sync-dry-run/run.sh                 # positive + negative
#   bash tests/sync-dry-run/run.sh files.txt registry.json expected.tsv   # + device
# Needs: docker, the homeserver-configs sops key (for CWA creds), CWA on :8083,
# and the calibre library at "/mnt/media/Calibre Library/metadata.db".
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT; mkdir -p "$W/cache"
bash "$HERE/build-harness.sh" "$REPO/bookbridge.koplugin/main.lua" "$W/dryrun.lua"
python3 "$HERE/scenarios.py" "$W"
cd /home/matthew/Desktop/homeserver-configs
set -a; eval "$(sops -d --input-type dotenv --output-type dotenv scripts/shelfmark-kindle-sync/.env.sops)"; set +a
# Which CWA answers the searches. Override to point the same suite at a
# candidate server -- e.g. a Calibre-Web-NextGen container on a spare port,
# against a COPY of the library -- and compare the scenario table:
#   CWA_TEST_URL=http://localhost:8099 bash tests/sync-dry-run/run.sh
# Still read-only: uploads are stubbed to error whatever this points at.
CWA_TEST_URL=${CWA_TEST_URL:-http://localhost:8083}
dryrun() { # tag files dir registry
  for i in $(seq 1 40); do
    rm -f "$W/cache/MISSING"
    docker run --rm -v "$W":/w -e FILES=/w/$2 -e DOWNLOAD_DIR="$3" -e REG_IN=/w/$4 -e REG_OUT=/w/$1.registry.json -e CACHE=/w/cache \
      openresty/openresty:alpine /usr/local/openresty/luajit/bin/luajit /w/dryrun.lua > "$W/$1.report.txt" 2> "$W/$1.err.txt" \
      || { echo "LUA ERROR in $1:"; cat "$W/$1.err.txt"; return 1; }
    [ -s "$W/cache/MISSING" ] || return 0
    sort -u "$W/cache/MISSING" | while IFS= read -r p; do
      key=$(python3 -c "import sys,re;print(re.sub(r'[^A-Za-z0-9]',lambda m:'_%02x'%ord(m.group()),sys.argv[1]))" "$p")
      code=$(curl -s -o "$W/cache/.body" -w '%{http_code}' -u "$CWA_USERNAME:$CWA_PASSWORD" "$CWA_TEST_URL$p")
      { echo "$code"; cat "$W/cache/.body"; } > "$W/cache/$key"
    done
  done
  echo "did not converge"; return 1
}
echo '{}' > "$W/empty.json"; FAIL=0
for f in "$W"/scenario_*.files; do
  tag=$(basename "$f" .files | sed 's/^scenario_//'); dir=$(dirname "$(head -1 "$f")")
  dryrun "$tag" "$(basename "$f")" "$dir" empty.json || FAIL=1
  python3 "$HERE/evaluate.py" "$W" "$tag" "$W/scenario_$tag.expected" || FAIL=1
  # CWA request count for the final (warm-cache) pass -- the harness counts
  # every doCwaRequest, so this is the number to watch when changing anything
  # that batches, caches or skips requests. Reported, never asserted: it moves
  # legitimately whenever the library or the scenarios change.
  printf '       %s %s\n' "tag=$tag" "$(grep -o 'requests=[0-9]*' "$W/$tag.err.txt" || echo requests=?)"
done
if [ $# -ge 3 ]; then
  cp "$1" "$W/device.files"; cp "$2" "$W/device.json"
  dryrun device device.files "$(dirname "$(head -1 "$1")")" device.json || FAIL=1
  python3 "$HERE/evaluate.py" "$W" device "$3" || FAIL=1
fi
[ $FAIL -eq 0 ] && echo "ALL SCENARIOS CLEAN" || { echo "FAILURES ABOVE"; exit 1; }
