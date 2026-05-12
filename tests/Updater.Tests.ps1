#Requires -Version 7.0
#Requires -Module Pester

<#
.SYNOPSIS
    Phase 8 (D-032): pure-logic + filesystem-mocked tests for the
    Updater module.

    The network-touching helper (Get-RipperLatestRelease) is exercised
    via Mock on Invoke-RestMethod so the test suite stays offline-safe
    in CI. The apply orchestrator (Invoke-RipperUpdateApply) is
    exercised against a real synthetic install tree under $TestDrive --
    that tests the rename / move / rollback paths against actual
    filesystem semantics (which is the most likely place for bugs).

    NOT covered here: the Update-MusicRipper.ps1 entry point's
    bootstrap (D-032 amendment, May 2026). The bootstrap copies
    itself + deps to %TEMP% and respawns a hidden pwsh from there
    so the apply step can rename the install dir without the
    parent process holding open file handles. That self-mutation
    bootstrap is hard to unit-test (spawns processes, mutates
    real filesystem state outside $TestDrive); it's verified
    manually via end-to-end testing on the parents'-PC test
    machine. Tests in this file would have caught the apply bug
    in isolation but did NOT catch the self-mutation bug because
    they run from $TestDrive, not from inside an "install dir"
    that the test process has loaded modules from.
#>

Set-StrictMode -Version 3.0

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force
    Import-Module (Join-Path $repoRoot 'src\lib\Common.psd1')  -Force
    Import-Module (Join-Path $repoRoot 'src\lib\Updater.psd1') -Force

    Start-RipperLog -Context 'updater-tests' | Out-Null

    function script:New-FakeInstall {
        # Create a synthetic install tree under $TestDrive with the
        # marker files Get-RipperInstallRoot looks for.
        param(
            [string]$RootName = 'MusicRipper-test',
            [string]$Marker   = 'v0.1'
        )
        $root = Join-Path $TestDrive $RootName
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'src') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'data') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'Install-MusicRipper.ps1')      -Value "# fake installer ($Marker)"
        Set-Content -LiteralPath (Join-Path $root 'src\Start-Ripper.ps1')         -Value "# fake start-ripper ($Marker)"
        Set-Content -LiteralPath (Join-Path $root 'data\driveoffsets.cached.json') -Value '{"_comment":"user file"}'
        return $root
    }

    function script:New-FakeStaging {
        # Mimics the layout of an Expand-Archive against a GitHub
        # source zip: one parent staging dir holding a single child
        # folder ('<repo>-<sha>' on the real thing) that itself looks
        # like a MusicRipper install.
        param(
            [string]$ChildName = 'ndbills-MusicRipper-deadbeef',
            [string]$Marker    = 'v0.2'
        )
        $stage = Join-Path $TestDrive ('staging-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        $child = Join-Path $stage $ChildName
        New-Item -ItemType Directory -Path $child -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $child 'src') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $child 'Install-MusicRipper.ps1') -Value "# new installer ($Marker)"
        Set-Content -LiteralPath (Join-Path $child 'src\Start-Ripper.ps1')    -Value "# new start-ripper ($Marker)"
        Set-Content -LiteralPath (Join-Path $child 'NEW-FILE.md')             -Value "shipped in $Marker"
        return $stage
    }
}

AfterAll {
    Stop-RipperLog
}


Describe 'Compare-RipperVersion' {
    It 'returns UpToDate when local equals remote' {
        Compare-RipperVersion -Local '0.2' -Remote '0.2' | Should -Be 'UpToDate'
    }
    It 'tolerates leading v on either side' {
        Compare-RipperVersion -Local 'v0.2' -Remote '0.2'  | Should -Be 'UpToDate'
        Compare-RipperVersion -Local '0.2'  -Remote 'v0.2' | Should -Be 'UpToDate'
        Compare-RipperVersion -Local 'v0.1' -Remote 'v0.2' | Should -Be 'NewerAvailable'
    }
    It 'returns NewerAvailable when remote is higher' {
        Compare-RipperVersion -Local '0.1'   -Remote '0.2'   | Should -Be 'NewerAvailable'
        Compare-RipperVersion -Local '0.1.5' -Remote '0.2.0' | Should -Be 'NewerAvailable'
        Compare-RipperVersion -Local '1.0'   -Remote '1.0.1' | Should -Be 'NewerAvailable'
    }
    It 'returns LocalAhead when local is higher (engineer pre-release)' {
        Compare-RipperVersion -Local '0.3' -Remote '0.2' | Should -Be 'LocalAhead'
    }
    It 'pads missing components with zero (0.2 == 0.2.0)' {
        Compare-RipperVersion -Local '0.2.0' -Remote '0.2' | Should -Be 'UpToDate'
    }
    It 'falls back to string compare on unparseable input (treats unequal as NewerAvailable for safety)' {
        Compare-RipperVersion -Local '0.2' -Remote 'main-latest' | Should -Be 'NewerAvailable'
    }
    It 'falls back to string compare and returns UpToDate when unparseable strings match exactly' {
        Compare-RipperVersion -Local 'main-latest' -Remote 'main-latest' | Should -Be 'UpToDate'
    }
}


Describe 'Get-RipperInstallRoot' {
    It 'walks up from a nested path and finds the install root' {
        $root = New-FakeInstall -RootName 'walk-up-test'
        $deep = Join-Path $root 'src\lib\sub'
        New-Item -ItemType Directory -Path $deep -Force | Out-Null
        Get-RipperInstallRoot -StartPath $deep | Should -Be $root
    }
    It 'returns the root unchanged when the start IS the root' {
        $root = New-FakeInstall -RootName 'at-root-test'
        Get-RipperInstallRoot -StartPath $root | Should -Be $root
    }
    It 'returns $null when no install marker is present in 5 levels' {
        $orphan = Join-Path $TestDrive 'orphan'
        New-Item -ItemType Directory -Path $orphan -Force | Out-Null
        Get-RipperInstallRoot -StartPath $orphan | Should -BeNullOrEmpty
    }
}


Describe 'Get-RipperLatestRelease' {

    It 'returns the latest Release fields when the API responds 200' {
        Mock -ModuleName Updater Invoke-RestMethod {
            [pscustomobject]@{
                tag_name     = 'v0.7'
                body         = 'cool changes'
                published_at = '2026-05-11T12:00:00Z'
                zipball_url  = 'https://api.github.com/repos/x/y/zipball/v0.7'
            }
        }
        $r = Get-RipperLatestRelease
        $r.Source      | Should -Be 'Release'
        $r.Version     | Should -Be '0.7'   # leading v stripped
        $r.Notes       | Should -Be 'cool changes'
        $r.PublishedAt | Should -Be '2026-05-11T12:00:00Z'
        $r.ZipballUrl  | Should -Be 'https://api.github.com/repos/x/y/zipball/v0.7'
    }

    It 'falls back to main-branch zip on 404 (no Releases yet)' {
        Mock -ModuleName Updater Invoke-RestMethod {
            $resp = [pscustomobject]@{ StatusCode = 404 }
            $exc = [System.Exception]::new('404 Not Found')
            $exc | Add-Member -MemberType NoteProperty -Name Response -Value $resp -Force
            throw $exc
        }
        $r = Get-RipperLatestRelease -Repo 'fake/repo'
        $r.Source     | Should -Be 'MainBranch'
        $r.Version    | Should -Be 'main-latest'
        $r.ZipballUrl | Should -Be 'https://github.com/fake/repo/archive/refs/heads/main.zip'
    }

    It 'falls back to main-branch zip on a generic network error (also returns a result, not $null)' {
        # Per docstring: any non-200 collapses to the main-branch
        # fallback. The user always gets a clickable update path
        # rather than "we could not check" which is a worse UX.
        Mock -ModuleName Updater Invoke-RestMethod { throw 'simulated dns failure' }
        $r = Get-RipperLatestRelease -Repo 'fake/repo'
        $r.Source | Should -Be 'MainBranch'
    }
}


Describe 'Save-RipperUpdateBackup' {
    It 'renames the install dir to <leaf>-old-<stamp> and returns the new path' {
        $root = New-FakeInstall -RootName 'backup-test'
        $bak  = Save-RipperUpdateBackup -InstallRoot $root
        $bak  | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $root | Should -BeFalse
        Test-Path -LiteralPath $bak  | Should -BeTrue
        $bak  | Should -Match '-old-\d{8}-\d{6}$'
    }
    It 'returns $null when the install dir does not exist' {
        $missing = Join-Path $TestDrive 'no-such-install'
        Save-RipperUpdateBackup -InstallRoot $missing | Should -BeNullOrEmpty
    }
}


Describe 'Invoke-RipperUpdateApply' {

    It 'applies a fresh staging tree, preserves user files, and reports success' {
        $live  = New-FakeInstall -RootName 'apply-success' -Marker 'v0.1'
        $stage = New-FakeStaging -Marker 'v0.2'

        $r = Invoke-RipperUpdateApply -InstallRoot $live -StagingRoot $stage
        $r.Success      | Should -BeTrue
        $r.BackupPath   | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $r.BackupPath | Should -BeTrue   # rollback point retained
        Test-Path -LiteralPath $live          | Should -BeTrue
        # New file from staging is in place.
        Test-Path -LiteralPath (Join-Path $live 'NEW-FILE.md') | Should -BeTrue
        # Marker is the new one.
        (Get-Content -LiteralPath (Join-Path $live 'Install-MusicRipper.ps1') -Raw).Trim() |
            Should -Match 'v0\.2'
        # Preserved user file is back.
        Test-Path -LiteralPath (Join-Path $live 'data\driveoffsets.cached.json') | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $live 'data\driveoffsets.cached.json') -Raw).Trim() |
            Should -Match 'user file'
    }

    It 'refuses to apply when staging has zero or multiple top-level folders' {
        $live  = New-FakeInstall -RootName 'apply-multi-child'
        $stage = Join-Path $TestDrive ('multi-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $stage 'a') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $stage 'b') -Force | Out-Null

        $r = Invoke-RipperUpdateApply -InstallRoot $live -StagingRoot $stage
        $r.Success | Should -BeFalse
        $r.ErrorMessage | Should -Match 'Expected exactly one top-level folder'
        # Live install untouched.
        Test-Path -LiteralPath $live | Should -BeTrue
    }

    It 'refuses to apply when the single staging child is missing required marker files' {
        $live  = New-FakeInstall -RootName 'apply-bad-staging'
        $stage = Join-Path $TestDrive ('bad-' + [guid]::NewGuid().ToString('N'))
        $child = Join-Path $stage 'incomplete'
        New-Item -ItemType Directory -Path $child -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $child 'README.md') -Value 'incomplete tree'

        $r = Invoke-RipperUpdateApply -InstallRoot $live -StagingRoot $stage
        $r.Success | Should -BeFalse
        $r.ErrorMessage | Should -Match 'does not look like a MusicRipper install'
        # Live install untouched (we refused before backup).
        Test-Path -LiteralPath $live | Should -BeTrue
    }

    It 'invokes the progress callback at every phase' {
        $live  = New-FakeInstall -RootName 'apply-progress'
        $stage = New-FakeStaging
        $phases = New-Object 'System.Collections.Generic.List[string]'
        $cb = { param($info) $phases.Add($info.Phase) }
        $r = Invoke-RipperUpdateApply -InstallRoot $live -StagingRoot $stage -ProgressCallback $cb
        $r.Success | Should -BeTrue
        @($phases) | Should -Contain 'Validate'
        @($phases) | Should -Contain 'Snapshot'
        @($phases) | Should -Contain 'Backup'
        @($phases) | Should -Contain 'Move'
        @($phases) | Should -Contain 'Restore'
    }
}


Describe 'Remove-RipperOldUpdateBackups' {

    It 'keeps the most recent N backups and prunes older ones' {
        $live = New-FakeInstall -RootName 'prune-test'
        $parent = Split-Path -Parent $live
        $leaf   = Split-Path -Leaf $live

        # Create 4 fake backup dirs with staggered LastWriteTime so the
        # sort is deterministic.
        $dirs = @()
        for ($i = 1; $i -le 4; $i++) {
            $d = Join-Path $parent ("$leaf-old-2026010$i-120000")
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            (Get-Item -LiteralPath $d).LastWriteTime = (Get-Date).AddDays(-($i))
            $dirs += $d
        }

        Remove-RipperOldUpdateBackups -InstallRoot $live -Keep 2

        $remaining = @(Get-ChildItem -LiteralPath $parent -Directory -Filter "$leaf-old-*")
        $remaining.Count | Should -Be 2
        # The two newest (smallest day-offset) survived.
        Test-Path -LiteralPath $dirs[0] | Should -BeTrue
        Test-Path -LiteralPath $dirs[1] | Should -BeTrue
        Test-Path -LiteralPath $dirs[2] | Should -BeFalse
        Test-Path -LiteralPath $dirs[3] | Should -BeFalse
    }

    It 'is a no-op when total backups is at or below Keep' {
        $live = New-FakeInstall -RootName 'prune-noop'
        $parent = Split-Path -Parent $live
        $leaf   = Split-Path -Leaf $live
        $d = Join-Path $parent "$leaf-old-20260101-120000"
        New-Item -ItemType Directory -Path $d -Force | Out-Null

        Remove-RipperOldUpdateBackups -InstallRoot $live -Keep 2
        Test-Path -LiteralPath $d | Should -BeTrue
    }
}
