# shelfmark.koplugin

A KOReader plugin that ties the device to a self-hosted reading stack:
[Shelfmark](https://github.com/calibrain/shelfmark) for requesting books,
Calibre-Web-Automated (CWA) for the library, and [Hardcover](https://hardcover.app)
for tracking what you read. Runs on Kindle, Android and desktop KOReader.

## What it does

Adds a **Shelfmark** entry to KOReader's main menu.

### Requesting books
- **Search & request a book** — searches Shelfmark's metadata providers and
  submits a request from the device. **Most popular** browses what others
  are requesting; **My requests** lists yours. The book itself still arrives
  the normal way (OPDS) once CWA has imported it.

### Library sync with CWA
- **Sync library with CWA** — uploads sideloaded books to CWA, matches them
  back once imported, and offers CWA's copies of unmatched books for
  download. A file this device has already pushed is never pushed twice.
- **Send to CWA** from a book's long-press menu.

### Hardcover
- **Sync reading progress to Hardcover** *(new)* — see below.
- **Log a book** as *Currently Reading* or *Read* from its long-press menu.
- **Follow an author…** / **Followed authors…** — keep a list of authors
  and check Hardcover for their books.
- **Browse a Hardcover list…** — pick from a list and request from it.
- **Review Hardcover matches** — the books progress sync wasn't sure about.
- **Hardcover settings** — API token (from hardcover.app/account/api) and
  the edition language to prefer (default English).

### Settings
- **Connections** — Shelfmark server, CWA, Anna's Archive, AI match
  suggestions, and a connection-status screen that says what is reachable.
- **Set up another device** — shows a QR code the other device scans to
  copy this one's settings (through the small pairing relay in
  `homeserver-configs/shelfmark-pairing-relay`).
- **Check for updates** — installs new builds from your own update server
  (`Update source`); the build id is in `manifest.json`.
- **View debug log** / **Send debug log to server** / **Clear log** — the plugin's own log; sending it uploads to the pairing relay for support.

## Reading progress sync (Hardcover)

Turn on **Hardcover → Sync reading progress to Hardcover** with a token set.
From then on, closing a book does the work — including "closing" it from
the Bookshelf home screen, which parks the reader rather than closing it.

1. The plugin records the percentage the footer shows (the same value the
   home screen shows; it excludes front/back matter marked non-linear).
2. It identifies the book, cheapest and most certain first:
   - **the file's own identifiers** (ISBN-13/10, ASIN, or a `hardcover-id`
     written by Calibre's Hardcover plugin) — one exact query, no guessing,
     and the edition it names is your file's, so its page count is used;
   - otherwise **a title search on Hardcover**, one round trip, scored on
     author surname, normalised title, not an omnibus unless the file says
     so, an edition in your preferred language, popularity as tie-break;
   - if that isn't sure, **Open Library** is asked for the work by title and
     author and its ISBNs are put to Hardcover, which turns most ambiguous
     classics and translations into an exact hit.
   A confident match syncs silently. Anything less is parked under
   **Review Hardcover matches**, where you pick the right book (or "None of
   these" to never sync it); its progress is kept and pushed once picked.
   Opening a review entry that has no candidates asks Hardcover again first.
3. The position goes to Hardcover as *page X of Y* for the matched edition,
   and the book is marked *Currently Reading* if it wasn't. A position
   Hardcover already has is not sent again.
4. A brief notice after the close says what happened — e.g.
   `Hardcover: synced as "Project Hail Mary" by Andy Weir -- page 19 of 482 (4%)`.
   On Android it is the system toast.

Offline? The position is queued and pushed when the network comes back or
the device next wakes. Nothing runs on a timer. **Forget Hardcover book
choices** clears every match so books are decided again.

## Scope / limitations

- Built for reaching the servers directly over home WiFi or Tailscale —
  there is no handling for an interactive-login gateway (e.g. Cloudflare
  Access) in front of them.
- Shelfmark: session auth only (username/password → cookie). No OIDC/SSO.
- Hardcover progress sync matches by metadata, so a file with poor or
  wrong embedded title/author ends up in the review list rather than synced
  to the wrong book.

## Install

Copy `shelfmark.koplugin/` into your KOReader install's `plugins/` directory
and restart KOReader, or point **Settings → Update source** at a server
hosting this repo's `shelfmark.koplugin/` and use **Check for updates** from
then on. Configure the servers under **Shelfmark → Settings → Connections**.

## Development

- `tests/run-all.sh` is the gate before anything ships: matcher fixtures,
  Trapper audits, the Hardcover matching/queue/notice suites, the update
  suite, a live sync against a sandboxed CWA, and `tests/hardcover-park`
  (the real Bookshelf plugin on a desktop KOReader).
- `tools/make-manifest.sh` regenerates `manifest.json`; the gate fails on a
  stale one.
- `CHANGELOG.md` has plain-language notes per build.

## Credits

This plugin stands on other people's work:

- [KOReader](https://github.com/koreader/koreader) — the reader and its plugin
  API. Its own `wallabag.koplugin` and `opds.koplugin` were the reference for
  how a plugin should talk HTTP, and `externalkeyboard.koplugin` and the
  Trapper/UIManager code were read closely for the parts that matter here.
- [Shelfmark](https://github.com/calibrain/shelfmark) by calibrain — the
  request server this plugin exists to talk to.
- [Calibre-Web-Automated](https://github.com/crocodilestick/Calibre-Web-Automated)
  — the library it syncs with (via OPDS and the upload endpoint).
- [Hardcover](https://hardcover.app) and its public GraphQL API — reading
  progress, lists, author follows.
- [bookshelf.koplugin](https://github.com/AndyHazz/bookshelf.koplugin) by
  AndyHazz — the home screen this plugin has to coexist with; its hot-parking
  behaviour shaped how "closing a book" is detected here.
- [Anna's Archive](https://annas-archive.org) — the search the `annas`
  features use.
- [Open Library](https://openlibrary.org) (Internet Archive) — its open
  search API is the second opinion that resolves ambiguous titles to ISBNs.

## Authorship

**All of the code, tests and documentation in this repository were written by
an AI** (Claude, by Anthropic). Matt directed the work, tested every build on
his own Kindle, Android phone and desktop KOReader, reported what he saw, and
decided what to build and what to drop. No line here was hand-written by a
person; treat it accordingly and read before you trust.
