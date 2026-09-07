#!/bin/bash
# One command for every stability check in this repo -- the gate a commit has
# to pass. Runs the three test suites and the two source audits, checks the
# manifest against the served files, and compares the sync dry-run's CWA
# request counts against the committed baseline.
#
#   bash tests/run-all.sh                    # exit 0 = everything green
#   bash tests/run-all.sh --update-baseline  # also rewrite baseline.txt
#   bash tests/run-all.sh --no-device        # skip the on-Kindle and live-sync suites, loudly
#
# The update-check suite needs KOReader's own luajit. With a local KOReader
# Linux install present it runs there; otherwise ON THE KINDLE over ssh. If
# neither is available it cannot run at all, and that is reported as SKIPPED,
# not FAIL -- a suite that goes red every time the reader sleeps
# is a suite people learn to ignore. SKIPPED is still not green: the default
# exits non-zero so a partial pass is never mistaken for a pass. --no-device
# makes that skip deliberate for a local-only iteration loop, and says so in
# the final line.
#
# Parses each suite's OUTPUT rather than trusting its exit status:
# update-check/run.sh has been seen to exit 0 with three failures printed
# (its harness loop swallows the status), so "=== 0 failure(s)" is the
# contract here, not $?. The matcher suite is parsed the same way for
# consistency.
#
# Needs what the suites need: docker, sops with the homeserver key, CWA on
# :8083 and the calibre library, for the dry-run. Without those the dry-run
# fails and so does this -- a partial pass is not a pass.
set -uo pipefail
cd "$(dirname "$0")/.."
UPDATE=0; NODEV=0
for a in "$@"; do
  case "$a" in
    --update-baseline) UPDATE=1 ;;
    --no-device)       NODEV=1 ;;
    *) echo "unknown flag: $a" >&2; exit 2 ;;
  esac
done
BASE=tests/sync-dry-run/baseline.txt
DEV=kindle
fail=0; skipped=""

section() { printf '\n== %s\n' "$1"; }

section "matcher regression cases"
out=$(bash tests/run-matcher-tests.sh 2>&1)
if echo "$out" | grep -q "=== 0 failure(s)"; then echo "PASS"
else echo "$out" | grep -E "^FAIL|failure\(s\)|anchor not found"; echo "FAIL"; fail=1; fi

section "manifest matches served files"
python3 tests/check-manifest.py || fail=1

section "Trapper audits"
python3 tests/audit-trapper.py || fail=1

section "Hardcover matching (offline, real captured API responses)"
out=$(bash tests/hardcover-match/run.sh 2>&1); rc=$?
if [ $rc -eq 0 ]; then echo "PASS  $(echo "$out" | grep -c '^PASS') cases, and the search is still ONE round trip"
elif [ $rc -eq 3 ]; then echo "SKIPPED  hardcover-match (no local KOReader)"; skipped="${skipped:+$skipped, }hardcover-match"
else echo "$out" | grep -E '^FAIL'; echo "FAIL"; fail=1; fi

# Prefers a local KOReader Linux install (identical frontend and luajit, no
# device needed), then the Kindle over ssh, then SKIPPED.
section "update-check suite (needs KOReader's luajit: local install or the Kindle)"
KLOCAL=${KOREADER_DIR:-$(ls -d ~/.local/opt/koreader-*/lib/koreader 2>/dev/null | sort -V | tail -1)}
if [ $NODEV -eq 1 ]; then
  echo "SKIPPED  --no-device"; skipped="update-check (by request)"
elif [ -x "${KLOCAL:-/nonexistent}/luajit" ]; then
  out=$(KOREADER_DIR="$KLOCAL" bash tests/update-check/run.sh local 2>&1)
  if echo "$out" | grep -q "=== 0 failure(s)"; then echo "PASS  on local KOReader ($KLOCAL)"
  else echo "$out" | grep -E "^FAIL|failure\(s\)|No update source|No local KOReader"; echo "FAIL"; fail=1; fi
elif ! timeout 8 ssh -o ConnectTimeout=5 -o BatchMode=yes "$DEV" true >/dev/null 2>&1; then
  echo "SKIPPED  no local KOReader and $DEV unreachable over ssh -- wake it, or pass --no-device"; skipped="update-check (device unreachable)"
else
  out=$(bash tests/update-check/run.sh "$DEV" 2>&1)
  if echo "$out" | grep -q "=== 0 failure(s)"; then echo "PASS  on $DEV"
  else echo "$out" | grep -E "^FAIL|failure\(s\)|No update source"; echo "FAIL"; fail=1; fi
fi

section "sync dry-run against the live library"
out=$(bash tests/sync-dry-run/run.sh 2>&1)
if echo "$out" | grep -q "ALL SCENARIOS CLEAN"; then echo "PASS  all scenarios clean"
else echo "$out" | grep -E "^FAIL|LUA ERROR|did not converge|FAILURES" | head -20; echo "FAIL"; fail=1; fi

# Request counts vs baseline. A rise is a WARNING, never a failure: the
# scenarios come from the live library, which grows. It still has to be
# looked at -- see the note at the top of baseline.txt.
counts=$(echo "$out" | grep -oE "tag=[a-z_]+ requests=[0-9]+" | sed 's/tag=//;s/ requests=/ /')
if [ -n "$counts" ]; then
  while read -r tag n; do
    b=$(awk -v t="$tag" '$1==t{print $2}' "$BASE")
    if   [ -z "$b" ];        then printf '  %-26s %4s  (no baseline)\n' "$tag" "$n"
    elif [ "$n" -gt "$b" ];  then printf '  %-26s %4s  WARN up from %s\n' "$tag" "$n" "$b"
    elif [ "$n" -lt "$b" ];  then printf '  %-26s %4s  down from %s\n' "$tag" "$n" "$b"
    else                          printf '  %-26s %4s  = baseline\n' "$tag" "$n"; fi
  done <<< "$counts"
  if [ $UPDATE -eq 1 ]; then
    build=$(python3 -c "import json;print(json.load(open('shelfmark.koplugin/manifest.json'))['build'])")
    { grep '^#' "$BASE" | grep -v '^# Recorded '
      echo "# Recorded $(date +%F) at build $build."
      echo "$counts"; } > "$BASE.tmp" && mv "$BASE.tmp" "$BASE"
    echo "  baseline.txt rewritten"
  fi
fi

# Live sync: the real plugin inside a real KOReader (Linux build) against a
# throwaway CWA -- the only suite that reaches the upload and post-upload
# registration path. Slow (~1 min), needs docker + a local KOReader + the
# stack's compose file, and it restarts the local KOReader. exit 3 = its
# prerequisites are missing, which is SKIPPED here, not FAIL.
section "live sync (real KOReader + sandbox CWA; reaches the upload path)"
if [ $NODEV -eq 1 ]; then
  echo "SKIPPED  --no-device"; skipped="${skipped:+$skipped, }live-sync (by request)"
else
  out=$(bash tests/live-sync/run.sh 2>&1); rc=$?
  if [ $rc -eq 0 ]; then echo "PASS  $(echo "$out" | grep -c '^PASS') assertions"
  elif [ $rc -eq 3 ]; then echo "$out" | grep '^SKIP' | sed 's/^SKIP /SKIPPED  /'; skipped="${skipped:+$skipped, }live-sync (prerequisites missing)"
  else echo "$out" | grep -E '^FAIL|^=== LIVE'; echo "FAIL"; fail=1; fi

  # Duplicate-upload guard: a book whose embedded author disagrees with its
  # filename, synced twice, must leave ONE copy in CWA (the on-device bug).
  out=$(bash tests/live-sync/dup-guard.sh 2>&1); rc=$?
  if [ $rc -eq 0 ]; then echo "PASS  dup-guard: $(echo "$out" | grep -c '^PASS') assertions, no duplicate"
  elif [ $rc -eq 3 ]; then echo "SKIPPED  dup-guard (prerequisites missing)"; skipped="${skipped:+$skipped, }dup-guard"
  else echo "$out" | grep -E '^FAIL|^=== DUP'; echo "FAIL"; fail=1; fi
fi

printf '\n'
if [ $fail -ne 0 ]; then
  echo "CHECKS FAILED"; exit 1
elif [ -n "$skipped" ] && [ $NODEV -eq 0 ]; then
  echo "NOT GREEN: skipped $skipped -- every local check passed, but a partial pass is not a pass"; exit 1
elif [ -n "$skipped" ]; then
  echo "LOCAL CHECKS GREEN (skipped $skipped)"; exit 0
else
  echo "ALL CHECKS GREEN"; exit 0
fi
