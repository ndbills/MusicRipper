<#
    Smoke tests for src/core/Get-DiscId.ps1. Cannot meaningfully test the
    end-to-end disc read without a physical inserted CD, so we verify:
        - Get-CueToolsPath finds the installed CUETools dir.
        - The required DLLs are present in that dir.
        - Initialize-CueToolsAssemblies loads them without throwing.
        - Get-RipperDiscId throws a clear error when no disc is inserted
          (we cannot guarantee the absence of a disc, so this test only
          asserts the function exists; the negative path is exercised
          interactively via the Phase-2 manual verify step).
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'src\lib\Common.psd1') -Force
    . (Join-Path $repoRoot 'src\core\Get-DiscId.ps1')
}

Describe 'Get-CueToolsPath' {
    It 'returns an existing directory containing CUETools.exe' {
        $p = Get-CueToolsPath
        Test-Path -LiteralPath $p | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $p 'CUETools.exe') | Should -BeTrue
    }

    It 'has the three DLLs Get-RipperDiscId depends on' {
        $p = Get-CueToolsPath
        Test-Path -LiteralPath (Join-Path $p 'CUETools.CDImage.dll')           | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $p 'CUETools.Ripper.dll')            | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $p 'plugins\CUETools.Ripper.SCSI.dll') | Should -BeTrue
    }
}

Describe 'Get-RipperDiscId function surface' {
    It 'is defined after dot-sourcing Get-DiscId.ps1' {
        Get-Command Get-RipperDiscId -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'Initialize-CueToolsAssemblies loads the DLLs without throwing' {
        # Regression: a parser bug had Join-Path consuming trailing commas
        # inside an @() array, causing AdditionalChildPath array→string
        # conversion errors. This test exercises the real load path.
        { Initialize-CueToolsAssemblies } | Should -Not -Throw
        [type]::GetType('CUETools.CDImage.CDImageLayout, CUETools.CDImage') |
            Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-RipperDiscId end-to-end (requires inserted disc + admin)' {
    BeforeAll {
        # Skip cleanly when there's no audio CD or we lack elevation, so
        # this file stays runnable on dev boxes and CI without a disc.
        $script:canRun = $false
        try {
            Initialize-CueToolsAssemblies
            $cfg = $null
            try {
                Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\lib\Config.psd1') -Force
                $cfg = Import-RipperConfig
            } catch { }
            if ($cfg -and $cfg.DriveLetter) {
                $r = New-Object CUETools.Ripper.SCSI.CDDriveReader
                try {
                    $r.Open([char]($cfg.DriveLetter[0])) | Out-Null
                    if ($r.TOC -and $r.TOC.AudioTracks -gt 0) { $script:canRun = $true }
                } catch { } finally {
                    $r.Close()   | Out-Null
                    $r.Dispose() | Out-Null
                }
            }
        } catch { }
    }

    It 'returns exactly one object with the documented properties' -Skip:(-not $script:canRun) {
        # Regression: bare $reader.Open() / .Close() / .Dispose() calls were
        # leaking non-void return values into the function's output, turning
        # the result into an array and breaking $disc.DiscId access.
        $disc = Get-RipperDiscId
        @($disc).Count                | Should -Be 1
        $disc | Should -BeOfType ([pscustomobject])
        $disc.PSObject.Properties.Name | Should -Contain 'DiscId'
        $disc.PSObject.Properties.Name | Should -Contain 'AudioTracks'
        $disc.PSObject.Properties.Name | Should -Contain 'Tracks'
        $disc.DiscId                  | Should -Match '^[A-Za-z0-9._-]{20,40}$'
        $disc.AudioTracks             | Should -BeGreaterThan 0
        @($disc.Tracks).Count         | Should -Be $disc.TrackCount
    }
}
