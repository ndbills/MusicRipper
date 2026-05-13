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

Describe 'Test-RipperDependencies' {
    # We exercise the function shape and the negative case (which we can
    # produce deterministically by stripping PATH + the fallback dirs).
    # The positive case depends on whether the dev/CI box has CUETools +
    # Xiph.FLAC installed; we assert shape only, not values.

    It 'returns a hashtable with Ok and Missing keys' {
        $r = Test-RipperDependencies
        $r              | Should -BeOfType [hashtable]
        $r.ContainsKey('Ok')      | Should -BeTrue
        $r.ContainsKey('Missing') | Should -BeTrue
        $r.Ok      | Should -BeOfType [bool]
        ,$r.Missing | Should -BeOfType [array]
    }

    It 'reports both deps missing when neither CUETools nor metaflac can be found' {
        $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("mr-deps-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path $sandbox | Out-Null
        $origPath  = $env:PATH
        $origLocal = $env:LOCALAPPDATA
        $origPF    = $env:ProgramFiles
        $origPF86  = ${env:ProgramFiles(x86)}
        try {
            $env:PATH              = ''
            $env:LOCALAPPDATA      = $sandbox
            $env:ProgramFiles      = $sandbox
            ${env:ProgramFiles(x86)} = $sandbox

            $r = Test-RipperDependencies
            $r.Ok | Should -BeFalse
            $r.Missing.Count | Should -Be 2
            ($r.Missing.Name -join ',') | Should -Match 'CUETools'
            ($r.Missing.Name -join ',') | Should -Match 'Xiph.FLAC'
            ($r.Missing.WingetId) | Should -Contain 'gchudov.CUETools'
            ($r.Missing.WingetId) | Should -Contain 'Xiph.FLAC'
        } finally {
            $env:PATH              = $origPath
            $env:LOCALAPPDATA      = $origLocal
            $env:ProgramFiles      = $origPF
            ${env:ProgramFiles(x86)} = $origPF86
            Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Read-RipperVersionFromFile (Phase 8.3 / D-032 amendment)' {

    It 'returns the trimmed contents of a single-line VERSION file' {
        $f = Join-Path $TestDrive 'VERSION'
        Set-Content -LiteralPath $f -Value '0.2' -NoNewline
        Read-RipperVersionFromFile -Path $f | Should -Be '0.2'
    }

    It 'tolerates a trailing newline (Set-Content default)' {
        $f = Join-Path $TestDrive 'VERSION-newline'
        Set-Content -LiteralPath $f -Value '0.3'   # trailing CRLF
        Read-RipperVersionFromFile -Path $f | Should -Be '0.3'
    }

    It 'tolerates leading and trailing whitespace inside the line' {
        $f = Join-Path $TestDrive 'VERSION-spaces'
        Set-Content -LiteralPath $f -Value '   0.4   '
        Read-RipperVersionFromFile -Path $f | Should -Be '0.4'
    }

    It 'reads the first non-empty line of a multi-line file' {
        # Engineer added a comment block under the version, or saved
        # with a stray blank first line; either way we want just the
        # version.
        $f = Join-Path $TestDrive 'VERSION-multiline'
        Set-Content -LiteralPath $f -Value @('', '0.5', '# a comment')
        Read-RipperVersionFromFile -Path $f | Should -Be '0.5'
    }

    It 'returns the unparseable fallback when the file is missing' {
        # Fallback is intentionally SemVer-unparseable so
        # Compare-RipperVersion treats it as "always update available"
        # (string-compare path) -- safer than a numeric like '0.0'
        # which would compare cleanly and silently misreport the
        # update state.
        $missing = Join-Path $TestDrive 'no-such-VERSION'
        Read-RipperVersionFromFile -Path $missing | Should -Be '0.0-unknown'
    }

    It 'returns the unparseable fallback when the file is empty' {
        $f = Join-Path $TestDrive 'VERSION-empty'
        Set-Content -LiteralPath $f -Value ''
        Read-RipperVersionFromFile -Path $f | Should -Be '0.0-unknown'
    }

    It 'returns the unparseable fallback when the file is whitespace-only' {
        $f = Join-Path $TestDrive 'VERSION-ws'
        Set-Content -LiteralPath $f -Value "   `n  `n"
        Read-RipperVersionFromFile -Path $f | Should -Be '0.0-unknown'
    }
}

Describe 'Get-RipperVersion (Phase 8.3 / D-032 amendment)' {

    It 'returns the version sourced from the repo-root VERSION file at module load' {
        # Sanity: the running test process loaded Common.psd1 from the
        # actual repo, so Get-RipperVersion should equal the contents
        # of the actual VERSION file. This catches regressions where
        # the module accidentally hardcodes a string again.
        $repoRoot   = Split-Path -Parent $PSScriptRoot
        $versionFile = Join-Path $repoRoot 'VERSION'
        $expected = (Get-Content -LiteralPath $versionFile -Raw).Trim()
        Get-RipperVersion | Should -Be $expected
    }

    It 'returns a non-empty string (defends against the worst-case fallback path)' {
        # Even if VERSION goes missing in some weird install state,
        # Get-RipperVersion must always return SOMETHING usable so the
        # MusicBrainz / CTDB / GnuDB User-Agent string composition
        # doesn't throw at the call sites.
        Get-RipperVersion | Should -Not -BeNullOrEmpty
    }
}
