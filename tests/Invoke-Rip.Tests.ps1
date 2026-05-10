#Requires -Version 7.0
#Requires -Module Pester

<#
.SYNOPSIS
    Phase 6.4.6: pure-logic tests for the friendly-error rewriter and
    the firmware-revision lookup added to src/core/Invoke-Rip.ps1.

    Both helpers are top-level functions in Invoke-Rip.ps1; dot-sourcing
    the file is safe because the CUETools DLL load is lazy (gated on
    Initialize-RipAssemblies) and the functions don't reference the
    Invoke-RipperRip body.
#>

Set-StrictMode -Version 3.0

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'src\core\Invoke-Rip.ps1')
}

Describe 'ConvertTo-RipperFriendlyRipError (Phase 6.4.6)' {

    It 'rewrites the "ILLEGAL MODE FOR THIS TRACK" SCSI error into a parent-friendly message' {
        # Real exception text from the parents'-PC TS-H653H disc-1 log.
        $raw = 'Exception calling "Read" with "2" argument(s): "Error reading CD: illegal request: ILLEGAL MODE FOR THIS TRACK"'
        $msg = ConvertTo-RipperFriendlyRipError `
                -ExceptionMessage $raw `
                -DriveName        'TSSTcorp - DVD+-RW TS-H653H' `
                -FirmwareRevision 'D300'
        $msg | Should -Not -BeNullOrEmpty
        # Names the drive + firmware so support diagnostics are useful.
        $msg | Should -Match 'TSSTcorp - DVD\+-RW TS-H653H'
        $msg | Should -Match 'firmware D300'
        # Tells the parent what to actually do.
        $msg | Should -Match 'use a different CD drive'
        # Preserves the underlying error for diagnostics.
        $msg | Should -Match 'ILLEGAL MODE FOR THIS TRACK'
        # Points at TROUBLESHOOTING.md for follow-up.
        $msg | Should -Match 'TROUBLESHOOTING\.md'
    }

    It 'rewrites the "failed to autodetect read command" SCSI error too (disc-2 form)' {
        # Real exception text from the parents'-PC TS-H653H disc-2 log;
        # CUETools surfaces this when none of its READ CD probes work.
        $raw = @'
Exception calling "Read" with "2" argument(s): "failed to autodetect read command
BEh, 10h, , 16 blocks at a time: ILLEGAL MODE FOR THIS TRACK (1261.9901ms)
BEh, F8h, , 16 blocks at a time: ILLEGAL MODE FOR THIS TRACK (1032.6387ms)
D8h, 10h, , 16 blocks at a time: INVALID COMMAND OPERATION CODE (3.5371ms)
"
'@
        $msg = ConvertTo-RipperFriendlyRipError `
                -ExceptionMessage $raw `
                -DriveName        'TSSTcorp - DVD+-RW TS-H653H'
        $msg | Should -Not -BeNullOrEmpty
        $msg | Should -Match 'TSSTcorp - DVD\+-RW TS-H653H'
        $msg | Should -Match 'use a different CD drive'
    }

    It 'returns $null for an unrelated rip exception (must NOT mask other errors)' {
        # Any other failure mode should fall through to the original
        # rethrow path so we don't hide bugs behind the friendly text.
        $msg = ConvertTo-RipperFriendlyRipError `
                -ExceptionMessage 'NullReferenceException at <some unrelated stack>' `
                -DriveName        'ASUS BW-12B1ST'
        $msg | Should -BeNullOrEmpty
    }

    It 'returns $null for an empty / whitespace exception message' {
        (ConvertTo-RipperFriendlyRipError -ExceptionMessage '' -DriveName 'foo') |
            Should -BeNullOrEmpty
        (ConvertTo-RipperFriendlyRipError -ExceptionMessage '   ' -DriveName 'foo') |
            Should -BeNullOrEmpty
    }

    It 'omits the firmware annotation when not supplied (does not produce "(firmware )")' {
        $raw = 'Error reading CD: illegal request: ILLEGAL MODE FOR THIS TRACK'
        $msg = ConvertTo-RipperFriendlyRipError `
                -ExceptionMessage $raw `
                -DriveName        'TSSTcorp - DVD+-RW TS-H653H'
        # An empty firmware annotation would render as "(firmware )"
        # which looks broken in a parent-facing dialog. Make sure the
        # default-empty path produces no parens at all.
        $msg | Should -Not -Match '\(firmware\s*\)'
    }

    It 'falls back to a placeholder when DriveName is empty (still rewrites the message)' {
        $raw = 'Error reading CD: illegal request: ILLEGAL MODE FOR THIS TRACK'
        $msg = ConvertTo-RipperFriendlyRipError `
                -ExceptionMessage $raw `
                -DriveName        ''
        $msg | Should -Not -BeNullOrEmpty
        $msg | Should -Match '<unknown drive>'
    }

    It 'matches the patterns case-insensitively (defensive)' {
        $raw = 'error reading cd: illegal request: illegal mode for this track'
        $msg = ConvertTo-RipperFriendlyRipError `
                -ExceptionMessage $raw `
                -DriveName        'TSSTcorp - DVD+-RW TS-H653H'
        $msg | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-RipperDriveFirmware (Phase 6.4.6)' {

    It 'returns "" for a drive letter with no Win32_CDROMDrive match' {
        # Z: is unlikely to be a real CD drive on the test machine; even
        # if it is, the function never throws -- worst case it returns
        # the actual firmware. The empty-on-miss case is the contract
        # we care about here, so use Mock to force the no-match branch.
        Mock -CommandName Get-CimInstance -MockWith { @() }
        (Get-RipperDriveFirmware -DriveLetter 'Z') | Should -Be ''
    }

    It 'returns "" when Get-CimInstance throws (best-effort, never propagates)' {
        Mock -CommandName Get-CimInstance -MockWith { throw 'wmi unavailable' }
        (Get-RipperDriveFirmware -DriveLetter 'D') | Should -Be ''
    }

    It 'returns the firmware revision when the drive is found' {
        Mock -CommandName Get-CimInstance -MockWith {
            @([pscustomobject]@{ Drive = 'D:'; FirmwareRevision = 'D300' })
        }
        (Get-RipperDriveFirmware -DriveLetter 'D:') | Should -Be 'D300'
    }

    It 'tolerates trailing colon / backslash on the drive letter input' {
        Mock -CommandName Get-CimInstance -MockWith {
            @([pscustomobject]@{ Drive = 'K:'; FirmwareRevision = 'TX01' })
        }
        (Get-RipperDriveFirmware -DriveLetter 'K:\') | Should -Be 'TX01'
    }
}

Describe 'Get-RipperOpticalDrives (Phase 6.4.6 firmware capture)' {

    BeforeAll {
        Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\lib\DriveRegistration.psd1') -Force
    }

    It 'includes FirmwareRevision on each row' {
        Mock -ModuleName DriveRegistration Get-CimInstance {
            @(
                [pscustomobject]@{ Drive = 'D:'; Name = 'TSSTcorp DVD+-RW TS-H653H'; FirmwareRevision = 'D300' }
                [pscustomobject]@{ Drive = 'E:'; Name = 'ASUS BW-12B1ST';            FirmwareRevision = '1.00' }
            )
        } -ParameterFilter { $ClassName -eq 'Win32_CDROMDrive' }

        $r = @(Get-RipperOpticalDrives)
        $r.Count | Should -Be 2
        $r[0].FirmwareRevision | Should -Be 'D300'
        $r[1].FirmwareRevision | Should -Be '1.00'
    }

    It 'returns "" for FirmwareRevision when CIM does not expose it (no schema break)' {
        Mock -ModuleName DriveRegistration Get-CimInstance {
            @([pscustomobject]@{ Drive = 'D:'; Name = 'OldDrive' })
        } -ParameterFilter { $ClassName -eq 'Win32_CDROMDrive' }

        $r = @(Get-RipperOpticalDrives)
        $r.Count | Should -Be 1
        $r[0].FirmwareRevision | Should -Be ''
    }
}
