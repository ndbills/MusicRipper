#Requires -Version 7.0
#Requires -Module Pester

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'src\lib\FailedRips.psd1') -Force
}

Describe 'Failed-rip lifecycle' {
    BeforeEach {
        $script:root = Join-Path $TestDrive 'library'
        $script:rip = Join-Path $script:root '_inbox\Artist - Album'
        New-Item -ItemType Directory -Path $script:rip -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:rip '01 - One.flac') -Value 'one'
        Set-Content -LiteralPath (Join-Path $script:rip '02 - Two.flac') -Value 'two'
        $script:metadata = [pscustomobject]@{ AlbumArtist='Artist'; Album='Album' }
    }

Describe 'Save-RipperFailedRip' {
    It 'writes manifests, copies the session log, and moves the attempt out of the inbox' {
        $log = Join-Path $TestDrive 'session.log'
        Set-Content -LiteralPath $log -Value 'session evidence'
        $completed = @([pscustomobject]@{ Number=1; Title='One'; FileName='01 - One.flac' })

        $destination = Save-RipperFailedRip -RipFolder $script:rip -LibraryRoot $script:root `
            -DiscId 'disc-ABC' -Metadata $script:metadata -CompletedTracks $completed `
            -FailedTrackNumber 2 -FailedTrackTitle 'Two' -ErrorMessage 'UNRECOVERED READ ERROR' `
            -DriveLetter 'D:' -DriveName 'HL-DT-ST GP65NB60' -FirmwareRevision '1.00' `
            -DriveOffset 6 -SessionLogPath $log

        Test-Path -LiteralPath $script:rip | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $destination '01 - One.flac') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $destination '02 - Two.flac') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $destination 'failed-rip.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $destination 'FAILED-RIP.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $destination 'ripper-session.log') | Should -BeTrue
        $state = Get-Content -LiteralPath (Join-Path $destination 'failed-rip.json') -Raw | ConvertFrom-Json
        $state.DiscId | Should -BeExactly 'disc-ABC'
        $state.FailedTrackNumber | Should -Be 2
        @($state.CompletedTracks).Count | Should -Be 1
    }

    It 'leaves a marked source intact when archival move fails' {
        Mock -ModuleName FailedRips Move-Item { throw 'simulated move failure' }
        { Save-RipperFailedRip -RipFolder $script:rip -LibraryRoot $script:root `
            -DiscId 'disc-ABC' -Metadata $script:metadata -CompletedTracks @() `
            -FailedTrackNumber 1 -FailedTrackTitle 'One' -ErrorMessage 'read failed' } |
            Should -Throw '*simulated move failure*'

        Test-Path -LiteralPath $script:rip | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:rip 'failed-rip.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:rip 'FAILED-RIP.txt') | Should -BeTrue
    }

    It 'writes the marker before log-copy failure and keeps completed evidence' {
        $log = Join-Path $TestDrive 'session.log'
        Set-Content -LiteralPath $log -Value 'session evidence'
        Mock -ModuleName FailedRips Copy-Item { throw 'simulated log-copy failure' }
        $completed = @([pscustomobject]@{ Number=1; Title='One'; FileName='01 - One.flac' })

        { Save-RipperFailedRip -RipFolder $script:rip -LibraryRoot $script:root `
            -DiscId 'disc-ABC' -Metadata $script:metadata -CompletedTracks $completed `
            -FailedTrackNumber 2 -FailedTrackTitle 'Two' -ErrorMessage 'read failed' `
            -SessionLogPath $log } | Should -Throw '*simulated log-copy failure*'

        Test-Path -LiteralPath (Join-Path $script:rip 'failed-rip.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:rip '01 - One.flac') | Should -BeTrue
    }
}

Describe 'Get-RipperFailedRipAttempts' {
    It 'matches disc ids exactly and ignores malformed manifests' {
        foreach ($id in 'disc-ABC','disc-ABCD') {
            $folder = Join-Path $script:root "_FailedRips\$id\attempt"
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            @{ DiscId=$id; AttemptId='attempt' } | ConvertTo-Json |
                Set-Content -LiteralPath (Join-Path $folder 'failed-rip.json')
        }
        $bad = Join-Path $script:root '_FailedRips\bad\attempt'
        New-Item -ItemType Directory -Path $bad -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $bad 'failed-rip.json') -Value '{bad json'

        $found = @(Get-RipperFailedRipAttempts -LibraryRoot $script:root -DiscId 'disc-ABC')
        $found.Count | Should -Be 1
        $found[0].DiscId | Should -BeExactly 'disc-ABC'
    }
}

Describe 'Move-RipperMarkedFailedRip' {
    It 'quarantines an attempt whose previous archive move did not complete' {
        @{ DiscId='disc-ABC'; AttemptId='prior-attempt'; CompletedTracks=@(
            @{ Number=1; Title='One'; FileName='01 - One.flac' }
        ) } | ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath (Join-Path $script:rip 'failed-rip.json')

        $destination = Move-RipperMarkedFailedRip -RipFolder $script:rip -LibraryRoot $script:root
        $destination | Should -Match '_FailedRips'
        Test-Path -LiteralPath $destination | Should -BeTrue
        Test-Path -LiteralPath $script:rip | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $destination '01 - One.flac') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $destination '02 - Two.flac') | Should -BeFalse
    }
}

Describe 'Remove-RipperFailedRipAttempts' {
    BeforeEach {
        $script:attempt = Join-Path $script:root '_FailedRips\disc-ABC\attempt'
        New-Item -ItemType Directory -Path $script:attempt -Force | Out-Null
        @{ DiscId='disc-ABC'; AttemptId='attempt'; CompletedTracks=@(1,2) } | ConvertTo-Json |
            Set-Content -LiteralPath (Join-Path $script:attempt 'failed-rip.json')
    }

    It 'recycles matching attempts and reports their outcome' {
        Mock -ModuleName FailedRips Move-RipperFolderToRecycleBin {}
        $result = @(Remove-RipperFailedRipAttempts -LibraryRoot $script:root -DiscId 'disc-ABC')
        $result.Count | Should -Be 1
        $result[0].Recycled | Should -BeTrue
        Should -Invoke -ModuleName FailedRips Move-RipperFolderToRecycleBin -Times 1 -Exactly
    }

    It 'reports recycle failures without throwing' {
        Mock -ModuleName FailedRips Move-RipperFolderToRecycleBin { throw 'recycle unavailable' }
        { $script:result = @(Remove-RipperFailedRipAttempts -LibraryRoot $script:root -DiscId 'disc-ABC') } |
            Should -Not -Throw
        $script:result[0].Recycled | Should -BeFalse
        $script:result[0].Error | Should -Match 'recycle unavailable'
    }

    It 'supports WhatIf without invoking the recycle operation' {
        Mock -ModuleName FailedRips Move-RipperFolderToRecycleBin {}
        Remove-RipperFailedRipAttempts -LibraryRoot $script:root -DiscId 'disc-ABC' -WhatIf | Out-Null
        Should -Invoke -ModuleName FailedRips Move-RipperFolderToRecycleBin -Times 0 -Exactly
        Test-Path -LiteralPath $script:attempt | Should -BeTrue
    }
}
}