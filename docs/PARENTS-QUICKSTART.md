# Parents' Quickstart

> **Status:** Stub. The full screenshot-heavy version lands in **Phase 7**.
>
> Until then, parents shouldn't be using this — there's no rip logic yet,
> just a Phase-1 stub message box.

Planned contents (Phase 7):

1. Insert a CD.
2. Double-click **Rip a CD** on the Desktop.
3. Confirm the album info that pops up. Click **Rip**.
4. Wait for the green check mark.
5. Eject the disc and insert the next one.

## Where do my CDs end up? *(Phase 6.1)*

Once a disc rips cleanly it lands in your **library folder** (the
path you picked when you first installed MusicRipper). From there,
the engineer can opt the machine in to **sync targets** that copy
each finished album somewhere else \u2014 OneDrive, the family Synology
NAS, etc. \u2014 and to a **retention rule** that decides what happens to
the local copy once every sync target has confirmed receipt:

- **Keep** (default): the album stays in the library forever. Safe.
- **Move to `_Sent`**: the album is moved into a `_Sent` shadow tree
  inside the library so you can see at a glance what's been pushed
  off the box.
- **Send to Recycle Bin**: the local copy goes to the Recycle Bin so
  you can recover it for 30 days if anything goes sideways. Use this
  when disk space matters and you trust the off-box copy.

If a sync target fails (NAS unreachable, OneDrive offline) the album
just stays in the library and shows up next time MusicRipper retries
\u2014 nothing is lost. See [SYNC-TARGETS.md](SYNC-TARGETS.md) for the
engineer-facing details.
