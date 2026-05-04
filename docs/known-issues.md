# Known Issues

Tracking outstanding ConsoleRDP bugs / friction points. Each entry has the
symptom, the impact, and what we know so far. Items remain here until a
patch lands AND the user confirms the fix on the live host.

## 1. Pre-login flash of last RDP screen content (security risk)

**Symptom.** When walking up to the host after an RDP session has been
torn down, between the GPU coming up and SDDM drawing the lock/login
screen, the user briefly (~200-500ms) sees the *contents* of the last
RDP session frame -- whatever was last on screen in mstsc. Could be email,
banking, code, anything sensitive.

**Impact.** **High security risk.** A drive-by viewer (coworker, repair
tech, anyone with physical access to the monitor) sees session content
they should not. Defeats the lock-on-disconnect contract.

**Hypotheses.**
- KWin keeps the last framebuffer of the (now-disappearing) virtual
  output in compositor memory. When `enable-physical` re-enables the
  physical output, KWin paints the last virtual frame onto the physical
  before SDDM grabs the screen.
- Order of operations in `on_disappear`: we currently re-enable physical
  *first*, then revert claim-screen, then rescue windows. The re-enable
  step may race against the SDDM lock screen draw.

**Next steps.**
- Add a deliberate "draw black" pass on the physical output between
  `enable-physical` and the rest of teardown, e.g. via KWin
  `Workspace.fillScreenBlack()` script or DPMS off+on cycle.
- Alternatively, force SDDM lock screen *before* re-enabling physical
  outputs, so the first frame the physical sees is the lock screen.

## How issues get retired

Move retired items to `docs/changelog.md` (create on first use) with
the patch hash and confirmation date. Do not delete from this file --
keep the postmortem visible for future debugging.
