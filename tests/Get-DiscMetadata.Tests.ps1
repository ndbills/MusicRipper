<#
    Pester tests for src/core/Get-DiscMetadata.ps1 — pure parser + ranking
    logic. Network IO functions are NOT exercised here (they're in the
    same .ps1 but require a config / live MusicBrainz to test meaningfully;
    that's covered by the manual verification step in the plan).
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'src\core\Get-DiscMetadata.ps1')

    $script:fixtures = Join-Path $PSScriptRoot 'fixtures'
    function script:Load-Fixture([string]$name) {
        Get-Content -LiteralPath (Join-Path $script:fixtures $name) -Raw | ConvertFrom-Json
    }
}

Describe 'ConvertFrom-MusicBrainzDiscIdResponse' {

    Context 'single match (Pink Floyd, mb-single-match.json)' {
        BeforeAll {
            $script:json = Load-Fixture 'mb-single-match.json'
            $script:cands = ConvertFrom-MusicBrainzDiscIdResponse `
                -Response $script:json -DiscId 'Wn8eRBtfLDfM0qjYPdxrz.Zjs_I-'
        }

        It 'returns exactly one candidate' {
            @($cands).Count | Should -Be 1
        }

        It 'extracts album-level fields' {
            $c = $cands[0]
            $c.Album            | Should -Be 'The Dark Side of the Moon'
            $c.AlbumArtist      | Should -Be 'Pink Floyd'
            $c.AlbumArtistMbid  | Should -Be '83d91898-7763-47d7-b03b-b92132375c47'
            $c.ReleaseMbid      | Should -Be 'f5093c06-23e3-404f-aeaa-40f72885ee3a'
            $c.Year             | Should -Be 1973
            $c.Country          | Should -Be 'US'
            $c.IsCompilation    | Should -BeFalse
            $c.HasCoverArt      | Should -BeTrue
            $c.DiscNumber       | Should -Be 1
            $c.TotalDiscs       | Should -Be 1
        }

        It 'extracts per-track fields' {
            $c = $cands[0]
            @($c.Tracks).Count   | Should -Be 3
            $c.Tracks[0].Number  | Should -Be 1
            $c.Tracks[0].Title   | Should -Be 'Speak to Me'
            $c.Tracks[0].Artist  | Should -Be 'Pink Floyd'
            $c.Tracks[0].LengthMs| Should -Be 67000
            $c.Tracks[1].Title   | Should -Be 'Breathe'
            $c.Tracks[2].RecordingMbid | Should -Be 'r03'
        }
    }

    Context 'multi match (Abbey Road original + 2019 remix)' {
        BeforeEach {
            # BeforeEach (not BeforeAll) so per-test mutations of $cands don't
            # bleed into sibling tests.
            $script:json  = Load-Fixture 'mb-multi-match.json'
            $script:cands = ConvertFrom-MusicBrainzDiscIdResponse `
                -Response $script:json -DiscId 'abcdefMULTIabcdefMULTI______'
        }

        It 'returns both releases as candidates' {
            @($cands).Count | Should -Be 2
        }

        It 'ranking prefers the candidate with cover art (2019 remix wins)' {
            $best = Select-BestMusicBrainzCandidate -Candidates $cands -PreferredCountry 'US'
            $best.ReleaseMbid | Should -Be '22222222-2222-2222-2222-222222222222'
            $best.Year        | Should -Be 2019
            $best.HasCoverArt | Should -BeTrue
        }

        It 'when both have cover art AND same country, prefers earliest year' {
            # Equalize the higher-priority sort keys so the year tie-break is
            # actually exercised.
            $cands[0].HasCoverArt = $true
            $cands[0].Country     = 'US'   # both now US
            $best = Select-BestMusicBrainzCandidate -Candidates $cands -PreferredCountry 'US'
            $best.Year | Should -Be 1969
        }

        It 'PreferredCountry beats earliest-year when both have cover art' {
            $cands[0].HasCoverArt = $true
            $best = Select-BestMusicBrainzCandidate -Candidates $cands -PreferredCountry 'GB'
            $best.Country | Should -Be 'GB'
            $best.Year    | Should -Be 1969
        }
    }

    Context 'no match (mb-no-match.json)' {
        It 'returns an empty array' {
            $json = Load-Fixture 'mb-no-match.json'
            $cands = ConvertFrom-MusicBrainzDiscIdResponse -Response $json -DiscId 'noMATCHnoMATCHnoMATCHnoMATCH'
            @($cands).Count | Should -Be 0
        }

        It 'tolerates a $null response (e.g. from a 404)' {
            $cands = ConvertFrom-MusicBrainzDiscIdResponse -Response $null -DiscId 'x'
            @($cands).Count | Should -Be 0
        }
    }

    Context 'compilation detection' {
        It 'flags a release whose release-group has secondary-type Compilation' {
            $json = Load-Fixture 'mb-single-match.json'
            $json.releases[0].'release-group'.'secondary-types' = @('Compilation')
            $cands = ConvertFrom-MusicBrainzDiscIdResponse -Response $json -DiscId 'Wn8eRBtfLDfM0qjYPdxrz.Zjs_I-'
            $cands[0].IsCompilation | Should -BeTrue
        }

        It 'flags a release credited to the Various Artists MBID' {
            $json = Load-Fixture 'mb-single-match.json'
            $json.releases[0].'artist-credit'[0].artist.id = '89ad4ac3-39f7-470e-963a-56509c546377'
            $cands = ConvertFrom-MusicBrainzDiscIdResponse -Response $json -DiscId 'Wn8eRBtfLDfM0qjYPdxrz.Zjs_I-'
            $cands[0].IsCompilation | Should -BeTrue
        }
    }
}

Describe 'Select-BestMusicBrainzCandidate' {
    It 'returns $null on empty input' {
        Select-BestMusicBrainzCandidate -Candidates @() | Should -BeNullOrEmpty
    }

    It 'returns the only candidate as-is on single input' {
        $only = [pscustomobject]@{ HasCoverArt=$false; Country='ZZ'; Year=2000 }
        Select-BestMusicBrainzCandidate -Candidates @($only) | Should -Be $only
    }
}
