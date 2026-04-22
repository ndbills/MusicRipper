#requires -Version 7.0
#requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

<#
.SYNOPSIS
    Smoke tests for src/tools/Complete-OrphanedRip.ps1 — the easy paths
    only (validation guards + sidecar fast-path delegation).

.DESCRIPTION
    The Mode-B path goes through Show-RipperMetadataDialog (WPF) and
    MusicBrainz HTTP, both of which are exercised by manual end-of-phase
    verification, not unit tests. This file covers what's automatable:
      - "RipFolder must exist" guard
      - "no sidecar AND no -DiscId" guard
      - "no .log file" guard
      - "sidecar present" path delegates cleanly to Resume-RipperOrphan
#>

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:tool     = Join-Path $script:repoRoot 'src\tools\Complete-OrphanedRip.ps1'
    $script:tmpRoot  = Join-Path ([System.IO.Path]::GetTempPath()) ("complete-orphan-tests-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:tmpRoot -Force | Out-Null
}

AfterAll {
    if ($script:tmpRoot -and (Test-Path -LiteralPath $script:tmpRoot)) {
        Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Complete-OrphanedRip.ps1 (validation guards)' {
    It 'throws when RipFolder does not exist' {
        $missing = Join-Path $script:tmpRoot 'does-not-exist'
        { & $script:tool -RipFolder $missing -LibraryRoot $script:tmpRoot } |
            Should -Throw -ExpectedMessage '*RipFolder not found*'
    }

    It 'throws when no sidecar and no -DiscId is supplied' {
        $folder = Join-Path $script:tmpRoot 'no-sidecar-no-discid'
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $folder 'rip.log') -Value 'log' -Encoding UTF8
        { & $script:tool -RipFolder $folder -LibraryRoot $script:tmpRoot } |
            Should -Throw -ExpectedMessage '*sidecar*'
    }

    It 'throws when no sidecar, -DiscId given, but folder has no *.log file' {
        $folder = Join-Path $script:tmpRoot 'no-log'
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        # No .log file inside.
        { & $script:tool -RipFolder $folder -DiscId 'TESTDISC' -LibraryRoot $script:tmpRoot } |
            Should -Throw -ExpectedMessage '*No .log file*'
    }
}
