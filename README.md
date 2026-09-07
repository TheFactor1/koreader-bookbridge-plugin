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
2. It looks the book up on Hardcover once — one round trip — and scores the
   candidates: author surname, normalised title, not an omnibus unless the
   file says so, an edition in your preferred language, popularity as the
   tie-break. A confident match syncs silently. Anything less is parked
   under **Review Hardcover matches**, where you pick the right book (or
   "None of these" to never sync it); its progress is kept and pushed once
   picked.
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
