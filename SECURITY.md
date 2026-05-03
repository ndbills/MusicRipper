# Security Policy

## Reporting a vulnerability

Please report suspected security issues **privately** via GitHub's
Security Advisories: <https://github.com/ndbills/MusicRipper/security/advisories/new>.

Do not open a public issue for security problems. Public issues are
fine for everything else.

A note on scope: MusicRipper is a single-user desktop tool that
shells out to local CLI binaries, talks to a handful of public
metadata APIs, and writes files to the user's own machine. There
are no servers, no auth tokens, no multi-tenant data. Realistic
threat surfaces are:

- A malicious sync target path or NAS UNC that escapes MusicRipper
  and writes outside the configured library / sync roots.
- A maliciously-crafted MusicBrainz / iTunes / Deezer / GnuDB / CTDB
  response that triggers code execution rather than just bad metadata.
- A WireGuard `.conf` import flow that mishandles a hostile config
  and ends up running arbitrary `wireguard.exe` arguments.
- Credential / DPAPI-blob handling that leaks secrets into a log
  file or another process.

Anything fitting one of those buckets is in scope. Functional bugs,
"my disc didn't get tagged correctly," and feature requests should
go through the regular Issues queue.

## Supported version

Only the latest commit on `main` is supported. There are no
maintained release branches and no LTS.

## What stays on your machine vs. what gets sent over the network

Everything in `%LOCALAPPDATA%\MusicRipper\` is local-only:

- `config.json` — your library path, drive offset, sync targets,
  WireGuard tunnel name, and your MusicBrainz contact address.
- `credentials.clixml` — DPAPI-encrypted Synology NAS credential
  (when `HasSynologyCredential = true`). DPAPI binds the blob to
  your Windows user account on this machine; copying the file to
  another machine renders it unreadable.
- `logs/` — per-session diagnostic logs. Rip results, file paths,
  config field names, exception traces. **No** credentials, **no**
  DPAPI blobs, **no** WireGuard keys.

What goes over the network during normal operation:

- **MusicBrainz** (`musicbrainz.org`): the disc-id of an inserted
  CD + your configured contact address in the `User-Agent` header.
- **CUETools DB** (`db.cuetools.net`): the disc TOC + your contact
  address in the UA.
- **GnuDB** (`gnudb.gnudb.org`): the disc-id + your contact address
  in the `hello=` query parameter.
- **Cover Art Archive** (`coverartarchive.org`): a release MBID and
  the resulting image bytes back.
- **iTunes Search** (`itunes.apple.com`): album / artist text +
  resulting album metadata + image CDN URL.
- **Deezer** (`api.deezer.com`): album / artist text + the
  `MusicRipper/<version> ( <contactAddress> )` UA + result data.
- **AccurateRip** (`accuraterip.com`): a one-time install-time fetch
  of the drive-offset list (read-only HTML scrape).
- **OneDrive sync target**: file copies via the Windows OneDrive
  client. MusicRipper itself never authenticates with Microsoft;
  it just writes to the local OneDrive folder you configured and
  the OneDrive client handles upload.
- **Synology NAS sync target**: SMB to the configured UNC, optionally
  through a per-tunnel WireGuard service you provision yourself.
  Credentials come from the DPAPI blob above.

What never goes over the network:

- The contents of your CDs.
- Your library path or any file paths.
- Your DPAPI credential blob, your WireGuard private keys, or any
  secret material from `config.json`.
