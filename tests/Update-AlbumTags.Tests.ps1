#requires -Version 7.0
#requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

<#
.SYNOPSIS
    Smoke tests for src/tools/Update-AlbumTags.ps1 — validation guards
    only. The real lookup paths require live MusicBrainz HTTP and a
    real FLAC file with embedded Vorbis tags, both covered by manual
    end-of-phase verification.
#>

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:tool     = Join-Path $script:repoRoot 'src\tools\Update-AlbumTags.ps1'
    $script:tmpRoot  = Join-Path ([System.IO.Path]::GetTempPath()) ("update-tags-tests-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:tmpRoot -Force | Out-Null
}

AfterAll {
    if ($script:tmpRoot -and (Test-Path -LiteralPath $script:tmpRoot)) {
        Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Update-AlbumTags.ps1 (validation guards)' {
    It 'throws when AlbumFolder does not exist' {
        $missing = Join-Path $script:tmpRoot 'does-not-exist'
        { & $script:tool -AlbumFolder $missing } |
            Should -Throw -ExpectedMessage '*AlbumFolder not found*'
    }

    It 'throws when AlbumFolder has no NN - <title>.flac files' {
        $folder = Join-Path $script:tmpRoot 'no-flacs'
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        # Drop a non-matching file so the folder isn't empty.
        Set-Content -LiteralPath (Join-Path $folder 'readme.txt') -Value 'x' -Encoding UTF8
        { & $script:tool -AlbumFolder $folder } |
            Should -Throw -ExpectedMessage "*No 'NN - <title>.flac' files*"
    }
}
