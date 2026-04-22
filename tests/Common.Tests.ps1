<#
    Pester tests for src/lib/Common.psm1 — pure path-sanitization logic.
    Run: Invoke-Pester ./tests
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'src\lib\Common.psd1') -Force
}

Describe 'ConvertTo-SafeWindowsPathSegment' {
    It 'replaces each illegal char with a single space' {
        ConvertTo-SafeWindowsPathSegment 'AC/DC' | Should -Be 'AC DC'
        ConvertTo-SafeWindowsPathSegment 'a:b'   | Should -Be 'a b'
        ConvertTo-SafeWindowsPathSegment 'a*b?c' | Should -Be 'a b c'
    }

    It 'collapses runs of whitespace introduced by replacement' {
        ConvertTo-SafeWindowsPathSegment 'a//b' | Should -Be 'a b'
        ConvertTo-SafeWindowsPathSegment 'a   b' | Should -Be 'a b'
    }

    It 'trims leading/trailing whitespace' {
        ConvertTo-SafeWindowsPathSegment '  hello  ' | Should -Be 'hello'
    }

    It 'strips trailing dots (Windows silently drops them)' {
        ConvertTo-SafeWindowsPathSegment 'foo...' | Should -Be 'foo'
        ConvertTo-SafeWindowsPathSegment 'foo. .' | Should -Be 'foo'
    }

    It 'replaces control characters with space' {
        $s = "a`tb`nc"   # tab and newline
        ConvertTo-SafeWindowsPathSegment $s | Should -Be 'a b c'
    }

    It 'returns _unknown_ for empty / whitespace / null input' {
        ConvertTo-SafeWindowsPathSegment ''       | Should -Be '_unknown_'
        ConvertTo-SafeWindowsPathSegment '   '    | Should -Be '_unknown_'
        ConvertTo-SafeWindowsPathSegment $null    | Should -Be '_unknown_'
    }

    It 'returns _unknown_ for reserved DOS device names (case-insensitive)' {
        ConvertTo-SafeWindowsPathSegment 'CON'  | Should -Be '_unknown_'
        ConvertTo-SafeWindowsPathSegment 'con'  | Should -Be '_unknown_'
        ConvertTo-SafeWindowsPathSegment 'COM1' | Should -Be '_unknown_'
        ConvertTo-SafeWindowsPathSegment 'lpt9' | Should -Be '_unknown_'
        ConvertTo-SafeWindowsPathSegment 'NUL'  | Should -Be '_unknown_'
    }

    It 'preserves Unicode (accents, non-Latin scripts) untouched' {
        ConvertTo-SafeWindowsPathSegment 'Björk'      | Should -Be 'Björk'
        ConvertTo-SafeWindowsPathSegment '坂本龍一'    | Should -Be '坂本龍一'
    }

    It 'sanitizes a realistic MusicBrainz title round-trip-safely' {
        $raw = 'Symphony No. 5: III. Allegro / Live at Carnegie Hall'
        $clean = ConvertTo-SafeWindowsPathSegment $raw
        $clean | Should -Be 'Symphony No. 5 III. Allegro Live at Carnegie Hall'
        # Sanitize again — must be idempotent.
        ConvertTo-SafeWindowsPathSegment $clean | Should -Be $clean
    }

    It 'accepts pipeline input' {
        'a:b','c?d' | ConvertTo-SafeWindowsPathSegment | Should -Be @('a b', 'c d')
    }
}

Describe 'Get-MetaflacPath' {
    # We don't want this test suite to depend on Xiph.FLAC actually being
    # installed (CI / dev box may not have it), and we don't want to mock
    # Get-Command at module scope (it's used everywhere). So we drop a
    # fake metaflac.exe in a temp dir and prepend it to PATH for the
    # "found on PATH" branch, and verify the throw branch by stripping
    # PATH and pointing the winget roots at empty dirs via env override.

    BeforeAll {
        $script:tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("mr-metaflac-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:tempDir | Out-Null
        $script:fakeExe = Join-Path $script:tempDir 'metaflac.exe'
        # Empty file is enough — Get-Command resolves by name + PATHEXT.
        Set-Content -LiteralPath $script:fakeExe -Value '' -NoNewline
        $script:origPath = $env:PATH
    }
    AfterAll {
        $env:PATH = $script:origPath
        Remove-Item -LiteralPath $script:tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'returns the PATH-resolved metaflac.exe when one exists' {
        $env:PATH = "$script:tempDir;$script:origPath"
        # Get-Command caches by session — clear the cache for metaflac.exe.
        $resolved = Get-MetaflacPath
        $resolved | Should -Be $script:fakeExe
    }

    It 'throws a clear error when metaflac cannot be found anywhere' {
        # Strip PATH of anything that could resolve metaflac, and point
        # LOCALAPPDATA / Program Files at empty dirs so the fallback
        # branches all miss too.
        $env:PATH = ''
        $sandbox = Join-Path $script:tempDir 'sandbox'
        New-Item -ItemType Directory -Path $sandbox | Out-Null
        $origLocal = $env:LOCALAPPDATA
        $origPF    = $env:ProgramFiles
        $origPF86  = ${env:ProgramFiles(x86)}
        try {
            $env:LOCALAPPDATA      = $sandbox
            $env:ProgramFiles      = $sandbox
            ${env:ProgramFiles(x86)} = $sandbox
            { Get-MetaflacPath } | Should -Throw -ErrorId '*' -ExpectedMessage '*metaflac.exe not found*'
        } finally {
            $env:LOCALAPPDATA      = $origLocal
            $env:ProgramFiles      = $origPF
            ${env:ProgramFiles(x86)} = $origPF86
        }
    }
}
