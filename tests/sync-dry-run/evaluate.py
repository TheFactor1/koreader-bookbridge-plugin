"""Score one dry-run scenario. Exit 1 on any wrong uuid, unexpected registration, unmatched expected file, or (positive scenarios) any would-upload."""
import json, os, sys
W, tag, expf = sys.argv[1], sys.argv[2], sys.argv[3]
exp = dict(l.rstrip('\n').split('\t') for l in open(expf) if '\t' in l)
reg = json.load(open(f"{W}/{tag}.registry.json")) if os.path.exists(f"{W}/{tag}.registry.json") else {}
rep = open(f"{W}/{tag}.report.txt").read().splitlines()
regp = {v['path']: u for u, v in reg.items() if isinstance(v, dict)}
wrong = [p for p, u in regp.items() if p in exp and exp[p] != u]
extra = [p for p in regp if p not in exp]
missing = [p for p in exp if p not in regp]
wu = sum("couldn't open local file to upload" in l for l in rep); am = sum('ambiguous' in l for l in rep); cm = sum('check manually' in l for l in rep)
bad = wrong or extra or missing or (exp and wu)
print(f"{'FAIL' if bad else 'ok  '} {tag:26s} registered={len(regp)} wrong-uuid={len(wrong)} not-matched={len(missing)} unexpected-registration={len(extra)} would-upload={wu} ambiguous={am} check-manually={cm}")
for p in wrong[:5]: print("      WRONG UUID:", os.path.basename(p))
for p in extra[:5]: print("      UNEXPECTED REGISTRATION:", os.path.basename(p))
for p in missing[:8]:
    line = [l.strip().split('] ', 1)[1] for l in rep if l.strip().startswith('[' + os.path.basename(p)[:-5] + ']')]
    print("      NOT MATCHED:", os.path.basename(p)[:60], "->", (line or ['?'])[0][:70])
sys.exit(1 if bad else 0)
