<#
    Pester tests for src/lib/Config.psm1.
    Run: Invoke-Pester ./tests
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'src\lib\Config.psd1') -Force
}

Describe 'New-RipperConfigObject' {
    It 'sets defaults that pass validation' {
        $cfg = New-RipperConfigObject -LibraryRoot 'D:\Music'
        $cfg.SchemaVersion           | Should -Be 1
        $cfg.LibraryRoot             | Should -Be 'D:\Music'
        $cfg.SynologySyncReviewQueue | Should -BeFalse
        $cfg.HasSynologyCredential   | Should -BeFalse
        $cfg.EjectAfterRip           | Should -BeTrue
        $cfg.ContinuousMode          | Should -BeTrue
        { Assert-RipperConfig -Config $cfg } | Should -Not -Throw
    }

    It 'carries optional fields through' {
        $cfg = New-RipperConfigObject -LibraryRoot 'D:\Music' `
            -DriveLetter 'D:' -DriveOffset 6 `
            -OneDrivePath 'C:\OneDrive\Music' -SynologyUnc '\\nas\music'
        $cfg.DriveLetter  | Should -Be 'D:'
        $cfg.DriveOffset  | Should -Be 6
        $cfg.OneDrivePath | Should -Be 'C:\OneDrive\Music'
        $cfg.SynologyUnc  | Should -Be '\\nas\music'
    }
}

Describe 'Assert-RipperConfig' {
    It 'rejects an unknown SchemaVersion' {
        $bad = [pscustomobject]@{ SchemaVersion = 99; LibraryRoot = 'D:\X' }
        { Assert-RipperConfig -Config $bad } | Should -Throw
    }

    It 'rejects an empty LibraryRoot' {
        $bad = [pscustomobject]@{ SchemaVersion = 1; LibraryRoot = '' }
        { Assert-RipperConfig -Config $bad } | Should -Throw
    }
}

Describe 'Save / Import round-trip' {
    BeforeAll {
        $script:tempDir  = Join-Path ([System.IO.Path]::GetTempPath()) ("musicripper-test-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:tempDir | Out-Null
        $script:cfgPath = Join-Path $script:tempDir 'config.json'
    }
    AfterAll {
        Remove-Item -LiteralPath $script:tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'persists and reloads identically' {
        $orig = New-RipperConfigObject -LibraryRoot 'D:\Music' -DriveLetter 'E:' -DriveOffset 102
        Save-RipperConfig -Config $orig -Path $script:cfgPath
        Test-Path -LiteralPath $script:cfgPath | Should -BeTrue

        $loaded = Import-RipperConfig -Path $script:cfgPath
        $loaded.LibraryRoot | Should -Be $orig.LibraryRoot
        $loaded.DriveLetter | Should -Be 'E:'
        $loaded.DriveOffset | Should -Be 102
    }

    It 'Import-RipperConfig throws when file is missing' {
        { Import-RipperConfig -Path (Join-Path $script:tempDir 'nope.json') } | Should -Throw
    }
}
