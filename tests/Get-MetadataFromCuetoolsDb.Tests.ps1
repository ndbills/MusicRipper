<#
.SYNOPSIS
    Unit tests for the CTDB metadata provider's pure pieces -- the
    ConvertFrom-CtdbMetadata parser, plus an orchestrator integration
    test that exercises the MB+CTDB merge path.

.DESCRIPTION
    The live CTDB call (Invoke-CuetoolsDbMetadataProvider against
    db.cuetools.net) is NOT covered here -- it requires CUETools DLLs and
    network. That path is exercised in manual testing.

    We CAN cover:
      - ConvertFrom-CtdbMetadata against fake CTDBResponseMeta-shaped
        PSCustomObjects (no CUETools dependency).
      - Get-RipperDiscMetadata's merge logic with both providers stubbed,
        verifying the synthesized "Merged (MusicBrainz + CTDB)" candidate
        is prepended and that MB wins on conflict while CTDB fills nulls.
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'src\core\metadata\Get-MetadataFromCuetoolsDb.ps1')
    . (Join-Path $repoRoot 'src\core\Get-DiscMetadata.ps1')
}

Describe 'ConvertFrom-CtdbMetadata' {

    BeforeAll {
        # Fake DiscIdInfo with three audio tracks so the converter knows
        # how long to make the per-track array.
        $script:disc = [pscustomobject]@{
            DiscId = 'fake-disc-id'
            Tracks = @(
                [pscustomobject]@{ Number=1; IsAudio=$true },
                [pscustomobject]@{ Number=2; IsAudio=$true },
                [pscustomobject]@{ Number=3; IsAudio=$true }
            )
        }
    }

    It 'returns an empty array when Metadata is null' {
        $r = ConvertFrom-CtdbMetadata -Metadata $null -DiscIdInfo $script:disc
        @($r).Count | Should -Be 0
    }

    It 'returns one candidate per CTDB metadata entry' {
        $meta = @(
            [pscustomobject]@{ artist='A'; album='X'; year='2001'; genre='Rock'
                tracks=@([pscustomobject]@{ name='t1'; artist='A' }) }
            [pscustomobject]@{ artist='B'; album='Y'; year='2002'; genre='Pop'
                tracks=@([pscustomobject]@{ name='t1'; artist='B' }) }
        )
        $cands = @(ConvertFrom-CtdbMetadata -Metadata $meta -DiscIdInfo $script:disc)
        $cands.Count | Should -Be 2
        $cands[0].Album | Should -Be 'X'
        $cands[1].Album | Should -Be 'Y'
    }

    It 'tags every candidate with Source="CTDB"' {
        $meta = @([pscustomobject]@{ artist='A'; album='X'; year='2001'; tracks=@() })
        $cands = @(ConvertFrom-CtdbMetadata -Metadata $meta -DiscIdInfo $script:disc)
        $cands[0].Source | Should -Be 'CTDB'
    }

    It 'parses a 4-digit year string into an int' {
        $meta = @([pscustomobject]@{ artist='A'; album='X'; year='1999'; tracks=@() })
        $cands = @(ConvertFrom-CtdbMetadata -Metadata $meta -DiscIdInfo $script:disc)
        $cands[0].Year | Should -Be 1999
    }

    It 'leaves Year as null when CTDB sends no year' {
        $meta = @([pscustomobject]@{ artist='A'; album='X'; tracks=@() })
        $cands = @(ConvertFrom-CtdbMetadata -Metadata $meta -DiscIdInfo $script:disc)
        $cands[0].Year | Should -BeNullOrEmpty
    }

    It 'pads the track array out to the disc audio-track count' {
        # CTDB shipped 1 track, disc has 3 -- expect 3 entries with the
        # last two having null Title.
        $meta = @([pscustomobject]@{
            artist='A'; album='X'; year='2001'
            tracks=@([pscustomobject]@{ name='t1'; artist='A' })
        })
        $cands = @(ConvertFrom-CtdbMetadata -Metadata $meta -DiscIdInfo $script:disc)
        $cands[0].Tracks.Count | Should -Be 3
        $cands[0].Tracks[0].Title | Should -Be 't1'
        $cands[0].Tracks[1].Title | Should -BeNullOrEmpty
        $cands[0].Tracks[2].Title | Should -BeNullOrEmpty
    }

    It 'flags the candidate as a compilation when CTDB artist is "Various Artists"' {
        $meta = @([pscustomobject]@{ artist='Various Artists'; album='X'; year='2001'; tracks=@() })
        $cands = @(ConvertFrom-CtdbMetadata -Metadata $meta -DiscIdInfo $script:disc)
        $cands[0].IsCompilation | Should -BeTrue
    }

    It 'leaves IsCompilation false for normal artists' {
        $meta = @([pscustomobject]@{ artist='Pink Floyd'; album='X'; year='2001'; tracks=@() })
        $cands = @(ConvertFrom-CtdbMetadata -Metadata $meta -DiscIdInfo $script:disc)
        $cands[0].IsCompilation | Should -BeFalse
    }

    It 'emits null for fields CTDB does not carry (MBIDs, label, barcode)' {
        $meta = @([pscustomobject]@{ artist='A'; album='X'; year='2001'; tracks=@() })
        $cands = @(ConvertFrom-CtdbMetadata -Metadata $meta -DiscIdInfo $script:disc)
        $cands[0].ReleaseMbid   | Should -BeNullOrEmpty
        $cands[0].LabelName     | Should -BeNullOrEmpty
        $cands[0].Barcode       | Should -BeNullOrEmpty
        $cands[0].CatalogNumber | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-CuetoolsDbMetadataProvider input validation' {

    It 'returns Status=Error when DiscIdInfo lacks Toc' {
        $disc = [pscustomobject]@{ DiscId='X'; CtdbId='Y'; Tracks=@() }
        $resp = Invoke-CuetoolsDbMetadataProvider -DiscIdInfo $disc
        $resp.Source | Should -Be 'CTDB'
        $resp.Status | Should -Be 'Error'
        $resp.Diagnostic | Should -Match 'Toc'
    }
}

Describe 'Get-RipperDiscMetadata orchestrator merge' {

    BeforeAll {
        # Stub disc.
        $script:disc = [pscustomobject]@{
            DiscId         = 'fake-disc-id'
            CtdbId         = 'fake-toc-id'
            DriveLetter    = 'D:'
            Tracks         = @(
                [pscustomobject]@{ Number=1; IsAudio=$true }
                [pscustomobject]@{ Number=2; IsAudio=$true }
            )
            MusicBrainzToc = '1 2 12345 150 6789'
        }
    }

    Context 'when both providers return matches' {

        BeforeEach {
            # MB candidate with a real MBID + label, but a missing track-2 title.
            $script:mbCand = [pscustomobject]@{
                Source           = 'MusicBrainz'
                AlbumArtist      = 'Pink Floyd'
                AlbumArtists     = @('Pink Floyd')
                AlbumArtistSort  = 'Floyd, Pink'
                AlbumArtistMbid  = @('mb-artist-id')
                Album            = 'Dark Side'
                Media            = 'CD'
                ReleaseMbid      = 'mb-release-id'
                ReleaseGroupMbid = 'mb-group-id'
                Year             = 1973
                ReleaseDate      = '1973-03-01'
                OriginalYear     = 1973
                OriginalDate     = '1973-03-01'
                Country          = 'GB'
                ReleaseStatus    = 'Official'
                ReleaseType      = 'Album'
                Script           = 'Latn'
                Language         = 'eng'
                Asin             = $null
                Barcode          = $null
                LabelName        = 'Harvest'
                CatalogNumber    = 'SHVL 804'
                TrackCount       = 2
                DiscNumber       = 1
                TotalDiscs       = 1
                IsCompilation    = $false
                HasCoverArt      = $false
                Tracks           = @(
                    [pscustomobject]@{ Number=1; Title='Speak to Me'; Artist='Pink Floyd'; Artists=@('Pink Floyd'); ArtistSort='Floyd, Pink'; ArtistMbid=@(); RecordingMbid=$null; ReleaseTrackMbid=$null; LengthMs=90000 }
                    [pscustomobject]@{ Number=2; Title=$null;        Artist='Pink Floyd'; Artists=@('Pink Floyd'); ArtistSort='Floyd, Pink'; ArtistMbid=@(); RecordingMbid=$null; ReleaseTrackMbid=$null; LengthMs=0 }
                )
            }
            # CTDB candidate with the missing track-2 title and a year that
            # MB also has (so MB wins) and a barcode MB doesn't have.
            $script:ctdbCand = [pscustomobject]@{
                Source           = 'CTDB'
                AlbumArtist      = 'Pink Floyd Different Spelling'
                AlbumArtists     = @('Pink Floyd Different Spelling')
                AlbumArtistSort  = 'Pink Floyd Different Spelling'
                AlbumArtistMbid  = @()
                Album            = 'Dark Side (CTDB title)'
                Media            = 'CD'
                ReleaseMbid      = $null
                ReleaseGroupMbid = $null
                Year             = 1974
                ReleaseDate      = '1974'
                OriginalYear     = 1974
                OriginalDate     = '1974'
                Country          = $null
                ReleaseStatus    = $null
                ReleaseType      = $null
                Script           = $null
                Language         = $null
                Asin             = $null
                Barcode          = '1234567890123'
                LabelName        = $null
                CatalogNumber    = $null
                Genre            = 'Progressive Rock'
                TrackCount       = 2
                DiscNumber       = 1
                TotalDiscs       = 1
                IsCompilation    = $false
                HasCoverArt      = $false
                Tracks           = @(
                    [pscustomobject]@{ Number=1; Title='Speak to Me (alt)'; Artist='Pink Floyd'; Artists=@('Pink Floyd'); ArtistSort='Pink Floyd'; ArtistMbid=@(); RecordingMbid=$null; ReleaseTrackMbid=$null; LengthMs=0 }
                    [pscustomobject]@{ Number=2; Title='Breathe';           Artist='Pink Floyd'; Artists=@('Pink Floyd'); ArtistSort='Pink Floyd'; ArtistMbid=@(); RecordingMbid=$null; ReleaseTrackMbid=$null; LengthMs=0 }
                )
            }

            # Stub both providers with a Mock that returns a single match each.
            Mock Invoke-MusicBrainzMetadataProvider {
                [pscustomobject]@{
                    Source='MusicBrainz'; Status='Match'
                    BestMatch=$script:mbCand; Candidates=@($script:mbCand); Diagnostic=$null
                }
            }
            Mock Invoke-CuetoolsDbMetadataProvider {
                [pscustomobject]@{
                    Source='CTDB'; Status='Match'
                    BestMatch=$script:ctdbCand; Candidates=@($script:ctdbCand); Diagnostic=$null
                }
            }
            # Cover art fetch must not actually hit the network.
            Mock Get-RipperBestCoverArt { $null }
        }

        It 'prepends a synthesized "Merged" candidate' {
            $r = Get-RipperDiscMetadata -DiscIdInfo $script:disc -Providers @('MusicBrainz','CuetoolsDb')
            $r.Candidates.Count | Should -Be 3   # merged + MB + CTDB
            $r.Candidates[0].Source | Should -Match '^Merged'
        }

        It 'lets MB win on a field both providers carry' {
            $r = Get-RipperDiscMetadata -DiscIdInfo $script:disc -Providers @('MusicBrainz','CuetoolsDb')
            $r.BestMatch.Album       | Should -Be 'Dark Side'
            $r.BestMatch.AlbumArtist | Should -Be 'Pink Floyd'
            $r.BestMatch.Year        | Should -Be 1973
        }

        It 'lets CTDB fill a field MB left null (Barcode)' {
            $r = Get-RipperDiscMetadata -DiscIdInfo $script:disc -Providers @('MusicBrainz','CuetoolsDb')
            $r.BestMatch.Barcode | Should -Be '1234567890123'
        }

        It 'lets CTDB fill a track Title MB left null' {
            $r = Get-RipperDiscMetadata -DiscIdInfo $script:disc -Providers @('MusicBrainz','CuetoolsDb')
            $r.BestMatch.Tracks[0].Title | Should -Be 'Speak to Me'   # MB wins
            $r.BestMatch.Tracks[1].Title | Should -Be 'Breathe'       # CTDB fills
        }

        It 'preserves the MB ReleaseMbid in the merged candidate' {
            $r = Get-RipperDiscMetadata -DiscIdInfo $script:disc -Providers @('MusicBrainz','CuetoolsDb')
            $r.BestMatch.ReleaseMbid | Should -Be 'mb-release-id'
        }

        It 'reports Status=MultiMatch when 2+ candidates exist' {
            $r = Get-RipperDiscMetadata -DiscIdInfo $script:disc -Providers @('MusicBrainz','CuetoolsDb')
            $r.Status | Should -Be 'MultiMatch'
        }

        It 'exposes per-provider raw responses via ProviderResults' {
            $r = Get-RipperDiscMetadata -DiscIdInfo $script:disc -Providers @('MusicBrainz','CuetoolsDb')
            $r.ProviderResults.Count | Should -Be 2
            ($r.ProviderResults | ForEach-Object Source) | Should -Contain 'MusicBrainz'
            ($r.ProviderResults | ForEach-Object Source) | Should -Contain 'CTDB'
        }
    }

    Context 'when only one provider matches' {

        BeforeEach {
            $script:mbOnly = [pscustomobject]@{
                Source='MusicBrainz'; AlbumArtist='Pink Floyd'; Album='X'
                ReleaseMbid='mb-id'; HasCoverArt=$false; Year=1973
                Tracks=@(); TrackCount=0
            }
            Mock Invoke-MusicBrainzMetadataProvider {
                [pscustomobject]@{
                    Source='MusicBrainz'; Status='Match'
                    BestMatch=$script:mbOnly; Candidates=@($script:mbOnly); Diagnostic=$null
                }
            }
            Mock Invoke-CuetoolsDbMetadataProvider {
                [pscustomobject]@{
                    Source='CTDB'; Status='NoMatch'
                    BestMatch=$null; Candidates=@(); Diagnostic=$null
                }
            }
            Mock Get-RipperBestCoverArt { $null }
        }

        It 'does NOT synthesize a merged candidate' {
            $r = Get-RipperDiscMetadata -DiscIdInfo $script:disc -Providers @('MusicBrainz','CuetoolsDb')
            $r.Candidates.Count | Should -Be 1
            $r.BestMatch.Source | Should -Be 'MusicBrainz'
        }

        It 'still records BOTH providers in ProviderResults' {
            $r = Get-RipperDiscMetadata -DiscIdInfo $script:disc -Providers @('MusicBrainz','CuetoolsDb')
            $r.ProviderResults.Count | Should -Be 2
        }
    }

    Context 'when no provider matches' {

        BeforeEach {
            Mock Invoke-MusicBrainzMetadataProvider {
                [pscustomobject]@{ Source='MusicBrainz'; Status='NoMatch'; BestMatch=$null; Candidates=@(); Diagnostic=$null }
            }
            Mock Invoke-CuetoolsDbMetadataProvider {
                [pscustomobject]@{ Source='CTDB'; Status='NoMatch'; BestMatch=$null; Candidates=@(); Diagnostic=$null }
            }
        }

        It 'returns Status=NoMatch with an empty candidate list' {
            $r = Get-RipperDiscMetadata -DiscIdInfo $script:disc -Providers @('MusicBrainz','CuetoolsDb')
            $r.Status | Should -Be 'NoMatch'
            $r.Candidates.Count | Should -Be 0
            $r.BestMatch | Should -BeNullOrEmpty
        }
    }

    Context 'when every provider is offline' {

        BeforeEach {
            Mock Invoke-MusicBrainzMetadataProvider {
                [pscustomobject]@{ Source='MusicBrainz'; Status='Offline'; BestMatch=$null; Candidates=@(); Diagnostic='no net' }
            }
            Mock Invoke-CuetoolsDbMetadataProvider {
                [pscustomobject]@{ Source='CTDB'; Status='Offline'; BestMatch=$null; Candidates=@(); Diagnostic='no net' }
            }
        }

        It 'returns Status=Offline so the UI can show the right message' {
            $r = Get-RipperDiscMetadata -DiscIdInfo $script:disc -Providers @('MusicBrainz','CuetoolsDb')
            $r.Status | Should -Be 'Offline'
        }
    }
}
