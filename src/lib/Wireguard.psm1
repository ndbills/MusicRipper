<#
.SYNOPSIS
    Phase 6.4: idempotent helpers around the WireGuard for Windows
    tunnel-service control plane.

.DESCRIPTION
    Pipeline position:
        Loaded by Sync-ToSynologyNAS.ps1 (and setup/New-RipperConfig.ps1)
        when cfg.WireGuardAutoToggle is true. Wraps the three operations
        we actually do at runtime -- start, stop, test -- plus the two
        operations we do once during setup -- install the tunnel as a
        Windows service and grant the current user start/stop rights so
        every subsequent rip is UAC-free.

    Service-name convention:
        WireGuard for Windows installs each .conf as a Windows service
        named "WireGuardTunnel$<TunnelName>" where <TunnelName> is the
        bare filename of the .conf without extension. We expose
        Get-RipperVpnTunnelServiceName so all callers go through the
        same translation.

    Why a per-tunnel SDDL grant?
        wireguard.exe /installtunnelservice creates a service that runs
        as LocalSystem. By default only members of Administrators can
        start/stop it, which means every rip would pop a UAC prompt --
        unacceptable for a parent-friendly tool. Microsoft's standard
        answer is to widen the SD via `sc.exe sdset` to give the
        current user SERVICE_START + SERVICE_STOP on that one specific
        service. Done once during setup with a single UAC, then every
        rip is silent. The grant is scoped to one service, so it does
        not weaken machine-wide permissions.

    Idempotency:
        Every public function in this module is safe to call twice.
        Start when already running -> $true (no-op). Stop when already
        stopped -> $true. Install when already installed (same .conf
        path) -> $true. Test always returns $true / $false based on
        live state with no side effects.

    Error policy:
        Public functions return $true on success / no-op, $false on
        failure, and write a WARN-level log line via Write-RipperLog.
        They do NOT throw -- the rip pipeline must never crash because
        a tunnel was unreachable; that's the whole point of the Phase
        6.1 "sync failures don't block rips" contract (D-022).

.NOTES
    All work is local to the user's machine. We never read or modify
    the .conf file itself -- AllowedIPs / DNS / endpoint are entirely
    the user's call. We just install + start the service that
    interprets it.
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Get-RipperVpnTunnelServiceName {
<#
.SYNOPSIS
    Translate a tunnel name (e.g. "home-wg") into the Windows service
    name WireGuard for Windows installs ("WireGuardTunnel$home-wg").

.PARAMETER Name
    Bare tunnel name, typically the .conf filename without extension.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$Name
    )
    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw "Tunnel name is required."
    }
    "WireGuardTunnel`$$Name"
}

function Test-RipperVpnTunnel {
<#
.SYNOPSIS
    Returns $true if the tunnel service is installed AND running.

.DESCRIPTION
    Distinguishes three states via -Detailed:
        NotInstalled : no service with that name exists.
        Stopped      : service exists but is not running.
        Running      : service exists and is in the Running state.

.PARAMETER Name
    Tunnel name (see Get-RipperVpnTunnelServiceName).

.PARAMETER Detailed
    Return the state string instead of $true/$false.
#>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [string]$Name,
        [switch]$Detailed
    )
    $svcName = Get-RipperVpnTunnelServiceName -Name $Name
    $svc = $null
    try {
        $svc = Get-Service -Name $svcName -ErrorAction Stop
    } catch {
        if ($Detailed) { return 'NotInstalled' }
        return $false
    }
    $state = if ($svc.Status -eq 'Running') { 'Running' } else { 'Stopped' }
    if ($Detailed) { return $state }
    return ($state -eq 'Running')
}

function Start-RipperVpnTunnel {
<#
.SYNOPSIS
    Bring up the named WireGuard tunnel (idempotent).

.DESCRIPTION
    No-op when already Running. Returns $false (and WARNs) when the
    service does not exist -- caller is expected to gate on
    Test-RipperVpnTunnel -Detailed first if it cares about the
    NotInstalled vs. Stopped distinction.

.PARAMETER Name
    Tunnel name (see Get-RipperVpnTunnelServiceName).

.PARAMETER TimeoutSeconds
    How long to wait for the service to report Running before declaring
    failure. The WG service binary handshakes with the kernel WinTun
    adapter on start, which can take a few seconds even on healthy
    systems.
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string]$Name,
        [int]$TimeoutSeconds = 15
    )
    $svcName = Get-RipperVpnTunnelServiceName -Name $Name
    $state = Test-RipperVpnTunnel -Name $Name -Detailed
    switch ($state) {
        'Running' {
            Write-RipperLog INFO 'Wireguard' "Tunnel '$Name' already running."
            return $true
        }
        'NotInstalled' {
            Write-RipperLog WARN 'Wireguard' "Tunnel '$Name' is not installed (service '$svcName' missing). Re-run setup/New-RipperConfig.ps1 to install it."
            return $false
        }
    }
    try {
        Start-Service -Name $svcName -ErrorAction Stop
    } catch {
        Write-RipperLog WARN 'Wireguard' "Start-Service '$svcName' failed: $($_.Exception.Message)"
        return $false
    }
    # Wait for Running. Start-Service returns once the SCM has
    # accepted the start, but the WG service binary takes another
    # second or two to actually open the tunnel.
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        Start-Sleep -Milliseconds 250
        if ((Test-RipperVpnTunnel -Name $Name -Detailed) -eq 'Running') {
            Write-RipperLog INFO 'Wireguard' "Tunnel '$Name' came up in $([int]$sw.Elapsed.TotalMilliseconds) ms."
            return $true
        }
    }
    Write-RipperLog WARN 'Wireguard' "Tunnel '$Name' did not reach Running within ${TimeoutSeconds}s."
    return $false
}

function Stop-RipperVpnTunnel {
<#
.SYNOPSIS
    Tear down the named WireGuard tunnel (idempotent).

.DESCRIPTION
    No-op when already Stopped. Returns $true if the service does not
    exist (nothing to stop is success).
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string]$Name,
        [int]$TimeoutSeconds = 10
    )
    $svcName = Get-RipperVpnTunnelServiceName -Name $Name
    $state = Test-RipperVpnTunnel -Name $Name -Detailed
    if ($state -eq 'NotInstalled') {
        Write-RipperLog INFO 'Wireguard' "Tunnel '$Name' not installed; nothing to stop."
        return $true
    }
    # NOTE: don't early-return on $state -eq 'Stopped'. Test-* collapses
    # everything that isn't 'Running' into 'Stopped', which includes the
    # transient 'StartPending' state right after wireguard.exe
    # /installtunnelservice -- the service is in the process of coming
    # up but has not yet reported Running. If we returned here we'd skip
    # the actual Stop-Service call and the service would then finish
    # transitioning to Running and stay there. Stop-Service is a safe
    # no-op against an already-Stopped service.
    try {
        Stop-Service -Name $svcName -ErrorAction Stop
    } catch {
        Write-RipperLog WARN 'Wireguard' "Stop-Service '$svcName' failed: $($_.Exception.Message)"
        return $false
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        Start-Sleep -Milliseconds 250
        if ((Test-RipperVpnTunnel -Name $Name -Detailed) -ne 'Running') {
            Write-RipperLog INFO 'Wireguard' "Tunnel '$Name' stopped in $([int]$sw.Elapsed.TotalMilliseconds) ms."
            return $true
        }
    }
    Write-RipperLog WARN 'Wireguard' "Tunnel '$Name' did not stop within ${TimeoutSeconds}s."
    return $false
}

function Install-RipperVpnTunnel {
<#
.SYNOPSIS
    Install a .conf as a Windows service via wireguard.exe
    /installtunnelservice. REQUIRES ELEVATION -- caller is expected to
    re-launch via Start-Process -Verb RunAs if not already admin. We do
    not auto-elevate inside this function because that creates a child
    process that loses our log scope.

.PARAMETER ConfPath
    Absolute path to the .conf file. The tunnel name = filename without
    extension.

.PARAMETER WireGuardExe
    Optional override for the path to wireguard.exe. Defaults to the
    well-known install location.
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string]$ConfPath,
        [string]$WireGuardExe = "$env:ProgramFiles\WireGuard\wireguard.exe"
    )
    if (-not (Test-Path -LiteralPath $ConfPath)) {
        Write-RipperLog WARN 'Wireguard' "Tunnel config '$ConfPath' does not exist."
        return $false
    }
    if (-not (Test-Path -LiteralPath $WireGuardExe)) {
        Write-RipperLog WARN 'Wireguard' "WireGuard executable not found at '$WireGuardExe'. Install via 'winget install WireGuard.WireGuard'."
        return $false
    }
    $tunnelName = [System.IO.Path]::GetFileNameWithoutExtension($ConfPath)
    $svcName = Get-RipperVpnTunnelServiceName -Name $tunnelName

    # Idempotent: if the service is already installed pointing at
    # exactly this conf, we're done. We can't easily introspect the
    # service binary path to verify "same conf" without parsing the
    # registry, so we settle for "exists" -- the user's setup flow is
    # the authority on which conf is current.
    if ((Test-RipperVpnTunnel -Name $tunnelName -Detailed) -ne 'NotInstalled') {
        Write-RipperLog INFO 'Wireguard' "Tunnel '$tunnelName' already installed; skipping /installtunnelservice."
        return $true
    }
    try {
        # WG's installer is synchronous and exits 0 on success.
        $proc = Start-Process -FilePath $WireGuardExe `
            -ArgumentList @('/installtunnelservice', $ConfPath) `
            -Wait -PassThru -WindowStyle Hidden
        if ($proc.ExitCode -ne 0) {
            Write-RipperLog WARN 'Wireguard' "/installtunnelservice exited $($proc.ExitCode) for '$ConfPath'."
            return $false
        }
    } catch {
        Write-RipperLog WARN 'Wireguard' "/installtunnelservice threw: $($_.Exception.Message)"
        return $false
    }
    Write-RipperLog INFO 'Wireguard' "Installed tunnel '$tunnelName' as service '$svcName'."
    return $true
}

function Uninstall-RipperVpnTunnel {
<#
.SYNOPSIS
    Remove a previously-installed WireGuard tunnel service. REQUIRES
    ELEVATION (same caveat as Install).
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string]$Name,
        [string]$WireGuardExe = "$env:ProgramFiles\WireGuard\wireguard.exe"
    )
    $svcName = Get-RipperVpnTunnelServiceName -Name $Name
    if ((Test-RipperVpnTunnel -Name $Name -Detailed) -eq 'NotInstalled') {
        Write-RipperLog INFO 'Wireguard' "Tunnel '$Name' not installed; nothing to uninstall."
        return $true
    }
    if (-not (Test-Path -LiteralPath $WireGuardExe)) {
        Write-RipperLog WARN 'Wireguard' "WireGuard executable not found at '$WireGuardExe'."
        return $false
    }
    try {
        $proc = Start-Process -FilePath $WireGuardExe `
            -ArgumentList @('/uninstalltunnelservice', $Name) `
            -Wait -PassThru -WindowStyle Hidden
        if ($proc.ExitCode -ne 0) {
            Write-RipperLog WARN 'Wireguard' "/uninstalltunnelservice exited $($proc.ExitCode) for '$Name'."
            return $false
        }
    } catch {
        Write-RipperLog WARN 'Wireguard' "/uninstalltunnelservice threw: $($_.Exception.Message)"
        return $false
    }
    Write-RipperLog INFO 'Wireguard' "Uninstalled tunnel '$Name' (service '$svcName')."
    return $true
}

function Grant-RipperVpnTunnelControl {
<#
.SYNOPSIS
    Widen the SD on a tunnel service so the current (non-admin) user
    can Start-Service / Stop-Service it. REQUIRES ELEVATION.

.DESCRIPTION
    Reads the existing security descriptor via `sc.exe sdshow`, splices
    in an extra ACE granting the target user SERVICE_START + SERVICE_STOP
    + SERVICE_QUERY_STATUS + READ_CONTROL on this one specific service,
    and writes it back via `sc.exe sdset`. The ACL is service-scoped --
    it does not affect any other service or any machine-wide policy.

    The standard SDDL bits we add (per
    https://learn.microsoft.com/en-us/windows/win32/services/service-security-and-access-rights):
        CC = SERVICE_QUERY_CONFIG       (0x0001)
        LC = SERVICE_QUERY_STATUS       (0x0004)
        SW = SERVICE_ENUMERATE_DEPENDENTS (0x0008)
        RP = SERVICE_START              (0x0010)
        WP = SERVICE_STOP               (0x0020)
        DT = SERVICE_PAUSE_CONTINUE     (0x0040)
        LO = SERVICE_INTERROGATE        (0x0080)
        CR = SERVICE_USER_DEFINED_CONTROL (0x0100)
        RC = READ_CONTROL               (0x00020000)
    We grant LCRPWPLO so the user can query, start, stop, and
    interrogate -- no config changes, no delete.

.PARAMETER Name
    Tunnel name.

.PARAMETER UserSid
    SID string of the user to grant control to. Defaults to the current
    user (which is what setup will pass).
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string]$Name,
        [string]$UserSid = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    )
    $svcName = Get-RipperVpnTunnelServiceName -Name $Name
    if ((Test-RipperVpnTunnel -Name $Name -Detailed) -eq 'NotInstalled') {
        Write-RipperLog WARN 'Wireguard' "Tunnel '$Name' is not installed; cannot grant control."
        return $false
    }

    # Read existing SD.
    $existing = & sc.exe sdshow $svcName 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($existing)) {
        Write-RipperLog WARN 'Wireguard' "sc.exe sdshow '$svcName' failed (exit $LASTEXITCODE)."
        return $false
    }
    $existing = $existing.Trim()
    Write-RipperLog INFO 'Wireguard' "Existing SD on '$svcName': $existing"

    # If our ACE is already in there, skip.
    $aceForUs = "(A;;LCRPWPLO;;;$UserSid)"
    if ($existing -like "*$aceForUs*") {
        Write-RipperLog INFO 'Wireguard' "Tunnel '$Name' SD already grants control to SID $UserSid."
        return $true
    }

    # SDDL is "[O:owner][G:group]D:[flags](ace)(ace)...[S:[flags](ace)...]".
    # Naive regex splits like `D:[^S]*?` are wrong because ACE bodies
    # contain S characters (LCSWLO etc.). We splice using a
    # two-anchor regex: take everything up through the LAST D:-section
    # ACE -- which is the last `)` before either an `S:` section or
    # end-of-string. Greedy `.*` backtracks to make the optional
    # trailing S: section match.
    if ($existing -match '^(?<prefix>.*D:[^()]*(?:\([^)]*\))*)(?<srest>S:.*)?$') {
        $newSd = "$($matches.prefix)$aceForUs$($matches.srest)"
    } else {
        Write-RipperLog WARN 'Wireguard' "Could not parse existing SD; refusing to overwrite. SD was: $existing"
        return $false
    }
    Write-RipperLog INFO 'Wireguard' "New SD for '$svcName': $newSd"

    $out = & sc.exe sdset $svcName $newSd 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-RipperLog WARN 'Wireguard' "sc.exe sdset '$svcName' failed (exit $LASTEXITCODE): $($out.Trim())"
        return $false
    }
    Write-RipperLog INFO 'Wireguard' "Granted SID $UserSid start/stop control on '$svcName'."
    return $true
}
