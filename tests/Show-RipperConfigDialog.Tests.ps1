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
            [string]$Email                      = 'me@example.com',
            [string[]]$SyncTargets              = @('Stub')
        )
        [pscustomobject]@{
            LibraryRoot          = $LibraryRoot
            MusicBrainzUserAgent = "MusicRipper/0.1 ( $Email )"
            SyncTargets          = $SyncTargets
        }
    }
}

Describe 'Test-RipperConfigEditorComplete' {
    Context 'non-FirstRun' {
        It 'requires only LibraryRoot' {
            $cfg = [pscustomobject]@{
                LibraryRoot          = 'C:\Music'
                MusicBrainzUserAgent = $null
                SyncTargets          = @()
            }
            (Test-RipperConfigEditorComplete -Config $cfg) | Should -BeTrue
        }
        It 'rejects a blank LibraryRoot' {
            $cfg = [pscustomobject]@{
                LibraryRoot          = '   '
                MusicBrainzUserAgent = 'MusicRipper/0.1 ( me@example.com )'
                SyncTargets          = @('Stub')
            }
            (Test-RipperConfigEditorComplete -Config $cfg) | Should -BeFalse
        }
    }

    Context 'FirstRun' {
        It 'accepts a fully-populated config' {
            $cfg = New-MinimalCfg
            (Test-RipperConfigEditorComplete -Config $cfg -FirstRun) | Should -BeTrue
        }
        It 'rejects the placeholder unknown@example.com email' {
            $cfg = New-MinimalCfg -Email 'unknown@example.com'
            (Test-RipperConfigEditorComplete -Config $cfg -FirstRun) | Should -BeFalse
        }
        It 'rejects a UA missing the email parens' {
            $cfg = [pscustomobject]@{
                LibraryRoot          = 'C:\Music'
                MusicBrainzUserAgent = 'MusicRipper/0.1 me@example.com'
                SyncTargets          = @('Stub')
            }
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
