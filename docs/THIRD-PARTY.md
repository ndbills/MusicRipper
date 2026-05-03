# Third-Party Dependencies

Structured companion to [`NOTICE.md`](../NOTICE.md). One row per third-party
component MusicRipper depends on at install or runtime. "Version pinned"
indicates whether the project requires a specific minimum version (we
generally accept whatever `winget` ships); "Bundled" indicates whether the
component travels with the MusicRipper source tree (none of them do).

For Deezer specifically, see the **Deezer API compliance investigation**
note at the bottom of this file.

| Name | Version pinned | License | How we use it | Bundled? | Link |
| --- | --- | --- | --- | --- | --- |
| CUETools / CUERipper | No (winget portable; auto-discovered under `%LOCALAPPDATA%\Microsoft\WinGet\Packages\gchudov.CUETools_*`) | Freely redistributable (project-defined) | TOC + disc-id read, secure rip, AccurateRip + CUETools DB verification, via .NET DLL interop | No | <https://cue.tools/> |
| FLAC tools (`flac.exe`, `metaflac.exe`) | No (winget `Xiph.FLAC`) | GPLv2 binaries / BSD-style libFLAC | Vorbis-comment tag I/O, embedded cover-art block writes, ReplayGain calculation, all via CLI | No | <https://xiph.org/flac/> |
| MusicBrainz Picard | No (winget `MusicBrainz.Picard`) | GPLv2 | Documented as the manual cleanup tool for `_ReviewQueue/` workflow; not invoked programmatically | No | <https://picard.musicbrainz.org/> |
| WireGuard (Windows client) | No (winget `WireGuard.WireGuard`) | GPLv2 | Optional auto-toggle of a per-tunnel WireGuard service for remote NAS sync. Trademark of Jason A. Donenfeld; we are not affiliated. | No | <https://www.wireguard.com/> |
| MusicBrainz Web Service | API v2 (`/ws/2`) | Data CC0 / CC-BY-NC-SA; API per [MetaBrainz terms](https://musicbrainz.org/doc/MusicBrainz_API) | Disc-id lookup; rate-limited ≤1 req/sec; user-supplied contact address goes in `User-Agent` | No (network service) | <https://musicbrainz.org/doc/MusicBrainz_API> |
| Cover Art Archive | API v1 (per-release `front-1200`) | Per-image rights vary | Front-cover image fetch keyed on MB Release MBID; written into local FLAC files only | No (network service) | <https://coverartarchive.org/> |
| AccurateRip drive offset list | Live-fetched at install time | © Illustrate (Spoon); proprietary; not redistributable | One-time install fetch from `accuraterip.com/driveoffsets.htm` → cached at `data/driveoffsets.cached.json` for runtime use; cache file is gitignored | No | <https://accuraterip.com/driveoffsets.htm> |
| iTunes Search API | Public endpoint (no version) | Per [Apple Search API ToS](https://performance-partners.apple.com/search-api) | Text-search album metadata + hi-res cover-art. Throttled to comply with Apple's documented soft limit. Attribution: *"Album metadata provided in part by the iTunes Search API, © Apple Inc."* | No (network service) | <https://performance-partners.apple.com/search-api> |
| Deezer API | Public endpoint (no version) | Per [Deezer API ToS](https://developers.deezer.com/api) | Text-search album metadata (`/search/album`, `/album/{id}`) + cover-art (`cover_xl`/`cover_big`). Public unauthenticated read tier. | No (network service) | <https://developers.deezer.com/api> |

---

## Deezer API compliance investigation

**Status:** Pending (Phase B3 of release-prep). This entry will be filled in
with: endpoints actually used, request volume per rip, applicable ToS
clauses (auth requirement, caching of cover images, attribution), and a
compliant / non-compliant / ambiguous verdict, plus a recommended next
action if any.
