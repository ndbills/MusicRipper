<#
    Pester tests for the pure-logic helpers in src/ui/Show-MetadataDialog.ps1
    (ConvertTo-MetadataViewModel, ConvertFrom-MetadataViewModel,
    Format-MetadataCandidateLabel). The WPF dialog itself is exercised by
    the manual smoke harness (src/ui/Show-MetadataDialog.smoke.ps1) — WPF
    can't be unit-tested headlessly without standing up a Dispatcher.

    Loads the same fixtures Get-DiscMetadata.Tests.ps1 uses, then drives
    the candidates through the parser and into the view-model.
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'src\core\Get-DiscMetadata.ps1')
    . (Join-Path $repoRoot 'src\ui\Show-MetadataDialog.ps1')

    $script:fixtures = Join-Path $PSScriptRoot 'fixtures'
    function script:Load-Candidate([string]$file, [string]$discId) {
        $json = Get-Content -LiteralPath (Join-Path $script:fixtures $file) -Raw | ConvertFrom-Json
        $cands = ConvertFrom-MusicBrainzDiscIdResponse -Response $json -DiscId $discId
        $cands[0]
    }
}

Describe 'ConvertTo-MetadataViewModel' {

    Context 'single match (Pink Floyd)' {
        BeforeAll {
            $script:cand = Load-Candidate 'mb-single-match.json' 'Wn8eRBtfLDfM0qjYPdxrz.Zjs_I-'
            $script:vm   = ConvertTo-MetadataViewModel -Candidate $script:cand
        }

        It 'projects album-level fields' {
            $vm.Album         | Should -Be 'The Dark Side of the Moon'
            $vm.AlbumArtist   | Should -Be 'Pink Floyd'
            $vm.Year          | Should -Be 1973
            $vm.DiscNumber    | Should -Be 1
            $vm.TotalDiscs    | Should -Be 1
            $vm.IsCompilation | Should -BeFalse
        }

        It 'attaches the source candidate for round-trip' {
            $vm.Source.ReleaseMbid | Should -Be 'f5093c06-23e3-404f-aeaa-40f72885ee3a'
        }

        It 'projects tracks as TrackRow rows in an ObservableCollection' {
            $vm.Tracks.GetType().FullName | Should -Match 'ObservableCollection'
            @($vm.Tracks).Count | Should -Be 3
            $vm.Tracks[0].GetType().FullName | Should -Be 'MusicRipper.TrackRow'
            $vm.Tracks[0].Number   | Should -Be 1
            $vm.Tracks[0].Title    | Should -Be 'Speak to Me'
            $vm.Tracks[0].LengthMs | Should -Be 67000
        }

        It 'formats Length as M:SS for display' {
            $vm.Tracks[1].Length | Should -Be '2:43'   # 163000 ms
            $vm.Tracks[2].Length | Should -Be '3:36'   # 216000 ms
        }
    }
}

Describe 'ConvertFrom-MetadataViewModel' {

    BeforeAll {
        $script:cand = Load-Candidate 'mb-single-match.json' 'Wn8eRBtfLDfM0qjYPdxrz.Zjs_I-'
        # Simulate a CoverArtBytes attachment (Get-DiscMetadata only adds it
        # to BestMatch in real usage).
        $script:cand | Add-Member -NotePropertyName CoverArtBytes -NotePropertyValue ([byte[]](1,2,3,4)) -Force
    }

    It 'round-trips an unedited view-model into an equivalent candidate' {
        $vm    = ConvertTo-MetadataViewModel -Candidate $cand
        $back  = ConvertFrom-MetadataViewModel -ViewModel $vm
        $back.Album            | Should -Be $cand.Album
        $back.AlbumArtist      | Should -Be $cand.AlbumArtist
        $back.AlbumArtistMbid  | Should -Be $cand.AlbumArtistMbid
        $back.ReleaseMbid      | Should -Be $cand.ReleaseMbid
        $back.ReleaseGroupMbid | Should -Be $cand.ReleaseGroupMbid
        $back.Year             | Should -Be $cand.Year
        $back.Country          | Should -Be $cand.Country
        $back.HasCoverArt      | Should -Be $cand.HasCoverArt
        @($back.Tracks).Count  | Should -Be @($cand.Tracks).Count
    }

    It 'preserves CoverArtBytes from the source candidate' {
        $vm   = ConvertTo-MetadataViewModel -Candidate $cand
        $back = ConvertFrom-MetadataViewModel -ViewModel $vm
        $back.CoverArtBytes | Should -Not -BeNullOrEmpty
        ,$back.CoverArtBytes | Should -BeOfType [byte[]]
        $back.CoverArtBytes.Length | Should -Be 4
    }

    It 'applies edited Album / AlbumArtist / Year / IsCompilation' {
        $vm = ConvertTo-MetadataViewModel -Candidate $cand
        $vm.Album         = 'New Album Title'
        $vm.AlbumArtist   = 'New Artist'
        $vm.Year          = 1999
        $vm.IsCompilation = $true
        $back = ConvertFrom-MetadataViewModel -ViewModel $vm
        $back.Album         | Should -Be 'New Album Title'
        $back.AlbumArtist   | Should -Be 'New Artist'
        $back.Year          | Should -Be 1999
        $back.IsCompilation | Should -BeTrue
    }

    It 'applies edited per-track Title and Artist while preserving Length and MBIDs' {
        $vm = ConvertTo-MetadataViewModel -Candidate $cand
        $vm.Tracks[0].Title  = 'Edited Track 1'
        $vm.Tracks[0].Artist = 'Guest Star'
        $back = ConvertFrom-MetadataViewModel -ViewModel $vm
        $back.Tracks[0].Title         | Should -Be 'Edited Track 1'
        $back.Tracks[0].Artist        | Should -Be 'Guest Star'
        $back.Tracks[0].LengthMs      | Should -Be 67000
        $back.Tracks[0].RecordingMbid | Should -Be 'r01'
        # Untouched track stays as-is.
        $back.Tracks[1].Title         | Should -Be 'Breathe'
    }

    It 'treats a blank Year as $null (allows clearing the field)' {
        $vm = ConvertTo-MetadataViewModel -Candidate $cand
        $vm.Year = $null
        $back = ConvertFrom-MetadataViewModel -ViewModel $vm
        $back.Year | Should -BeNullOrEmpty
    }

    It 'preserves Picard-parity album fields from the source (regression: dialog used to drop them)' {
        $vm   = ConvertTo-MetadataViewModel -Candidate $cand
        $back = ConvertFrom-MetadataViewModel -ViewModel $vm
        # These are populated on the enriched mb-single-match.json fixture and
        # were silently dropped by ConvertFrom-MetadataViewModel pre-fix, so
        # rip-flow FLACs were missing the new Picard tags even though
        # New-RipperFlacTagSet knew how to emit them.
        $back.AlbumArtistSort | Should -Be $cand.AlbumArtistSort
        $back.ReleaseDate     | Should -Be $cand.ReleaseDate
        $back.OriginalDate    | Should -Be $cand.OriginalDate
        $back.OriginalYear    | Should -Be $cand.OriginalYear
        $back.ReleaseStatus   | Should -Be $cand.ReleaseStatus
        $back.ReleaseType     | Should -Be $cand.ReleaseType
        $back.Script          | Should -Be $cand.Script
        $back.Language        | Should -Be $cand.Language
        $back.Asin            | Should -Be $cand.Asin
        $back.Barcode         | Should -Be $cand.Barcode
        $back.LabelName       | Should -Be $cand.LabelName
        $back.CatalogNumber   | Should -Be $cand.CatalogNumber
    }

    It 'preserves per-track ArtistSort from the source (regression)' {
        $vm   = ConvertTo-MetadataViewModel -Candidate $cand
        $back = ConvertFrom-MetadataViewModel -ViewModel $vm
        for ($i = 0; $i -lt @($cand.Tracks).Count; $i++) {
            $back.Tracks[$i].ArtistSort | Should -Be $cand.Tracks[$i].ArtistSort
        }
    }
}

Describe 'Format-MetadataCandidateLabel' {

    BeforeAll {
        $script:cand = Load-Candidate 'mb-single-match.json' 'Wn8eRBtfLDfM0qjYPdxrz.Zjs_I-'
    }

    It 'renders Artist - Album (Year) [Country]' {
        Format-MetadataCandidateLabel -Candidate $cand |
            Should -Be 'Pink Floyd - The Dark Side of the Moon (1973) [US]'
    }

    It 'appends a (disc N/M) suffix on multi-disc releases' {
        $multi = $cand.PSObject.Copy()
        $multi.TotalDiscs = 2
        $multi.DiscNumber = 2
        Format-MetadataCandidateLabel -Candidate $multi |
            Should -Match '\(disc 2/2\)$'
    }
}
