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

**Status: implemented in Phase 6.4 (D-026).** What follows is the
operator's reference; design rationale lives in `DECISIONS.md`.

#### Prerequisites

- A WireGuard `.conf` file describing one tunnel (peer = the
  Synology, or the router in front of it). Author this on the
  *server* side (DSM has a WireGuard package, or run `wg-quick` on
  any Linux box on the same LAN as the NAS) and copy it to the
  client laptop.
- The `.conf`'s `AllowedIPs` should be the **NAS subnet only**
  (e.g. `AllowedIPs = 192.168.1.0/24`). This gives you a split
  tunnel automatically -- only NAS traffic goes through the VPN,
  the parent's regular browsing stays direct. MusicRipper does NOT
  rewrite `.conf` files; that's entirely your call.

#### One-time install

1. Run `./setup/Install-Dependencies.ps1`. Among the other
   dependencies, this winget-installs `WireGuard.WireGuard`. The
   first install pulls in the WinTun kernel driver (signed); you'll
   see one UAC prompt for that.
2. Run `./setup/New-RipperConfig.ps1`. After the Synology UNC
   prompts, you'll be asked:
   *"Set up WireGuard auto-toggle for the NAS share? (y/N)"*
   Answer `y`, then paste the absolute path to your `.conf`.
3. Setup spawns an elevated `pwsh` child that does both of:
   - `wireguard.exe /installtunnelservice <path>` -- registers a
     Windows service named `WireGuardTunnel$<filename-stem>`
     running as LocalSystem.
   - `sc.exe sdset` -- widens that one service's security
     descriptor so your (non-admin) Windows user can `Start-Service`
     and `Stop-Service` it without elevation.
   This is the **only** UAC prompt you'll ever see for tunnel
   management. Subsequent rips toggle the tunnel silently.
4. Setup writes `WireGuardTunnelName` and `WireGuardAutoToggle = true`
   to `config.json`.

#### What happens at rip time

Before each NAS sync, `Sync-ToSynologyNAS.ps1`:

1. Reads `cfg.WireGuardTunnelName` + `cfg.WireGuardAutoToggle`.
2. If both set and the tunnel service is not Running, calls
   `Start-Service WireGuardTunnel$<Name>` and waits for it to
   reach Running (15s default timeout).
3. Marks `$script:RipperSession.WgStartedByUs = $true`.
4. Runs the existing UNC pre-flight + robocopy.

When MusicRipper exits (last `Stop-RipperLog`), if `WgStartedByUs`
is true the script calls `Stop-Service` on the tunnel. Tunnel does
**not** bounce between discs in a stack -- one rip session, one
tunnel-up/tunnel-down cycle.

#### When the tunnel won't come up

Examples: parent is on a guest network that blocks UDP; the peer
is offline; the WG service crashed. `Sync-ToSynologyNAS` returns
`Status='Failed'` with a `Diagnostic` pointing at the WG service,
the rip pipeline keeps going (per D-022), the album lands in
`sync-state.json` as Failed. **The Phase-6.5 startup retry dialog
catches it next time** the parent launches MusicRipper from a
network where the tunnel works -- no manual intervention needed.

#### Manual control

- Status: `Get-Service WireGuardTunnel$<Name>`
- Start/stop: `Start-Service WireGuardTunnel$<Name>` /
  `Stop-Service WireGuardTunnel$<Name>` (no elevation needed if
  setup ran successfully).
- Disable auto-toggle without uninstalling the tunnel: set
  `cfg.WireGuardAutoToggle = false` in `config.json` (or re-run
  `setup/New-RipperConfig.ps1`).
- Remove entirely: delete `cfg.WireGuardTunnelName` and run
  `wireguard.exe /uninstalltunnelservice <Name>` from an elevated
  prompt (or use the WireGuard tray app's "Remove tunnel" UI).
