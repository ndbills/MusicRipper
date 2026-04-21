# Synology NAS Share Setup

> **Status:** Stub. Full screenshot walkthrough lands in **Phase 6** when
> `Sync-ToSynologyNAS.ps1` is implemented.

Planned contents:

1. DSM → **Control Panel** → **Shared Folder** → **Create**.
2. Permissions → grant your user read/write.
3. **File Services** → enable SMB.
4. Grab the UNC path (`\\<nas-host>\<share>`).
5. Run `./setup/New-RipperConfig.ps1` and paste the UNC + credential
   when prompted. Credential is DPAPI-encrypted.
