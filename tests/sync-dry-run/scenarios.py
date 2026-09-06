"""Generate dry-run scenarios from the live calibre library. See run.sh."""
import re, sqlite3, sys
W = sys.argv[1]
c = sqlite3.connect("file:/mnt/media/Calibre Library/metadata.db?mode=ro", uri=True)
rows = c.execute("""select b.uuid, b.title,
 (select group_concat(a.name,' & ') from books_authors_link l join authors a on a.id=l.author where l.book=b.id),
 (select s.name from books_series_link sl join series s on s.id=sl.series where sl.book=b.id), b.series_index from books b""").fetchall()
fs = lambda s: re.sub(r'[/:?*"<>|]', '_', s)          # what sources do to filename-illegal chars
roman = {1:'I',2:'II',3:'III',4:'IV',5:'V',6:'VI',7:'VII',8:'VIII',9:'IX'}
shapes = {}
def add(shape, name, uuid): shapes.setdefault(shape, []).append((f"/mnt/us/{shape}/{name}.epub", uuid))
for u, t, a, ser, idx in rows:
    a1 = re.split(r' & |\|', a or '')[0].strip(); parts = a1.split(' ')
    lastfirst = f"{parts[-1]}, {' '.join(parts[:-1])}" if len(parts) > 1 else a1
    add("title_author", f"{fs(t)} - {a1}", u)
    add("author_title", f"{a1} - {fs(t)}", u)
    add("lastfirst_title", f"{lastfirst} - {fs(t)}", u)
    add("title_paren_author_zlib", f"{fs(t)} ({a1}) (Z-Library)", u)
    add("bare_title", fs(t), u)
    if re.search(r'\bBook \d+\b', t):
        add("paren_book_n", f"{fs(re.sub(r'\b(Book \d+)\b', r'(\1)', t))} - {a1}", u)
    if ser and idx:
        base = re.sub(r'\s*\([^)]*\)\s*$', '', t); n = int(idx)
        add("series_tag", f"{fs(base)} ({ser} Book {n}) - {a1}", u)
        add("book_roman_of_saga", f"{a1} - {fs(base)}_ Book {roman.get(n, n)} of the {re.sub(r' Series$', '', ser)} Saga", u)
for shape, lst in shapes.items():
    seen = {}
    for p, u in lst: seen.setdefault(p, u)
    open(f"{W}/scenario_{shape}.files", "w").write("\n".join(seen) + "\n")
    open(f"{W}/scenario_{shape}.expected", "w").write("".join(f"{p}\t{u}\n" for p, u in seen.items()))
# Negative controls: real books NOT in this library that share words or a series with ones that are.
# Expected: never registered. Add to this list whenever a wrong match is found in the wild.
neg = ["Pierce Brown - Light Bringer_ Book VI of the Red Rising Saga", "Light Bringer - Pierce Brown",
       "Iron Flame (The Empyrean, 2) - Rebecca Yarros", "Onyx Storm - Rebecca Yarros",
       "The Gate of the Feral Gods_ Dungeon Crawler Carl Book 4 - Matt Dinniman", "Children of Dune - Frank Herbert",
       "The Dark Tower II_ The Drawing of the Three - Stephen King", "The Dark Tower - Stephen King",
       "Wayward Pines - Blake Crouch", "Red Rising Saga - Pierce Brown", "Dungeon Crawler Carl Book 2 - Matt Dinniman",
       "Dark Matter - Michelle Paver", "The Stranger - Harlan Coben", "Run - Ann Patchett",
       "Foundation and Empire - Isaac Asimov", "The Institute of Ideas - Anonymous", "Dune_ The Graphic Novel - Frank Herbert",
       "Hail Mary - Andy Weir", "The Way of Kings Part Two - Brandon Sanderson"]
open(f"{W}/scenario_negative.files", "w").write("\n".join(f"/mnt/us/negative/{n}.epub" for n in neg) + "\n")
open(f"{W}/scenario_negative.expected", "w").write("")
print(f"scenarios: {', '.join(f'{k}={len(v)}' for k, v in shapes.items())}, negative={len(neg)}")
