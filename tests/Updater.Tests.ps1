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
                html_url     = 'https://github.com/x/y/releases/tag/v0.7'
            }
        }
        $r = Get-RipperLatestRelease
        $r.Source      | Should -Be 'Release'
        $r.Version     | Should -Be '0.7'   # leading v stripped
        $r.Notes       | Should -Be 'cool changes'
        $r.PublishedAt | Should -Be '2026-05-11T12:00:00Z'
        $r.ZipballUrl  | Should -Be 'https://api.github.com/repos/x/y/zipball/v0.7'
        $r.HtmlUrl     | Should -Be 'https://github.com/x/y/releases/tag/v0.7'
    }

    It 'returns HtmlUrl as empty string when the API omits html_url' {
        # Defensive: GitHub always sets html_url on real Releases, but
        # we still need the field present in the returned hashtable
        # so the WPF binding code can read it without tripping
        # StrictMode 3.0 on a missing property.
        Mock -ModuleName Updater Invoke-RestMethod {
            [pscustomobject]@{
                tag_name    = 'v0.8'
                zipball_url = 'https://api.github.com/repos/x/y/zipball/v0.8'
            }
        }
        $r = Get-RipperLatestRelease
        $r.Source                         | Should -Be 'Release'
        $r.ContainsKey('HtmlUrl')         | Should -BeTrue
        $r.HtmlUrl                        | Should -Be ''
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
        # No release page exists for the bare-main-branch zip path; the
        # WPF uses an empty HtmlUrl to hide the 'View on GitHub' button.
        $r.HtmlUrl    | Should -Be ''
    }

    It 'falls back to main-branch zip on a generic network error (also returns a result, not $null)' {
        # Per docstring: any non-200 collapses to the main-branch
        # fallback. The user always gets a clickable update path
        # rather than "we could not check" which is a worse UX.
        Mock -ModuleName Updater Invoke-RestMethod { throw 'simulated dns failure' }
        $r = Get-RipperLatestRelease -Repo 'fake/repo'
        $r.Source  | Should -Be 'MainBranch'
        $r.HtmlUrl | Should -Be ''
    }

    It 'returns a [hashtable] whose keys are visible via ContainsKey (NOT via PSObject.Properties)' {
        # v0.2.1 regression guard. The WPF dialogs (Show-UpdateDialog
        # + Show-UpdatePromptDialog) both check whether HtmlUrl /
        # Notes are populated before showing the View-on-GitHub button
        # and the release-notes panel. v0.2.0 used the wrong pattern:
        #
        #   $hasUrl = $latest.PSObject.Properties['HtmlUrl'] -and ...
        #
        # which silently evaluates to $null on a hashtable -- because
        # PSObject.Properties on a [hashtable] surfaces .NET dictionary
        # internals (Keys, Count, IsSynchronized, ...), NOT the user's
        # dictionary keys. Net effect: button stayed Collapsed, notes
        # panel showed "(No release notes provided.)" even when the
        # API returned both. Fixed in v0.2.1 by switching to
        # ContainsKey(). This test locks in the contract: callers
        # MUST use ContainsKey() (not PSObject.Properties) to test
        # for key presence on this return value.
        Mock -ModuleName Updater Invoke-RestMethod {
            [pscustomobject]@{
                tag_name    = 'v0.9'
                body        = 'release notes'
                zipball_url = 'https://api.github.com/repos/x/y/zipball/v0.9'
                html_url    = 'https://github.com/x/y/releases/tag/v0.9'
            }
        }
        $r = Get-RipperLatestRelease
        $r -is [hashtable]                 | Should -BeTrue
        $r.ContainsKey('HtmlUrl')          | Should -BeTrue
        $r.ContainsKey('Notes')            | Should -BeTrue
        $r.ContainsKey('Version')          | Should -BeTrue
        $r.ContainsKey('Source')           | Should -BeTrue
        # And confirm the trap: PSObject.Properties does NOT see
        # hashtable keys. If a future PowerShell version changes this
        # behavior, this assertion will fail and we'll know we can
        # simplify the WPF call sites.
        $r.PSObject.Properties['HtmlUrl'] | Should -BeNullOrEmpty
    }
}


Describe 'Save-RipperUpdateBackup' {
    It 'renames the install dir to a timestamped backup folder and returns Success=true with BackupPath' {
        $root = New-FakeInstall -RootName 'backup-test'
        $r    = Save-RipperUpdateBackup -InstallRoot $root
        $r          | Should -Not -BeNullOrEmpty
        $r.Success  | Should -BeTrue
        $r.ErrorMessage | Should -BeNullOrEmpty
        Test-Path -LiteralPath $root         | Should -BeFalse
        Test-Path -LiteralPath $r.BackupPath | Should -BeTrue
        $r.BackupPath | Should -Match '-old-\d{8}-\d{6}$'
    }
    It 'returns Success=false with a descriptive error when the install dir does not exist' {
        $missing = Join-Path $TestDrive 'no-such-install'
        $r = Save-RipperUpdateBackup -InstallRoot $missing
        $r.Success      | Should -BeFalse
        $r.BackupPath   | Should -BeNullOrEmpty
        $r.ErrorMessage | Should -Match 'does not exist'
    }
    It 'surfaces the underlying exception text + an "in use" hint when Rename-Item fails with a sharing violation' {
        # Mock Rename-Item to throw the exact ERROR_SHARING_VIOLATION
        # message PowerShell produces on Windows ("because it is in use").
        # The real failure on the parents'-PC test machine -- this test
        # is the regression guard for the fix that surfaced the
        # underlying message + a parent-friendly hint instead of just
        # "rename failed".
        $root = New-FakeInstall -RootName 'backup-shared'
        Mock -ModuleName Updater Rename-Item {
            throw "Cannot rename the item at '$root' because it is in use."
        }
        $r = Save-RipperUpdateBackup -InstallRoot $root
        $r.Success      | Should -BeFalse
        $r.BackupPath   | Should -BeNullOrEmpty
        # Underlying exception text preserved (the most common cause we
        # hit in the field; previously thrown away into an unhelpful
        # generic "rename failed").
        $r.ErrorMessage | Should -Match 'because it is in use'
        # Parent-friendly hint enumerating the three usual culprits.
        $r.ErrorMessage | Should -Match 'system tray'
        $r.ErrorMessage | Should -Match 'File Explorer'
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

    It 'propagates the underlying rename-failed exception text into the orchestrator ErrorMessage' {
        # Regression for the "rename failed" diagnostic-loss bug: when
        # Save-RipperUpdateBackup fails, the orchestrator must surface
        # the underlying exception (e.g. "because it is in use") +
        # the parent-friendly hint, NOT a generic placeholder.
        $live  = New-FakeInstall -RootName 'apply-locked'
        $stage = New-FakeStaging
        Mock -ModuleName Updater Rename-Item {
            throw "Cannot rename the item at '$live' because it is in use."
        }
        $r = Invoke-RipperUpdateApply -InstallRoot $live -StagingRoot $stage
        $r.Success      | Should -BeFalse
        $r.BackupPath   | Should -BeNullOrEmpty
        $r.ErrorMessage | Should -Match 'because it is in use'
        $r.ErrorMessage | Should -Match 'system tray'
        # Live install untouched (the rename never succeeded).
        Test-Path -LiteralPath $live | Should -BeTrue
    }

    It 'falls back to recursive copy when Move-Item fails (cross-volume / OneDrive boundary)' {
        # Regression for the Phase-8.2 copy-fallback wildcard bug:
        # the fallback used -LiteralPath with a trailing '\*', which
        # PowerShell read as a literal filename '*' (not a wildcard)
        # and failed every cross-volume / OneDrive-boundary update
        # with "Cannot find path '...\*' because it does not exist".
        # Forcing Move-Item to throw drives the fallback path; the
        # test passes when the install ends up populated from the
        # staging child's contents.
        $live  = New-FakeInstall -RootName 'apply-fallback'
        $stage = New-FakeStaging -Marker 'v0.2'
        Mock -ModuleName Updater Move-Item {
            throw 'simulated cross-volume failure'
        }
        $r = Invoke-RipperUpdateApply -InstallRoot $live -StagingRoot $stage
        $r.Success | Should -BeTrue
        Test-Path -LiteralPath $live                                 | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $live 'NEW-FILE.md')        | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $live 'Install-MusicRipper.ps1') | Should -BeTrue
        # Marker is the new one (so the contents really were copied,
        # not just a stub left behind by another path).
        (Get-Content -LiteralPath (Join-Path $live 'Install-MusicRipper.ps1') -Raw).Trim() |
            Should -Match 'v0\.2'
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


# =========================================================================
# v0.2.4: tests for the pure-function helpers extracted from the WPF
# dialogs and the Update-MusicRipper.ps1 bootstrap. Locking these in
# prevents the bug classes that hit v0.1.1 (View-on-GitHub button
# stayed hidden), v0.2.0 (startup-prompt showed "(No release notes
# provided.)"), and the hypothetical "added a new dependency module
# but forgot to stage it" from re-shipping.
# =========================================================================

Describe 'Get-RipperReleaseIndexUrl' {
    It 'returns the canonical Releases index URL (NOT a per-tag URL)' {
        $url = Get-RipperReleaseIndexUrl
        $url | Should -Be 'https://github.com/ndbills/MusicRipper/releases'
        # Belt-and-braces: a future refactor that accidentally points
        # this at the /releases/tag/<x> page would break the v0.2.2
        # design decision. Explicit no-/tag/ assertion.
        $url | Should -Not -Match '/releases/tag/'
    }
}

Describe 'Get-RipperAccurateRipDatabaseUrl' {
    # v0.3.0: backs the 'Browse AccurateRip database (web)' button in
    # Show-RegisterDriveDialog. Centralized so the same URL doesn't
    # drift across the dialog click handler + Register-Drive.ps1's
    # doc-comment + future callers. Tests lock the URL shape so a
    # well-intentioned 'let's clean this up' refactor can't silently
    # point parents at the wrong page.

    It 'returns the AccurateRip drive-offsets index URL' {
        $url = Get-RipperAccurateRipDatabaseUrl
        $url | Should -Be 'http://www.accuraterip.com/driveoffsets.htm'
    }

    It 'is a well-formed absolute http(s) URL that ProcessStartInfo can launch' {
        # The button hands the string straight to
        # ProcessStartInfo.FileName + UseShellExecute=$true. The
        # shell-execute path REQUIRES an absolute URI with a scheme;
        # a relative path would silently open in File Explorer
        # against the dialog's CWD. Lock that contract.
        $url = Get-RipperAccurateRipDatabaseUrl
        $uri = $null
        [System.Uri]::TryCreate($url, [System.UriKind]::Absolute, [ref]$uri) |
            Should -BeTrue -Because "URL must parse as absolute for ShellExecute"
        $uri.Scheme | Should -BeIn @('http', 'https')
        $uri.Host   | Should -Be 'www.accuraterip.com'
    }

    It "matches the URL referenced in setup/Register-Drive.ps1's doc-comment" {
        # The console-flow Register-Drive.ps1 cites the same URL in
        # its banner; if either drifts the parent sees inconsistent
        # advice depending on which path they took. Lock the
        # host+path in sync via a regex grep (scheme-agnostic --
        # the doc-comment historically mentions both http:// and
        # https://, but the host + path are what actually matter).
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $script   = Join-Path $repoRoot 'setup\Register-Drive.ps1'
        # The file might predate the helper by a long time; defend
        # the assertion only if the script is still present. Guards
        # against test brittleness if the console flow ever gets
        # removed.
        if (Test-Path -LiteralPath $script) {
            $body = Get-Content -LiteralPath $script -Raw
            $body | Should -Match 'www\.accuraterip\.com/driveoffsets\.htm'
        }
    }
}

Describe 'Test-RipperReleaseHasViewButton' {

    It 'returns $true when ReleaseInfo is a hashtable with a non-empty HtmlUrl' {
        $r = @{ HtmlUrl = 'https://github.com/x/y/releases/tag/v1.0' }
        Test-RipperReleaseHasViewButton -ReleaseInfo $r | Should -BeTrue
    }

    It 'returns $false when HtmlUrl is present but empty (MainBranch fallback shape)' {
        $r = @{ HtmlUrl = '' }
        Test-RipperReleaseHasViewButton -ReleaseInfo $r | Should -BeFalse
    }

    It 'returns $false when ReleaseInfo lacks the HtmlUrl key entirely' {
        # Defensive: an older Get-RipperLatestRelease (or a forked
        # caller building its own hashtable) might not have the key.
        $r = @{ Version = '1.0'; Notes = 'x' }
        Test-RipperReleaseHasViewButton -ReleaseInfo $r | Should -BeFalse
    }

    It 'returns $false when ReleaseInfo is $null' {
        Test-RipperReleaseHasViewButton -ReleaseInfo $null | Should -BeFalse
    }

    It 'returns $false when ReleaseInfo is a [pscustomobject] (the v0.1.1 trap)' {
        # The v0.1.1 bug came from $latest.PSObject.Properties['HtmlUrl']
        # being null on a hashtable. The defensive `-is [hashtable]`
        # guard means a pscustomobject input (which DOES have
        # PSObject.Properties working) is treated as 'unsupported'
        # rather than silently returning $true via a different path.
        $pco = [pscustomobject]@{ HtmlUrl = 'https://example.com/x' }
        Test-RipperReleaseHasViewButton -ReleaseInfo $pco | Should -BeFalse
    }

    It 'works end-to-end against the real Get-RipperLatestRelease output shape' {
        # Highest-fidelity regression: mock the API the way our own
        # production code paths build the hashtable, then assert the
        # helper says yes. If a future refactor accidentally changes
        # the shape returned by Get-RipperLatestRelease, this test
        # fails loudly with the WPF visibility consequence.
        Mock -ModuleName Updater Invoke-RestMethod {
            [pscustomobject]@{
                tag_name    = 'v0.7'
                body        = 'release notes'
                zipball_url = 'https://api.github.com/repos/x/y/zipball/v0.7'
                html_url    = 'https://github.com/x/y/releases/tag/v0.7'
            }
        }
        $r = Get-RipperLatestRelease
        Test-RipperReleaseHasViewButton -ReleaseInfo $r | Should -BeTrue
    }
}

Describe 'Get-RipperReleaseNotesText' {

    It 'returns the trimmed Notes value when present and non-empty' {
        $r = @{ Notes = "  ## What's new`n- Thing 1`n  " }
        $text = Get-RipperReleaseNotesText -ReleaseInfo $r
        $text | Should -Match "## What's new"
        $text.StartsWith(' ') | Should -BeFalse   # leading whitespace stripped
        $text.EndsWith(' ')   | Should -BeFalse   # trailing whitespace stripped
    }

    It 'returns the parent-friendly fallback when Notes key is missing' {
        $r = @{ HtmlUrl = 'https://x'; Version = '1.0' }
        Get-RipperReleaseNotesText -ReleaseInfo $r |
            Should -Be '(No release notes provided.)'
    }

    It 'returns the fallback when Notes is empty string' {
        $r = @{ Notes = '' }
        Get-RipperReleaseNotesText -ReleaseInfo $r |
            Should -Be '(No release notes provided.)'
    }

    It 'returns the fallback when Notes is whitespace-only' {
        $r = @{ Notes = "   `n`t  " }
        Get-RipperReleaseNotesText -ReleaseInfo $r |
            Should -Be '(No release notes provided.)'
    }

    It 'returns the fallback when ReleaseInfo is $null' {
        Get-RipperReleaseNotesText -ReleaseInfo $null |
            Should -Be '(No release notes provided.)'
    }

    It 'works end-to-end against the real Get-RipperLatestRelease output shape' {
        Mock -ModuleName Updater Invoke-RestMethod {
            [pscustomobject]@{
                tag_name    = 'v0.9'
                body        = 'cool changes in v0.9'
                zipball_url = 'https://api.github.com/repos/x/y/zipball/v0.9'
                html_url    = 'https://github.com/x/y/releases/tag/v0.9'
            }
        }
        $r = Get-RipperLatestRelease
        Get-RipperReleaseNotesText -ReleaseInfo $r |
            Should -Be 'cool changes in v0.9'
    }
}

Describe 'Copy-RipperUpdaterBootstrap' {

    function script:New-FakeUpdateInstall {
        # Synthesizes a minimum-viable install tree that has every
        # file Copy-RipperUpdaterBootstrap is supposed to stage.
        param([switch]$NoVersion)
        $root = Join-Path $TestDrive ('install-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root                       -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'src\lib') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'src\ui')  -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'Update-MusicRipper.ps1') -Value '# fake updater'
        foreach ($m in 'Logging','Common','Updater') {
            Set-Content -LiteralPath (Join-Path $root "src\lib\$m.psd1") -Value "@{ RootModule = '$m.psm1' }"
            Set-Content -LiteralPath (Join-Path $root "src\lib\$m.psm1") -Value "# fake $m"
        }
        Set-Content -LiteralPath (Join-Path $root 'src\ui\Show-UpdateDialog.ps1') -Value '# fake dialog'
        if (-not $NoVersion) {
            Set-Content -LiteralPath (Join-Path $root 'VERSION') -Value '0.2.4'
        }
        return $root
    }

    It 'copies the full v0.2.4 manifest (9 files) into a fresh staging dir' {
        $src   = New-FakeUpdateInstall
        $stage = Join-Path $TestDrive ('stage-' + [guid]::NewGuid().ToString('N'))

        $copied = Copy-RipperUpdaterBootstrap -SourceRoot $src -StagingRoot $stage

        # Sanity on the return value: list order is the manifest order,
        # and the count is the locked-in 9 (1 + 3 modules x 2 exts + 1
        # dialog + VERSION).
        @($copied).Count | Should -Be 9

        # Files actually on disk under staging.
        $expected = @(
            'Update-MusicRipper.ps1',
            'src\lib\Logging.psd1', 'src\lib\Logging.psm1',
            'src\lib\Common.psd1',  'src\lib\Common.psm1',
            'src\lib\Updater.psd1', 'src\lib\Updater.psm1',
            'src\ui\Show-UpdateDialog.ps1',
            'VERSION'
        )
        foreach ($rel in $expected) {
            Test-Path -LiteralPath (Join-Path $stage $rel) | Should -BeTrue -Because "Bootstrap should have staged '$rel'"
            $copied | Should -Contain $rel
        }
    }

    It 'skips VERSION cleanly when the source pre-dates v0.2.0' {
        # Older installs (v0.1.x) don't have a VERSION file. The
        # bootstrap must succeed anyway -- the helper falls back to
        # '0.0-unknown' which still works.
        $src   = New-FakeUpdateInstall -NoVersion
        $stage = Join-Path $TestDrive ('stage-' + [guid]::NewGuid().ToString('N'))

        $copied = Copy-RipperUpdaterBootstrap -SourceRoot $src -StagingRoot $stage

        @($copied).Count | Should -Be 8
        $copied                                                  | Should -Not -Contain 'VERSION'
        Test-Path -LiteralPath (Join-Path $stage 'VERSION')      | Should -BeFalse
        # But every REQUIRED file is still there.
        Test-Path -LiteralPath (Join-Path $stage 'src\lib\Updater.psm1') | Should -BeTrue
    }

    It 'throws a helpful error when a required source file is missing' {
        # Catches "I added a new required module but forgot to ship it
        # in the install" -- the bootstrap detects the gap up front
        # instead of letting the helper crash on Import-Module.
        $src   = New-FakeUpdateInstall
        Remove-Item -LiteralPath (Join-Path $src 'src\lib\Updater.psm1') -Force
        $stage = Join-Path $TestDrive ('stage-' + [guid]::NewGuid().ToString('N'))

        { Copy-RipperUpdaterBootstrap -SourceRoot $src -StagingRoot $stage } |
            Should -Throw -ExpectedMessage '*required source file missing*Updater.psm1*'
    }

    It 'throws when SourceRoot itself does not exist' {
        $stage = Join-Path $TestDrive ('stage-' + [guid]::NewGuid().ToString('N'))
        { Copy-RipperUpdaterBootstrap -SourceRoot 'C:\does\not\exist' -StagingRoot $stage } |
            Should -Throw -ExpectedMessage '*SourceRoot does not exist*'
    }

    It 'is idempotent: re-running into the same staging dir overwrites cleanly' {
        $src   = New-FakeUpdateInstall
        $stage = Join-Path $TestDrive ('stage-' + [guid]::NewGuid().ToString('N'))

        $first  = Copy-RipperUpdaterBootstrap -SourceRoot $src -StagingRoot $stage
        $second = Copy-RipperUpdaterBootstrap -SourceRoot $src -StagingRoot $stage

        @($first).Count  | Should -Be 9
        @($second).Count | Should -Be 9
        Test-Path -LiteralPath (Join-Path $stage 'src\lib\Updater.psm1') | Should -BeTrue
    }

    It 'stages files that match the source contents byte-for-byte' {
        # If a future refactor accidentally writes a placeholder
        # instead of copying, the helper would import the wrong code
        # and silently misbehave. Assert content fidelity.
        $src   = New-FakeUpdateInstall
        $stage = Join-Path $TestDrive ('stage-' + [guid]::NewGuid().ToString('N'))
        $sentinel = "## sentinel content $(Get-Random)"
        Set-Content -LiteralPath (Join-Path $src 'src\lib\Updater.psm1') -Value $sentinel

        Copy-RipperUpdaterBootstrap -SourceRoot $src -StagingRoot $stage | Out-Null

        (Get-Content -LiteralPath (Join-Path $stage 'src\lib\Updater.psm1') -Raw).Trim() |
            Should -Be $sentinel
    }

    It "stages the REAL repo's Update-MusicRipper.ps1 + its dependencies (live-tree smoke)" {
        # The strongest guarantee: point Copy-RipperUpdaterBootstrap at
        # the live repo and confirm every manifest entry resolves on
        # the actual install layout. Catches "the bootstrap manifest
        # drifted from the on-disk layout" without us needing a
        # full integration test that spawns a child pwsh process.
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $stage    = Join-Path $TestDrive ('stage-live-' + [guid]::NewGuid().ToString('N'))

        $copied = Copy-RipperUpdaterBootstrap -SourceRoot $repoRoot -StagingRoot $stage

        # Every required file must resolve against the actual repo.
        @($copied) | Should -Contain 'Update-MusicRipper.ps1'
        @($copied) | Should -Contain 'src\lib\Updater.psm1'
        @($copied) | Should -Contain 'src\ui\Show-UpdateDialog.ps1'

        # And the staged Updater.psm1 must AST-parse on its own -- if
        # a future commit lands an orphaned-brace bug in the helper's
        # most critical dependency, this test surfaces it AT THE
        # BOOTSTRAP STEP, not at the parent's-house step.
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $stage 'src\lib\Updater.psm1'),
            [ref]$null, [ref]$errs) | Out-Null
        $errs | Should -BeNullOrEmpty
    }
}
