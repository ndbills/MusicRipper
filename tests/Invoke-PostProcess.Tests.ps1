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
    function script:Move-RipToLibrary { param($RipFolder,$LibraryRoot,$Metadata,$Quality,$DiscId,[switch]$AllowSideBySide) }
    function script:Write-RipperReviewTxt { param($ReviewFolder,$Quality,$Metadata,$DiscId,$LogFileName) }
    function script:New-RipperReviewImage { param($ReviewFolder,$Metadata,$DiscId) }
    function script:Add-RipperLibraryDiscIndexEntry { param($LibraryRoot,$DiscId,$Path,$Label,$Source) }
    function script:Invoke-RipperSync { param($AlbumPath,$LibraryRoot,$DiscId,$Config) }
    function script:Invoke-RipperLibraryRetention { param($AlbumPath,$LibraryRoot,$Config,$SyncResult,$DiscId) }

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
                IsSideBySide  = $false
                FilesMoved    = 5
            }
        }
        Mock -CommandName Write-RipperReviewTxt    -MockWith { $null }
        Mock -CommandName New-RipperReviewImage    -MockWith { $null }
        Mock -CommandName Add-RipperLibraryDiscIndexEntry -MockWith { $null }
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

    It 'records the rip in the cross-session DiscId index (Phase 5.8)' {
        Invoke-RipperPostProcess -RipFolder 'C:\rip' -LogFile 'C:\rip\album.log' `
            -Metadata (New-FakeMetadata) -DiscId 'discABC' -LibraryRoot 'C:\Library' | Out-Null
        Should -Invoke -CommandName Add-RipperLibraryDiscIndexEntry -Times 1 -Exactly -ParameterFilter {
            $DiscId -eq 'discABC' -and
            $Path -eq 'C:\Library\Mormon Tabernacle Choir\Spirit of the Season (2007)' -and
            $Label -eq 'Mormon Tabernacle Choir - Spirit of the Season (2007)' -and
            $Source -eq 'library'
        }
    }

    It 'forwards -AllowSideBySide to Move-RipToLibrary' {
        Invoke-RipperPostProcess -RipFolder 'C:\rip' -LogFile 'C:\rip\album.log' `
            -Metadata (New-FakeMetadata) -DiscId 'discABC' -LibraryRoot 'C:\Library' `
            -AllowSideBySide | Out-Null
        Should -Invoke -CommandName Move-RipToLibrary -Times 1 -Exactly -ParameterFilter {
            $AllowSideBySide -eq $true
        }
    }

    It 'swallows index-write failures (best effort)' {
        Mock -CommandName Add-RipperLibraryDiscIndexEntry -MockWith { throw 'simulated NAS write failure' }
        { Invoke-RipperPostProcess -RipFolder 'C:\rip' -LogFile 'C:\rip\album.log' `
            -Metadata (New-FakeMetadata) -DiscId 'discABC' -LibraryRoot 'C:\Library' } |
            Should -Not -Throw
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
                IsSideBySide  = $false
                FilesMoved    = 5
            }
        }
        Mock -CommandName Write-RipperReviewTxt    -MockWith { $null }
        Mock -CommandName New-RipperReviewImage    -MockWith { $null }
        Mock -CommandName Add-RipperLibraryDiscIndexEntry -MockWith { $null }
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

    It 'does NOT index review-queue rips (Phase 5.8)' {
        Invoke-RipperPostProcess -RipFolder 'C:\rip' -LogFile 'C:\rip\album.log' `
            -Metadata (New-FakeMetadata) -DiscId 'discABC' -LibraryRoot 'C:\Library' | Out-Null
        Should -Invoke -CommandName Add-RipperLibraryDiscIndexEntry -Times 0 -Exactly
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

Describe 'Invoke-RipperPostProcess (-ForceReviewQueue, Phase 5.9)' {
    BeforeEach {
        # Quality gate says Verified/Library — exactly the case where
        # ForceReviewQueue must override and route to ReviewQueue.
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
                Target        = 'C:\Library\_ReviewQueue\USER-REVIEW - Mormon Tabernacle Choir - Spirit of the Season - discABC'
                IsReviewQueue = $true
                IsSideBySide  = $false
                FilesMoved    = 5
            }
        }
        Mock -CommandName Write-RipperReviewTxt          -MockWith { $null }
        Mock -CommandName New-RipperReviewImage          -MockWith { $null }
        Mock -CommandName Add-RipperLibraryDiscIndexEntry -MockWith { $null }
    }

    It 'overrides quality-gate routing to ReviewQueue with USER-REVIEW prefix' {
        Invoke-RipperPostProcess -RipFolder 'C:\rip' -LogFile 'C:\rip\album.log' `
            -Metadata (New-FakeMetadata) -DiscId 'discABC' -LibraryRoot 'C:\Library' `
            -ForceReviewQueue | Out-Null
        Should -Invoke -CommandName Move-RipToLibrary -Times 1 -Exactly -ParameterFilter {
            $Quality.Destination -eq 'ReviewQueue' -and $Quality.RoutingPrefix -eq 'USER-REVIEW'
        }
    }

    It 'skips library tagging when forced to review' {
        Invoke-RipperPostProcess -RipFolder 'C:\rip' -LogFile 'C:\rip\album.log' `
            -Metadata (New-FakeMetadata) -DiscId 'discABC' -LibraryRoot 'C:\Library' `
            -ForceReviewQueue | Out-Null
        Should -Invoke -CommandName Invoke-RipperWriteTags -Times 0 -Exactly
    }

    It 'emits review artifacts (REVIEW.txt + single-file image)' {
        Invoke-RipperPostProcess -RipFolder 'C:\rip' -LogFile 'C:\rip\album.log' `
            -Metadata (New-FakeMetadata) -DiscId 'discABC' -LibraryRoot 'C:\Library' `
            -ForceReviewQueue | Out-Null
        Should -Invoke -CommandName Write-RipperReviewTxt -Times 1 -Exactly
        Should -Invoke -CommandName New-RipperReviewImage -Times 1 -Exactly
    }

    It 'does NOT add the disc to the cross-session DiscId index' {
        Invoke-RipperPostProcess -RipFolder 'C:\rip' -LogFile 'C:\rip\album.log' `
            -Metadata (New-FakeMetadata) -DiscId 'discABC' -LibraryRoot 'C:\Library' `
            -ForceReviewQueue | Out-Null
        Should -Invoke -CommandName Add-RipperLibraryDiscIndexEntry -Times 0 -Exactly
    }

    It 'does not double-override when quality already routed to ReviewQueue' {
        # Suspect rip + ForceReviewQueue: keep the original SUSPECT prefix,
        # don't replace it with USER-REVIEW (the auto-routing reason is
        # more useful to the human triaging the queue).
        Mock -CommandName Test-RipQuality -MockWith {
            [pscustomobject]@{
                Status        = 'Suspect'
                Destination   = 'ReviewQueue'
                RoutingPrefix = 'SUSPECT'
            }
        }
        Invoke-RipperPostProcess -RipFolder 'C:\rip' -LogFile 'C:\rip\album.log' `
            -Metadata (New-FakeMetadata) -DiscId 'discABC' -LibraryRoot 'C:\Library' `
            -ForceReviewQueue | Out-Null
        Should -Invoke -CommandName Move-RipToLibrary -Times 1 -Exactly -ParameterFilter {
            $Quality.RoutingPrefix -eq 'SUSPECT'
        }
    }
}

Describe 'Invoke-RipperPostProcess (Phase 6.1 sync wiring)' {
    BeforeEach {
        Mock -CommandName Test-RipQuality -MockWith {
            [pscustomobject]@{ Status='Verified'; Destination='Library'; RoutingPrefix='' }
        }
        Mock -CommandName Invoke-RipperWriteTags -MockWith { $null }
        Mock -CommandName Move-RipToLibrary -MockWith {
            @{
                Target='C:\Library\A\B (2020)'; IsReviewQueue=$false; IsSideBySide=$false; FilesMoved=5
            }
        }
        Mock -CommandName Write-RipperReviewTxt          -MockWith { $null }
        Mock -CommandName New-RipperReviewImage          -MockWith { $null }
        Mock -CommandName Add-RipperLibraryDiscIndexEntry -MockWith { $null }
        Mock -CommandName Invoke-RipperSync -MockWith {
            @{ AlbumPath=$AlbumPath; Targets=@(@{Target='Stub';Status='OK';BytesCopied=10;Diagnostic=$null}); AllOk=$true; Skipped=$false }
        }
        Mock -CommandName Invoke-RipperLibraryRetention -MockWith {
            @{ Action='None'; Reason='LocalRetention=Keep'; NewPath=$null }
        }
    }

    It 'does NOT call Invoke-RipperSync when -Config is omitted (back-compat)' {
        Invoke-RipperPostProcess -RipFolder 'C:\rip' -LogFile 'C:\rip\album.log' `
            -Metadata (New-FakeMetadata) -DiscId 'discABC' -LibraryRoot 'C:\Library' | Out-Null
        Should -Invoke -CommandName Invoke-RipperSync             -Times 0 -Exactly
        Should -Invoke -CommandName Invoke-RipperLibraryRetention -Times 0 -Exactly
    }

    It 'calls sync + retention when -Config supplied on a Library route' {
        $cfg = [pscustomobject]@{ SyncTargets=@('Stub'); LocalRetention='Keep' }
        $r = Invoke-RipperPostProcess -RipFolder 'C:\rip' -LogFile 'C:\rip\album.log' `
            -Metadata (New-FakeMetadata) -DiscId 'discABC' -LibraryRoot 'C:\Library' `
            -Config $cfg
        Should -Invoke -CommandName Invoke-RipperSync             -Times 1 -Exactly
        Should -Invoke -CommandName Invoke-RipperLibraryRetention -Times 1 -Exactly
        $r.Sync.AllOk            | Should -BeTrue
        $r.Retention.Action      | Should -Be 'None'
    }

    It 'skips retention when sync was a no-op (Skipped=$true)' {
        Mock -CommandName Invoke-RipperSync -MockWith {
            @{ AlbumPath=$AlbumPath; Targets=@(); AllOk=$true; Skipped=$true }
        }
        Invoke-RipperPostProcess -RipFolder 'C:\rip' -LogFile 'C:\rip\album.log' `
            -Metadata (New-FakeMetadata) -DiscId 'discABC' -LibraryRoot 'C:\Library' `
            -Config ([pscustomobject]@{ SyncTargets=@(); LocalRetention='RecycleAfterAllSynced' }) | Out-Null
        Should -Invoke -CommandName Invoke-RipperLibraryRetention -Times 0 -Exactly
    }

    It 'reports the new _Sent path as Target when retention moved the album' {
        Mock -CommandName Invoke-RipperLibraryRetention -MockWith {
            @{ Action='MovedToSent'; Reason='All targets OK'; NewPath='C:\Library\_Sent\A\B (2020)' }
        }
        $r = Invoke-RipperPostProcess -RipFolder 'C:\rip' -LogFile 'C:\rip\album.log' `
            -Metadata (New-FakeMetadata) -DiscId 'discABC' -LibraryRoot 'C:\Library' `
            -Config ([pscustomobject]@{ SyncTargets=@('Stub'); LocalRetention='MoveToSentAfterAllSynced' })
        $r.Target           | Should -Be 'C:\Library\_Sent\A\B (2020)'
        $r.Move.Target      | Should -Be 'C:\Library\A\B (2020)'   # original move target preserved
    }

    It 'does NOT sync review-queue routes' {
        Mock -CommandName Test-RipQuality -MockWith {
            [pscustomobject]@{ Status='Suspect'; Destination='ReviewQueue'; RoutingPrefix='SUSPECT' }
        }
        Mock -CommandName Move-RipToLibrary -MockWith {
            @{ Target='C:\Library\_ReviewQueue\SUSPECT - x'; IsReviewQueue=$true; IsSideBySide=$false; FilesMoved=5 }
        }
        Invoke-RipperPostProcess -RipFolder 'C:\rip' -LogFile 'C:\rip\album.log' `
            -Metadata (New-FakeMetadata) -DiscId 'discABC' -LibraryRoot 'C:\Library' `
            -Config ([pscustomobject]@{ SyncTargets=@('Stub'); LocalRetention='Keep' }) | Out-Null
        Should -Invoke -CommandName Invoke-RipperSync             -Times 0 -Exactly
        Should -Invoke -CommandName Invoke-RipperLibraryRetention -Times 0 -Exactly
    }

    It 'swallows a sync orchestrator exception (rip stays in library)' {
        Mock -CommandName Invoke-RipperSync -MockWith { throw 'simulated' }
        { Invoke-RipperPostProcess -RipFolder 'C:\rip' -LogFile 'C:\rip\album.log' `
            -Metadata (New-FakeMetadata) -DiscId 'discABC' -LibraryRoot 'C:\Library' `
            -Config ([pscustomobject]@{ SyncTargets=@('Stub'); LocalRetention='Keep' }) } |
            Should -Not -Throw
    }
}
