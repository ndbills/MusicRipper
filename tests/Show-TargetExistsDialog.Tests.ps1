#requires -Version 7.0
#requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

<#
.SYNOPSIS
    Phase 5.11: smoke tests for src/ui/Show-TargetExistsDialog.ps1's
    non-WPF helper Move-RipperFolderToRecycleBin and the dispatcher
    contract on the dialog itself.

    The WPF window is not driven from Pester (same convention as
    Show-DuplicateDiscDialog.Tests would have followed -- its CI tests
    only cover the dispatcher sink + script load). We only test:
      - Move-RipperFolderToRecycleBin throws on a non-existent path.
      - Move-RipperFolderToRecycleBin throws on a file (not directory).
      - The script defines the dispatcher unhandled-exception sink
        (Phase-4 / 5.2 rule).
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force
    . (Join-Path $repoRoot 'src\ui\Show-TargetExistsDialog.ps1')

    $script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("targetexists-tests-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
}

AfterAll {
    if (Test-Path -LiteralPath $tmpRoot) {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Move-RipperFolderToRecycleBin' {

    It 'throws when the path does not exist' {
        $missing = Join-Path $tmpRoot 'does-not-exist'
        { Move-RipperFolderToRecycleBin -Path $missing } |
            Should -Throw '*not a directory*'
    }

    It 'throws when the path is a file, not a directory' {
        $f = Join-Path $tmpRoot 'a.txt'
        Set-Content -LiteralPath $f -Value 'x' -Encoding UTF8
        { Move-RipperFolderToRecycleBin -Path $f } |
            Should -Throw '*not a directory*'
    }

    It 'supports -WhatIf without actually deleting the folder' {
        $d = Join-Path $tmpRoot 'whatif-dir'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Move-RipperFolderToRecycleBin -Path $d -WhatIf
        Test-Path -LiteralPath $d | Should -BeTrue
    }
}

Describe 'Show-RipperTargetExistsDialog source contract' {

    BeforeAll {
        $script:src = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'src\ui\Show-TargetExistsDialog.ps1')
    }

    It 'installs a Dispatcher.add_UnhandledException sink (Phase-4 rule)' {
        ($src -match 'Dispatcher\.add_UnhandledException') | Should -BeTrue
    }

    It 'declares the four expected actions on the result object' {
        foreach ($a in 'SideBySide','Review','Discard','Leave') {
            ($src -match [regex]::Escape("'$a'")) | Should -BeTrue -Because "expected action '$a' to appear as a state value"
        }
    }
}
