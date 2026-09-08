# Changelog

Plain-language notes on what changed and why. Build ids refer to the
`build` field in `shelfmark.koplugin/manifest.json`, which is what
**Shelfmark → Check for updates** compares against.

## 2026-09-08 — build 26fa851

- **Bluetooth keyboard: "Pair the phone" on an already-paired phone now just
  starts listening** (about 20 s) instead of timing out. Open the keyboard
  app on the phone and choose Kindle.

## 2026-09-08 — build 8b1bfd8

### Bluetooth keyboard, now part of Bookbridge (Kindle)

- **Bookbridge → Bluetooth keyboard** replaces the separate plugin. One tap
  pairs the phone: the first time it installs the keyboard rule (asks
  first) and asks for the phone's Bluetooth address once; then the Kindle
  starts the pairing, you tap Pair on the phone, and it's done the moment
  the phone confirms — already listening for the keyboard app.
- **Ready for keyboard now** after a sleep, or **Keep Bluetooth ready when
  the Kindle wakes** to make reconnecting just "choose Kindle in the app".
- Status, Bluetooth off, Forget the paired phone, Install/Uninstall rule.

## 2026-09-08 — build 314d83e

### The plugin is now called Bookbridge

- Shelfmark is one of the services it connects to, not the plugin, so the
  plugin is **Bookbridge** (`bookbridge.koplugin`) and the menu entry says
  Bookbridge. "Shelfmark" remains the name of the request feature and its
  server settings.
- **Nothing to redo on your devices.** Check for updates as usual; the new
  build moves itself into its own folder and asks to restart once. All your
  settings, Hardcover matches, CWA registry and logs stay exactly as they
  are (their files keep their old names on purpose).
- README carries a plain "written 100% by an AI" disclaimer at the top.

## 2026-09-08 — build 6f36f79

- **"Restart now" after an update.** When Check for updates installs a new
  build, the confirmation now offers to restart KOReader on the spot (a
  clean restart — settings and reading position are saved first), instead
  of leaving you to find the restart yourself.

## 2026-09-08 — build f808bd4

### Matching: identifiers first, Open Library as a second opinion

- **Books with an ISBN, ASIN or Hardcover id in their metadata match
  exactly** — one query, no guessing — and progress is recorded against
  that very edition's page count. About two thirds of a typical sideloaded
  library carries one.
- **When the title search isn't sure, Open Library is asked** for the work
  by title and author and its ISBNs settle the match on Hardcover. Ambiguous
  classics, translations and omnibus editions that used to land in the
  review list now resolve on their own.
- Nothing changes for books that already matched confidently.

## 2026-09-08 — build a86ccdb

- **Fixed: a book closed while offline landed in "Review Hardcover matches"
  with nothing to choose from.** A failed lookup (no network) was being
  treated like "Hardcover found nothing". Now an unreachable Hardcover
  leaves the book queued and it is looked up again when you're back online,
  and opening a review entry that has no candidates asks Hardcover again
  first — so any such entry you already have fixes itself when opened.

## 2026-09-07 — build e70c72e

- **The library sync now writes its report to the debug log** (each line as
  `[sync] …`) followed by one summary line with counts: found, tracked,
  matched, uploaded, importing, unmatched, ambiguous, re-downloaded, failed.
  Same for "Send to CWA". Nothing on screen changes; it makes "what did the
  sync do on that device" answerable from a sent log.
- README gained Credits and Authorship sections.

## 2026-09-07 — build 969f16f

### New: reading progress syncs to Hardcover

- **Close a book, and Hardcover knows where you are.** Turn on
  **Hardcover → Sync reading progress to Hardcover** (with your API token
  in Hardcover settings). When you close a book the plugin records the
  percentage the footer shows, matches the book to Hardcover, and sends
  the position as *page X of Y* for that edition, marking it *Currently
  Reading* if it wasn't. A short notice after the close says what it did.
- **Matches are silent when they're sure, and ask when they're not.**
  Author surname, title, edition language (English by default — change it
  in Hardcover settings), omnibus-vs-single-book and popularity all count.
  The books it wasn't sure about wait under **Review Hardcover matches**
  with their progress kept; pick the right one and it syncs. "None of
  these" means never sync that file. **Forget Hardcover book choices**
  starts over.
- **Offline is fine.** Positions queue up and go out when the network is
  back or the device next wakes. Nothing polls in the background, and a
  position Hardcover already has is not sent twice.
- **The percentage is the one you see.** It's the footer's figure, which
  leaves out front and back matter some EPUBs mark as non-linear; the raw
  page ratio could read higher.

### Fixed: the notice only appeared after opening the menu

- The Bookshelf home screen "parks" a book you close from it instead of
  closing it, and only really closes it after half a minute of no input
  or when you open the menu — so the plugin wasn't told about the close
  until then. The park now counts as the close. On the Kindle the notice
  appears within a couple of seconds of closing; on Android it's the
  system toast, which the phone draws immediately.

### Also

- Book metadata is read the way devices actually write it: several
  credited people, "unknown author" lines, series tags in brackets after
  the title, curly quotes.
- **Send debug log to server** in the Settings menu uploads the log to the pairing
  relay, for the times a device can't be plugged in.

## 2026-09-06 — build 501b324

### Better battery life on the Kindle

- **No more popup every time you wake the device.** If you had a book
  request outstanding, Shelfmark used to flash a "Talking to Shelfmark…"
  message on every single wake. On e-ink that means a full screen
  refresh, which is one of the more power-hungry things the device does.
  It now checks quietly and only interrupts you when a book is actually
  ready to read.
- **Gives up faster when the server can't be reached.** If you wake the
  Kindle with Wi-Fi still off, or before Tailscale has reconnected, that
  same check used to sit there waiting up to 45 seconds for an answer
  that was never coming — keeping the processor awake the whole time. It
  now gives up after 12. Nothing is lost by waiting less: it simply
  tries again next time you wake the device.
- **The debug log can no longer grow forever.** It was append-only with
  no size limit and was only ever emptied by hand, so it quietly ate
  storage over time. It now caps at 256 KB and keeps one older copy, so
  recent history is always there without the file running away.
  "Clear log" empties both.

### Library sync is quicker

- **Fewer repeated questions to the server.** Sync was asking the server
  the same things more than once — re-requesting book details it had
  already fetched, and re-running identical searches for different
  files. This is especially wasteful with series, where every volume
  ends up searching for the same series name.
- On a first-time sync of a library with a lot of series, this is
  roughly **30% fewer requests**. Ordinary syncs of an
  already-established library were already fast and are unchanged.
- **Which books get matched is exactly the same.** This was only about
  asking fewer times, never about changing what counts as a match — the
  full matching test suite produces identical results before and after.

### Sync now shows progress

- **"Sync library with CWA"** and the per-book **"Send to CWA"** now
  show a progress bar instead of one static message that sat there for
  the whole run with no sign of how far along it was.

### Buttons that used to freeze the screen

Six places would lock up the interface until whatever they'd started
finished talking to the network — no progress, no way to cancel, just an
unresponsive screen:

- Starting a library sync
- **"Yes"** when accepting a suggested book match
- **Both** buttons on the "Anna's Archive seems to be down" prompt
- Hardcover **"Mark as \<status\>"**
- Hardcover **"Follow this author"**

All six now run properly in the background, so the screen stays alive.
This is also why the new sync progress bar didn't appear at first — the
sync was blocking the very thing that would have drawn it.

### Note

Everything above was tested as far as it can be off-device: the matching,
update and sync test suites all pass, and the log rotation and progress
maths were exercised directly under the same Lua runtime KOReader uses.
The screen-freeze fixes are the exception — a freeze that no longer
happens looks like nothing at all, so those are best confirmed by using
the buttons listed above.
