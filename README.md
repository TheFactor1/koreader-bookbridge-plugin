# shelfmark.koplugin

A KOReader plugin for searching and requesting books/audiobooks from a
self-hosted [Shelfmark](https://github.com/calibrain/shelfmark) server,
without leaving KOReader.

## What it does

Adds a "Shelfmark" entry to KOReader's main menu:

- **Search & request a book** — searches Shelfmark's metadata providers and
  lets you submit a request directly from the device.
- **My requests** — lists your pending/fulfilled requests.
- **Settings** — server URL, username, password.

It only submits the *request*. The actual book still arrives on the device
the normal way, via your existing OPDS catalog once your library manager
(e.g. Calibre-Web-Automated) has imported it.

## Scope / limitations

- Built for reaching Shelfmark directly over home WiFi or Tailscale — there
  is no handling for an interactive-login gateway (e.g. Cloudflare Access)
  in front of the server. A non-browser HTTP client can't complete that kind
  of login flow.
- Session auth only (username/password → cookie), matching Shelfmark's
  built-in auth. No OIDC/SSO support.

## Install

Copy `shelfmark.koplugin/` into your KOReader install's `plugins/`
directory, then restart KOReader. Configure the server URL/username/password
under **Shelfmark → Settings**.

## Status

First version, built against Shelfmark's live API (inspected directly from
a running instance) and cross-checked against KOReader's own
`wallabag.koplugin` and `opds.koplugin` for correct API usage. Syntax-checked
with a Lua loader, but not yet run on an actual device — expect to iterate.
