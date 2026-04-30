#requires -Version 7.0
#requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

# tests/ConfigDiscovery.Tests.ps1
#   Phase 6.6.B: cover the filesystem-driven discovery helpers used
#   by the WPF config editor and the CLI prompts.
#
# Strategy: against a temp scratch repo containing fake provider
# files / Sync-To* files / a fake Invoke-RipperSync with the Stub
# function, drive each `Get-RipperAvailable*` with -RepoRoot so the
# tests don't depend on (and aren't influenced by) the real checkout.

Set-StrictMode -Version 3.0

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..\src\lib\ConfigDiscovery.psd1' | Resolve-Path
    Import-Module $script:ModulePath -Force

    function New-DiscoveryFakeRepo {
        param(
            [string[]]$SyncFunctionNames = @(),    # for Invoke-RipperSyncTo<Name>
            [string[]]$MetadataFiles     = @(),    # bare suffix names, e.g. 'MusicBrainz'
            [string[]]$CoverArtFiles     = @()     # bare suffix names, e.g. 'CoverArtArchive'
        )
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rdisc_' + [guid]::NewGuid().ToString('N').Substring(0,8))
        $sync = Join-Path $root 'src\sync'
        $meta = Join-Path $root 'src\core\metadata'
        $art  = Join-Path $root 'src\core\coverart'
        New-Item -ItemType Directory -Path $sync, $meta, $art -Force | Out-Null

        if ($SyncFunctionNames.Count -gt 0) {
            $body = @()
            foreach ($n in $SyncFunctionNames) {
                $body += "function Invoke-RipperSyncTo$n { param(`$x) }"
            }
            Set-Content -LiteralPath (Join-Path $sync 'fake-sync.ps1') -Value ($body -join "`n") -Encoding UTF8
        }
        foreach ($n in $MetadataFiles) {
            Set-Content -LiteralPath (Join-Path $meta "Get-MetadataFrom$n.ps1") -Value "# fake $n" -Encoding UTF8
        }
        foreach ($n in $CoverArtFiles) {
            Set-Content -LiteralPath (Join-Path $art "Get-CoverArtFrom$n.ps1") -Value "# fake $n" -Encoding UTF8
        }
        $root
    }
}

AfterAll {
    Remove-Module ConfigDiscovery -ErrorAction SilentlyContinue
}

Describe 'Get-RipperAvailableSyncTargets' {
    It 'returns sorted unique names from Invoke-RipperSyncTo<Name> declarations' {
        $repo = New-DiscoveryFakeRepo -SyncFunctionNames @('Stub','OneDrive','SynologyNAS')
        try {
            $result = Get-RipperAvailableSyncTargets -RepoRoot $repo
            $result | Should -Be @('OneDrive','Stub','SynologyNAS')
        } finally { Remove-Item -LiteralPath $repo -Recurse -Force }
    }

    It 'returns an empty array when src/sync does not exist' {
        $repo = Join-Path ([System.IO.Path]::GetTempPath()) ('rdisc_' + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        try {
            (Get-RipperAvailableSyncTargets -RepoRoot $repo) | Should -BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $repo -Recurse -Force }
    }

    It 'ignores function declarations that are commented out' {
        $repo = New-DiscoveryFakeRepo -SyncFunctionNames @()
        try {
            $sync = Join-Path $repo 'src\sync'
            Set-Content -LiteralPath (Join-Path $sync 'comments.ps1') `
                -Value "# function Invoke-RipperSyncToFakeOne { }`n  function Invoke-RipperSyncToReal { }`n" `
                -Encoding UTF8
            $result = Get-RipperAvailableSyncTargets -RepoRoot $repo
            $result | Should -Be @('Real')
        } finally { Remove-Item -LiteralPath $repo -Recurse -Force }
    }
}

Describe 'Get-RipperAvailableMetadataProviders' {
    It 'returns sorted suffixes from Get-MetadataFrom*.ps1 filenames' {
        $repo = New-DiscoveryFakeRepo -MetadataFiles @('MusicBrainz','CuetoolsDb','GnuDb')
        try {
            (Get-RipperAvailableMetadataProviders -RepoRoot $repo) | Should -Be @('CuetoolsDb','GnuDb','MusicBrainz')
        } finally { Remove-Item -LiteralPath $repo -Recurse -Force }
    }

    It 'maps the ItunesSearch filename to the iTunesSearch canonical name' {
        $repo = New-DiscoveryFakeRepo -MetadataFiles @('ItunesSearch','MusicBrainz')
        try {
            (Get-RipperAvailableMetadataProviders -RepoRoot $repo) | Should -Be @('iTunesSearch','MusicBrainz')
        } finally { Remove-Item -LiteralPath $repo -Recurse -Force }
    }

    It 'returns an empty array when the metadata folder does not exist' {
        $repo = Join-Path ([System.IO.Path]::GetTempPath()) ('rdisc_' + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        try {
            (Get-RipperAvailableMetadataProviders -RepoRoot $repo) | Should -BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $repo -Recurse -Force }
    }
}

Describe 'Get-RipperAvailableCoverArtProviders' {
    It 'returns sorted suffixes from Get-CoverArtFrom*.ps1 filenames' {
        $repo = New-DiscoveryFakeRepo -CoverArtFiles @('CoverArtArchive','Deezer','ItunesSearch')
        try {
            (Get-RipperAvailableCoverArtProviders -RepoRoot $repo) | Should -Be @('CoverArtArchive','Deezer','iTunesSearch')
        } finally { Remove-Item -LiteralPath $repo -Recurse -Force }
    }

    It 'does not pick up Get-CoverArt.ps1 (orchestrator, not a provider)' {
        $repo = New-DiscoveryFakeRepo -CoverArtFiles @('CoverArtArchive')
        try {
            $art = Join-Path $repo 'src\core\coverart'
            Set-Content -LiteralPath (Join-Path $art 'Get-CoverArt.ps1') -Value '# orchestrator' -Encoding UTF8
            (Get-RipperAvailableCoverArtProviders -RepoRoot $repo) | Should -Be @('CoverArtArchive')
        } finally { Remove-Item -LiteralPath $repo -Recurse -Force }
    }
}

Describe 'Real repo discovery (integration)' {
    It 'finds the canonical provider/target lists from this checkout' {
        # Smoke test against the real repo so a future rename is caught.
        (Get-RipperAvailableSyncTargets)         | Should -Contain 'Stub'
        (Get-RipperAvailableSyncTargets)         | Should -Contain 'OneDrive'
        (Get-RipperAvailableSyncTargets)         | Should -Contain 'SynologyNAS'
        (Get-RipperAvailableMetadataProviders)   | Should -Contain 'MusicBrainz'
        (Get-RipperAvailableMetadataProviders)   | Should -Contain 'iTunesSearch'
        (Get-RipperAvailableCoverArtProviders)   | Should -Contain 'CoverArtArchive'
        (Get-RipperAvailableCoverArtProviders)   | Should -Contain 'iTunesSearch'
    }
}
