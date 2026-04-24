#requires -Version 7.0
#requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

<#
.SYNOPSIS
    Pester tests for src/core/Get-LibraryDiscIndex.ps1 — round-trip,
    corruption recovery, stale-entry handling.
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force
    . (Join-Path $repoRoot 'src\core\Get-LibraryDiscIndex.ps1')

    $script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("libidx-tests-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

    function New-FakeAlbum {
        param([string]$Lib, [string]$Artist, [string]$Album)
        $p = Join-Path (Join-Path $Lib $Artist) $Album
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        $p
    }
}

AfterAll {
    if ($script:tmpRoot -and (Test-Path -LiteralPath $script:tmpRoot)) {
        Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Get-RipperLibraryDiscIndexPath' {
    It 'composes <root>\.musicripper\discids.json' {
        $p = Get-RipperLibraryDiscIndexPath -LibraryRoot 'C:\lib'
        $p | Should -Be 'C:\lib\.musicripper\discids.json'
    }
}

Describe 'Get-RipperLibraryDiscIndex' {
    BeforeEach {
        $script:lib = Join-Path $script:tmpRoot ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:lib -Force | Out-Null
    }

    It 'returns empty hashtable when index file missing' {
        $r = Get-RipperLibraryDiscIndex -LibraryRoot $script:lib
        $r | Should -BeOfType [hashtable]
        $r.Count | Should -Be 0
    }

    It 'returns empty hashtable when index file is empty' {
        $idxDir = Join-Path $script:lib '.musicripper'
        New-Item -ItemType Directory -Path $idxDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $idxDir 'discids.json') -Value '' -NoNewline
        (Get-RipperLibraryDiscIndex -LibraryRoot $script:lib).Count | Should -Be 0
    }

    It 'recovers gracefully from corrupt JSON (returns empty, logs warn)' {
        $idxDir = Join-Path $script:lib '.musicripper'
        New-Item -ItemType Directory -Path $idxDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $idxDir 'discids.json') -Value '{ this is not json'
        $r = Get-RipperLibraryDiscIndex -LibraryRoot $script:lib
        $r.Count | Should -Be 0
    }
}

Describe 'Add-RipperLibraryDiscIndexEntry + Find-RipperLibraryDiscIndexEntry' {
    BeforeEach {
        $script:lib = Join-Path $script:tmpRoot ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:lib -Force | Out-Null
    }

    It 'round-trips a single entry' {
        $album = New-FakeAlbum $script:lib 'Foo' 'Bar (2007)'
        Add-RipperLibraryDiscIndexEntry -LibraryRoot $script:lib `
            -DiscId 'D1' -Path $album -Label 'Foo - Bar (2007)'

        $idx = Get-RipperLibraryDiscIndex -LibraryRoot $script:lib
        $idx.Count | Should -Be 1
        $idx['D1'].Path  | Should -Be $album
        $idx['D1'].Label | Should -Be 'Foo - Bar (2007)'
        $idx['D1'].Source | Should -Be 'library'
        # ConvertFrom-Json auto-parses ISO timestamps to [datetime]; just
        # assert the field exists and round-trips to "now-ish".
        $idx['D1'].RippedAt | Should -Not -BeNullOrEmpty
        ([datetime]$idx['D1'].RippedAt).ToUniversalTime() |
            Should -BeGreaterThan ([datetime]::UtcNow.AddMinutes(-1))
    }

    It 'creates .musicripper directory if missing' {
        $album = New-FakeAlbum $script:lib 'A' 'B'
        Add-RipperLibraryDiscIndexEntry -LibraryRoot $script:lib -DiscId 'X' -Path $album
        Test-Path -LiteralPath (Join-Path $script:lib '.musicripper\discids.json') | Should -BeTrue
    }

    It 'upserts (later write wins for same DiscId)' {
        $a1 = New-FakeAlbum $script:lib 'A' 'A1'
        $a2 = New-FakeAlbum $script:lib 'A' 'A2'
        Add-RipperLibraryDiscIndexEntry -LibraryRoot $script:lib -DiscId 'D' -Path $a1 -Label 'old'
        Add-RipperLibraryDiscIndexEntry -LibraryRoot $script:lib -DiscId 'D' -Path $a2 -Label 'new'
        $idx = Get-RipperLibraryDiscIndex -LibraryRoot $script:lib
        $idx.Count | Should -Be 1
        $idx['D'].Path  | Should -Be $a2
        $idx['D'].Label | Should -Be 'new'
    }

    It 'preserves multiple entries across writes' {
        $a1 = New-FakeAlbum $script:lib 'A' '1'
        $a2 = New-FakeAlbum $script:lib 'B' '2'
        Add-RipperLibraryDiscIndexEntry -LibraryRoot $script:lib -DiscId 'D1' -Path $a1
        Add-RipperLibraryDiscIndexEntry -LibraryRoot $script:lib -DiscId 'D2' -Path $a2
        $idx = Get-RipperLibraryDiscIndex -LibraryRoot $script:lib
        $idx.Count | Should -Be 2
        $idx['D1'].Path | Should -Be $a1
        $idx['D2'].Path | Should -Be $a2
    }

    It 'Find returns entry when path exists' {
        $album = New-FakeAlbum $script:lib 'F' 'Found'
        Add-RipperLibraryDiscIndexEntry -LibraryRoot $script:lib -DiscId 'FX' -Path $album -Label 'F - Found'
        $e = Find-RipperLibraryDiscIndexEntry -LibraryRoot $script:lib -DiscId 'FX'
        $e | Should -Not -BeNullOrEmpty
        $e.Path | Should -Be $album
    }

    It 'Find returns $null when DiscId not in index' {
        Find-RipperLibraryDiscIndexEntry -LibraryRoot $script:lib -DiscId 'MISSING' | Should -BeNullOrEmpty
    }

    It 'Find returns $null when entry path is stale (folder removed)' {
        $album = New-FakeAlbum $script:lib 'S' 'Stale'
        Add-RipperLibraryDiscIndexEntry -LibraryRoot $script:lib -DiscId 'SX' -Path $album
        Remove-Item -LiteralPath $album -Recurse -Force
        Find-RipperLibraryDiscIndexEntry -LibraryRoot $script:lib -DiscId 'SX' | Should -BeNullOrEmpty
    }
}
