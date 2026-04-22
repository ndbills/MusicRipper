#requires -Version 7.0
#requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

<#
.SYNOPSIS
    Pester tests for src/core/Resume.ps1 — sidecar I/O + orphan scanning +
    Resume-RipperOrphan replay.
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force

    # Stub the Invoke-RipperPostProcess dependency BEFORE dot-sourcing
    # Resume.ps1 — Pester 5's Mock can only override commands that already
    # exist in scope. Same pattern used in Invoke-PostProcess.Tests.ps1.
    function script:Invoke-RipperPostProcess {
        param($RipFolder, $LogFile, $Metadata, $DiscId, $LibraryRoot, $CoverArtFile)
    }

    . (Join-Path $repoRoot 'src\core\Resume.ps1')

    $script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("resume-tests-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

    function New-FakeRipFolder {
        param(
            [Parameter(Mandatory)] [string] $Parent,
            [Parameter(Mandatory)] [string] $Name,
            [switch] $WithCover,
            [switch] $WithLog
        )
        $f = Join-Path $Parent $Name
        New-Item -ItemType Directory -Path $f -Force | Out-Null
        if ($WithLog)   { Set-Content -LiteralPath (Join-Path $f 'rip.log')   -Value 'fake log' -Encoding UTF8 }
        if ($WithCover) { [System.IO.File]::WriteAllBytes((Join-Path $f 'cover.jpg'), [byte[]](1,2,3)) }
        $f
    }

    function New-SampleMetadata {
        [pscustomobject]@{
            DiscId      = 'TESTDISCID-abc123'
            AlbumArtist = 'Test Artist'
            Album       = 'Test Album'
            Year        = 2026
            TrackCount  = 2
            Tracks      = @(
                [pscustomobject]@{ Number = 1; Title = 'One'; Duration = 240 }
                [pscustomobject]@{ Number = 2; Title = 'Two'; Duration = 180 }
            )
        }
    }
}

AfterAll {
    if ($script:tmpRoot -and (Test-Path -LiteralPath $script:tmpRoot)) {
        Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Write-/Read-RipperRipState (sidecar round-trip)' {
    It 'writes _ripper-state.json and round-trips via Read-RipperRipState' {
        $folder = New-FakeRipFolder -Parent $tmpRoot -Name 'rt-1' -WithLog -WithCover
        $meta   = New-SampleMetadata

        $path = Write-RipperRipState `
            -RipFolder        $folder `
            -DiscId           'TESTDISCID-abc123' `
            -Metadata         $meta `
            -LogFileName      'rip.log' `
            -CoverArtFileName 'cover.jpg'

        Test-Path -LiteralPath $path | Should -BeTrue
        (Split-Path -Leaf $path) | Should -Be '_ripper-state.json'

        $state = Read-RipperRipState -RipFolder $folder
        $state.Version          | Should -Be 1
        $state.DiscId           | Should -Be 'TESTDISCID-abc123'
        $state.LogFileName      | Should -Be 'rip.log'
        $state.CoverArtFileName | Should -Be 'cover.jpg'
        $state.Metadata.AlbumArtist | Should -Be 'Test Artist'
        $state.Metadata.Tracks.Count | Should -Be 2
        $state.Metadata.Tracks[1].Title | Should -Be 'Two'
        # RipFinishedUtc is ISO-8601 round-trip (sortable).
        { [datetime]::Parse($state.RipFinishedUtc) } | Should -Not -Throw
    }

    It 'omits CoverArtFileName when not supplied' {
        $folder = New-FakeRipFolder -Parent $tmpRoot -Name 'no-cover' -WithLog
        Write-RipperRipState -RipFolder $folder -DiscId 'D' -Metadata (New-SampleMetadata) -LogFileName 'rip.log' | Out-Null

        $state = Read-RipperRipState -RipFolder $folder
        # Property exists (we always emit it as null) but value is empty.
        [string]::IsNullOrEmpty($state.CoverArtFileName) | Should -BeTrue
    }

    It 'Read-RipperRipState returns $null when there is no sidecar' {
        $folder = New-FakeRipFolder -Parent $tmpRoot -Name 'empty' -WithLog
        Read-RipperRipState -RipFolder $folder | Should -BeNullOrEmpty
    }

    It 'Read-RipperRipState throws on schema-version mismatch' {
        $folder = New-FakeRipFolder -Parent $tmpRoot -Name 'badver' -WithLog
        $bad = @{ Version = 999; DiscId = 'D'; Metadata = @{}; LogFileName = 'rip.log' } | ConvertTo-Json
        [System.IO.File]::WriteAllText((Join-Path $folder '_ripper-state.json'), $bad)
        { Read-RipperRipState -RipFolder $folder } | Should -Throw -ExpectedMessage '*version*'
    }

    It 'Read-RipperRipState throws on missing required property' {
        $folder = New-FakeRipFolder -Parent $tmpRoot -Name 'badshape' -WithLog
        $bad = @{ Version = 1; DiscId = 'D' } | ConvertTo-Json   # missing Metadata + LogFileName
        [System.IO.File]::WriteAllText((Join-Path $folder '_ripper-state.json'), $bad)
        { Read-RipperRipState -RipFolder $folder } | Should -Throw -ExpectedMessage "*missing required property*"
    }

    It 'Remove-RipperRipState is idempotent' {
        $folder = New-FakeRipFolder -Parent $tmpRoot -Name 'rm' -WithLog
        Write-RipperRipState -RipFolder $folder -DiscId 'D' -Metadata (New-SampleMetadata) -LogFileName 'rip.log' | Out-Null
        Remove-RipperRipState -RipFolder $folder
        Test-Path -LiteralPath (Join-Path $folder '_ripper-state.json') | Should -BeFalse
        # Second call is a no-op, must not throw.
        { Remove-RipperRipState -RipFolder $folder } | Should -Not -Throw
    }

    It 'Write-RipperRipState throws when RipFolder does not exist' {
        $missing = Join-Path $tmpRoot 'does-not-exist'
        { Write-RipperRipState -RipFolder $missing -DiscId 'D' -Metadata (New-SampleMetadata) -LogFileName 'rip.log' } |
            Should -Throw -ExpectedMessage '*RipFolder not found*'
    }
}

Describe 'Find-RipperOrphanedRips' {
    It 'returns only inbox folders with a sidecar' {
        $libRoot = Join-Path $tmpRoot ("lib-find-" + [guid]::NewGuid())
        $inbox   = Join-Path $libRoot '_inbox'
        New-Item -ItemType Directory -Path $inbox -Force | Out-Null

        $orphan1 = New-FakeRipFolder -Parent $inbox -Name 'A - Album1' -WithLog
        $orphan2 = New-FakeRipFolder -Parent $inbox -Name 'B - Album2' -WithLog -WithCover
        $clean   = New-FakeRipFolder -Parent $inbox -Name 'C - InProgress' -WithLog  # no sidecar

        Write-RipperRipState -RipFolder $orphan1 -DiscId 'D1' -Metadata (New-SampleMetadata) -LogFileName 'rip.log' | Out-Null
        Write-RipperRipState -RipFolder $orphan2 -DiscId 'D2' -Metadata (New-SampleMetadata) -LogFileName 'rip.log' -CoverArtFileName 'cover.jpg' | Out-Null

        $found = @(Find-RipperOrphanedRips -LibraryRoot $libRoot)
        $found.Count | Should -Be 2
        ($found.Folder | Sort-Object) -join '|' | Should -Be (($orphan1, $orphan2 | Sort-Object) -join '|')
        # State payload is included.
        ($found | Where-Object { $_.Folder -eq $orphan1 }).State.DiscId | Should -Be 'D1'
    }

    It 'returns empty when _inbox does not exist' {
        $libRoot = Join-Path $tmpRoot ("lib-noinbox-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $libRoot -Force | Out-Null
        @(Find-RipperOrphanedRips -LibraryRoot $libRoot).Count | Should -Be 0
    }

    It 'returns empty when _inbox has no orphans' {
        $libRoot = Join-Path $tmpRoot ("lib-empty-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $libRoot '_inbox') -Force | Out-Null
        New-FakeRipFolder -Parent (Join-Path $libRoot '_inbox') -Name 'just-files' -WithLog | Out-Null
        @(Find-RipperOrphanedRips -LibraryRoot $libRoot).Count | Should -Be 0
    }
}

Describe 'Resume-RipperOrphan' {
    It 'reconstructs args from the sidecar and invokes Invoke-RipperPostProcess' {
        $folder = New-FakeRipFolder -Parent $tmpRoot -Name 'res-1' -WithLog -WithCover
        $meta   = New-SampleMetadata
        Write-RipperRipState -RipFolder $folder -DiscId 'TESTDISCID' -Metadata $meta `
            -LogFileName 'rip.log' -CoverArtFileName 'cover.jpg' | Out-Null

        # Mock pp to (a) capture args, (b) return a "moved" target so
        # Resume-RipperOrphan can clean the sidecar from the post-move dir.
        # Use $script: scope so the Mock scriptblock can see it ($using: is
        # only valid for Invoke-Command/Start-Job, NOT Pester mocks).
        $script:movedTarget = Join-Path $tmpRoot 'moved-res-1'
        New-Item -ItemType Directory -Path $script:movedTarget -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $folder '_ripper-state.json') -Destination $script:movedTarget

        Mock -CommandName Invoke-RipperPostProcess -MockWith {
            @{
                Quality       = @{ Status = 'Verified'; Destination = 'Library'; RoutingPrefix = '' }
                Move          = @{ Target = $script:movedTarget; IsReviewQueue = $false; FilesMoved = 5 }
                Target        = $script:movedTarget
                IsReviewQueue = $false
            }
        }

        $pp = Resume-RipperOrphan -RipFolder $folder -LibraryRoot 'C:\Library'
        $pp.Target | Should -Be $script:movedTarget

        Should -Invoke -CommandName Invoke-RipperPostProcess -Times 1 -ParameterFilter {
            $RipFolder    -eq $folder -and
            $LogFile      -eq (Join-Path $folder 'rip.log') -and
            $DiscId       -eq 'TESTDISCID' -and
            $LibraryRoot  -eq 'C:\Library' -and
            $CoverArtFile -eq (Join-Path $folder 'cover.jpg')
        }

        # Sidecar removed from the post-move target.
        Test-Path -LiteralPath (Join-Path $script:movedTarget '_ripper-state.json') | Should -BeFalse
    }

    It 'passes $null CoverArtFile when sidecar has no cover or file is missing' {
        $folder = New-FakeRipFolder -Parent $tmpRoot -Name 'res-no-cover' -WithLog
        Write-RipperRipState -RipFolder $folder -DiscId 'D' -Metadata (New-SampleMetadata) `
            -LogFileName 'rip.log' | Out-Null

        $script:resNoCoverFolder = $folder
        Mock -CommandName Invoke-RipperPostProcess -MockWith {
            @{ Quality=@{}; Move=@{ Target=$script:resNoCoverFolder; IsReviewQueue=$false; FilesMoved=1 }; Target=$script:resNoCoverFolder; IsReviewQueue=$false }
        }

        Resume-RipperOrphan -RipFolder $folder -LibraryRoot 'C:\Library' | Out-Null
        Should -Invoke -CommandName Invoke-RipperPostProcess -Times 1 -ParameterFilter { -not $CoverArtFile }
    }

    It 'throws if the sidecar is missing' {
        $folder = New-FakeRipFolder -Parent $tmpRoot -Name 'res-no-sidecar' -WithLog
        { Resume-RipperOrphan -RipFolder $folder -LibraryRoot 'C:\Library' } |
            Should -Throw -ExpectedMessage '*no sidecar*'
    }

    It 'throws if the log file referenced by the sidecar is missing' {
        $folder = New-FakeRipFolder -Parent $tmpRoot -Name 'res-no-log'
        Write-RipperRipState -RipFolder $folder -DiscId 'D' -Metadata (New-SampleMetadata) `
            -LogFileName 'rip.log' | Out-Null   # but no rip.log was written
        { Resume-RipperOrphan -RipFolder $folder -LibraryRoot 'C:\Library' } |
            Should -Throw -ExpectedMessage "*log file*not found*"
    }

    It 'leaves the sidecar in place if Invoke-RipperPostProcess throws' {
        $folder = New-FakeRipFolder -Parent $tmpRoot -Name 'res-pp-fail' -WithLog
        Write-RipperRipState -RipFolder $folder -DiscId 'D' -Metadata (New-SampleMetadata) `
            -LogFileName 'rip.log' | Out-Null

        Mock -CommandName Invoke-RipperPostProcess -MockWith { throw 'boom' }

        { Resume-RipperOrphan -RipFolder $folder -LibraryRoot 'C:\Library' } |
            Should -Throw -ExpectedMessage '*boom*'

        Test-Path -LiteralPath (Join-Path $folder '_ripper-state.json') | Should -BeTrue
    }
}
