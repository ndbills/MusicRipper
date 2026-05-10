#requires -Version 7.0
#requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

# tests/Show-RipperConfigDialog.Tests.ps1
#   Phase 6.6.B: cover the pure-logic helpers exposed by the WPF
#   editor:
#     * Test-RipperConfigEditorComplete  (OK-enable predicate)
#     * Move-RipperConfigEditorListItem  (up/down reorder)
#     * Get-RipperOrderedCheckboxState   (saved+available merge)
#
# The Window/XAML itself stays manual-verify -- WPF round-trip in
# Pester is fragile and adds zero coverage of the actual decisions
# the helpers encode.

Set-StrictMode -Version 3.0

BeforeAll {
    . (Join-Path $PSScriptRoot '..\src\ui\Show-RipperConfigDialog.ps1')

    function New-MinimalCfg {
        # The minimum field set required by Test-RipperConfigEditorComplete.
        param(
            [string]$LibraryRoot                = 'C:\Music',
            [string]$ContactAddress             = 'me@example.com',
            [string[]]$SyncTargets              = @('Stub'),
            [bool]$HasSynologyCredential        = $false
        )
        [pscustomobject]@{
            LibraryRoot             = $LibraryRoot
            contactAddress          = $ContactAddress
            SyncTargets             = $SyncTargets
            OneDriveSyncTargetRoot  = $null
            SynologyUnc             = $null
            HasSynologyCredential   = $HasSynologyCredential
        }
    }
}

Describe 'Test-RipperConfigEditorComplete' {
    Context 'non-FirstRun' {
        It 'requires LibraryRoot AND a non-empty contactAddress' {
            $cfg = [pscustomobject]@{
                LibraryRoot          = 'C:\Music'
                contactAddress       = 'me@example.com'
                SyncTargets          = @()
            }
            (Test-RipperConfigEditorComplete -Config $cfg) | Should -BeTrue
        }
        It 'rejects a blank LibraryRoot' {
            $cfg = [pscustomobject]@{
                LibraryRoot          = '   '
                contactAddress       = 'me@example.com'
                SyncTargets          = @('Stub')
            }
            (Test-RipperConfigEditorComplete -Config $cfg) | Should -BeFalse
        }
        It 'rejects a blank contactAddress (required by MB on every metadata call)' {
            $cfg = [pscustomobject]@{
                LibraryRoot          = 'C:\Music'
                contactAddress       = $null
                SyncTargets          = @('Stub')
            }
            (Test-RipperConfigEditorComplete -Config $cfg) | Should -BeFalse
        }
        It 'rejects a whitespace-only contactAddress' {
            $cfg = [pscustomobject]@{
                LibraryRoot          = 'C:\Music'
                contactAddress       = '   '
                SyncTargets          = @('Stub')
            }
            (Test-RipperConfigEditorComplete -Config $cfg) | Should -BeFalse
        }
    }

    Context 'FirstRun' {
        It 'accepts a fully-populated config (email contact)' {
            $cfg = New-MinimalCfg
            (Test-RipperConfigEditorComplete -Config $cfg -FirstRun) | Should -BeTrue
        }
        It 'accepts a URL contact address (e.g. GitHub profile)' {
            $cfg = New-MinimalCfg -ContactAddress 'https://github.com/example'
            (Test-RipperConfigEditorComplete -Config $cfg -FirstRun) | Should -BeTrue
        }
        It 'rejects an empty contactAddress' {
            $cfg = New-MinimalCfg -ContactAddress ''
            (Test-RipperConfigEditorComplete -Config $cfg -FirstRun) | Should -BeFalse
        }
        It 'rejects a whitespace-only contactAddress' {
            $cfg = New-MinimalCfg -ContactAddress '   '
            (Test-RipperConfigEditorComplete -Config $cfg -FirstRun) | Should -BeFalse
        }
        It 'rejects an empty SyncTargets list' {
            $cfg = New-MinimalCfg -SyncTargets @()
            (Test-RipperConfigEditorComplete -Config $cfg -FirstRun) | Should -BeFalse
        }
        It 'rejects a missing LibraryRoot' {
            $cfg = New-MinimalCfg -LibraryRoot ''
            (Test-RipperConfigEditorComplete -Config $cfg -FirstRun) | Should -BeFalse
        }
    }

    Context 'OneDrive cross-field rule' {
        It 'non-FirstRun: rejects OneDrive checked but no OneDrive root' {
            $cfg = New-MinimalCfg -SyncTargets @('OneDrive')
            (Test-RipperConfigEditorComplete -Config $cfg) | Should -BeFalse
        }
        It 'non-FirstRun: accepts OneDrive checked when OneDrive root is set' {
            $cfg = New-MinimalCfg -SyncTargets @('OneDrive')
            $cfg.OneDriveSyncTargetRoot = 'C:\Users\Me\OneDrive\Music'
            (Test-RipperConfigEditorComplete -Config $cfg) | Should -BeTrue
        }
        It 'non-FirstRun: ignores OneDrive root when OneDrive is not in SyncTargets' {
            $cfg = New-MinimalCfg -SyncTargets @('Stub')
            (Test-RipperConfigEditorComplete -Config $cfg) | Should -BeTrue
        }
        It 'FirstRun: rejects OneDrive checked but no OneDrive root' {
            $cfg = New-MinimalCfg -SyncTargets @('OneDrive')
            (Test-RipperConfigEditorComplete -Config $cfg -FirstRun) | Should -BeFalse
        }
        It 'FirstRun: accepts OneDrive checked when OneDrive root is set' {
            $cfg = New-MinimalCfg -SyncTargets @('OneDrive')
            $cfg.OneDriveSyncTargetRoot = 'C:\Users\Me\OneDrive\Music'
            (Test-RipperConfigEditorComplete -Config $cfg -FirstRun) | Should -BeTrue
        }
    }

    Context 'SynologyNAS cross-field rule' {
        It 'non-FirstRun: rejects SynologyNAS checked but no UNC path' {
            $cfg = New-MinimalCfg -SyncTargets @('SynologyNAS')
            (Test-RipperConfigEditorComplete -Config $cfg) | Should -BeFalse
        }
        It 'non-FirstRun: rejects SynologyNAS checked + UNC set but no stored credential' {
            $cfg = New-MinimalCfg -SyncTargets @('SynologyNAS')
            $cfg.SynologyUnc = '\\nas\music'
            $cfg.HasSynologyCredential = $false
            (Test-RipperConfigEditorComplete -Config $cfg) | Should -BeFalse
        }
        It 'non-FirstRun: accepts SynologyNAS checked when UNC is set AND credential is stored' {
            $cfg = New-MinimalCfg -SyncTargets @('SynologyNAS') -HasSynologyCredential $true
            $cfg.SynologyUnc = '\\nas\music'
            (Test-RipperConfigEditorComplete -Config $cfg) | Should -BeTrue
        }
        It 'non-FirstRun: ignores SynologyUnc and credential when SynologyNAS is not in SyncTargets' {
            $cfg = New-MinimalCfg -SyncTargets @('Stub')
            (Test-RipperConfigEditorComplete -Config $cfg) | Should -BeTrue
        }
        It 'FirstRun: rejects SynologyNAS checked but no UNC path' {
            $cfg = New-MinimalCfg -SyncTargets @('SynologyNAS')
            (Test-RipperConfigEditorComplete -Config $cfg -FirstRun) | Should -BeFalse
        }
        It 'FirstRun: rejects SynologyNAS checked + UNC set but no credential' {
            $cfg = New-MinimalCfg -SyncTargets @('SynologyNAS')
            $cfg.SynologyUnc = '\\nas\music'
            (Test-RipperConfigEditorComplete -Config $cfg -FirstRun) | Should -BeFalse
        }
        It 'FirstRun: accepts SynologyNAS checked when UNC is set AND credential is stored' {
            $cfg = New-MinimalCfg -SyncTargets @('SynologyNAS') -HasSynologyCredential $true
            $cfg.SynologyUnc = '\\nas\music'
            (Test-RipperConfigEditorComplete -Config $cfg -FirstRun) | Should -BeTrue
        }
    }
}

Describe 'Move-RipperConfigEditorListItem' {
    It 'moves an item up' {
        $r = Move-RipperConfigEditorListItem -List @('A','B','C') -Index 2 -Direction -1
        $r | Should -Be @('A','C','B')
    }
    It 'moves an item down' {
        $r = Move-RipperConfigEditorListItem -List @('A','B','C') -Index 0 -Direction 1
        $r | Should -Be @('B','A','C')
    }
    It 'is a no-op at the top with -1' {
        $r = Move-RipperConfigEditorListItem -List @('A','B','C') -Index 0 -Direction -1
        $r | Should -Be @('A','B','C')
    }
    It 'is a no-op at the bottom with +1' {
        $r = Move-RipperConfigEditorListItem -List @('A','B','C') -Index 2 -Direction 1
        $r | Should -Be @('A','B','C')
    }
    It 'is a no-op for a single-item list' {
        $r = Move-RipperConfigEditorListItem -List @('Only') -Index 0 -Direction 1
        $r | Should -Be @('Only')
    }
    It 'does not mutate the input array' {
        $orig = @('A','B','C')
        $r = Move-RipperConfigEditorListItem -List $orig -Index 0 -Direction 1
        $orig | Should -Be @('A','B','C')
        $r    | Should -Be @('B','A','C')
    }
}

Describe 'Get-RipperOrderedCheckboxState' {
    It 'preserves saved order with checked=true and appends new options unchecked' {
        $r = Get-RipperOrderedCheckboxState -Saved @('B','A') -Available @('A','B','C')
        @($r).Count | Should -Be 3
        $r[0].Name | Should -Be 'B'; $r[0].Checked | Should -BeTrue
        $r[1].Name | Should -Be 'A'; $r[1].Checked | Should -BeTrue
        $r[2].Name | Should -Be 'C'; $r[2].Checked | Should -BeFalse
    }
    It 'drops saved entries that are no longer available' {
        $r = Get-RipperOrderedCheckboxState -Saved @('Gone','A') -Available @('A','B')
        @($r.Name) | Should -Be @('A','B')
        $r[0].Checked | Should -BeTrue
        $r[1].Checked | Should -BeFalse
    }
    It 'returns all-unchecked when nothing was saved' {
        $r = Get-RipperOrderedCheckboxState -Saved @() -Available @('A','B')
        @($r.Name) | Should -Be @('A','B')
        ($r | Where-Object Checked) | Should -BeNullOrEmpty
    }
    It 'returns an empty array when nothing is available' {
        $r = Get-RipperOrderedCheckboxState -Saved @('A') -Available @()
        @($r).Count | Should -Be 0
    }
    It 'deduplicates a saved name that appears twice' {
        $r = Get-RipperOrderedCheckboxState -Saved @('A','A','B') -Available @('A','B')
        @($r.Name) | Should -Be @('A','B')
    }
}
