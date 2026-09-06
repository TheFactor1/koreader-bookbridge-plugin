# Changelog

Plain-language notes on what changed and why. Build ids refer to the
`build` field in `shelfmark.koplugin/manifest.json`, which is what
**Shelfmark → Check for updates** compares against.

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
