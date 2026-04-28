# Synology NAS Share Setup

> **Status:** Stub. Full screenshot walkthrough lands in **Phase 6.3**
> when `Sync-ToSynologyNAS.ps1` is implemented. The Phase 6.1 sync
> framework + retention layer is already in place \u2014 see
> [SYNC-TARGETS.md](SYNC-TARGETS.md) \u2014 so once the NAS target file
> exists it slots in as a new entry in `cfg.SyncTargets`.

## Remote-access model (decided)

The NAS is reachable from the rip machine over the user's existing
**self-hosted WireGuard VPN** on their router. No third-party relay
(no Tailscale, no QuickConnect) — data path is laptop → home router
→ NAS, end-to-end encrypted by WireGuard with no outside service in
the middle. See [DECISIONS.md D-007](DECISIONS.md).

## Planned doc contents (Phase 6)

### Part A — DSM share

1. DSM → **Control Panel** → **Shared Folder** → **Create**.
2. Permissions → grant your user read/write.
3. **File Services** → enable SMB.
4. Grab the UNC path (`\\<nas-host-or-vpn-ip>\<share>`).
5. Run `./setup/New-RipperConfig.ps1` and paste the UNC + credential
   when prompted. Credential is DPAPI-encrypted.

### Part B — WireGuard tunnel management

The MusicRipper post-processor needs the VPN up *only* during the
NAS sync. Goal: the user never has to remember to toggle anything.

Phase 6.4 scope (to be implemented in `Sync-ToSynologyNAS.ps1` and a
new `src/lib/Wireguard.psm1`):

1. **Install hook in `setup/Install-Dependencies.ps1`:** add
   `WireGuard.WireGuard` to the winget list.
2. **Config additions in `config.template.json`:**
   - `WireGuardTunnelName` — the name of the WG tunnel config
     (`.conf`) to bring up. `null` = no VPN management; assume share
     is already reachable.
   - `WireGuardAutoToggle` — bool. When `true`, the post-processor
     brings the tunnel up before sync and tears it down after.
   - `WireGuardIdleTimeoutMinutes` — int. If MusicRipper is going
     to rip multiple discs in a row, leave the tunnel up for this
     many minutes after the last sync rather than thrashing it on
     every disc. Default 10.
3. **`Wireguard.psm1` API:**
   - `Start-RipperVpnTunnel -Name <tunnel>` — wraps
     `wireguard.exe /installtunnelservice <path-to-conf>` (or
     `Set-Service`/`Start-Service` if the tunnel is already
     installed as a service).
   - `Stop-RipperVpnTunnel -Name <tunnel>` — wraps
     `wireguard.exe /uninstalltunnelservice <name>`.
   - `Test-RipperVpnTunnel -Name <tunnel>` — returns whether the
     tunnel service is running.
   - All three idempotent so repeated calls during a batch rip are
     no-ops.
4. **Post-processor flow:**
   ```
   Sync-ToSynologyNAS:
     if WireGuardAutoToggle and not Test-RipperVpnTunnel:
         Start-RipperVpnTunnel; record start time in session state
     robocopy ... \\<unc>\...
     register a shutdown hook in Start-Ripper.ps1 that, on exit OR
     after IdleTimeoutMinutes of inactivity, calls Stop-RipperVpnTunnel
   ```
5. **Split tunnel — investigate but probably skip.** Windows
   WireGuard supports per-tunnel `AllowedIPs` (route only the NAS
   subnet through the VPN), which is the cleanest "split tunnel"
   for our use case. The user is expected to author the `.conf` with
   `AllowedIPs = <nas-subnet>/24` so only NAS traffic uses the
   tunnel — no routing tricks needed in MusicRipper itself. Doc
   this in the Phase-6 walkthrough; do NOT try to rewrite the user's
   `.conf` from PowerShell.

### Open questions for Phase 6

- Does `wireguard.exe /installtunnelservice` need elevation every
  time, or only at first install? If every time, we may need to
  pre-install the tunnel as a service during setup and then just
  start/stop it (no UAC prompt) during rips.
- How do we surface a clear error to parents when the tunnel won't
  come up (e.g., they're on a guest network that blocks UDP)?
  Probably: log it, route the rip to `_ReviewQueue/` is overkill —
  better to just skip the NAS sync with a warning and let OneDrive
  (if configured) carry the day.
