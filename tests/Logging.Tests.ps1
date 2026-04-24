<#
    Pester tests for src/lib/Logging.psm1.

    Focus: the new Copy-RipperLog snapshot helper. Start/Write/Stop and
    Get-RipperLogPath are exercised indirectly by every other suite that
    starts a session log; we don't re-test them here.

    Run: Invoke-Pester ./tests/Logging.Tests.ps1
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force
}

Describe 'Copy-RipperLog' {
    AfterEach {
        Stop-RipperLog
    }

    It 'copies the active session log into the destination folder' {
        $logRoot = Join-Path ([IO.Path]::GetTempPath()) "logging-tests-$([guid]::NewGuid())"
        $dest    = Join-Path ([IO.Path]::GetTempPath()) "logging-dest-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        try {
            Start-RipperLog -Context 'copy-test' -LogRoot $logRoot | Out-Null
            Write-RipperLog INFO 'unit-test' 'hello world' | Out-Null

            $target = Copy-RipperLog -Destination $dest

            $target | Should -Not -BeNullOrEmpty
            (Test-Path -LiteralPath $target) | Should -BeTrue
            (Get-Content -Raw -LiteralPath $target) | Should -Match 'hello world'
            (Split-Path -Leaf $target)               | Should -Be 'ripper-session.log'
        } finally {
            Remove-Item -LiteralPath $logRoot -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $dest    -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'honors a custom -FileName' {
        $logRoot = Join-Path ([IO.Path]::GetTempPath()) "logging-tests-$([guid]::NewGuid())"
        $dest    = Join-Path ([IO.Path]::GetTempPath()) "logging-dest-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        try {
            Start-RipperLog -Context 'copy-test-named' -LogRoot $logRoot | Out-Null
            $target = Copy-RipperLog -Destination $dest -FileName 'rip.log'
            (Split-Path -Leaf $target) | Should -Be 'rip.log'
        } finally {
            Remove-Item -LiteralPath $logRoot -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $dest    -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns $null and warns when no session is active' {
        $dest = Join-Path ([IO.Path]::GetTempPath()) "logging-dest-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        try {
            $r = Copy-RipperLog -Destination $dest -WarningAction SilentlyContinue
            $r | Should -BeNullOrEmpty
        } finally {
            Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns $null and warns when destination folder is missing' {
        $logRoot = Join-Path ([IO.Path]::GetTempPath()) "logging-tests-$([guid]::NewGuid())"
        try {
            Start-RipperLog -Context 'copy-test-missing' -LogRoot $logRoot | Out-Null
            $bogus = Join-Path ([IO.Path]::GetTempPath()) "logging-missing-$([guid]::NewGuid())"
            $r = Copy-RipperLog -Destination $bogus -WarningAction SilentlyContinue
            $r | Should -BeNullOrEmpty
        } finally {
            Remove-Item -LiteralPath $logRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
