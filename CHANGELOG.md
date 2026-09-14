# Changelog

Plain-language notes on what changed and why. Build ids refer to the
`build` field in `shelfmark.koplugin/manifest.json`, which is what
**Shelfmark → Check for updates** compares against.

## 2026-09-14 — build 9fd6795

- **Fixed a regression from the last build.** Parking an unmatched book
  after one search (to stop the battery drain) accidentally also stopped
  it from ever completing a real match automatically, even when Hardcover
  was genuinely sure about it -- every such book would have been stuck
  showing only a guess link forever. Confident matches now complete for
  real again, same as before either fix; only genuinely unconfident books
  get parked and left alone.

## 2026-09-14 — build 3063b3c

- **Fixed a real battery drain.** A finished book with no Hardcover match
  at all could end up retrying a live search on every single book close
  afterward, forever, instead of just once -- each retry meant waking the
  WiFi radio for no reason. Now it's tried once and then left alone
  (parked under Hardcover > Review matches, same as any other ambiguous
  book) until you resolve it yourself.
- Also fixed: a book explicitly marked never-sync could still get the
  automatic review popup. It won't now.

## 2026-09-14 — build 1100c10

- **New: an ISBN is now captured at download time when downloading
  through Anna's Archive**, and used as a fallback for Hardcover matching
  whenever the file's own metadata has none (common after DeDRM/format
  conversion, which routinely strips it). Needs the companion
  annas-archive-api service redeployed to actually take effect.

## 2026-09-13 — build 3e79f6b

- **Fixed: the review popup could fire twice for the same book.** Caught
  live -- a book that got the new "best guess" popup would sometimes show
  it again moments later once it resolved to a real, confirmed match. Now
  it only ever shows once per finish, guess or confirmed.

## 2026-09-13 — build cabcb5b

Five follow-ups in one build:

- **Finishing a book with no confident Hardcover match now shows the
  review popup too**, using the same best-guess search the manual
  "Review on Hardcover" action already had -- it used to show nothing at
  all for these.
- **A best guess is now labeled as one** in the popup, so it's clear when
  the link isn't a confirmed match.
- **"Review on Hardcover" moved up** in the long-press menu, right after
  Currently Reading/Read instead of last.
- **A repeated guess for the same book no longer repeats the search** --
  remembered for the rest of the session.
- **New toggle**: Hardcover settings > "Show a review reminder when a
  book finishes" (on by default) turns off both automatic popups. The
  manual "Review on Hardcover" action still works either way.

## 2026-09-13 — build 0cd0342

- **"Review on Hardcover" now uses the book's own ISBN/ASIN when it's
  known**, for an exact match instead of a fuzzy title/author guess. This
  metadata was already sitting in the book's own file info -- it just
  wasn't being passed along to the search yet.

## 2026-09-13 — build 29d7a78

- **"Review on Hardcover" now finds the right book even when it was never
  matched at all**, instead of just showing a search page. When there's no
  recorded match, it searches Hardcover live and links straight to
  whichever candidate has the most readers/reviews -- the real entry
  reliably has far more than any near-duplicate, so this is usually right.
  This doesn't change which book gets your reading progress or ratings
  synced -- only which page one tap opens.

## 2026-09-13 — build d6e8413

- **Fixed: finishing a book could still show a search page instead of the
  actual book**, for books matched to Hardcover before this plugin started
  remembering their direct link. The previous fix only covered the manual
  "Review on Hardcover" action; now an already-matched book's link gets
  filled in quietly during ordinary reading (on its next normal progress
  sync), so by the time you actually finish it, the direct link is already
  there.

## 2026-09-13 — build abd34c4

- **Fixed: "Review on Hardcover" kept showing a search page instead of
  the actual book, for books already matched to Hardcover.** Those books
  were matched before this plugin started caching a direct link at match
  time, so the lookup always came up empty. It now fetches the link live
  the first time you use it on such a book and remembers it after that.
- **The search fallback now includes the author, not just the title** --
  a title-only search for something like "Dune" was too ambiguous to be
  useful on its own.

## 2026-09-13 — build 84695a7

- **New: "Review on Hardcover" on a book's long-press menu.** Long-press
  any book's cover (FileManager, History, Collections, or a file search
  result) to pull up the same congrats-and-QR/link dialog on demand, any
  time -- not only right when a book finishes. Uses the same direct link
  when the book's already matched to Hardcover, the same search-link
  fallback when it isn't. Only shown when a Hardcover token is configured.

## 2026-09-13 — build ca97ea4

- **The finish dialog is tap-anywhere-to-dismiss on the phone/button
  version too now**, not just the plain Kindle QR version -- tapping the
  buttons still works exactly as before, tapping anywhere else now closes
  it too.
- **Stays up longer**: 15s -> 30s.

## 2026-09-13 — build bf7c156

- **The finish message now includes a random quote**, picked from a small
  bank of public-domain lines (Carroll, Austen, Alcott, Montgomery,
  Henley, Dickens) alongside the congratulations.
- **The direct link now goes straight to Hardcover's review editor**
  (`/books/<slug>/reviews/edit`) instead of the plain book page -- one
  step closer to actually writing something, whether you scan it or tap
  it.

## 2026-09-13 — build a93353e

- **The review QR is smaller and says what it's for.** It now shows a
  "Congratulations, you've finished X! Consider reviewing it on Hardcover"
  message above a QR code about half the previous size.
- **On a phone, it's a real link instead of a code to scan.** Scanning a
  QR shown on the very screen you're holding never made sense -- devices
  that can open a link themselves (Android, chiefly) now get "Open in
  browser" and "Close" buttons instead of a code to point a second camera
  at. Kindles keep the tap-anywhere QR dialog as before.

## 2026-09-13 — build dc36b70

- **The review QR now shows up even if the Kindle has no internet at
  all.** It used to wait on the Hardcover write actually going through
  first, which needs the Kindle's OWN connection -- offline, nothing
  showed at all. Now it shows immediately: a direct link if this book was
  already matched to Hardcover before (the usual case), or a Hardcover
  search link for the title if not -- either way built entirely from what's
  already on the device, no network needed to show it. The actual Read
  status and rating/review still sync in the background and retry until
  they land, same as before.
- **Fixed a real bug this surfaced:** a genuinely offline Kindle (not just
  a slow one) could crash the background sync instead of retrying quietly,
  because of a mis-ordered helper function. Only mattered when a Hardcover
  write actually failed outright.

## 2026-09-13 — build 0e52652

- **Finishing a book now shows a QR code straight to its Hardcover page.**
  Right after a book syncs as Read, a tap-to-dismiss QR code pops up (15s,
  or tap/any key to close sooner) linking to that book's own page on
  hardcover.app -- scan it with your phone to leave a fuller review than
  KOReader's Book Status note field gives room for. If Hardcover can't be
  reached for the extra lookup this needs, it's skipped silently -- the
  Read status and rating/review already went through by that point either
  way.

## 2026-09-13 — build d6aa67b

- **Ratings and reviews now come straight from KOReader's own Book Status
  screen, instead of a dialog Bookbridge showed itself.** Set a star rating
  or write a review there (the same screen used to mark a book Finished)
  and it syncs to Hardcover along with the Read status -- no separate popup.
  This removes the risk that came with building that popup from scratch,
  but it also means nothing prompts for a rating anymore: skip Book Status
  and Hardcover just gets the Read status with no rating, same as any book
  synced without one.

## 2026-09-14 — build a308ef6

- **The finish-a-book prompt is now one compact dialog instead of two.**
  Stars and the review field show together, with one Save/Skip pair --
  tapping a star no longer closes the box, it just updates which stars are
  filled. Should also fix the review step never appearing at all: that was
  very likely caused by two separate dialogs opening and closing back to
  back with no pause in between, which this removes entirely by combining
  them.

## 2026-09-13 — build 9e378af

- **Fixed: the finish/rating prompt kept popping back up on every book
  close, not just the finished one.** A network hiccup mid-write ("HTTP
  wantread" -- a transport-level blip, not anything Hardcover actually
  said) threw away the star rating and review you'd already given and left
  the book stuck asking again, on every subsequent close, regardless of
  what book that close was for. Your answer is now kept: if a write fails,
  it retries quietly in the background using what you already chose,
  without asking a second time.

## 2026-09-13 — build 9838843

- **Fixed: the rating prompt still didn't show up for some finished books.**
  It only worked for a book Bookbridge had already synced with Hardcover
  before. A book reaching Hardcover for the very first time already
  finished -- a short book, or one read start to finish in one sitting --
  fell through to the ordinary sync instead. Confirmed live: two of the
  first three books tested hit exactly this.

## 2026-09-14 — build a6ae41b

- **The Read-marking prompt is now a row of tappable stars, plus an
  optional written review.** Replaces the earlier number picker with real
  stars matching KOReader's own rating look, and adds a second step to
  write a few words about the book if you want to.
- **New, first live verification in progress.** The review field in
  particular is an educated guess at what Hardcover's API expects -- if it
  reports "marked Read, but the review didn't save," that's the part
  needing a follow-up fix, same as the rating mutation from the last build.

## 2026-09-14 — build fc9464a

- **Fixed: the "mark as Read" prompt never showed up.** It was keyed on
  KOReader's own "Book status: Finished" flag, which turns out not to get
  set just by reading to the end and closing a book -- confirmed live on two
  books that both reached 100% and were pushed the ordinary way instead.
  Reaching the end of a book now triggers it too.

## 2026-09-14 — build 5cd4767

- **Marking a book Finished in KOReader can now mark it Read on Hardcover
  too.** Finishing a book (the real "Book status: Finished" action, not just
  reaching 100%) offers to record a star rating and syncs both to Hardcover
  in one step -- previously nothing ever moved a book off "Currently
  Reading," so finished books sat there indefinitely. A re-read is told
  apart from an ordinary resync automatically.
- **New, first live verification in progress.** The rating half of this
  reached the real Hardcover API for the first time after this build shipped
  -- if rating a book reports success but doesn't show up on Hardcover, that
  half needs a follow-up fix; marking Read (no rating chosen) uses the same
  calls this plugin has pushed reading progress with all along.

## 2026-09-13 — build a9ad4d4

- **Hardcover corner notices now wrap and stay out of your way while
  reading.** Longer messages no longer get cut off mid-sentence, and a tap
  anywhere on the screen dismisses the notice while still doing whatever
  that tap was already going to do (turn the page, and so on).

## 2026-09-13 — build 21eacec

- **Hardcover notices in the bottom-left corner now stack instead of
  replacing each other.** If more than one shows up close together, they
  pile upward so all of them stay readable instead of the newest one
  wiping out the last.

## 2026-09-13 — build 13af8cb

- **Hardcover sync notices moved to a small box in the bottom-left corner.**
  Closing a book still tells you the page it recorded, but no longer with a
  box parked mid-screen for 6 seconds — it's a small, low-key notice tucked
  out of the way instead.

## 2026-09-13 — build 1779c14

- **Hardcover now syncs quietly.** Closing a book no longer pops a box
  reporting the page it just recorded — that sync happens in the background
  and the page number is on Hardcover anyway. A notice appears only when
  Hardcover genuinely could not record your progress; a push that failed
  because the device had no network stays silent and retries on its own.
  Books that need you to confirm a match still say so.

## 2026-09-12 — build 539040c

- **Menus now say "Calibre-Web" instead of "CWA."** *Sync library with
  Calibre-Web*, *Send to Calibre-Web*, *Calibre-Web settings*, and so on.
  "CWA" was short for Calibre-Web-Automated specifically; the plugin works
  with any Calibre-Web server, so it now says that. Your settings are
  untouched — only the wording changed.

## 2026-09-12 — build 0bc2e8c

- **Library sync is faster, especially the first one on a new device.** The
  book list Bookbridge already downloads at the start of every sync is now
  used to recognise your books directly, instead of asking CWA to search for
  each one. On a 40-book device that is 111 requests down to 72; the effect is
  largest on a first sync, where nothing is tracked yet. Books it cannot
  recognise that way are searched for exactly as before.
- **Fixed a book that was re-uploaded on every sync.** A file whose name had a
  "?" where the apostrophe should be (some download sources substitute it) —
  for example "The Handmaid?s Tale" — could never be found in CWA by search,
  so it was treated as missing and uploaded again each time. It now matches
  the copy you already have.

## 2026-09-11 — build bf07a69

- **Send to CWA recognises more filename shapes.** A browser's re-download
  suffix ("Title - Author (1)") no longer counts as "volume 1"; titles that
  end in a number ("Fahrenheit 451: A Novel") aren't mistaken for a series
  tag; bracket tags ("[Series 02]", "[Kindle Edition]"), "Title by Author"
  and en/em-dash separators are understood; and a new volume named
  "Series III: Title", "Author - Series 2 - Title" or "Series 02 - Title -
  Author" is uploaded instead of being held back as a possible duplicate
  of book 1. Two of these shapes used to upload a duplicate of a book CWA
  already had.

## 2026-09-10 — build 5d6a711

- **Your reading shelves are back in "Browse a Hardcover list."** Want to
  Read / Currently Reading / Read / Did Not Finish appear first, for the
  device owner's own account, with counts.
- **Fixed a Send-to-CWA parse edge case** that could upload a duplicate of a
  book named with two underscores (e.g. "…Book 2_ Book II of the … Saga").

## 2026-09-10 — build d854622

- **Text shared from your phone now lands straight in the open field.** If a
  text box is open on the Kindle when you share, the text is typed into it
  for you (a "Pasted: …" note confirms). Nothing open? It waits in the
  clipboard as before — long-press → Clipboard → paste.
- **Bluetooth keyboard removed.** The feature and its menu are gone in favour
  of sharing text from the phone.

## 2026-09-10 — build 0b7b9a7

- **Hardcover lists are now the device owner's, not the server's.** "Browse a
  Hardcover list" used to go through the Shelfmark server's own Hardcover
  account, so every Kindle saw the same person's lists. It now reads the
  lists (followed and own) with the device's own Hardcover token, and
  browses a list's books the same way — each Kindle sees its owner's lists.
  "Most Popular" is global by design and is unchanged.

## 2026-09-10 — build 5f2b1f3

- **Send to CWA: "Series N_ Title" downloads now upload.** The earlier fix
  never engaged on the device (it depended on the author being recognised),
  and the search's prefix-shortening then re-found book 1 of the same
  series anyway. The real title is now read off whichever side carries the
  volume marker, and a confidently-parsed title skips the shortening, so a
  book you don't have is uploaded instead of parked in "check manually."

## 2026-09-10 — build 649edf7

- **Send to CWA now handles "Series N_ Title" download names.** A file named
  like "Author - Series 2_ Actual Title" was searching CWA for the series
  name, matching book 1 of the same series, and skipping the upload as a
  possible duplicate — so a book you didn't have never got added. It now
  reads the real title after the volume number and uploads correctly.

## 2026-09-10 — build 71c3876

- **Fixed: author search hung silently.** The new author picker crashed
  internally (a loop variable shadowed gettext), so searching an author
  showed "Searching Hardcover..." and then nothing. Now it lists matches as
  intended.

## 2026-09-10 — build 3a584b9

- **Send text to the Kindle from your phone.** Bookbridge now runs a small
  always-on receiver (port 8090). Send `http://<kindle>:8090/clip?text=...`
  (e.g. from a phone share-sheet shortcut) and the text lands in KOReader's
  clipboard — long-press any input field → Clipboard → paste, instead of
  typing on the device. It does only this one thing (it does not expose the
  device like the debug HTTP inspector), starts on launch and after wake, and
  a brief on-screen note confirms each receipt.

## 2026-09-10 — build 44057c8

- **Following an author now lets you choose.** Instead of following whatever
  Hardcover ranked first — often a "summary of" or study-guide account rather
  than the real author — the plugin lists the matches (each with its book
  count, so a 102-book author stands out from a 1-book imitator) and lets you
  pick. A single clear match still confirms in one tap.
  (Note: Hardcover only lets a token follow authors if it carries the
  `write:social` scope; a token without it gets an HTTP 403 at the follow
  step. Regenerate the token with social/write access at
  hardcover.app/account/api if following fails.)

## 2026-09-10 — build dcbe3c0

- **Anna's Archive finds a working mirror on its own.** When the current
  mirror is down, the plugin now switches to a live one and retries without
  asking — the backend verifies a candidate is really Anna's Archive before
  switching, so your donator key is never sent to a squatted domain. Falls
  back to other sources only when every mirror is unreachable.

## 2026-09-08 — build 0838c07

- **Automatic updates retry sooner.** A check that couldn't reach the update
  server (Kindle awake before Wi-Fi or Tailscale is back) no longer counts as
  the six-hourly check; it tries again ten minutes later.

## 2026-09-08 — build 5557266

- **Updates install themselves.** With a self-hosted update source set, the
  plugin checks it quietly when the device wakes, reconnects, or starts (at
  most every six hours), installs a changed build, and asks only whether to
  restart now. *Bookbridge → Install updates automatically* turns it off.
  Verified end to end on the desktop KOReader: a stale install, a Resume
  event, the served build installed with no dialogs, and a second wake inside
  the interval doing nothing.

## 2026-09-08 — build 3d02dd3

- **Bluetooth keyboard: "ready" in a few seconds after waking**, not a
  minute. The engine was waiting for a log line the radio never writes, so
  every wake ran out its full 15-round wait, and each round re-read the
  Kindle's entire archived system log (about a quarter million lines). It
  now reads the live log and matches the real "radio on" line. Measured on
  a Paperwhite 5: the ready step finishes 7 s after waking (was 68 s), and
  the phone's keyboard is attached about 7 s after the wake.
- The README's Bluetooth section now describes the current behaviour: the
  Kindle stays listening for as long as it is awake, not for 10 minutes.

## 2026-09-08 — build 6dfdfee

- **Bluetooth keyboard: keep-ready now survives a quick sleep/wake** (the
  wake-time step waits for the sleep-time radio-off to finish instead of
  giving up), and the keep-ready switch flips in place with a check mark.

## 2026-09-08 — build ddfec2a

### Bluetooth keyboard: smoother

- **Ready in about two seconds** when the radio is already on (it used to
  wait 15–20 s), and instant if the Kindle is already listening.
- **The Kindle stays connectable the whole time it's awake**, not just for
  10 minutes — and with *Keep Bluetooth ready when the Kindle wakes* on,
  the radio goes off when it sleeps and comes back when it wakes, so
  reconnecting is just choosing Kindle in the phone's app.
- **"Keyboard connected"** appears the moment the link comes up.

## 2026-09-08 — build 4e9a426

- **Bluetooth keyboard: "Pair from scratch"** when the phone has forgotten
  the Kindle (the Kindle still remembered it and said "already paired").
  The saved phone address from the earlier Bluetooth plugin is picked up
  automatically.

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
