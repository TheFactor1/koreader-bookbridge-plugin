#!/usr/bin/env python3
"""Refuses to pass if shelfmark.koplugin/manifest.json disagrees with the
served files on disk.

The update server serves the git working tree, and the plugin verifies each
downloaded file against the manifest's checksum before installing. A stale
manifest therefore doesn't corrupt anything -- the plugin refuses the file --
but it makes updates stop working silently, which looks exactly like a bug.
tools/make-manifest.sh must be re-run after any change to a served file;
this check is what makes forgetting it a test failure instead of a support
question.

    python3 tests/check-manifest.py         # exit 0 = manifest matches disk
"""
import hashlib
import json
import sys
from pathlib import Path

DIR = Path(__file__).resolve().parent.parent / "shelfmark.koplugin"


def main() -> int:
    manifest = json.loads((DIR / "manifest.json").read_text())
    bad = 0
    for name, meta in manifest["files"].items():
        data = (DIR / name).read_bytes()
        actual = hashlib.sha256(data).hexdigest()
        if actual != meta["sha256"] or len(data) != meta["size"]:
            bad += 1
            print(f"FAIL  {name}: manifest is stale -- run tools/make-manifest.sh")
            print(f"        manifest sha256 {meta['sha256'][:12]}… size {meta['size']}")
            print(f"        on disk  sha256 {actual[:12]}… size {len(data)}")
    if not bad:
        print(f"PASS  manifest build {manifest.get('build', '?')} matches {len(manifest['files'])} served file(s) on disk")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
