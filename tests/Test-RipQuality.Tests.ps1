<#
    Pester tests for src/core/Test-RipQuality.ps1 — pure-logic helpers
    (read-error detection + Status-to-routing mapping). The integration
    function Test-RipQuality is exercised against the existing rip-log
    fixture; the actual disk I/O path is covered by Phase 5's manual
    verification step.

    Run: Invoke-Pester ./tests
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'src\core\Test-RipQuality.ps1')
    $script:fixtureLog = Join-Path $repoRoot 'tests\fixtures\rip-log-spirit-of-the-season.txt'
}

Describe 'Test-RipperLogContainsReadErrors' {
    It 'returns false on the clean Spirit-of-the-Season fixture' {
        $log = Get-Content -LiteralPath $script:fixtureLog -Raw
        Test-RipperLogContainsReadErrors -LogText $log | Should -BeFalse
    }

    It 'returns false on empty / whitespace input' {
        Test-RipperLogContainsReadErrors -LogText ''     | Should -BeFalse
        Test-RipperLogContainsReadErrors -LogText "  `n" | Should -BeFalse
    }

    It 'detects re-read / reread / rereading' {
        Test-RipperLogContainsReadErrors -LogText 'Sector 12345 re-read 3 times'  | Should -BeTrue
        Test-RipperLogContainsReadErrors -LogText 'Sector 12345 reread (ok)'      | Should -BeTrue
        Test-RipperLogContainsReadErrors -LogText 'rereading after C2 anomaly'    | Should -BeTrue
    }

    It 'detects retry variants' {
        Test-RipperLogContainsReadErrors -LogText 'retry attempt 2'   | Should -BeTrue
        Test-RipperLogContainsReadErrors -LogText 'Retried 4 times'   | Should -BeTrue
        Test-RipperLogContainsReadErrors -LogText 'Retrying...'       | Should -BeTrue
    }

    It 'detects abort / aborted / aborting' {
        Test-RipperLogContainsReadErrors -LogText 'rip aborted'  | Should -BeTrue
        Test-RipperLogContainsReadErrors -LogText 'Aborting...'  | Should -BeTrue
    }

    It 'detects skipped, bad sector, unrecoverable, read error' {
        Test-RipperLogContainsReadErrors -LogText 'Track 03 skipped'        | Should -BeTrue
        Test-RipperLogContainsReadErrors -LogText 'bad sector at 12:34.56'  | Should -BeTrue
        Test-RipperLogContainsReadErrors -LogText 'Bad sectors detected'    | Should -BeTrue
        Test-RipperLogContainsReadErrors -LogText 'Unrecoverable read'      | Should -BeTrue
        Test-RipperLogContainsReadErrors -LogText 'read error at LBA 1000'  | Should -BeTrue
        Test-RipperLogContainsReadErrors -LogText 'Read errors: 7'          | Should -BeTrue
    }

    It 'flags C2 only when followed by error(s) (not bare offset notation)' {
        Test-RipperLogContainsReadErrors -LogText 'C2 errors detected: 12'  | Should -BeTrue
        Test-RipperLogContainsReadErrors -LogText 'C2 error at 03:21.45'    | Should -BeTrue
        # Bare "C2" (e.g. inside another token) must not match.
        Test-RipperLogContainsReadErrors -LogText 'AC2DC reference byte'    | Should -BeFalse
    }

    It 'is word-boundary aware (no false positives inside other words)' {
        Test-RipperLogContainsReadErrors -LogText 'Aborigines of Australia' | Should -BeFalse
        Test-RipperLogContainsReadErrors -LogText 'cretrying is not a word' | Should -BeFalse
    }
}

Describe 'Get-RipperQualityRouting' {
    It 'sends Verified to the main library' {
        $r = Get-RipperQualityRouting -Status 'Verified'
        $r.Destination | Should -Be 'Library'
        $r.QueuePrefix | Should -BeNullOrEmpty
        $r.Reason      | Should -Match 'verified'
    }

    It 'sends ProbablyGood to the main library (rip OK, low AR confidence)' {
        $r = Get-RipperQualityRouting -Status 'ProbablyGood'
        $r.Destination | Should -Be 'Library'
        $r.QueuePrefix | Should -BeNullOrEmpty
    }

    It 'sends NotInDatabase to the main library (deliberate per Phase 5 spec)' {
        $r = Get-RipperQualityRouting -Status 'NotInDatabase'
        $r.Destination | Should -Be 'Library'
        $r.QueuePrefix | Should -BeNullOrEmpty
        $r.Reason      | Should -Match 'not present'
    }

    It 'sends Suspect to the review queue with SUSPECT prefix' {
        $r = Get-RipperQualityRouting -Status 'Suspect'
        $r.Destination | Should -Be 'ReviewQueue'
        $r.QueuePrefix | Should -Be 'SUSPECT'
    }

    It 'sends Unknown to the review queue with UNKNOWN prefix' {
        $r = Get-RipperQualityRouting -Status 'Unknown'
        $r.Destination | Should -Be 'ReviewQueue'
        $r.QueuePrefix | Should -Be 'UNKNOWN'
    }

    It 'falls back to ReviewQueue/UNKNOWN for any unexpected status' {
        $r = Get-RipperQualityRouting -Status 'WeirdNewValue'
        $r.Destination | Should -Be 'ReviewQueue'
        $r.QueuePrefix | Should -Be 'UNKNOWN'
        $r.Reason      | Should -Match 'WeirdNewValue'
    }
}

Describe 'Test-RipQuality (integration over fixture log)' {
    It 'classifies the Spirit-of-the-Season fixture as Verified -> Library' {
        $q = Test-RipQuality -LogPath $script:fixtureLog
        $q.Status         | Should -Be 'Verified'
        $q.OriginalStatus | Should -Be 'Verified'
        $q.Destination    | Should -Be 'Library'
        $q.QueuePrefix    | Should -BeNullOrEmpty
        $q.Summary        | Should -Not -BeNullOrEmpty
        $q.Summary.AccurateRip.MatchedTracks | Should -Be $q.Summary.AccurateRip.TotalTracks
    }

    It 'returns Unknown -> ReviewQueue when the log file is missing' {
        $missing = Join-Path $TestDrive 'no-such-log.txt'
        $q = Test-RipQuality -LogPath $missing
        $q.Status      | Should -Be 'Unknown'
        $q.Destination | Should -Be 'ReviewQueue'
        $q.QueuePrefix | Should -Be 'UNKNOWN'
        $q.Summary     | Should -BeNullOrEmpty
    }

    It 'escalates Verified -> Suspect when a read-error keyword is appended' {
        $tampered = Join-Path $TestDrive 'tampered.log'
        $orig = Get-Content -LiteralPath $script:fixtureLog -Raw
        Set-Content -LiteralPath $tampered -Value ($orig + "`nSector 99 re-read 5 times`n") -NoNewline
        $q = Test-RipQuality -LogPath $tampered
        $q.OriginalStatus | Should -Be 'Verified'
        $q.Status         | Should -Be 'Suspect'
        $q.Destination    | Should -Be 'ReviewQueue'
        $q.QueuePrefix    | Should -Be 'SUSPECT'
    }
}
