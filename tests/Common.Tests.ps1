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
