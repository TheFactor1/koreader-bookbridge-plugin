#!/usr/bin/env python3
"""Static audits for the Trapper coroutine rule in bookbridge.koplugin/main.lua.

Two checks, both of which caught real bugs during the 2026-09-06 pass:

1. Every callback that reaches a *forking* method must open its own
   Trapper:wrap. A ConfirmBox/menu callback fires from the UI loop, NOT from
   the coroutine that showed it -- that coroutine returned long before the
   user pressed anything -- so a Trapper:dismissableRunInSubprocess reached
   from an unwrapped callback has nothing to yield to and blocks the UI for
   the length of the network round-trip. Six of these were fixed in one pass
   (the sync menu entry, which hid the progress bar entirely, plus five
   ConfirmBox buttons that froze the screen).

2. Every `Trapper:` / `Trapper2:` reference in real code must resolve to a
   local declared earlier in the same top-level function. There is no
   file-level Trapper; an unresolved one is a nil global and a runtime crash
   on a path the test suites never reach. One of these was introduced and
   caught before commit during the same pass.

Both are heuristics over source text, not a Lua parser: the "forking" set is
computed from method bodies, and a callback's body is taken as the next
WINDOW lines. They are deliberately a little over-eager -- a false positive
costs a minute of reading; a miss costs a frozen Kindle.

    python3 tests/audit-trapper.py          # exit 0 = clean
"""
import io
import re
import sys
from pathlib import Path

MAIN = Path(__file__).resolve().parent.parent / "bookbridge.koplugin" / "main.lua"
WINDOW = 18

FORK_MARKERS = re.compile(
    r"dismissableRunInSubprocess|self:apiRequest|self:cwaRequest|self:annasSearch"
    r"|self:annasMirrorRefresh|runSyncWithProgress"
)


def strip_comment(line: str) -> str:
    if line.lstrip().startswith("--"):
        return ""
    return line.split("--", 1)[0]


def forking_methods(lines):
    fork = set()
    for i, line in enumerate(lines):
        m = re.match(r"function Bookbridge:(\w+)\(", line)
        if not m:
            continue
        body = []
        for x in lines[i:]:
            body.append(x)
            if x == "end":
                break
        if FORK_MARKERS.search("\n".join(body)):
            fork.add(m.group(1))
    return fork


def audit_unwrapped_callbacks(lines):
    fork = forking_methods(lines)
    findings = []
    for i, line in enumerate(lines):
        if not re.search(r"\b(ok_|cancel_)?callback = function\(", line):
            continue
        body = "\n".join(lines[i : i + WINDOW])
        hits = [m for m in re.findall(r"self(?:_ref)?:(\w+)", body) if m in fork]
        if hits and "Trapper" not in body:
            findings.append((i + 1, hits[0]))
    return findings, len(fork)


def audit_trapper_scope(lines):
    findings = []
    seen_plain = False
    fn_start = 0
    for i, raw in enumerate(lines):
        code = strip_comment(raw)
        if re.match(r"^(local )?function ", raw):
            seen_plain = False
            fn_start = i + 1
        if re.search(r"\blocal\s+Trapper\b", code):
            seen_plain = True
        m = re.search(r"(?<![\w.])Trapper(\d?):", code)
        if not m or re.search(r"\blocal\s+Trapper", code):
            continue
        name = "Trapper" + m.group(1)
        if name == "Trapper":
            ok = seen_plain
        else:
            ok = any(
                re.search(r"\blocal\s+" + name + r"\b", strip_comment(x))
                for x in lines[fn_start : i + 1]
            )
        if not ok:
            findings.append((i + 1, name))
    return findings


def main() -> int:
    lines = io.open(MAIN, encoding="utf-8").read().split("\n")
    bad = 0

    unwrapped, nfork = audit_unwrapped_callbacks(lines)
    if unwrapped:
        bad += len(unwrapped)
        print(f"FAIL  {len(unwrapped)} callback(s) reach a forking method without Trapper:wrap:")
        for ln, method in unwrapped:
            print(f"        main.lua:{ln}  -> {method}()")
    else:
        print(f"PASS  every callback reaching any of the {nfork} forking methods is Trapper-wrapped")

    unresolved = audit_trapper_scope(lines)
    if unresolved:
        bad += len(unresolved)
        print(f"FAIL  {len(unresolved)} Trapper reference(s) with no in-scope local:")
        for ln, name in unresolved:
            print(f"        main.lua:{ln}  -> {name}")
    else:
        print("PASS  every Trapper reference in real code resolves to an in-scope local")

    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
