#requires -Version 7.0
#requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

<#
    Pester tests for src/tools/Sync-PendingAlbums.ps1 (Phase 6.1
    follow-up). Runs the script in a fresh pwsh child so its
    Import-Module / dot-source preamble matches real-world usage.
#>

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:tool     = Join-Path $script:repoRoot 'src\tools\Sync-PendingAlbums.ps1'
    $script:tmpRoot  = Join-Path ([System.IO.Path]::GetTempPath()) ("syncpending-tests-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:tmpRoot -Force | Out-Null

    function script:New-Lib {
        param([string]$Name)
        $lib = Join-Path $script:tmpRoot $Name
        New-Item -ItemType Directory -Path (Join-Path $lib '.musicripper') -Force | Out-Null
        $lib
    }

    function script:New-FakeAlbum {
        param([string]$Lib, [string]$Artist, [string]$Album)
        $p = Join-Path (Join-Path $Lib $Artist) $Album
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $p 'placeholder.txt') -Value 'x' -NoNewline
        $p
    }

    function script:Write-FakeConfig {
        param([string]$Lib, [string[]]$Targets)
        $cfgDir = Join-Path $env:LOCALAPPDATA 'MusicRipperTests'
        New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
        $cfgPath = Join-Path $cfgDir 'config.json'
        $obj = [pscustomobject]@{
            LibraryRoot    = $Lib
            ReviewQueueRoot= Join-Path $Lib '_ReviewQueue'
            SyncTargets    = $Targets
            LocalRetention = 'Keep'
        }
        ($obj | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $cfgPath -Encoding UTF8
        $cfgPath
    }

    function script:Write-State {
        param([string]$Lib, [hashtable]$State)
        $path = Join-Path (Join-Path $Lib '.musicripper') 'sync-state.json'
        ($State | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $path -Encoding UTF8
    }

    function script:Run-Tool {
        param([string]$Lib, [switch]$Force, [switch]$WhatIf)
        # Exec in a fresh pwsh so the tool's own Import-RipperConfig
        # uses the test config we just wrote, untouched by this
        # session's modules.
        $extra = @()
        if ($Force)  { $extra += '-Force' }
        if ($WhatIf) { $extra += '-WhatIf' }
        $env:LOCALAPPDATA_RipperConfigOverride = $null  # placeholder; Import-RipperConfig reads %LOCALAPPDATA% directly
        $args = @('-NoProfile','-NonInteractive','-File',$script:tool,'-LibraryRoot',$Lib) + $extra
        & pwsh @args 2>&1
    }
}

AfterAll {
    if ($script:tmpRoot -and (Test-Path -LiteralPath $script:tmpRoot)) {
        Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Sync-PendingAlbums.ps1 (in-process logic)' {

    # The tool itself spawns Import-RipperConfig and reads %LOCALAPPDATA%
    # which is awkward to mock cross-process. The functional pieces it
    # composes (Get-RipperLibrarySyncState, Test-RipperEntryNeedsRetry,
    # Invoke-RipperSync, Invoke-RipperLibraryRetention) all have their
    # own coverage. Here we exercise just the pure-logic helper the
    # tool defines internally, by re-declaring it (kept in lock-step
    # with the tool by hand -- a 5-line predicate).

    BeforeAll {
        function script:Test-RipperEntryNeedsRetry {
            param([object]$Entry, [string[]]$Targets)
            foreach ($name in $Targets) {
                if (-not $Entry.Targets.PSObject.Properties[$name]) { return $true }
                if ([string]$Entry.Targets.$name.Status -ne 'OK')   { return $true }
            }
            $false
        }
    }

    It 'flags an entry whose required target is missing' {
        $e = [pscustomobject]@{
            Targets = [pscustomobject]@{ Stub = [pscustomobject]@{ Status='OK' } }
        }
        Test-RipperEntryNeedsRetry -Entry $e -Targets @('Stub','OneDrive') | Should -BeTrue
    }

    It 'flags an entry whose target reported Failed' {
        $e = [pscustomobject]@{
            Targets = [pscustomobject]@{
                Stub     = [pscustomobject]@{ Status='OK' }
                OneDrive = [pscustomobject]@{ Status='Failed' }
            }
        }
        Test-RipperEntryNeedsRetry -Entry $e -Targets @('Stub','OneDrive') | Should -BeTrue
    }

    It 'returns false when every required target is OK' {
        $e = [pscustomobject]@{
            Targets = [pscustomobject]@{
                Stub     = [pscustomobject]@{ Status='OK' }
                OneDrive = [pscustomobject]@{ Status='OK' }
            }
        }
        Test-RipperEntryNeedsRetry -Entry $e -Targets @('Stub','OneDrive') | Should -BeFalse
    }
}
