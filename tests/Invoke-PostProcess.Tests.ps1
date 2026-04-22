<#
    Pester tests for src/core/Invoke-PostProcess.ps1.

    Invoke-RipperPostProcess is pure orchestration: quality-gate routing
    decides whether to tag, where to move, and whether to emit review
    artifacts. We mock the five wrapped functions and assert call shape +
    return shape — the wrapped functions have their own dedicated suites.

    Run: Invoke-Pester ./tests/Invoke-PostProcess.Tests.ps1
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force

    # Pester 5's Mock requires the target command to exist before it can be
    # mocked. Define lightweight stubs in script scope BEFORE dot-sourcing
    # Invoke-PostProcess so the call sites resolve. Per-Describe `Mock`
    # then overrides them with the route-specific behavior.
    function script:Test-RipQuality { param($LogPath) }
    function script:Invoke-RipperWriteTags { param($RipFolder,$Metadata,$DiscId,$CoverArtBytes) }
    function script:Move-RipToLibrary { param($RipFolder,$LibraryRoot,$Metadata,$Quality,$DiscId) }
    function script:Write-RipperReviewTxt { param($ReviewFolder,$Quality,$Metadata,$DiscId,$LogFileName) }
    function script:New-RipperReviewImage { param($ReviewFolder,$Metadata,$DiscId) }

    . (Join-Path $repoRoot 'src\core\Invoke-PostProcess.ps1')

    function script:New-FakeMetadata {
        [pscustomobject]@{
            AlbumArtist = 'Mormon Tabernacle Choir'
            Album       = 'Spirit of the Season'
            Year        = 2007
            DiscNumber  = 1
            TotalDiscs  = 1
        }
    }

    Start-RipperLog -Context 'invoke-postprocess-tests' | Out-Null
}

AfterAll {
    Stop-RipperLog
}

Describe 'Invoke-RipperPostProcess (library route)' {
    BeforeEach {
        # Per-test mocks: library-bound rip.
        Mock -CommandName Test-RipQuality -MockWith {
            [pscustomobject]@{
                Status        = 'Verified'
                Destination   = 'Library'
                RoutingPrefix = ''
            }
        }
        Mock -CommandName Invoke-RipperWriteTags -MockWith { $null }
        Mock -CommandName Move-RipToLibrary -MockWith {
            @{
                Target        = 'C:\Library\Mormon Tabernacle Choir\Spirit of the Season (2007)'
                IsReviewQueue = $false
                FilesMoved    = 5
            }
        }
        Mock -CommandName Write-RipperReviewTxt    -MockWith { $null }
        Mock -CommandName New-RipperReviewImage    -MockWith { $null }
    }

    It 'returns Quality, Move, Target, IsReviewQueue' {
        $r = Invoke-RipperPostProcess -RipFolder 'C:\rip' -LogFile 'C:\rip\album.log' `
            -Metadata (New-FakeMetadata) -DiscId 'discABC' -LibraryRoot 'C:\Library'
        $r              | Should -BeOfType [hashtable]
        $r.Quality      | Should -Not -BeNullOrEmpty
        $r.Move         | Should -Not -BeNullOrEmpty
        $r.Target       | Should -Be 'C:\Library\Mormon Tabernacle Choir\Spirit of the Season (2007)'
        $r.IsReviewQueue | Should -BeFalse
    }

    It 'tags the rip when destination is Library' {
        Invoke-RipperPostProcess -RipFolder 'C:\rip' -LogFile 'C:\rip\album.log' `
            -Metadata (New-FakeMetadata) -DiscId 'discABC' -LibraryRoot 'C:\Library' | Out-Null
        Should -Invoke -CommandName Invoke-RipperWriteTags -Times 1 -Exactly
    }

    It 'does NOT emit review artifacts on the library route' {
        Invoke-RipperPostProcess -RipFolder 'C:\rip' -LogFile 'C:\rip\album.log' `
            -Metadata (New-FakeMetadata) -DiscId 'discABC' -LibraryRoot 'C:\Library' | Out-Null
        Should -Invoke -CommandName Write-RipperReviewTxt -Times 0 -Exactly
        Should -Invoke -CommandName New-RipperReviewImage -Times 0 -Exactly
    }

    It 'forwards CoverArtBytes to Invoke-RipperWriteTags when CoverArtFile exists' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) "ipp-cover-$([guid]::NewGuid()).jpg"
        [byte[]]$bytes = 1,2,3,4,5,6,7,8
        [IO.File]::WriteAllBytes($tmp, $bytes)
        try {
            Invoke-RipperPostProcess -RipFolder 'C:\rip' -LogFile 'C:\rip\album.log' `
                -Metadata (New-FakeMetadata) -DiscId 'discABC' -LibraryRoot 'C:\Library' `
                -CoverArtFile $tmp | Out-Null
            Should -Invoke -CommandName Invoke-RipperWriteTags -Times 1 -Exactly -ParameterFilter {
                $CoverArtBytes -and $CoverArtBytes.Length -eq 8
            }
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It 'omits CoverArtBytes when CoverArtFile is missing on disk' {
        $bogus = Join-Path ([IO.Path]::GetTempPath()) "ipp-missing-$([guid]::NewGuid()).jpg"
        Invoke-RipperPostProcess -RipFolder 'C:\rip' -LogFile 'C:\rip\album.log' `
            -Metadata (New-FakeMetadata) -DiscId 'discABC' -LibraryRoot 'C:\Library' `
            -CoverArtFile $bogus | Out-Null
        Should -Invoke -CommandName Invoke-RipperWriteTags -Times 1 -Exactly -ParameterFilter {
            -not $PSBoundParameters.ContainsKey('CoverArtBytes')
        }
    }
}

Describe 'Invoke-RipperPostProcess (review route)' {
    BeforeEach {
        Mock -CommandName Test-RipQuality -MockWith {
            [pscustomobject]@{
                Status        = 'Suspect'
                Destination   = 'ReviewQueue'
                RoutingPrefix = 'SUSPECT'
            }
        }
        Mock -CommandName Invoke-RipperWriteTags -MockWith { $null }
        Mock -CommandName Move-RipToLibrary -MockWith {
            @{
                Target        = 'C:\Library\_ReviewQueue\SUSPECT - X - Y - z'
                IsReviewQueue = $true
                FilesMoved    = 5
            }
        }
        Mock -CommandName Write-RipperReviewTxt    -MockWith { $null }
        Mock -CommandName New-RipperReviewImage    -MockWith { $null }
    }

    It 'reports IsReviewQueue=$true and the review-queue target' {
        $r = Invoke-RipperPostProcess -RipFolder 'C:\rip' -LogFile 'C:\rip\album.log' `
            -Metadata (New-FakeMetadata) -DiscId 'discABC' -LibraryRoot 'C:\Library'
        $r.IsReviewQueue | Should -BeTrue
        $r.Target        | Should -Match '_ReviewQueue'
    }

    It 'skips tagging on the review route (raw rip preserved)' {
        Invoke-RipperPostProcess -RipFolder 'C:\rip' -LogFile 'C:\rip\album.log' `
            -Metadata (New-FakeMetadata) -DiscId 'discABC' -LibraryRoot 'C:\Library' | Out-Null
        Should -Invoke -CommandName Invoke-RipperWriteTags -Times 0 -Exactly
    }

    It 'emits REVIEW.txt and the single-file image' {
        Invoke-RipperPostProcess -RipFolder 'C:\rip' -LogFile 'C:\rip\album.log' `
            -Metadata (New-FakeMetadata) -DiscId 'discABC' -LibraryRoot 'C:\Library' | Out-Null
        Should -Invoke -CommandName Write-RipperReviewTxt -Times 1 -Exactly
        Should -Invoke -CommandName New-RipperReviewImage -Times 1 -Exactly
    }

    It 'passes the log filename (not full path) to Write-RipperReviewTxt' {
        Invoke-RipperPostProcess -RipFolder 'C:\rip' -LogFile 'C:\rip\My Album.log' `
            -Metadata (New-FakeMetadata) -DiscId 'discABC' -LibraryRoot 'C:\Library' | Out-Null
        Should -Invoke -CommandName Write-RipperReviewTxt -Times 1 -Exactly -ParameterFilter {
            $LogFileName -eq 'My Album.log'
        }
    }
}

Describe 'Invoke-RipperPostProcess (failure surface)' {
    It 'propagates exceptions from the pipeline (caller owns UI/eject)' {
        Mock -CommandName Test-RipQuality -MockWith { throw 'simulated quality-gate failure' }
        { Invoke-RipperPostProcess -RipFolder 'C:\rip' -LogFile 'C:\rip\album.log' `
            -Metadata (New-FakeMetadata) -DiscId 'discABC' -LibraryRoot 'C:\Library' } |
            Should -Throw -ExpectedMessage '*simulated quality-gate failure*'
    }
}
