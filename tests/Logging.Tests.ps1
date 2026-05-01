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

Describe 'Set-RipperLogPath' {
    AfterEach {
        Stop-RipperLog
    }

    It 'adopts an existing log file so subsequent writes append to it' {
        $logRoot = Join-Path ([IO.Path]::GetTempPath()) "logging-tests-$([guid]::NewGuid())"
        try {
            # Pretend to be the parent runspace: start a session, write a
            # line, capture the path.
            Start-RipperLog -Context 'parent-test' -LogRoot $logRoot | Out-Null
            Write-RipperLog INFO 'parent' 'from parent' | Out-Null
            $parentLog = Get-RipperLogPath

            # Pretend to be a fresh worker runspace: clear the path then
            # adopt the parent log; subsequent writes should land in the
            # SAME file.
            Stop-RipperLog
            (Get-RipperLogPath) | Should -BeNullOrEmpty
            Set-RipperLogPath -Path $parentLog -Context 'worker-test'
            (Get-RipperLogPath) | Should -Be $parentLog
            Write-RipperLog INFO 'worker' 'from worker' | Out-Null

            $body = Get-Content -Raw -LiteralPath $parentLog
            $body | Should -Match 'from parent'
            $body | Should -Match 'from worker'
        } finally {
            Remove-Item -LiteralPath $logRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'warns and leaves state unchanged when path does not exist' {
        $logRoot = Join-Path ([IO.Path]::GetTempPath()) "logging-tests-$([guid]::NewGuid())"
        try {
            Start-RipperLog -Context 'set-missing' -LogRoot $logRoot | Out-Null
            $original = Get-RipperLogPath

            Set-RipperLogPath -Path 'C:\definitely\nope\nope.log' -WarningAction SilentlyContinue
            (Get-RipperLogPath) | Should -Be $original
        } finally {
            Remove-Item -LiteralPath $logRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'lets Copy-RipperLog snapshot the adopted log' {
        $logRoot = Join-Path ([IO.Path]::GetTempPath()) "logging-tests-$([guid]::NewGuid())"
        $dest    = Join-Path ([IO.Path]::GetTempPath()) "logging-dest-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        try {
            Start-RipperLog -Context 'set-and-copy-parent' -LogRoot $logRoot | Out-Null
            Write-RipperLog INFO 'parent' 'parent line' | Out-Null
            $parentLog = Get-RipperLogPath

            # Worker: forget, adopt, copy.
            Stop-RipperLog
            Set-RipperLogPath -Path $parentLog
            $target = Copy-RipperLog -Destination $dest

            $target | Should -Not -BeNullOrEmpty
            (Get-Content -Raw -LiteralPath $target) | Should -Match 'parent line'
        } finally {
            Remove-Item -LiteralPath $logRoot -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $dest    -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
