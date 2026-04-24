<#
.SYNOPSIS
    Unit tests for the cover-art provider chain (Phase 5.2).

.DESCRIPTION
    Covers:
      - Get-RipperCoverArtChain dispatch logic (first-non-null wins,
        unknown providers warn, empty chain returns null).
      - Each provider's input-validation paths (skip when candidate
        lacks the keys the provider needs).

    Live HTTP calls (CAA / iTunes / Deezer) are NOT covered; those are
    exercised by manual ripping. We mock Invoke-WebRequest /
    Invoke-RestMethod via Pester's command mocking so the tests stay
    network-free and fast.
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'src\core\coverart\Get-CoverArt.ps1')
}

Describe 'Invoke-CoverArtArchiveProvider input validation' {

    It 'returns Bytes=$null when candidate has no ReleaseMbid' {
        $cand = [pscustomobject]@{ AlbumArtist='A'; Album='B' }
        $r = Invoke-CoverArtArchiveProvider -Candidate $cand
        $r.Source | Should -Be 'CoverArtArchive'
        $r.Bytes | Should -BeNullOrEmpty
        $r.Diagnostic | Should -Match 'ReleaseMbid'
    }

    It 'short-circuits when MB explicitly says HasCoverArt=$false' {
        $cand = [pscustomobject]@{ AlbumArtist='A'; Album='B'; ReleaseMbid='abc'; HasCoverArt=$false }
        $r = Invoke-CoverArtArchiveProvider -Candidate $cand
        $r.Bytes | Should -BeNullOrEmpty
        $r.Diagnostic | Should -Match 'no front art'
    }
}

Describe 'Invoke-ItunesSearchCoverArtProvider input validation' {

    It 'returns Bytes=$null when candidate has no AlbumArtist' {
        $cand = [pscustomobject]@{ Album='B' }
        $r = Invoke-ItunesSearchCoverArtProvider -Candidate $cand
        $r.Bytes | Should -BeNullOrEmpty
        $r.Diagnostic | Should -Match 'AlbumArtist'
    }

    It 'returns Bytes=$null when candidate has no Album' {
        $cand = [pscustomobject]@{ AlbumArtist='A' }
        $r = Invoke-ItunesSearchCoverArtProvider -Candidate $cand
        $r.Bytes | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-DeezerCoverArtProvider input validation' {

    It 'returns Bytes=$null when candidate has no AlbumArtist' {
        $cand = [pscustomobject]@{ Album='B' }
        $r = Invoke-DeezerCoverArtProvider -Candidate $cand
        $r.Bytes | Should -BeNullOrEmpty
    }
}

Describe 'Get-RipperCoverArtChain dispatch' {

    BeforeEach {
        $script:cand = [pscustomobject]@{
            AlbumArtist='Pink Floyd'; Album='Dark Side'; ReleaseMbid='mb-id'; HasCoverArt=$true
        }
    }

    It 'returns the bytes from the first provider that produces them (CAA)' {
        Mock Invoke-CoverArtArchiveProvider {
            [pscustomobject]@{ Source='CoverArtArchive'; Bytes=[byte[]]@(1,2,3); Url='caa-url'; Diagnostic=$null }
        }
        Mock Invoke-ItunesSearchCoverArtProvider {
            throw 'should not be called when CAA succeeded'
        }
        Mock Invoke-DeezerCoverArtProvider {
            throw 'should not be called when CAA succeeded'
        }

        $bytes = Get-RipperCoverArtChain -Candidate $script:cand -Providers @('CoverArtArchive','iTunesSearch','Deezer')
        $bytes | Should -Be ([byte[]]@(1,2,3))
        Should -Invoke Invoke-CoverArtArchiveProvider     -Times 1
        Should -Invoke Invoke-ItunesSearchCoverArtProvider -Times 0
        Should -Invoke Invoke-DeezerCoverArtProvider       -Times 0
    }

    It 'falls through to iTunes when CAA returns Bytes=$null' {
        Mock Invoke-CoverArtArchiveProvider {
            [pscustomobject]@{ Source='CoverArtArchive'; Bytes=$null; Url='caa-url'; Diagnostic='404' }
        }
        Mock Invoke-ItunesSearchCoverArtProvider {
            [pscustomobject]@{ Source='iTunesSearch'; Bytes=[byte[]]@(9,9); Url='itunes-url'; Diagnostic=$null }
        }
        Mock Invoke-DeezerCoverArtProvider {
            throw 'should not be called when iTunes succeeded'
        }

        $bytes = Get-RipperCoverArtChain -Candidate $script:cand -Providers @('CoverArtArchive','iTunesSearch','Deezer')
        $bytes | Should -Be ([byte[]]@(9,9))
        Should -Invoke Invoke-DeezerCoverArtProvider -Times 0
    }

    It 'falls through to Deezer when CAA + iTunes both come up empty' {
        Mock Invoke-CoverArtArchiveProvider {
            [pscustomobject]@{ Source='CoverArtArchive'; Bytes=$null; Url=$null; Diagnostic=$null }
        }
        Mock Invoke-ItunesSearchCoverArtProvider {
            [pscustomobject]@{ Source='iTunesSearch'; Bytes=$null; Url=$null; Diagnostic=$null }
        }
        Mock Invoke-DeezerCoverArtProvider {
            [pscustomobject]@{ Source='Deezer'; Bytes=[byte[]]@(7); Url='dz-url'; Diagnostic=$null }
        }

        $bytes = Get-RipperCoverArtChain -Candidate $script:cand -Providers @('CoverArtArchive','iTunesSearch','Deezer')
        $bytes | Should -Be ([byte[]]@(7))
    }

    It 'returns $null when every provider in the chain returns Bytes=$null' {
        Mock Invoke-CoverArtArchiveProvider     { [pscustomobject]@{ Source='CoverArtArchive'; Bytes=$null; Url=$null; Diagnostic=$null } }
        Mock Invoke-ItunesSearchCoverArtProvider { [pscustomobject]@{ Source='iTunesSearch';    Bytes=$null; Url=$null; Diagnostic=$null } }
        Mock Invoke-DeezerCoverArtProvider       { [pscustomobject]@{ Source='Deezer';          Bytes=$null; Url=$null; Diagnostic=$null } }

        $bytes = Get-RipperCoverArtChain -Candidate $script:cand -Providers @('CoverArtArchive','iTunesSearch','Deezer')
        $bytes | Should -BeNullOrEmpty
    }

    It 'honors a custom provider order' {
        # Put Deezer FIRST and have it succeed; CAA must NOT be called.
        Mock Invoke-CoverArtArchiveProvider { throw 'should not be called when Deezer is first and succeeds' }
        Mock Invoke-DeezerCoverArtProvider {
            [pscustomobject]@{ Source='Deezer'; Bytes=[byte[]]@(5,5); Url='dz'; Diagnostic=$null }
        }

        $bytes = Get-RipperCoverArtChain -Candidate $script:cand -Providers @('Deezer','CoverArtArchive')
        $bytes | Should -Be ([byte[]]@(5,5))
        Should -Invoke Invoke-CoverArtArchiveProvider -Times 0
    }

    It 'skips unknown provider names without throwing' {
        Mock Invoke-CoverArtArchiveProvider {
            [pscustomobject]@{ Source='CoverArtArchive'; Bytes=[byte[]]@(1); Url='caa'; Diagnostic=$null }
        }
        $bytes = Get-RipperCoverArtChain -Candidate $script:cand -Providers @('NotARealProvider','CoverArtArchive')
        $bytes | Should -Be ([byte[]]@(1))
    }
}

Describe 'Get-RipperCoverArtCandidates (picker: all providers, not short-circuit)' {

    BeforeEach {
        $script:cand = [pscustomobject]@{
            AlbumArtist='Pink Floyd'; Album='Dark Side'; ReleaseMbid='mb-id'; HasCoverArt=$true
        }
    }

    It 'invokes every provider in the list even when earlier ones succeed' {
        Mock Invoke-CoverArtArchiveProvider     { [pscustomobject]@{ Source='CoverArtArchive'; Bytes=[byte[]]@(1,2); Url='caa'; Diagnostic=$null } }
        Mock Invoke-ItunesSearchCoverArtProvider { [pscustomobject]@{ Source='iTunesSearch';    Bytes=[byte[]]@(3,4); Url='it';  Diagnostic=$null } }
        Mock Invoke-DeezerCoverArtProvider       { [pscustomobject]@{ Source='Deezer';          Bytes=[byte[]]@(5,6); Url='dz';  Diagnostic=$null } }

        $results = Get-RipperCoverArtCandidates -Candidate $script:cand -Providers @('CoverArtArchive','iTunesSearch','Deezer')
        @($results).Count | Should -Be 3
        Should -Invoke Invoke-CoverArtArchiveProvider     -Times 1
        Should -Invoke Invoke-ItunesSearchCoverArtProvider -Times 1
        Should -Invoke Invoke-DeezerCoverArtProvider       -Times 1
    }

    It 'returns one entry per provider, in the given order, even when some return Bytes=$null' {
        Mock Invoke-CoverArtArchiveProvider     { [pscustomobject]@{ Source='CoverArtArchive'; Bytes=$null;         Url=$null; Diagnostic='404' } }
        Mock Invoke-ItunesSearchCoverArtProvider { [pscustomobject]@{ Source='iTunesSearch';    Bytes=[byte[]]@(9,9); Url='it';  Diagnostic=$null } }
        Mock Invoke-DeezerCoverArtProvider       { [pscustomobject]@{ Source='Deezer';          Bytes=$null;         Url=$null; Diagnostic='no match' } }

        $results = @(Get-RipperCoverArtCandidates -Candidate $script:cand -Providers @('CoverArtArchive','iTunesSearch','Deezer'))
        $results.Count | Should -Be 3
        $results[0].Source | Should -Be 'CoverArtArchive'
        $results[0].Bytes  | Should -BeNullOrEmpty
        $results[1].Source | Should -Be 'iTunesSearch'
        $results[1].Bytes  | Should -Be ([byte[]]@(9,9))
        $results[2].Source | Should -Be 'Deezer'
        $results[2].Bytes  | Should -BeNullOrEmpty
    }

    It 'continues past a throwing provider and records the error in the diagnostic' {
        Mock Invoke-CoverArtArchiveProvider     { throw 'network exploded' }
        Mock Invoke-ItunesSearchCoverArtProvider { [pscustomobject]@{ Source='iTunesSearch'; Bytes=[byte[]]@(7); Url='it'; Diagnostic=$null } }

        $results = @(Get-RipperCoverArtCandidates -Candidate $script:cand -Providers @('CoverArtArchive','iTunesSearch'))
        $results.Count | Should -Be 2
        $results[0].Source     | Should -Be 'CoverArtArchive'
        $results[0].Bytes      | Should -BeNullOrEmpty
        $results[0].Diagnostic | Should -Match 'network exploded'
        $results[1].Bytes      | Should -Be ([byte[]]@(7))
    }

    It 'emits a WARN-style entry for unknown provider names instead of throwing' {
        $results = @(Get-RipperCoverArtCandidates -Candidate $script:cand -Providers @('NotARealProvider'))
        $results.Count | Should -Be 1
        $results[0].Source     | Should -Be 'NotARealProvider'
        $results[0].Bytes      | Should -BeNullOrEmpty
        $results[0].Diagnostic | Should -Match 'Unknown provider'
    }
}
