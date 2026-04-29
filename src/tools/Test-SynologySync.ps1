<#
.SYNOPSIS
    Diagnostic stub: verifies the configured Synology NAS share is
    reachable and writable using the exact same code path as the real
    sync target -- without needing to rip a disc.

.DESCRIPTION
    Reads cfg.SynologyUnc + cfg.HasSynologyCredential from the saved
    config, attempts (in order):
      1. Parse the UNC into a share root.
      2. Decrypt credentials.clixml (if HasSynologyCredential=true).
      3. Mount the share via New-SmbMapping.
      4. Test-Path the configured UNC.
      5. Create a tiny throwaway file at $unc\.musicripper-probe and
         delete it.
      6. Unmount the share.
    Each step prints PASS / FAIL with the diagnostic so you can see
    exactly where things break -- the most common failure (bad
    username/password) shows up at step 3.

    Trailing slash on the UNC: the script reports both with and
    without so you can tell whether normalization matters. (It
    shouldn't -- robocopy and Test-Path both accept either -- but
    this script will surface it if your DSM share rejects one form.)

.PARAMETER NoCleanup
    Skip the unmount in step 6. Useful if you want to poke the share
    in Explorer afterwards.

.EXAMPLE
    PS> ./src/tools/Test-SynologySync.ps1
#>
[CmdletBinding()]
param(
    [switch]$NoCleanup
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force
Import-Module (Join-Path $repoRoot 'src\lib\Config.psd1')  -Force
. (Join-Path $repoRoot 'src\sync\Sync-ToSynologyNAS.ps1')

function Write-Step {
    param([string]$Label, [bool]$Ok, [string]$Detail = '')
    $tag = if ($Ok) { 'PASS' } else { 'FAIL' }
    $col = if ($Ok) { 'Green' } else { 'Red' }
    Write-Host ("[{0}] {1}" -f $tag, $Label) -ForegroundColor $col
    if ($Detail) { Write-Host "       $Detail" -ForegroundColor DarkGray }
}

# -- Load config -----------------------------------------------------------
$cfg = Import-RipperConfig
if (-not $cfg) { throw 'No config found. Run setup/New-RipperConfig.ps1 first.' }

$unc       = if ($cfg.PSObject.Properties['SynologyUnc']) { [string]$cfg.SynologyUnc } else { '' }
$hasCred   = if ($cfg.PSObject.Properties['HasSynologyCredential']) { [bool]$cfg.HasSynologyCredential } else { $false }

Write-Host ''
Write-Host '=== Synology NAS sync diagnostic ===' -ForegroundColor Cyan
Write-Host ("Configured UNC          : '{0}'" -f $unc)
Write-Host ("HasSynologyCredential   : {0}" -f $hasCred)
Write-Host ''

if ([string]::IsNullOrWhiteSpace($unc)) {
    Write-Step 'cfg.SynologyUnc set' $false 'Empty/missing. Run setup to configure.'
    return
}
Write-Step 'cfg.SynologyUnc set' $true

# -- Step 1: parse share root ---------------------------------------------
$isUnc = Test-RipperUncPath -Path $unc
$uncTrimmed   = $unc.TrimEnd('\','/')
$uncWithSlash = $uncTrimmed + '\'
Write-Host ("Normalised (no trailing): '{0}'" -f $uncTrimmed)
Write-Host ("Normalised (w/ trailing): '{0}'" -f $uncWithSlash)

$shareRoot = $null
if ($isUnc) {
    $shareRoot = Get-RipperSynologyShareRoot -Path $unc
    Write-Step 'Parse share root from UNC' ([bool]$shareRoot) "shareRoot='$shareRoot'"
} else {
    Write-Step 'Path is a UNC (\\server\share...)' $false "'$unc' looks local; SMB mount will be skipped."
}

# -- Step 2: decrypt credential -------------------------------------------
$cred = $null
if ($hasCred) {
    try {
        $cred = Import-RipperCredential
    } catch {
        Write-Step 'Decrypt credentials.clixml' $false $_.Exception.Message
        return
    }
    if (-not $cred) {
        Write-Step 'Decrypt credentials.clixml' $false 'Import-RipperCredential returned $null. File missing? Run setup again.'
        return
    }
    Write-Step 'Decrypt credentials.clixml' $true ("UserName='{0}'" -f $cred.UserName)
} else {
    Write-Host '[SKIP] No stored credential (HasSynologyCredential=false). Will use ambient session creds.' -ForegroundColor Yellow
}

# -- Step 3: mount the share ----------------------------------------------
$mountedRoot = $null
if ($isUnc -and $cred -and $shareRoot) {
    # Tear down any pre-existing mapping so we test the saved cred fresh.
    try {
        $existing = Get-SmbMapping -RemotePath $shareRoot -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Host "       (Removing pre-existing mapping for $shareRoot to force re-auth)" -ForegroundColor DarkGray
            Remove-SmbMapping -RemotePath $shareRoot -Force -ErrorAction SilentlyContinue | Out-Null
        }
    } catch { }

    try {
        New-SmbMapping `
            -RemotePath $shareRoot `
            -UserName   $cred.UserName `
            -Password   $cred.GetNetworkCredential().Password `
            -ErrorAction Stop | Out-Null
        $mountedRoot = $shareRoot
        Write-Step ("Mount {0} as {1}" -f $shareRoot, $cred.UserName) $true
    } catch {
        Write-Step ("Mount {0} as {1}" -f $shareRoot, $cred.UserName) $false $_.Exception.Message
        Write-Host ''
        Write-Host 'Most likely causes:' -ForegroundColor Yellow
        Write-Host '  * Wrong username or password (re-run setup -> "new")' -ForegroundColor Yellow
        Write-Host '  * Username needs domain prefix on DSM, e.g. NAS\nathan or nathan@nas' -ForegroundColor Yellow
        Write-Host '  * Share name has different capitalization than configured' -ForegroundColor Yellow
        Write-Host '  * SMB1 disabled on the NAS (DSM Control Panel -> File Services -> SMB)' -ForegroundColor Yellow
        return
    }
} elseif ($isUnc -and -not $cred) {
    Write-Host '[SKIP] No credential to mount with. Test-Path will use ambient session creds.' -ForegroundColor Yellow
}

try {
    # -- Step 4: probe both forms of the UNC -------------------------------
    $okPlain = Test-Path -LiteralPath $uncTrimmed
    Write-Step ("Test-Path (no trailing slash) '{0}'" -f $uncTrimmed) $okPlain
    $okSlash = Test-Path -LiteralPath $uncWithSlash
    Write-Step ("Test-Path (w/ trailing slash) '{0}'" -f $uncWithSlash) $okSlash

    if (-not ($okPlain -or $okSlash)) {
        Write-Host ''
        Write-Host 'Share is mounted but the configured path is not reachable. Check the subfolder name in the UNC.' -ForegroundColor Yellow
        return
    }

    # -- Step 5: write + delete a probe file -------------------------------
    $probe = Join-Path $uncTrimmed '.musicripper-probe.txt'
    try {
        Set-Content -LiteralPath $probe -Value ("probe {0:o}" -f (Get-Date)) -Encoding UTF8 -ErrorAction Stop
        Write-Step "Write probe file '$probe'" $true
    } catch {
        Write-Step "Write probe file '$probe'" $false $_.Exception.Message
        return
    }
    try {
        Remove-Item -LiteralPath $probe -Force -ErrorAction Stop
        Write-Step "Delete probe file" $true
    } catch {
        Write-Step "Delete probe file" $false $_.Exception.Message
    }

    Write-Host ''
    Write-Host 'All checks passed -- the SynologyNAS sync target should work end-to-end.' -ForegroundColor Green
}
finally {
    if ($mountedRoot -and -not $NoCleanup) {
        try {
            Remove-SmbMapping -RemotePath $mountedRoot -Force -ErrorAction Stop | Out-Null
            Write-Host ("[done] Unmounted {0}" -f $mountedRoot) -ForegroundColor DarkGray
        } catch {
            Write-Warning ("Failed to unmount {0}: {1}" -f $mountedRoot, $_.Exception.Message)
        }
    } elseif ($mountedRoot -and $NoCleanup) {
        Write-Host ("[note] Leaving {0} mounted (-NoCleanup)" -f $mountedRoot) -ForegroundColor Yellow
    }
}
