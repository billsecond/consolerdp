# ConsoleRDP Changelog

Retired issues from `known-issues.md` live here with fix hash / date /
evidence so we keep the postmortem visible.

## 2026-05-04 — Cannot reconnect over RDP until physical host login

**Resolved in:** `bin/consolerdp-daemon` (`_tear_down_locked` +
`RdpWatcher` debounce + `/etc/consolerdp/consolerdp.conf`
`lock_on_release=false`).

**Root cause.** Two distinct bugs stacking into the same
symptom:

1. **Daemon parked the local VT on the greeter after mstsc
   disconnect.** `_tear_down_locked` did `loginctl lock-session`
   but never `chvt`'d back to `console_tty`. The local VT stayed
   on `tty<greeter_tty>` until a human at the console
   manually switched back or logged in at the greeter. KWin
   (running on `console_tty`) was therefore not the foreground
   VT, lost DRM master, and returned `Permission denied` from
   every atomic modeset. The next mstsc connect authenticated
   via NLA but `krdpserver` could not satisfy the screencast
   stream request -- no screen, looked like "can't connect".
   Ctrl+Alt+F<console_tty> from the physical host restored DRM
   master and the same mstsc connection flow succeeded
   immediately.

2. **`RdpWatcher` false-positive disconnect on every NLA
   handshake.** The watcher polls `/proc/net/tcp*` every 500ms
   for `TCP_ESTABLISHED` entries on port 3389. mstsc with NLA
   briefly closes the auth TCP and opens a fresh stream TCP;
   during that gap the watcher saw zero established sockets
   and fired `RELEASE` ~200ms after every `TAKEOVER`. With the
   old "park on greeter" behaviour this was invisible (greeter
   was already there). With the new "chvt to console_tty"
   behaviour it cycled the VT twice per connect and caused the
   "black and didn't connect, then welcome screen, then a
   clean retry worked" pattern.

**Fixes.**
- `_tear_down_locked`: after `loginctl lock-session`, clear
  `rdp_active` FIRST (so `VtMonitor` will not fire a spurious
  `reclaim` on the VT transition we are about to cause), then
  `chvt` back to `saved_console_tty or cfg.console_tty`.
- `RdpWatcher`: added `DISCONNECT_DEBOUNCE = 3` consecutive
  empty polls before firing `RELEASE`. Any re-observed
  connection resets the counter.
- `/etc/consolerdp/consolerdp.conf`: set `lock_on_release =
  false` per user preference, so reconnect doesn't double-prompt
  (mstsc NLA + Plasma lockscreen).

**Tests.** `tests/smoke.py`:
- `test_release_locks_and_chvts_back` — asserts
  `sys.chvt(1)` after `release`.
- `test_rdp_watcher_debounces_brief_connection_gaps` — two
  empty polls between established polls must NOT fire release.
- `test_rdp_watcher_fires_release_after_sustained_disconnect` —
  3+ empty polls must fire release exactly once.

**Evidence.**
- Before: every `takeover` in the journal paired with a
  `release` 100-200ms later (`08:49:08.269 takeover ->
  08:49:08.470 release`).
- After install + restart: clean takeover, no spurious release;
  user confirmed "I was able to re-connect via RDP".

**Caveat** (new issue visible only now). With `lock_on_release
= false`, a human walking up to the host after a disconnect
sees the user's unlocked Plasma desktop on the physical
display until DPMS sleeps it (or until a subsequent mstsc
connect reclaims the VT). The original "pre-login flash"
concern (known-issues #1, formerly #2) still applies and gets
worse in this configuration -- will be addressed separately
by blanking the physical output on disconnect via a KWin
script, since Hyper-V's `hyperv_drm` driver cannot honour
Wayland `kde_output_configuration_v2` disable requests.

## 2026-05-04 — Faint / washed-out colors over RDP

**Resolved in:** `patches/kpipewire/0001-libx264-bt601-color-init-order.patch`

**Root cause.** Three stacked bugs, all inside
`libKPipeWireRecord::LibX264Encoder`:

1. **Initialization-order race in the ctor.** The filter graph string
   (`m_filterGraphToParse`) was built from `m_colorRange` at construction
   time. `PipeWireProduce::setupEncoder()` however calls
   `encoder->setColorRange(m_colorRange)` *after* the encoder is
   constructed and *before* `encoder->initialize()` runs. At ctor time
   `m_colorRange` is still the `Encoder` base-class default (`Limited`).
   Setting `ColorRange::Full` on the `PipeWireEncodedStream` silently
   did nothing — the filter kept squeezing YUV into `[16,235]`.
2. **VUI / YUV mismatch.** Because of bug #1, the filter produced
   Limited-range YUV, but the separate VUI-metadata patch correctly
   set `color_range = AVCOL_RANGE_JPEG` (Full) in the H.264 SPS.
   mstsc honored the VUI, decoded with a Full-range inverse, and
   rendered 16-235 as if it were 0-255 — lifted blacks, muted whites.
   Host `#000000` showed up as `~#262426` in mstsc.
3. **BT.709 vs BT.601 matrix drift.** libswscale's default RGB→YUV
   matrix for ≥720p is BT.709, but RDP-EGFX / mstsc inverts with
   BT.601. Subtle tint on reds/greens.

**Fix.**
- Moved `m_filterGraphToParse` construction from the ctor to
  `initialize()`, which runs after `setColorRange()`.
- Added `scale=out_color_matrix=bt601` so encoder and decoder agree.
- Wrote explicit VUI tags (`AVCOL_PRI/TRC/SPC_SMPTE170M` +
  `color_range` derived from `m_colorRange`) so there is no ambiguity.

**Evidence.**
- Filter dump at runtime:
  `CONSOLERDP-LIBX264-FILTER-GRAPH "format=yuv420p,pad=...,scale=out_color_matrix=bt601:out_range=full"`
- Before: `/home/wdaugherty/Desktop/Test/Normal/RDP.jpg` sample pixel
  `(24, 24, 24)` on host rendered as `(38, 36, 39)` in mstsc.
- After: visual confirmation from user — "Color is normal."
- Service: `systemctl --user restart app-org.kde.krdpserver.service`
  after installing the patched
  `/usr/lib/x86_64-linux-gnu/libKPipeWireRecord.so.6.6.4`.

**Environment dependency.** The drop-in
`~/.config/systemd/user/app-org.kde.krdpserver.service.d/color-range.conf`
sets `KRDP_COLOR_RANGE=full`. That env var is read inside the krdp
`PlasmaScreencastV1Session` / `PortalSession` patch
(`patches/krdp/0009-color-range-limited-for-mstsc.patch`) and passed
through to the encoder.

**Outstanding.** `h264vaapiencoder.cpp` has the same init-order shape
but VAAPI is not exercised on this Hyper-V VM. Patch deferred.
