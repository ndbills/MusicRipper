# Third-Party Notices

MusicRipper depends on (and gratefully acknowledges) the following third-party
software and services. None of these are bundled with the MusicRipper source
distribution; they are installed separately (typically via `winget`) and
invoked at runtime via CLI, .NET interop, or HTTP.

For a structured contributor/auditor view (license, version pinning, bundling
status), see [docs/THIRD-PARTY.md](docs/THIRD-PARTY.md).

---

## CUETools / CUERipper

- **Author:** Grigory Chudov
- **License:** Freely redistributable (see project for terms)
- **How we use it:** Disc TOC reading, secure ripping, AccurateRip + CUETools
  DB verification. Invoked via .NET DLLs (`CUETools.CDImage.dll`,
  `CUETools.Ripper.dll`, `CUETools.Ripper.SCSI.dll`,
  `CUETools.AccurateRip.dll`, `CUETools.CTDB.dll`) loaded from the
  user-installed CUETools location.
- **Bundled:** No. Installed via `winget install gchudov.CUETools`.
- **Project:** <https://cue.tools/>

## FLAC tools (`flac.exe`, `metaflac.exe`)

- **Author:** Xiph.Org Foundation
- **License:** GPLv2 (binaries) / BSD-style (libFLAC)
- **How we use it:** ReplayGain calculation (`metaflac --add-replay-gain`),
  Vorbis-comment tag read/write, embedded cover-art block writes. Invoked via
  CLI.
- **Bundled:** No. Installed via `winget install Xiph.FLAC`.
- **Project:** <https://xiph.org/flac/>

## MusicBrainz Picard

- **Author:** MetaBrainz Foundation
- **License:** GPLv2
- **How we use it:** Optional manual cleanup tool for the `_ReviewQueue/`
  workflow. MusicRipper does not invoke Picard programmatically; the project
  documentation references it for parents/users who want to re-tag rescued
  rips before promoting them with `Move-FromReviewQueue.ps1`.
- **Bundled:** No. Installed via `winget install MusicBrainz.Picard`.
- **Project:** <https://picard.musicbrainz.org/>

## WireGuard

- **Author:** Jason A. Donenfeld
- **License:** GPLv2
- **How we use it:** Optional auto-toggle of a per-tunnel WireGuard service so
  the Synology NAS sync target can reach a remotely-hosted NAS. Setup installs
  the Windows client via `winget install WireGuard.WireGuard` and registers a
  user-supplied `.conf` as a per-tunnel service. Runtime calls are
  `Start-Service` / `Stop-Service` against that service name.
- **Bundled:** No.
- **Trademark notice:** *WireGuard* is a registered trademark of
  Jason A. Donenfeld. MusicRipper is not affiliated with or endorsed by the
  WireGuard project.
- **Project:** <https://www.wireguard.com/>

## MusicBrainz Web Service

- **Author:** MetaBrainz Foundation
- **License:** Data is CC0 (core MusicBrainz dataset) / CC-BY-NC-SA (some
  derived data). API access is governed by MetaBrainz's
  [API terms](https://musicbrainz.org/doc/MusicBrainz_API).
- **How we use it:** Disc-id lookup
  (`/ws/2/discid/<id>?inc=artist-credits+recordings+release-groups+labels`).
  User supplies a contact address (email or URL) in their local config; this
  is sent in the `User-Agent` header per MetaBrainz's policy. All requests
  are rate-limited to ≤1 request per second.
- **Bundled:** No (network service).
- **Project:** <https://musicbrainz.org/doc/MusicBrainz_API>

## Cover Art Archive

- **Author:** Internet Archive / MetaBrainz Foundation
- **License:** Per-image rights vary; see <https://coverartarchive.org/> for
  details.
- **How we use it:** Front-cover image fetch keyed off a MusicBrainz Release
  MBID (`/release/<mbid>/front-1200`). Downloaded images are written into
  the user's local FLAC files only; nothing is redistributed.
- **Bundled:** No (network service).
- **Project:** <https://coverartarchive.org/>

## AccurateRip drive offset list

- **Author:** © Illustrate (Spoon)
- **License:** Proprietary; not redistributable.
- **How we use it:** MusicRipper fetches the live drive-offset list from
  `accuraterip.com/driveoffsets.htm` at install time and caches it locally
  under `data/driveoffsets.cached.json` for runtime fallback. The cache file
  is **not** committed to this repository. Internet access is required at
  install time.
- **Bundled:** No.
- **Project:** <https://accuraterip.com/driveoffsets.htm>

## iTunes Search API

- **Author:** © Apple Inc.
- **License:** Per Apple's
  [Search API terms](https://performance-partners.apple.com/search-api).
- **How we use it:** Text-search fallback for album metadata
  (`/search?term=...&entity=album`) and high-resolution cover-art lookup.
  Throttled to comply with Apple's documented soft limit.
- **Attribution (per Apple's API ToS):**
  *"Album metadata provided in part by the iTunes Search API, © Apple Inc."*
- **Bundled:** No (network service).
- **Project:** <https://performance-partners.apple.com/search-api>

## Deezer API

- **Author:** © Deezer
- **License:** Usage subject to Deezer's
  [API terms](https://developers.deezer.com/api).
- **How we use it:** Text-search fallback for album metadata
  (`/search/album`, `/album/{id}`) and cover-art (`cover_xl`,
  `cover_big`). Public unauthenticated read endpoints.
- **Bundled:** No (network service).
- **Project:** <https://developers.deezer.com/api>
