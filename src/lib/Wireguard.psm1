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
    # If the SCM is mid-transition (StartPending / StopPending) Stop-Service
    # will fail with "service cannot accept control messages at this time"
    # (Win32 error 1061). Wait briefly for the service to settle into a
    # stable state before issuing the stop. Seen right after
    # wireguard.exe /installtunnelservice, which spawns the service in
    # StartPending while WG handshakes with WinTun.
    try {
        $svcRaw = Get-Service -Name $svcName -ErrorAction Stop
        $settleSw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($settleSw.Elapsed.TotalSeconds -lt 10 -and `
               ($svcRaw.Status -eq 'StartPending' -or $svcRaw.Status -eq 'StopPending')) {
            Start-Sleep -Milliseconds 250
            $svcRaw.Refresh()
        }
        if ($svcRaw.Status -ne 'Running' -and $svcRaw.Status -ne 'Stopped') {
            Write-RipperLog WARN 'Wireguard' "Tunnel '$Name' is in transient state '$($svcRaw.Status)' after 10s wait; attempting Stop-Service anyway."
        }
    } catch {
        # Get-Service should not fail here (Test-* just succeeded) but
        # be defensive -- fall through to Stop-Service which will surface
        # any real problem.
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

# --- Phase 6.4.1: refcounted lifecycle wrapper ----------------------------
# Per-tunnel state lives in $script: scope of THIS module instance. Each
# runspace that imports the module gets its own copy, which is fine
# because each runspace's own sync calls are sequential. Cross-runspace
# bookkeeping is handled by the caller (Start-Ripper exit hook +
# $env:MUSICRIPPER_WG_SESSION_REF env-var sentinel for the keep-alive
# case).
#
#   $script:WgRefs[<name>] = @{ RefCount = <int>; OwnedByUs = <bool> }
#
# OwnedByUs is set when WE were the one who flipped the tunnel from
# Stopped to Running. We never stop a tunnel a different process or a
# previous session brought up.
$script:WgRefs = @{}

function Get-RipperVpnTunnelRefState {
<#
.SYNOPSIS
    Diagnostic helper -- returns the in-process refcount state for the
    named tunnel. Used by tests; not for production callers.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Name)
    if (-not $script:WgRefs.ContainsKey($Name)) {
        return @{ RefCount = 0; OwnedByUs = $false }
    }
    # Return a clone so tests can't accidentally mutate state.
    $s = $script:WgRefs[$Name]
    @{ RefCount = [int]$s.RefCount; OwnedByUs = [bool]$s.OwnedByUs }
}

function Add-RipperVpnTunnelRef {
<#
.SYNOPSIS
    Increment the refcount for the named tunnel. Brings the tunnel up
    on the 0 -> 1 transition (and remembers that WE started it so the
    matching Remove-RipperVpnTunnelRef can stop it on the way back to
    0). On every subsequent acquire just bumps the counter. Returns
    $true on success / no-op, $false if the tunnel could not be
    started.

.DESCRIPTION
    Pair with Remove-RipperVpnTunnelRef in a try/finally, or use
    Use-RipperVpnTunnel which does that for you.
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [string]$Name)
    if (-not $script:WgRefs.ContainsKey($Name)) {
        $script:WgRefs[$Name] = @{ RefCount = 0; OwnedByUs = $false }
    }
    $s = $script:WgRefs[$Name]
    if ($s.RefCount -eq 0) {
        $state = Test-RipperVpnTunnel -Name $Name -Detailed
        if ($state -eq 'Running') {
            # Already up before we got here -- don't take ownership;
            # release will be a no-op.
            $s.OwnedByUs = $false
            Write-RipperLog INFO 'Wireguard' "Acquired ref to tunnel '$Name' (already up; not owned)."
        } elseif ($state -eq 'NotInstalled') {
            Write-RipperLog WARN 'Wireguard' "Cannot acquire tunnel '$Name': service not installed."
            return $false
        } else {
            $started = Start-RipperVpnTunnel -Name $Name
            if (-not $started) { return $false }
            $s.OwnedByUs = $true
        }
    }
    $s.RefCount++
    return $true
}

function Remove-RipperVpnTunnelRef {
<#
.SYNOPSIS
    Decrement the refcount for the named tunnel. On the 1 -> 0
    transition, stops the tunnel IFF Add-RipperVpnTunnelRef was the one
    that started it. No-op if RefCount is already 0 (defensive: a stray
    Remove without a paired Add must not bring down a tunnel some other
    consumer is still holding).
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [string]$Name)
    if (-not $script:WgRefs.ContainsKey($Name)) {
        Write-RipperLog WARN 'Wireguard' "Remove-RipperVpnTunnelRef '$Name': no acquire on record; ignoring."
        return $true
    }
    $s = $script:WgRefs[$Name]
    if ($s.RefCount -le 0) {
        Write-RipperLog WARN 'Wireguard' "Remove-RipperVpnTunnelRef '$Name': refcount already 0; ignoring."
        return $true
    }
    $s.RefCount--
    if ($s.RefCount -eq 0 -and $s.OwnedByUs) {
        $stopped = Stop-RipperVpnTunnel -Name $Name
        $s.OwnedByUs = $false
        return $stopped
    }
    return $true
}

function Use-RipperVpnTunnel {
<#
.SYNOPSIS
    Refcounted lifecycle wrapper: acquire the named tunnel, run the
    scriptblock, release in a finally. The tunnel is brought up on the
    first acquire and (if WE started it) torn down on the last release.

.DESCRIPTION
    The right way for a sync target to gate work on a WG tunnel.
    Nested acquires are safe; the tunnel stays up across all of them
    and only comes down on the outermost release. Exceptions inside
    the scriptblock are re-thrown after release.

    Returns the result of the scriptblock when acquire succeeds; throws
    a terminating error when acquire fails (so the caller's catch can
    convert it into a sync-target Failed result).

.PARAMETER Name
    Tunnel name (see Get-RipperVpnTunnelServiceName).

.PARAMETER ScriptBlock
    Work to do while the tunnel is held up. May return any value
    (passed through to the caller).

.EXAMPLE
    Use-RipperVpnTunnel -Name 'home-wg' -ScriptBlock {
        robocopy $src $unc /MIR
    }
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [scriptblock]$ScriptBlock
    )
    $ok = Add-RipperVpnTunnelRef -Name $Name
    if (-not $ok) {
        throw "Could not bring WireGuard tunnel '$Name' up; sync cannot proceed."
    }
    try {
        & $ScriptBlock
    } finally {
        [void](Remove-RipperVpnTunnelRef -Name $Name)
    }
}

function Enable-RipperVpnTunnelSessionKeepAlive {
<#
.SYNOPSIS
    Phase 6.4.1: hold an extra refcount on the named tunnel for the
    rest of the session, so it stays up between consecutive sync
    operations (e.g. between discs in continuous-mode rip). Idempotent;
    safe to call before every sync. Pair with
    Disable-RipperVpnTunnelSessionKeepAlive at session exit.

.DESCRIPTION
    Used when cfg.WireGuardKeepAliveBetweenDiscs is true. Without this
    extra ref, a 30-disc rip session would bounce the tunnel 30 times
    (each disc's Use-RipperVpnTunnel acquires + releases on its own).
    With this ref, the first per-sync acquire brings it up, the
    keep-alive ref pins it at refcount=1 even after the per-sync
    release, and Disable-* on session exit drops the last ref.

    Sets $env:MUSICRIPPER_WG_SESSION_REF=<name> so the parent runspace
    (Start-Ripper) can disable on exit even if the worker that
    originally enabled has already terminated.
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [string]$Name)
    # Already enabled in this runspace? No-op.
    if ($env:MUSICRIPPER_WG_SESSION_REF -eq $Name) {
        return $true
    }
    $ok = Add-RipperVpnTunnelRef -Name $Name
    if (-not $ok) { return $false }
    $env:MUSICRIPPER_WG_SESSION_REF = $Name
    Write-RipperLog INFO 'Wireguard' "Session keep-alive enabled for tunnel '$Name'."
    return $true
}

function Disable-RipperVpnTunnelSessionKeepAlive {
<#
.SYNOPSIS
    Drop the keep-alive refcount on the named tunnel. Idempotent. Reads
    the tunnel name from $env:MUSICRIPPER_WG_SESSION_REF if -Name is
    omitted, so an exit hook in a different runspace from the one that
    enabled keep-alive can still clean up correctly.
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Name)
    if (-not $Name) { $Name = $env:MUSICRIPPER_WG_SESSION_REF }
    if ([string]::IsNullOrWhiteSpace($Name)) { return $true }
    [void](Remove-RipperVpnTunnelRef -Name $Name)
    $env:MUSICRIPPER_WG_SESSION_REF = $null
    Write-RipperLog INFO 'Wireguard' "Session keep-alive disabled for tunnel '$Name'."
    return $true
}
