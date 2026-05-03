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
| iTunes Search API | Public endpoint (no version) | Per [Apple Search API ToS](https://performance-partners.apple.com/search-api) | Text-search album metadata + hi-res cover-art. Per-process 1500 ms throttle (~40 req/min) between API calls; CDN downloads unthrottled. See D-029. Attribution: *"Album metadata provided in part by the iTunes Search API, © Apple Inc."* | No (network service) | <https://performance-partners.apple.com/search-api> |
| Deezer API | Public endpoint (no version) | Per [Deezer API ToU](https://developers.deezer.com/termsofuse) (French law, non-commercial / family-scope only) | Text-search album metadata (`/search/album`, `/album/{id}`) + cover-art (`cover_xl`/`cover_big`). Public unauthenticated read tier. See investigation block below + D-030. | No (network service) | <https://developers.deezer.com/api> |

---

## Deezer API compliance investigation

**Investigation date:** May 2026 (release-prep phase B3).
**ToU snapshot reviewed:** [developers.deezer.com/termsofuse via web.archive.org/web/2024/...](https://web.archive.org/web/2024/https://developers.deezer.com/termsofuse) (Dec 2024 capture; Deezer's live site renders client-side and resists static fetch).
**Verdict:** ✅ **Compliant** for MusicRipper's documented use case (personal/family CD ripping).

### Endpoints used

| Endpoint | Caller | Purpose | Volume per rip |
| --- | --- | --- | --- |
| `GET https://api.deezer.com/search/album?q=...&limit=10` | `src/core/metadata/Get-MetadataFromDeezer.ps1` | Text-search modal fallback when MB / CTDB / GnuDB return no match | 0 (only fires on user 'Search' click in the no-match modal) |
| `GET https://api.deezer.com/album/{id}` | `src/core/metadata/Get-MetadataFromDeezer.ps1` | Per-hit detail fetch for top-N albums during text search | 0–5 per user search (DetailLimit) |
| `GET https://api.deezer.com/search/album?q=...&limit=5` | `src/core/coverart/Get-CoverArtFromDeezer.ps1` | Cover-art fallback when CAA / iTunes return no bytes | 0–1 per rip (only fires when earlier providers fail) |
| `GET <cover_xl URL>` | same | Download chosen cover image bytes | 0–1 per rip |

**Auth:** None. All endpoints are public unauthenticated reads. Deezer's ToU formally requires a Developer account, but the listed endpoints are served openly by their CDN; we do not bypass any auth check.

### Applicable ToU clauses

- **Section IV — Non-commercial use.** *"The use of the Content is limited to a strictly private use within a family scope."* This is exactly MusicRipper's stated use case (parent ripping their own CDs into the family library). MIT-licensed open source with no monetization satisfies the non-commercial environment requirement.
- **Section IV (cont.) — No commercial association.** *"Content shall not be associated, directly or indirectly with any trademark, brand name, or logo."* Aimed at third parties wrapping Deezer behind their own brand; ordinary third-party attribution (this NOTICE block, mentioning "Deezer" as a provider name in code) is conventional and not a violation.
- **Section VII — Intellectual property.** Cover-art images are Deezer's / the right-holder's property. The Section IV "strictly private use within a family scope" carve-out is the basis for embedding them in the user's local FLAC files. **A user who repurposes MusicRipper for paid work (DJ catalog, music-licensing prep, etc.) is NOT covered by this carve-out and should not use the Deezer provider in that context.**

### Recommended follow-ups (not in this round)

1. **Set an identifying `User-Agent` on Deezer requests** so Deezer can attribute traffic to MusicRipper rather than seeing anonymous PowerShell defaults. Parallel to what we already do for MB / CTDB / GnuDB. Pure good-citizenship.
2. **Surface the non-commercial caveat** in user-facing docs (README / SETUP / TROUBLESHOOTING) so a future user with a commercial use case understands they should disable the Deezer provider in their config.
3. **Honor the 50 req/sec/IP figure** with an explicit throttle. Current code relies on "not a concern at one-rip-per-disc cadence" which is true, but a future feature (e.g. batch re-tag of an existing library) would change the math. No urgency.

No code changes were made in this investigation round per the release-prep brief; see D-030 for the decision rationale.
