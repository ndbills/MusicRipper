<#
.SYNOPSIS
    Interactively create %LOCALAPPDATA%\MusicRipper\config.json.

.DESCRIPTION
    Pipeline position:
        Setup script #3. Run after Install-Dependencies.ps1. May be re-run
        anytime to re-prompt; existing values are shown as defaults.

    Prompts for:
        - Library root path (required)
        - MusicBrainz contact email (required by their ToS)
        - Optional OneDrive mirror path
        - Optional Synology NAS UNC + credential (DPAPI-stored)
        - Metadata-provider chain   (Phase 5.2; comma-separated, in priority order)
        - Cover-art-provider chain  (Phase 5.2; comma-separated, in priority order)

.EXAMPLE
    PS> ./setup/New-RipperConfig.ps1

.EXAMPLE
    PS> ./setup/New-RipperConfig.ps1 -TopUp
    # Non-interactive: leaves existing values alone but fills in any
    # fields that are missing (e.g. MetadataProviders on a pre-5.2
    # config) with their built-in defaults. Safe to run unattended.

.NOTES
    Why DPAPI for the NAS credential: PowerShell's Export-Clixml encrypts
    SecureStrings with the current Windows user's DPAPI key. The resulting
    file is unreadable by any other user on the machine and unportable to
    other machines — a cheap, dependency-free, "good enough for Mom's
    laptop" credential vault.
    See: https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/export-clixml
#>

[CmdletBinding()]
param(
    # Non-interactive mode: keep every existing value, but write any
    # missing fields with their built-in defaults. Useful after a
    # MusicRipper upgrade introduces a new config key (Phase 5.2 added
    # MetadataProviders + CoverArtProviders).
    [switch]$TopUp
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\lib\Config.psd1')  -Force
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force

Start-RipperLog -Context 'new-ripper-config' | Out-Null

# Script-level trap: log any uncaught error with line + stack so a
# StrictMode-3.0 surprise (e.g. a `.Count` access on a scalar that
# the loaded JSON happens to deserialise as a single-item) shows up
# in the log file rather than just on screen where it scrolls away
# behind a thrown exception.
trap {
    try {
        $msg = $_.Exception.Message
        $where = if ($_.InvocationInfo) {
            "$($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber) -- $($_.InvocationInfo.Line.Trim())"
        } else { '(no InvocationInfo)' }
        Write-RipperLog ERROR 'New-RipperConfig' "Unhandled error: $msg | at $where"
        if ($_.ScriptStackTrace) {
            Write-RipperLog ERROR 'New-RipperConfig' "Stack: $($_.ScriptStackTrace -replace "`r?`n", ' >> ')"
        }
    } catch { }
    # Re-throw so the user sees the error too.
    break
}

# Read existing config (if any) so we can offer existing values as defaults.
$configPath = Get-RipperConfigPath
$existing   = if (Test-Path -LiteralPath $configPath) { Import-RipperConfig } else { $null }

# Built-in defaults for fields added in later phases. Referenced in two
# places: the "missing key" detection below, and the provider-chain
# prompts further down.
$knownMd  = @('MusicBrainz', 'CuetoolsDb', 'GnuDb')
$knownCov = @('CoverArtArchive', 'iTunesSearch', 'Deezer')

# Detect config keys that New-RipperConfigObject would emit but the
# existing file is missing. An upgrade-in-place without re-prompting
# the user just writes these out with their built-in defaults.
$missingKeys = @()
if ($existing) {
    $expected = @{
        MetadataProviders = $knownMd
        CoverArtProviders = $knownCov
        EjectAfterRip     = $true
        ContinuousMode    = $true
        SyncTargets       = @()
        LocalRetention    = 'Keep'
        RetryPendingSyncOnStartup = $true
        WireGuardTunnelName = $null
        WireGuardAutoToggle = $true
    }
    foreach ($k in $expected.Keys) {
        if (-not $existing.PSObject.Properties[$k]) {
            $missingKeys += $k
        }
    }
}

function Read-WithDefault {
<#
.SYNOPSIS
    Read-Host with a default value shown in brackets. Press Enter to accept.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$Prompt,
        [string]$Default
    )
    $shown = if ($Default) { "$Prompt [$Default] (Enter = keep)" } else { $Prompt }
    $val = Read-Host $shown
    if ([string]::IsNullOrWhiteSpace($val)) { $Default } else { $val }
}

if ($existing) {
    Write-Host ""
    Write-Host "Existing config found at $configPath" -ForegroundColor Cyan
    Write-Host "  LibraryRoot           : $($existing.LibraryRoot)"
    Write-Host "  MusicBrainzUserAgent  : $($existing.MusicBrainzUserAgent)"
    Write-Host "  OneDriveSyncTargetRoot: $($existing.OneDriveSyncTargetRoot)"
    Write-Host "  SynologyUnc           : $($existing.SynologyUnc)"
    Write-Host "  DriveLetter / Offset  : $($existing.DriveLetter) / $($existing.DriveOffset)"
    $existingMd  = if ($existing.PSObject.Properties['MetadataProviders']  -and $existing.MetadataProviders)  { ($existing.MetadataProviders  -join ', ') } else { '(missing — will default to: ' + ($knownMd  -join ', ') + ')' }
    $existingCov = if ($existing.PSObject.Properties['CoverArtProviders'] -and $existing.CoverArtProviders) { ($existing.CoverArtProviders -join ', ') } else { '(missing — will default to: ' + ($knownCov -join ', ') + ')' }
    $existingEject = if ($existing.PSObject.Properties['EjectAfterRip']) { [string][bool]$existing.EjectAfterRip } else { '(missing — will default to: True)' }
    $existingCont  = if ($existing.PSObject.Properties['ContinuousMode']) { [string][bool]$existing.ContinuousMode } else { '(missing — will default to: True)' }
    $existingSync  = if ($existing.PSObject.Properties['SyncTargets']    -and $existing.SyncTargets)    { (@($existing.SyncTargets) -join ', ') } else { '(missing — will default to: <empty> = no sync)' }
    $existingRet   = if ($existing.PSObject.Properties['LocalRetention']) { [string]$existing.LocalRetention } else { '(missing — will default to: Keep)' }
    $existingRetry = if ($existing.PSObject.Properties['RetryPendingSyncOnStartup']) { [string][bool]$existing.RetryPendingSyncOnStartup } else { '(missing — will default to: True)' }
    Write-Host "  MetadataProviders     : $existingMd"
    Write-Host "  CoverArtProviders     : $existingCov"
    Write-Host "  EjectAfterRip         : $existingEject"
    Write-Host "  ContinuousMode        : $existingCont"
    Write-Host "  SyncTargets           : $existingSync"
    Write-Host "  LocalRetention        : $existingRet"
    Write-Host "  RetryPendingSyncOnStartup: $existingRetry"
    Write-Host ""

    # -TopUp: non-interactive upgrade path. Write existing values back
    # verbatim plus any missing keys with their built-in defaults.
    if ($TopUp) {
        if ($missingKeys.Count -eq 0) {
            Write-Host "-TopUp: config already has every known field. No changes." -ForegroundColor Green
            Stop-RipperLog
            return
        }
        Write-Host "-TopUp: adding missing field(s) with defaults: $($missingKeys -join ', ')" -ForegroundColor Yellow
        $cfg = New-RipperConfigObject `
            -LibraryRoot   $existing.LibraryRoot `
            -OneDriveSyncTargetRoot $existing.OneDriveSyncTargetRoot `
            -SynologyUnc   $existing.SynologyUnc
        foreach ($p in $existing.PSObject.Properties) {
            # Carry every existing key over; New-RipperConfigObject has
            # already filled in defaults for anything the existing file
            # didn't have.
            if ($cfg.PSObject.Properties[$p.Name]) { $cfg.$($p.Name) = $p.Value }
        }
        $cfg | Save-RipperConfig
        Write-Host "Config written to $configPath" -ForegroundColor Green
        Write-RipperLog INFO 'New-RipperConfig' "Top-up: added missing keys $($missingKeys -join ', ')."
        Stop-RipperLog
        return
    }

    $hint = if ($missingKeys.Count -gt 0) {
        "Missing field(s) detected: $($missingKeys -join ', '). Type 'u' to add defaults, 'e' to edit field-by-field, or Enter to keep as-is"
    } else {
        "Press Enter to keep ALL existing values, type 'u' to top up any missing fields with defaults, or 'e' to edit field-by-field"
    }
    $ans = Read-Host $hint
    if ([string]::IsNullOrWhiteSpace($ans)) {
        Write-Host "No changes made." -ForegroundColor Green
        Stop-RipperLog
        return
    }
    if ($ans -match '^\s*u\s*$') {
        if ($missingKeys.Count -eq 0) {
            Write-Host "Config already has every known field. No changes." -ForegroundColor Green
            Stop-RipperLog
            return
        }
        Write-Host "Adding missing field(s) with defaults: $($missingKeys -join ', ')" -ForegroundColor Yellow
        $cfg = New-RipperConfigObject `
            -LibraryRoot   $existing.LibraryRoot `
            -OneDriveSyncTargetRoot $existing.OneDriveSyncTargetRoot `
            -SynologyUnc   $existing.SynologyUnc
        foreach ($p in $existing.PSObject.Properties) {
            if ($cfg.PSObject.Properties[$p.Name]) { $cfg.$($p.Name) = $p.Value }
        }
        $cfg | Save-RipperConfig
        Write-Host "Config written to $configPath" -ForegroundColor Green
        Write-RipperLog INFO 'New-RipperConfig' "Top-up (interactive): added missing keys $($missingKeys -join ', ')."
        Stop-RipperLog
        return
    }
    # Anything else (typically 'e') falls through to the edit loop.
}

# --- Library root (required) ----------------------------------------------
$defaultLib = if ($existing) { $existing.LibraryRoot } else { Join-Path ([Environment]::GetFolderPath('MyMusic')) 'MusicRipper' }
$libraryRoot = Read-WithDefault -Prompt 'Library root path' -Default $defaultLib
if ([string]::IsNullOrWhiteSpace($libraryRoot)) { throw "Library root is required." }
if (-not (Test-Path -LiteralPath $libraryRoot)) {
    New-Item -ItemType Directory -Path $libraryRoot -Force | Out-Null
    Write-RipperLog INFO 'New-RipperConfig' "Created library root '$libraryRoot'."
}

# --- MusicBrainz UA / contact email ---------------------------------------
$defaultUa = if ($existing) { $existing.MusicBrainzUserAgent } else { 'MusicRipper/0.1 ( unknown@example.com )' }
$email = Read-WithDefault -Prompt 'MusicBrainz contact email (required by their ToS)' `
                          -Default ($defaultUa -replace '.*\(\s*', '' -replace '\s*\).*', '')
$ua = "MusicRipper/0.1 ( $email )"

# --- OneDrive (optional, Phase 6.2) --------------------------------------
# Stores cfg.OneDriveSyncTargetRoot -- the absolute folder under
# OneDrive that ripped albums get mirrored into. We pop a Windows
# Forms FolderBrowserDialog seeded at the user's OneDrive root (looked
# up via HKCU\Software\Microsoft\OneDrive\UserFolder) so the user can
# just navigate inside it instead of typing the path. Cancelling the
# dialog leaves the field empty -- the OneDrive sync target then
# fails fast at sync time with a clear "not configured" message rather
# than silently doing nothing.
. (Join-Path $repoRoot 'src\sync\Sync-ToOneDrive.ps1')
$defaultOd = if ($existing -and $existing.PSObject.Properties['OneDriveSyncTargetRoot']) { [string]$existing.OneDriveSyncTargetRoot } else { '' }
$oneDriveRoot = Get-RipperOneDriveUserFolder
if ($oneDriveRoot) {
    Write-Host "OneDrive root detected: $oneDriveRoot" -ForegroundColor DarkGray
} else {
    Write-Host "OneDrive client not detected (HKCU\\Software\\Microsoft\\OneDrive\\UserFolder missing). You can still pick a folder manually." -ForegroundColor Yellow
}
$prompt = if ($defaultOd) {
    "OneDrive sync target root [$defaultOd] (Enter = keep, 'pick' to browse, '-' to clear)"
} elseif ($oneDriveRoot) {
    "OneDrive sync target root (Enter or 'pick' = browse from $oneDriveRoot, '-' to skip)"
} else {
    "OneDrive sync target root (Enter or 'pick' = browse, '-' to skip)"
}
$ans = Read-Host $prompt
$oneDrive = $defaultOd
$ansTrim = $ans.Trim()
if ($ansTrim -eq '-') {
    $oneDrive = ''
} elseif ([string]::IsNullOrWhiteSpace($ans) -and $defaultOd) {
    # Enter with an existing value = keep it; do not pop the dialog.
    $oneDrive = $defaultOd
} elseif ([string]::IsNullOrWhiteSpace($ans) -or $ansTrim.ToLowerInvariant() -eq 'pick') {
    # Browse. Use Windows Forms FolderBrowserDialog -- ships with
    # every Windows install, no extra dependencies. Seed at the
    # registered OneDrive root so the user can just navigate inside
    # it; if no OneDrive is detected, seed at the existing value or
    # %USERPROFILE%.
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Select the OneDrive subfolder where ripped albums should be mirrored to. Cancel to skip the OneDrive sync target.'
    $dlg.UseDescriptionForTitle = $true
    $dlg.ShowNewFolderButton = $true
    $seed = if ($defaultOd -and (Test-Path -LiteralPath $defaultOd)) { $defaultOd }
            elseif ($oneDriveRoot) { $oneDriveRoot }
            else { [Environment]::GetFolderPath('UserProfile') }
    $dlg.SelectedPath = $seed
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $oneDrive = $dlg.SelectedPath
        Write-Host "  OneDrive sync target -> $oneDrive" -ForegroundColor Green
    } else {
        Write-Host "  OneDrive sync target left as: $(if ($defaultOd) { $defaultOd } else { '(not set)' })" -ForegroundColor DarkGray
    }
} else {
    $oneDrive = $ansTrim
}
if ([string]::IsNullOrWhiteSpace($oneDrive)) { $oneDrive = $null }
elseif (-not (Test-Path -LiteralPath $oneDrive)) {
    Write-Warning "OneDriveSyncTargetRoot '$oneDrive' does not exist on disk. The OneDrive sync target will report Failed until the folder exists."
}

# --- Synology NAS (optional, Phase 6.3) ----------------------------------
# Stores cfg.SynologyUnc -- the UNC path of the NAS share that the
# 'SynologyNAS' sync target mirrors albums onto. Optional DPAPI
# credential lives in credentials.clixml; we only re-prompt when the
# user opts in, so re-running setup never silently asks for the NAS
# password again.
$defaultSyn = if ($existing) { $existing.SynologyUnc } else { '' }
$syn = Read-WithDefault -Prompt 'Synology NAS UNC path, e.g. \\nas\music (blank to skip)' -Default $defaultSyn
if ([string]::IsNullOrWhiteSpace($syn)) { $syn = $null }

$hasCred = if ($existing -and $existing.PSObject.Properties['HasSynologyCredential']) { [bool]$existing.HasSynologyCredential } else { $false }
if ($syn) {
    # Match the rest of the script's "Enter = keep" idiom. The
    # bracketed default reflects current state (stored / not set);
    # 'new' triggers a fresh Get-Credential prompt and saves it,
    # '-' clears any existing credential. On first run (no cred
    # stored yet) we default to prompting since that's the common
    # case -- the user just typed a UNC and almost certainly needs
    # to authenticate to it.
    $credDefault = if ($hasCred) { 'stored' } else { 'not set' }
    $credAns = (Read-Host "Synology NAS credential [$credDefault] (Enter = keep, 'new' to enter/replace, '-' to clear)").Trim()
    $wantsNew   = $credAns -match '^(?i)new$'
    $wantsClear = $credAns -eq '-'
    # Backwards-compat: a bare 'y' still means 'enter a new credential'
    # so muscle memory from the old y/N prompt keeps working.
    if (-not $wantsNew -and -not $wantsClear -and $credAns -match '^(?i)[yt1]$') {
        $wantsNew = $true
    }
    # First-run convenience: bare Enter with no cred stored = prompt now.
    if (-not $wantsNew -and -not $wantsClear -and -not $hasCred -and [string]::IsNullOrEmpty($credAns)) {
        $wantsNew = $true
    }
    if ($wantsClear -and $hasCred) {
        $credPath = Join-Path (Get-RipperConfigRoot) 'credentials.clixml'
        if (Test-Path -LiteralPath $credPath) {
            Remove-Item -LiteralPath $credPath -Force
        }
        $hasCred = $false
        Write-RipperLog INFO 'New-RipperConfig' 'Synology credential cleared.'
    } elseif ($wantsNew) {
        $cred = Get-Credential -Message "Credentials for $syn (cancel to skip)"
        if ($cred) {
            Save-RipperCredential -Credential $cred
            $hasCred = $true
            Write-RipperLog INFO 'New-RipperConfig' 'Synology credential saved (DPAPI).'
        }
    }
}

# --- WireGuard auto-toggle (optional, Phase 6.4) --------------------------
# When the family NAS lives behind a WireGuard VPN (typical home-lab
# setup where the parent is ripping at a friend's house), MusicRipper
# can bring the tunnel up before each NAS sync and tear it down on
# exit. We do the install + per-user grant ONCE here, with a single
# UAC prompt; afterwards every rip is silent.
#
# UX flow:
#   1. Ask if the user wants auto-toggle (default: only ask if a
#      Synology UNC was set, since with no NAS there's nothing to
#      tunnel to).
#   2. Prompt for a .conf path. Skip-out is empty input.
#   3. If the tunnel service doesn't already exist, spawn an
#      elevated child PowerShell that runs Install-RipperVpnTunnel
#      + Grant-RipperVpnTunnelControl. This is the ONE UAC prompt.
#   4. Save WireGuardTunnelName + WireGuardAutoToggle to cfg.

$wgTunnelName = $null
if ($existing -and $existing.PSObject.Properties['WireGuardTunnelName']) {
    $wgTunnelName = $existing.WireGuardTunnelName
}
$wgAutoToggle = $true
if ($existing -and $existing.PSObject.Properties['WireGuardAutoToggle']) {
    $wgAutoToggle = [bool]$existing.WireGuardAutoToggle
}

if ($syn) {
    $wgWanted = $false
    if ($wgTunnelName) {
        Write-Host "  WireGuard tunnel: '$wgTunnelName' (currently $(if ($wgAutoToggle){'auto-toggle ON'}else{'auto-toggle OFF'}))"
        $ans = (Read-Host "Configure WireGuard auto-toggle? [Enter = keep, 'new' to (re)install, '-' to clear]").Trim()
        if ($ans -eq '-') {
            $wgTunnelName = $null
            $wgAutoToggle = $true
        } elseif ($ans -match '^(?i)(new|y|t|1)$') {
            $wgWanted = $true
        }
    } else {
        $ans = (Read-Host 'Set up WireGuard auto-toggle for the NAS share? (y/N)').Trim()
        if ($ans -match '^(?i)[yt1]') { $wgWanted = $true }
    }

    if ($wgWanted) {
        $confPath = Read-Host 'Path to WireGuard .conf file (blank to skip)'
        $confPath = $confPath.Trim().Trim('"').Trim("'")
        if ([string]::IsNullOrWhiteSpace($confPath)) {
            Write-RipperLog INFO 'New-RipperConfig' 'WireGuard setup skipped (no .conf path provided).'
        } elseif (-not (Test-Path -LiteralPath $confPath)) {
            Write-Warning ".conf file '$confPath' does not exist. Skipping WireGuard setup."
        } else {
            $tunnelStem = [System.IO.Path]::GetFileNameWithoutExtension($confPath)
            $svcName    = "WireGuardTunnel`$$tunnelStem"
            $alreadyInstalled = $false
            try {
                $null = Get-Service -Name $svcName -ErrorAction Stop
                $alreadyInstalled = $true
            } catch { $alreadyInstalled = $false }

            if (-not $alreadyInstalled) {
                # Spawn an elevated child to run /installtunnelservice
                # + sc.exe sdset in a single UAC prompt. We pass the
                # current user's SID + repo root so the child knows
                # who to grant control to and can dot-source our
                # Wireguard module.
                #
                # Implementation detail: we write the helper to a temp
                # .ps1 file and run it with `-File`, rather than passing
                # a heredoc to `-Command`. Heredoc-via-Command is
                # fragile -- escape rules for embedded $vars and quoted
                # paths under -Verb RunAs are different from the parent
                # shell, and parse failures crash the elevated child
                # before our try/catch (or even Start-RipperLog) can
                # run, leaving no log and a vanishing window. A real
                # script file makes the helper trivially debuggable
                # (rerun manually in any elevated pwsh) and removes a
                # whole class of escape bugs. We always `pause` at the
                # end so the window cannot disappear regardless of
                # success/failure.
                $repoRoot = Split-Path -Parent $PSScriptRoot
                $userSid  = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
                $helperPath = Join-Path ([System.IO.Path]::GetTempPath()) "musicripper-wginstall-$([guid]::NewGuid().Guid.Substring(0,8)).ps1"
                # Build the helper script. Single-quote string literals
                # inside the script so backslashes and $-signs in the
                # passed paths/SIDs don't get reinterpreted by the
                # elevated child's parser.
                $helperBody = @"
Set-StrictMode -Version 3.0
`$ErrorActionPreference = 'Stop'
`$RepoRoot   = '$repoRoot'
`$ConfPath   = '$confPath'
`$TunnelStem = '$tunnelStem'
`$UserSid    = '$userSid'
`$LogPath    = `$null
try {
    Import-Module (Join-Path `$RepoRoot 'src\lib\Logging.psd1') -Force
    `$LogPath = Start-RipperLog -Context 'WgInstall'
    Import-Module (Join-Path `$RepoRoot 'src\lib\Wireguard.psd1') -Force
    Write-Host ''
    Write-Host "Installing WireGuard tunnel '`$TunnelStem' from '`$ConfPath' ..." -ForegroundColor Cyan
    `$ok1 = Install-RipperVpnTunnel -ConfPath `$ConfPath
    if (-not `$ok1) { throw "Install-RipperVpnTunnel returned false. See log: `$LogPath" }
    Write-Host "Granting start/stop control to SID `$UserSid ..." -ForegroundColor Cyan
    `$ok2 = Grant-RipperVpnTunnelControl -Name `$TunnelStem -UserSid `$UserSid
    if (-not `$ok2) { throw "Grant-RipperVpnTunnelControl returned false. See log: `$LogPath" }
    # `wireguard.exe /installtunnelservice` registers the service with
    # StartType=Automatic, meaning Windows would bring the tunnel up
    # at every boot/login. That is not what we want -- the whole
    # point of the auto-toggle is for MusicRipper to be the one (and
    # only) thing that starts the tunnel, on demand, and only for
    # the duration of a NAS sync. Flip it to Manual now.
    `$svcName = "WireGuardTunnel`$`$TunnelStem"
    Write-Host "Setting service '`$svcName' StartType to Manual ..." -ForegroundColor Cyan
    try {
        Set-Service -Name `$svcName -StartupType Manual -ErrorAction Stop
    } catch {
        Write-Host "  Set-Service failed: `$(`$_.Exception.Message). Tunnel will still work but may auto-start on boot." -ForegroundColor Yellow
    }
    # `wireguard.exe /installtunnelservice` auto-starts the tunnel.
    # Leave it stopped after setup so the next rip's auto-toggle is
    # what brings it up (and so a parent who walks away mid-setup
    # isn't left with an unexpectedly-active VPN). The fact that the
    # service reached Running between Install and Grant already
    # validated the .conf -- if WG had refused the conf, Get-Service
    # in Grant-RipperVpnTunnelControl would have failed.
    Write-Host 'Stopping tunnel (will be re-started automatically per rip) ...' -ForegroundColor Cyan
    [void](Stop-RipperVpnTunnel -Name `$TunnelStem)
    Write-Host ''
    Write-Host 'WireGuard tunnel installed and start/stop control granted.' -ForegroundColor Green
    Write-Host "Log: `$LogPath" -ForegroundColor DarkGray
    `$exitCode = 0
} catch {
    Write-Host ''
    Write-Host '======================================================================' -ForegroundColor Red
    Write-Host 'WireGuard install FAILED:' -ForegroundColor Red
    Write-Host `$_.Exception.Message -ForegroundColor Red
    if (`$_.InvocationInfo) {
        Write-Host ''
        Write-Host "At: `$(`$_.InvocationInfo.ScriptName):`$(`$_.InvocationInfo.ScriptLineNumber)" -ForegroundColor DarkRed
        Write-Host "    `$(`$_.InvocationInfo.Line.Trim())" -ForegroundColor DarkRed
    }
    if (`$_.ScriptStackTrace) {
        Write-Host ''
        Write-Host 'Stack trace:' -ForegroundColor DarkRed
        Write-Host `$_.ScriptStackTrace -ForegroundColor DarkRed
    }
    if (`$LogPath) {
        Write-Host ''
        Write-Host "Full log: `$LogPath" -ForegroundColor Yellow
    }
    Write-Host '======================================================================' -ForegroundColor Red
    `$exitCode = 2
} finally {
    try { Stop-RipperLog } catch { }
    # Always pause so the window cannot vanish, regardless of how we
    # got here. Read-Host needs a console; Start-Process -Verb RunAs
    # gives one.
    Write-Host ''
    Read-Host 'Press Enter to close this window'
}
exit `$exitCode
"@
                Set-Content -LiteralPath $helperPath -Value $helperBody -Encoding UTF8
                Write-Host 'Launching elevated helper to install the WireGuard tunnel (one UAC prompt)...' -ForegroundColor Cyan
                Write-Host "  Helper script: $helperPath" -ForegroundColor DarkGray
                try {
                    $proc = Start-Process -FilePath 'pwsh' `
                        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $helperPath) `
                        -Verb RunAs -Wait -PassThru
                    if ($proc.ExitCode -ne 0) {
                        Write-Warning "Elevated helper exited $($proc.ExitCode); WireGuard tunnel was NOT installed. Auto-toggle will be left disabled. Helper script kept at: $helperPath"
                    } else {
                        $wgTunnelName = $tunnelStem
                        Write-RipperLog INFO 'New-RipperConfig' "WireGuard tunnel '$tunnelStem' installed via elevated helper."
                        # Helper succeeded -- delete the temp script.
                        # On failure we keep it around so the user can
                        # rerun it manually for diagnosis.
                        Remove-Item -LiteralPath $helperPath -Force -ErrorAction SilentlyContinue
                    }
                } catch {
                    Write-Warning "Failed to launch elevated helper: $($_.Exception.Message). WireGuard tunnel was NOT installed. Helper script kept at: $helperPath"
                }
            } else {
                Write-Host "WireGuard service '$svcName' is already installed; reusing." -ForegroundColor Green
                $wgTunnelName = $tunnelStem
            }
        }
    }

    if ($wgTunnelName) {
        $autoStr = Read-WithDefault -Prompt 'WireGuardAutoToggle (Y/N — start/stop tunnel automatically per NAS sync)' -Default ([string][bool]$wgAutoToggle)
        $wgAutoToggle = ($autoStr -match '^\s*[YyTt1]')
    }
}

# --- Provider chains (Phase 5.2) ------------------------------------------
# Free-form comma-separated lists so the user can reorder, drop, or add
# providers we ship later without this script needing to grow a menu.
# Names that don't match a known provider are accepted but warned about
# (the orchestrator skips unknowns at runtime with a WARN log line).
# ($knownMd / $knownCov were computed at the top of the script.)

function Read-ProviderList {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [string]$Prompt,
        [Parameter(Mandatory)] [string[]]$Default,
        [Parameter(Mandatory)] [string[]]$Known
    )
    $defStr = $Default -join ', '
    $raw = Read-Host "$Prompt [$defStr] (Enter = keep)"
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    $list = @($raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($n in $list) {
        if ($Known -notcontains $n) {
            Write-Warning "Provider '$n' is not one of the built-ins ($($Known -join ', ')). It will be skipped at runtime unless you add a matching provider module."
        }
    }
    return $list
}

$defaultMd  = if ($existing -and $existing.PSObject.Properties['MetadataProviders']  -and $existing.MetadataProviders)  { @($existing.MetadataProviders)  } else { $knownMd }
$defaultCov = if ($existing -and $existing.PSObject.Properties['CoverArtProviders'] -and $existing.CoverArtProviders) { @($existing.CoverArtProviders) } else { $knownCov }
$metadataProviders = Read-ProviderList -Prompt 'Metadata providers (priority order, comma-separated)'  -Default $defaultMd  -Known $knownMd
$coverArtProviders = Read-ProviderList -Prompt 'Cover-art providers (priority order, comma-separated)' -Default $defaultCov -Known $knownCov

# --- Eject-after-rip toggle (Phase 5.4) -----------------------------------
# Default-true preserves the parent-friendly batch flow (insert disc,
# wait for green check, eject, repeat). The confirm dialog still
# surfaces a per-rip checkbox seeded from this value, so power users
# can flip it per-disc without editing the config.
$defaultEject = if ($existing -and $existing.PSObject.Properties['EjectAfterRip']) { [bool]$existing.EjectAfterRip } else { $true }
$ejectStr = Read-WithDefault -Prompt 'Eject disc after rip? (Y/N)' -Default ($(if ($defaultEject) { 'Y' } else { 'N' }))
$ejectAfterRip = ($ejectStr -match '^\s*[YyTt1]')

# --- Continuous mode (Phase 5.7) ------------------------------------------
# Default-true keeps MusicRipper running after each disc so the parent
# can rip a whole stack without re-launching (and re-answering UAC).
# A between-discs dialog (Rip Next / Quit) appears after each rip; if
# a disc arrives via WMI while it's open, Rip Next is auto-selected.
$defaultCont = if ($existing -and $existing.PSObject.Properties['ContinuousMode']) { [bool]$existing.ContinuousMode } else { $true }
$contStr = Read-WithDefault -Prompt 'Continuous mode (keep running between discs)? (Y/N)' -Default ($(if ($defaultCont) { 'Y' } else { 'N' }))
$continuousMode = ($contStr -match '^\s*[YyTt1]')

# --- Sync targets (Phase 6.1) --------------------------------------------
# Ordered list of sync-target names invoked per album after a successful
# Library move. Built-in 'Stub' is for testing the orchestrator without
# a real off-machine target. Real targets land in 6.2 (OneDrive) and
# 6.3 (SynologyNAS). Empty = no sync (current behaviour).
$knownSync   = @('Stub','OneDrive','SynologyNAS')
# Wrap the whole `if` expression in @(), not just the truthy branch.
# Under Strict Mode 3.0, `$x = if(...) { ... } else { @() }` produces
# $null when the else branch fires (the empty array gets unrolled by
# the if-expression's pipeline), and `$null.Count` then throws on the
# next line. `@(if (...) { $existing.SyncTargets })` always yields an
# array, even when the condition is false.
$defaultSync = @(if ($existing -and $existing.PSObject.Properties['SyncTargets'] -and $existing.SyncTargets) { $existing.SyncTargets })
$defStr      = if ($defaultSync.Count -gt 0) { $defaultSync -join ', ' } else { '<empty>' }
$rawSync = Read-Host "Sync targets, comma-separated (known: $($knownSync -join ', '); blank for none) [$defStr] (Enter = keep)"
if ([string]::IsNullOrWhiteSpace($rawSync)) {
    $syncTargets = $defaultSync
} elseif ($rawSync.Trim() -eq '<empty>' -or $rawSync.Trim() -eq '-') {
    $syncTargets = @()
} else {
    $syncTargets = @($rawSync -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($n in $syncTargets) {
        if ($knownSync -notcontains $n) {
            Write-Warning "Sync target '$n' is not built-in. It will be reported Failed at runtime unless src/sync/Sync-To$n.ps1 ships an Invoke-RipperSyncTo$n function."
        }
    }
}

# --- LocalRetention (Phase 6.1) ------------------------------------------
# What to do with the local album after every configured sync target
# returned OK. 'Keep' is safest (default); 'MoveToSentAfterAllSynced'
# moves to <LibraryRoot>\_Sent\; 'RecycleAfterAllSynced' sends to the
# Windows Recycle Bin (recoverable). Both no-op if SyncTargets is empty
# or any target failed.
$retentionOptions = @('Keep','MoveToSentAfterAllSynced','RecycleAfterAllSynced')
$defaultRet = if ($existing -and $existing.PSObject.Properties['LocalRetention'] -and $existing.LocalRetention) { [string]$existing.LocalRetention } else { 'Keep' }
if ($retentionOptions -notcontains $defaultRet) { $defaultRet = 'Keep' }
$retStr = Read-WithDefault -Prompt "LocalRetention (one of: $($retentionOptions -join ' | '))" -Default $defaultRet
if ($retentionOptions -notcontains $retStr) {
    Write-Warning "LocalRetention '$retStr' is not one of $($retentionOptions -join ', '); falling back to 'Keep'."
    $localRetention = 'Keep'
} else {
    $localRetention = $retStr
}

# Phase 6.5: at startup -- before any disc-rip -- show a WPF dialog that
# retries albums whose previous sync didn't finish (e.g. NAS was off).
# Default Y. The dialog has its own Cancel button, so a single launch
# can still skip the retry without flipping this flag.
$defaultRetry = if ($existing -and $existing.PSObject.Properties['RetryPendingSyncOnStartup']) { [bool]$existing.RetryPendingSyncOnStartup } else { $true }
$retryStr = Read-WithDefault -Prompt 'RetryPendingSyncOnStartup (Y/N)' -Default ([string][bool]$defaultRetry)
$retryPendingSyncOnStartup = ($retryStr -match '^\s*[YyTt1]')

# --- Build & persist -------------------------------------------------------
$cfg = New-RipperConfigObject `
    -LibraryRoot   $libraryRoot `
    -OneDriveSyncTargetRoot $oneDrive `
    -SynologyUnc   $syn

$cfg.MusicBrainzUserAgent  = $ua
$cfg.HasSynologyCredential = $hasCred
$cfg.MetadataProviders     = $metadataProviders
$cfg.CoverArtProviders     = $coverArtProviders
$cfg.EjectAfterRip         = $ejectAfterRip
$cfg.ContinuousMode        = $continuousMode
$cfg.SyncTargets           = $syncTargets
$cfg.LocalRetention        = $localRetention
$cfg.RetryPendingSyncOnStartup = $retryPendingSyncOnStartup
$cfg.WireGuardTunnelName       = $wgTunnelName
$cfg.WireGuardAutoToggle       = $wgAutoToggle

# Carry over drive info if Register-Drive ran first.
if ($existing) {
    $cfg.DriveLetter = $existing.DriveLetter
    $cfg.DriveOffset = $existing.DriveOffset
}

$cfg | Save-RipperConfig
Write-Host "Config written to $(Get-RipperConfigPath)" -ForegroundColor Green
Stop-RipperLog
