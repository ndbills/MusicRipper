---
name: Bug report
about: Something MusicRipper did wrong on your machine.
title: "[bug] "
labels: bug
---

<!--
Thanks for taking the time to file this. The more of the context
sections below you can fill in, the faster the bug can be reproduced
and fixed. Sections you can't or don't want to fill in are fine to
leave blank.

DO NOT paste DPAPI-encrypted credentials, NAS paths that include
real domain names, or WireGuard config contents. None of those are
needed to debug normal failures.
-->

### Environment

- **Windows version:** <!-- e.g. Windows 11 23H2; `winver` to look up -->
- **PowerShell version:** <!-- output of `$PSVersionTable | Format-List PSVersion, PSEdition, OS` -->
- **MusicRipper commit / version:** <!-- `git -C C:\bin\MusicRipper rev-parse --short HEAD`, or the version shown in Settings -->
- **Optical drive model:** <!-- output of `Get-CimInstance Win32_CDROMDrive | Select-Object Name, Drive` -->

### What happened

<!-- Describe the failure in one or two sentences. -->

### Expected vs actual

- **Expected:** <!-- what you thought would happen -->
- **Actual:** <!-- what actually happened -->

### Repro steps

1.
2.
3.

### Log excerpt

<!--
MusicRipper writes per-session logs to:
  %LOCALAPPDATA%\MusicRipper\logs\

Open the most recent ripper-session-*.log and paste the relevant
chunk (typically the last ~50 lines around the failure). For WPF
crashes, also check:
  %LOCALAPPDATA%\MusicRipper\logs\<dialog-name>-dispatcher.log

Wrap the paste in a fenced code block so GitHub formats it.
-->

```
(paste log excerpt here)
```

### Anything else

<!-- Workarounds tried, related issues, screenshots, the disc that
triggered it (if you're comfortable naming an album), etc. -->
