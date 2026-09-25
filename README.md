# bookbridge.koplugin

> **Written 100% by an AI.** Every line of code, every test and this document
> were written by Claude (Anthropic). I directed the work, ran every build on
> my own Kindle, Android phone and desktop KOReader, reported what I saw and
> decided what to build. No line here was hand-written by a person -- read it
> before you trust it, and treat it as you would any unaudited code.

*Formerly `shelfmark.koplugin`. Shelfmark is one of the services it connects
to, not the plugin; the name changed in September 2026. Settings and log files
keep their `shelfmark*` names, and an existing install moves itself into the
new folder on its first start after updating.*

A KOReader plugin that ties the device to a self-hosted reading stack:
[Shelfmark](https://github.com/calibrain/shelfmark) for requesting books,
Calibre-Web-Automated (CWA) for the library, and [Hardcover](https://hardcover.app)
for tracking what you read. Runs on Kindle, Android and desktop KOReader.

## Set it up, step by step

**What you need**

- A computer that stays switched on -- Linux or Mac (on Windows, use
  [WSL](https://learn.microsoft.com/windows/wsl/install)). This becomes your
  "server".
- A Kindle, Kobo or Android device with [KOReader](https://github.com/koreader/koreader)
  installed.
- About 15 minutes.

### Step 1 -- Install Docker on the computer

Docker runs the server programs for you. Install it from
[docs.docker.com/get-docker](https://docs.docker.com/get-docker/) and open it
once so it's running.

### Step 2 -- Install Tailscale (recommended)

Tailscale lets your reader reach the computer from anywhere, privately.
Skip this step if you'll only ever use it at home on the same Wi-Fi.

- On the computer: install it from [tailscale.com/download](https://tailscale.com/download)
  and sign in.
- On a Kindle or Kobo: install the *Tailscale VPN* KOReader plugin and sign
  in to the same Tailscale account. Bookbridge finds it by itself later.

### Step 3 -- Download the server files

Open a terminal on the computer and run:

```bash
git clone https://github.com/TheFactor1/shelfmark-stack
cd shelfmark-stack
```

(No `git`? On the [shelfmark-stack page](https://github.com/TheFactor1/shelfmark-stack)
click **Code > Download ZIP**, unzip it, and open a terminal in that folder.)

### Step 4 -- Start the setup wizard

In the same terminal:

```bash
docker compose -f docker-compose.setup.yml up -d
```

Then open **http://localhost:8090** in a web browser on that computer.

### Step 5 -- Follow the wizard

The wizard has five parts, top to bottom:

1. **This machine's address** -- the address your reader will use to reach
   the computer. With Tailscale it starts with `100.` (the Tailscale app shows
   it). Without Tailscale it's the computer's home-network address, like
   `192.168.1.20`.
2. **What to run** -- Shelfmark (search & request books) is always on. Tick
   **Library sync** too if you want your books to land in a library the
   reader can download from (recommended). Anna's Archive and AI suggestions
   are optional extras.
3. **Configure & start** -- press the button and wait. The first time takes
   a few minutes while the programs download.
4. **Check the services** -- every line should say it answered. If one
   doesn't, wait a minute and press **Re-check**.
5. **Pair your Kindle** -- a **6-character code** appears. Leave this page
   open. The code works for 10 minutes; press **New code** if it runs out.

### Step 6 -- Make your Shelfmark account

Open **http://localhost:8084** and follow Shelfmark's first-time setup. Choose
a username and password -- you'll type them on your reader in Step 9.

### Step 7 -- Put Bookbridge on your reader

1. Download **bookbridge.koplugin.zip** from the
   [latest release](https://github.com/TheFactor1/koreader-bookbridge-plugin/releases/latest).
2. Unzip it. You get a folder called `bookbridge.koplugin`.
3. Plug the reader into the computer by USB and copy that folder into
   KOReader's `plugins` folder:
   - Kindle: `koreader/plugins`
   - Kobo: `.adds/koreader/plugins`
4. Eject the reader, then restart KOReader (menu > **Exit** > **Restart KOReader**).

### Step 8 -- Connect the reader to your server

Bookbridge opens **Status & setup** by itself the first time.

1. Tap **Start here: import settings from your server**.
2. Type the address from Step 5 (just the address, e.g. `100.64.0.10`) and
   the 6-character code, then tap **Import**.
3. The list checks everything and shows what works.

### Step 9 -- Sign in to Shelfmark

On the same list, the **Shelfmark** line says **Needs login**. Tap it, enter
the username and password from Step 6, and tap **Apply**. It should say
**Signed in to Shelfmark**.

**That's it.** Open the **Bookbridge** menu and choose **Search & request a
book**. When you're finished setting up you can close the wizard -- your
servers keep running:

```bash
docker compose -f docker-compose.setup.yml down
```

### Extras (all optional)

- **Hardcover** (track what you read): make a token at
  [hardcover.app/account/api](https://hardcover.app/account/api), then
  **Bookbridge > Hardcover > Hardcover settings** and paste it.
- **Readest** (keep your place in sync with a phone or tablet): install the
  Readest KOReader plugin from its [releases](https://github.com/readest/readest/releases),
  sign in under **Tools > Readest** and turn on its auto sync.
- **Anna's Archive** (if you ticked it in Step 5): enter your Anna's Archive
  account key under **Settings > Connections > Anna's Archive settings**.
- **Library login**: if you ticked Library sync, its first login is `admin`
  / `admin123`. Change it at **http://localhost:8083**, then enter the new
  one on the reader under **Settings > Connections > Calibre-Web settings**.

### If a line on Status & setup says...

| It says | What to do |
|---|---|
| **Can't reach** | Make sure the computer is on and Docker is running, and that the reader is on the same Wi-Fi -- or that Tailscale is on for both. |
| **Wrong login** | Tap the line and re-type the username and password. |
| **Locked -- try later** | Too many wrong passwords. Wait 30 minutes, then try again. |
| **Needs login** | Tap it and sign in (Step 9). |
| **Not installed** / **Not set up** | Optional -- only needed for that extra feature. |

Import said the code didn't work? Codes are single-use and last 10 minutes --
press **New code** in the wizard (Step 5, part 5) and try again.

## What you need to host

Bookbridge is only the part on the reader. Everything it does talks to a
server you run yourself, or to an account you already have. **You need a
computer that runs Docker and stays on** -- the plugin can't replace that.
Only Shelfmark is required; each other piece switches on one feature.

| Piece | Needed? | What Bookbridge gains | Where it comes from | What you enter in Bookbridge |
|---|---|---|---|---|
| [Shelfmark](https://github.com/calibrain/shelfmark) | **Required** | Search & request books from the reader | Its own Docker image; see its README. Default port 8084 | Settings > Connections > Shelfmark: address, username, password |
| A Calibre-Web server -- [Calibre-Web-Automated](https://github.com/crocodilestick/Calibre-Web-Automated) or [Calibre-Web-NextGen](https://github.com/new-usemame/Calibre-Web-NextGen) | Optional | Library sync, downloads of delivered books | Its own Docker image. Default port 8083. Give it the **same ingest folder** Shelfmark downloads into, so requested books land in the library | Settings > Connections > Calibre-Web: address, username, password |
| [annas-archive-api](https://github.com/bitesized/annas-archive-api) | Optional | Anna's Archive as a search and download source | Its own Docker image (by bitesized). Default port 3000 | Settings > Connections > Anna's Archive: address and your Anna's Archive account key |
| An update source | Optional | Automatic updates of the plugin | Any plain web server that serves this repo's `bookbridge.koplugin/` folder (with its `manifest.json`) -- e.g. nginx pointed at a checkout | Settings > Update source |
| [Tailscale](https://tailscale.com) | Recommended | Reaching the server away from home, privately | Tailscale on the server; on a Kindle/Kobo, the Tailscale VPN KOReader plugin by Jadehawk | Nothing -- its proxy (127.0.0.1:1055) is filled in automatically |

Accounts, not servers:

- **[Hardcover](https://hardcover.app)** -- reading progress, lists, followed
  authors. Paste an API token from hardcover.app/account/api into Hardcover
  settings.
- **[Readest](https://readest.com)** -- keeps your place in sync with the
  Readest app on a phone or tablet. Install the Readest KOReader plugin
  (from [readest/readest](https://github.com/readest/readest) releases), sign
  in under Tools > Readest and turn its auto sync on. See *Readest* below.

**Easiest:** [shelfmark-stack](https://github.com/TheFactor1/shelfmark-stack)
runs all of the servers above from one compose file, with a browser setup
wizard that hands the reader its settings by a 6-character code (*Import from
server*). It also includes the pairing relay (behind *Set up another device*
and *Send debug log to server*) and the optional AI relay (*Match
suggestions*). See **Set it up, step by step** above.

Once it's set up, **Bookbridge > Status & setup** shows each piece, whether it
works (it really logs in -- and tests the Anna's Archive key without spending
a download), and what to tap to fix it.

## What it does

Adds a **Bookbridge** entry to KOReader's main menu.

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

### Status & setup
- The first item in the menu, and what a new device opens on its own the
  first time: one line per piece above with its state (Signed in, Wrong
  login, Can't reach, Key works, Syncing...) and the fix on tap. Saving any
  connection's settings tests that login straight away.

### Settings
- **Connections** — Shelfmark server, CWA, Anna's Archive, AI match
  suggestions, and **Advanced** (the SOCKS5 proxy and pairing relay, which
  most people never need to touch).
- **Phone clipboard** — the reader listens on port 8090; sending
  `GET /clip?text=...` from a phone puts the text into the field you're
  typing in, or the clipboard.
- **Set up another device** — shows a QR code the other device scans to
  copy this one's settings (through the small pairing relay in
  `homeserver-configs/shelfmark-pairing-relay`).
- **Check for updates** — installs new builds from your own update server
  (`Update source`); the build id is in `manifest.json`.
- **Install updates automatically** (on by default once an update source is
  set) — the plugin looks at the update server quietly when the device wakes,
  gets its network back, or starts (at most once every six hours), installs a
  changed build without asking, and only asks about the restart. Nothing is
  ever checked unasked against GitHub releases.
- **View debug log** / **Send debug log to server** / **Clear log** — the plugin's own log; sending it uploads to the pairing relay for support.

## Reading progress sync (Hardcover)

Turn on **Bookbridge → Hardcover → Sync reading progress to Hardcover** with a token set.
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
4. It happens silently: on an e-ink screen every notice is a flash. Long-press
   a book > **Hardcover sync status** to see where it stands. You're only
   told when something needs you -- a failure, or a match waiting for review.

Offline? The position is queued and pushed when the network comes back or
the device next wakes. Nothing runs on a timer. **Forget Hardcover book
choices** clears every match so books are decided again.

## Readest (phone & tablet sync)

Bookbridge works alongside the separate Readest KOReader plugin, which does the
syncing itself; Bookbridge fills three gaps it leaves:

- **A book you're reading goes into your Readest library.** After a few pages
  in one sitting the reader's own file is uploaded (quietly), so the phone or
  tablet opens the same bytes and progress lines up. Books already there are
  left alone.
- **Your place is saved when the device sleeps.** Readest itself only saves
  a few seconds after a page turn and on close.
- **Waking the device picks up where the phone left off**, once Wi-Fi is back.

Readest matches books by the file's exact bytes, so on the phone or tablet
open books from the Readest library, not from the Calibre-Web catalog. It only
ever moves your place forward. If the Readest plugin isn't installed or
signed in, none of this runs.

## Scope / limitations

- Built for reaching the servers directly over home WiFi or Tailscale —
  there is no handling for an interactive-login gateway (e.g. Cloudflare
  Access) in front of them.
- Shelfmark: session auth only (username/password → cookie). No OIDC/SSO.
- Hardcover progress sync matches by metadata, so a file with poor or
  wrong embedded title/author ends up in the review list rather than synced
  to the wrong book.

## Install

See **Set it up, step by step** above. Bookbridge then keeps itself up to date
from this repository's published releases (never unreleased work). To use your
own update server instead, set **Settings > Update source**.

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
- [Calibre-Web-NextGen](https://github.com/new-usemame/Calibre-Web-NextGen)
  by new-usemame — the Calibre-Web fork the author's library runs on; its
  OPDS and KOReader-sync endpoints are what Bookbridge is tested against.
- [annas-archive-api](https://github.com/bitesized/annas-archive-api) by
  bitesized — the search and download service behind the Anna's Archive
  features.
- [Readest](https://github.com/readest/readest) by chrox and contributors —
  its KOReader plugin does the phone/tablet sync; Bookbridge calls its own
  upload and sync code rather than re-implementing it.
- The Tailscale VPN KOReader plugin by Jadehawk — its local SOCKS5 proxy is
  how a Kindle reaches the server over Tailscale.

## Authorship

**All of the code, tests and documentation in this repository were written by
an AI** (Claude, by Anthropic). Matt directed the work, tested every build on
his own Kindle, Android phone and desktop KOReader, reported what he saw, and
decided what to build and what to drop. No line here was hand-written by a
person; treat it accordingly and read before you trust.
