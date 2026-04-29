#requires -Version 7.0
#requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

<#
    Pester tests for src/sync/Invoke-PendingSync.ps1 (Phase 6.5).
    Exercises the in-process function directly with mocked
    Invoke-RipperSync and Invoke-RipperLibraryRetention.
#>

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src\lib\Logging.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src\lib\Common.psd1')  -Force
    . (Join-Path $script:repoRoot 'src\core\Get-LibraryDiscIndex.ps1')
    . (Join-Path $script:repoRoot 'src\sync\Get-LibrarySyncState.ps1')
    . (Join-Path $script:repoRoot 'src\sync\Invoke-PendingSync.ps1')

    # Stub the two collaborators so we never touch real targets.
    function global:Invoke-RipperSync {
        param($AlbumPath, $LibraryRoot, $DiscId, $Config)
        # Default: succeed. Tests override via Mock with -ParameterFilter.
        @{ AlbumPath=$AlbumPath; Targets=@(@{Target='Stub';Status='OK';BytesCopied=0;Diagnostic=''}); AllOk=$true; Skipped=$false }
    }
    function global:Invoke-RipperLibraryRetention {
        param($AlbumPath, $LibraryRoot, $Config, $SyncResult, $DiscId)
        @{ Action='None'; Path=$AlbumPath }
    }

    function script:New-Lib {
        $lib = Join-Path ([System.IO.Path]::GetTempPath()) ("pendingsync-tests-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $lib '.musicripper') -Force | Out-Null
        $lib
    }
    function script:New-Album {
        param([string]$Lib, [string]$Rel)
        $abs = Join-Path $Lib ($Rel -replace '/','\')
        New-Item -ItemType Directory -Path $abs -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $abs 'a.flac') -Value 'x' -NoNewline
        $abs
    }
    function script:Write-State {
        param([string]$Lib, [hashtable]$Index)
        $path = Join-Path (Join-Path $Lib '.musicripper') 'sync-state.json'
        ($Index | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $path -Encoding UTF8
    }
    function script:New-Cfg {
        param([string[]]$Targets = @('Stub'))
        [pscustomobject]@{ SyncTargets = $Targets; LocalRetention = 'Keep' }
    }
    function script:New-Entry {
        param([hashtable]$Targets, [string]$DiscId='d1')
        $tObj = [pscustomobject]@{}
        foreach ($k in $Targets.Keys) {
            $tObj | Add-Member -NotePropertyName $k -NotePropertyValue ([pscustomobject]@{
                Status      = $Targets[$k]
                BytesCopied = 0
                Diagnostic  = ''
                LastAttempt = (Get-Date).ToString('o')
            })
        }
        [pscustomobject]@{
            DiscId            = $DiscId
            Targets           = $tObj
            AllOk             = $false
            LastSync          = (Get-Date).ToString('o')
            RetentionApplied  = $null
            Source            = 'library'
        }
    }
}

AfterAll {
    Remove-Item function:global:Invoke-RipperSync           -ErrorAction SilentlyContinue
    Remove-Item function:global:Invoke-RipperLibraryRetention -ErrorAction SilentlyContinue
}

Describe 'Get-RipperPendingSyncPlan' {

    It 'returns an empty plan when every entry is already OK' {
        $state = @{
            'Foo/Bar' = New-Entry -Targets @{ Stub='OK' }
        }
        $r = Get-RipperPendingSyncPlan -State $state -ConfiguredTargets @('Stub')
        $r.Plan.Count | Should -Be 0
        $r.Pruned     | Should -BeFalse
    }

    It 'flags an entry with a Failed target' {
        $state = @{
            'Foo/Bar' = New-Entry -Targets @{ Stub='Failed' }
        }
        $r = Get-RipperPendingSyncPlan -State $state -ConfiguredTargets @('Stub')
        $r.Plan.Count | Should -Be 1
        $r.Plan[0].Key | Should -Be 'Foo/Bar'
    }

    It 'flags an entry missing a required target' {
        $state = @{
            'Foo/Bar' = New-Entry -Targets @{ Stub='OK' }
        }
        $r = Get-RipperPendingSyncPlan -State $state -ConfiguredTargets @('Stub','OneDrive')
        $r.Plan.Count | Should -Be 1
    }

    It 'prunes targets no longer in the configured list' {
        $state = @{
            'Foo/Bar' = New-Entry -Targets @{ Stub='OK'; OldTarget='Failed' }
        }
        $r = Get-RipperPendingSyncPlan -State $state -ConfiguredTargets @('Stub')
        $r.Pruned | Should -BeTrue
        $state['Foo/Bar'].Targets.PSObject.Properties.Name | Should -Not -Contain 'OldTarget'
    }

    It '-Force returns every entry regardless of status' {
        $state = @{
            'A' = New-Entry -Targets @{ Stub='OK' }
            'B' = New-Entry -Targets @{ Stub='OK' }
        }
        $r = Get-RipperPendingSyncPlan -State $state -ConfiguredTargets @('Stub') -Force
        $r.Plan.Count | Should -Be 2
    }
}

Describe 'Invoke-RipperPendingSync' {

    BeforeEach {
        $script:lib = New-Lib
    }
    AfterEach {
        if ($script:lib -and (Test-Path -LiteralPath $script:lib)) {
            Remove-Item -LiteralPath $script:lib -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns Total=0 when sync-state is empty' {
        Write-State -Lib $script:lib -Index @{}
        $r = Invoke-RipperPendingSync -LibraryRoot $script:lib -Config (New-Cfg)
        $r.Total | Should -Be 0
        $r.Synced | Should -Be 0
    }

    It 'returns Total=0 when no SyncTargets are configured' {
        Write-State -Lib $script:lib -Index @{ 'A/B' = New-Entry -Targets @{ Stub='Failed' } }
        $r = Invoke-RipperPendingSync -LibraryRoot $script:lib -Config (New-Cfg -Targets @())
        $r.Total | Should -Be 0
    }

    It 'retries a single failing album and reports Synced=1 on success' {
        New-Album -Lib $script:lib -Rel 'Foo/Bar'
        Write-State -Lib $script:lib -Index @{ 'Foo/Bar' = New-Entry -Targets @{ Stub='Failed' } }
        $r = Invoke-RipperPendingSync -LibraryRoot $script:lib -Config (New-Cfg)
        $r.Total        | Should -Be 1
        $r.Synced       | Should -Be 1
        $r.StillFailing | Should -Be 0
        $r.Albums.Count | Should -Be 1
        $r.Albums[0].Status | Should -Be 'OK'
    }

    It 'reports StillFailing when Invoke-RipperSync returns AllOk=$false' {
        function global:Invoke-RipperSync {
            param($AlbumPath, $LibraryRoot, $DiscId, $Config)
            @{
                AlbumPath=$AlbumPath
                Targets=@(@{Target='Stub';Status='Failed';BytesCopied=0;Diagnostic='still down'})
                AllOk=$false; Skipped=$false
            }
        }
        try {
            New-Album -Lib $script:lib -Rel 'Foo/Bar'
            Write-State -Lib $script:lib -Index @{ 'Foo/Bar' = New-Entry -Targets @{ Stub='Failed' } }
            $r = Invoke-RipperPendingSync -LibraryRoot $script:lib -Config (New-Cfg)
            $r.StillFailing       | Should -Be 1
            $r.Albums[0].Status   | Should -Be 'StillFailing'
            $r.Albums[0].FailedTargets | Should -Contain 'Stub'
            $r.Albums[0].Diagnostic    | Should -Match 'still down'
        } finally {
            # Restore the default success stub for subsequent tests.
            function global:Invoke-RipperSync {
                param($AlbumPath, $LibraryRoot, $DiscId, $Config)
                @{ AlbumPath=$AlbumPath; Targets=@(@{Target='Stub';Status='OK';BytesCopied=0;Diagnostic=''}); AllOk=$true; Skipped=$false }
            }
        }
    }

    It 'skips albums whose folder is gone' {
        # No New-Album for this rel -- folder absent.
        Write-State -Lib $script:lib -Index @{ 'Ghost/Album' = New-Entry -Targets @{ Stub='Failed' } }
        $r = Invoke-RipperPendingSync -LibraryRoot $script:lib -Config (New-Cfg)
        $r.Skipped | Should -Be 1
        $r.Synced  | Should -Be 0
        $r.Albums[0].Status | Should -Be 'Skipped'
    }

    It 'invokes the ProgressCallback for plan/album-start/album-end/done' {
        New-Album -Lib $script:lib -Rel 'A/B'
        Write-State -Lib $script:lib -Index @{ 'A/B' = New-Entry -Targets @{ Stub='Failed' } }
        $script:phases = @()
        $cb = { param($Phase, $i, $t, $k, $l, $rs, $rd) $script:phases += $Phase }
        Invoke-RipperPendingSync -LibraryRoot $script:lib -Config (New-Cfg) -ProgressCallback $cb | Out-Null
        $script:phases | Should -Contain 'plan'
        $script:phases | Should -Contain 'album-start'
        $script:phases | Should -Contain 'album-end'
        $script:phases | Should -Contain 'done'
    }

    It 'honours -CancelRequested before starting the next album' {
        New-Album -Lib $script:lib -Rel 'A/B'
        New-Album -Lib $script:lib -Rel 'C/D'
        Write-State -Lib $script:lib -Index @{
            'A/B' = New-Entry -Targets @{ Stub='Failed' }
            'C/D' = New-Entry -Targets @{ Stub='Failed' }
        }
        # Trip the flag immediately so neither album runs.
        $cancel = { $true }
        $r = Invoke-RipperPendingSync -LibraryRoot $script:lib -Config (New-Cfg) -CancelRequested $cancel
        $r.Cancelled | Should -BeTrue
        $r.Synced    | Should -Be 0
    }

    It 'calls Invoke-RipperLibraryRetention exactly once per successful album' {
        $script:retentionCalls = 0
        function global:Invoke-RipperLibraryRetention {
            param($AlbumPath, $LibraryRoot, $Config, $SyncResult, $DiscId)
            $script:retentionCalls++
            @{ Action='None'; Path=$AlbumPath }
        }
        try {
            New-Album -Lib $script:lib -Rel 'A/B'
            New-Album -Lib $script:lib -Rel 'C/D'
            Write-State -Lib $script:lib -Index @{
                'A/B' = New-Entry -Targets @{ Stub='Failed' }
                'C/D' = New-Entry -Targets @{ Stub='Failed' }
            }
            Invoke-RipperPendingSync -LibraryRoot $script:lib -Config (New-Cfg) | Out-Null
            $script:retentionCalls | Should -Be 2
        } finally {
            function global:Invoke-RipperLibraryRetention {
                param($AlbumPath, $LibraryRoot, $Config, $SyncResult, $DiscId)
                @{ Action='None'; Path=$AlbumPath }
            }
        }
    }
}
