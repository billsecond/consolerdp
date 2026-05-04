# ConsoleRDP

**Windows-style RDP for Linux: one seat, one session, seamless takeover — on KDE Plasma 6 Wayland.**

ConsoleRDP makes a Kubuntu workstation behave like a Windows box with Remote
Desktop enabled:

- There is exactly **one** desktop session at any time.
- Logging in at the physical console opens the session on the attached monitor.
- Connecting via RDP **takes the session over** — the mstsc user sees the live
  Plasma desktop, and the physical display flips to a greeter login banner.
- Disconnecting mstsc locks the session. Reconnecting auto-unlocks (NLA
  already authenticated you).
- Signing in at the physical greeter evicts the RDP user immediately.
- Whoever authenticates last wins, just like Windows console session
  takeover.

ConsoleRDP is a thin orchestration layer on top of:

- **KDE's `krdpserver`** (patched for NLA, color range, Plasma clipboard)
- **KDE's `kpipewire`** (patched for BT.601 color + correct H.264 VUI metadata)
- **`consolerdp-daemon`** — a ~1000-line Python daemon that drives VT
  switching, xinput lockdown, session lock/unlock, and connection-state
  detection via `/proc/net/tcp`.

> **Status:** Working for single-user Kubuntu 26.04 LTS. Not yet packaged for
> other distros. See [INSTALL.md](INSTALL.md) for compatibility details.

---

## Why this project exists

Stock options all have friction:

| Tool | Problem |
|------|---------|
| `xrdp` | Spawns a *new* X session per connection; ignores the live Plasma session. No NLA. |
| `krdpserver` alone | Works but has no disconnect/takeover logic. The physical screen keeps showing the user's desktop while someone else RDPs in. No auto-unlock. No VT switching. Washed-out colors on mstsc (BT.709 mismatch, limited/full range confusion). |
| `vino` / `x11vnc` | VNC, not RDP. No NLA. Doesn't integrate with mstsc's credential prompt. |
| `NoMachine`, `AnyDesk` | Proprietary, third-party servers. |

ConsoleRDP fixes the gaps around `krdpserver`: takeover semantics, VT
management, session lock, auto-unlock, and color correctness for mstsc.

---

## How it differs from stock `krdpserver`

| Behavior | Stock krdpserver | ConsoleRDP |
|----------|:---:|:---:|
| RDP connects to the live Plasma session | ✔ | ✔ |
| Physical monitor hides desktop during RDP | ✘ | ✔ (greeter on tty8) |
| Physical monitor reclaims on disconnect | ✘ | ✔ (lockscreen on tty2) |
| Auto-unlock mstsc reconnect | ✘ | ✔ (NLA-validated) |
| Local login evicts the RDP user | ✘ | ✔ (`VtMonitor`) |
| Mstsc shows `#000000` as pure black | ✘ (lifted blacks) | ✔ (BT.601 patch) |
| Works with mstsc's NLA prompt | ✘ without patch | ✔ |
| Plasma clipboard bridge (CTRL+C/V across mstsc) | ✘ | ✔ |
| Disconnect debounce (no phantom release on NLA) | n/a | ✔ |

---

## Install

See [INSTALL.md](INSTALL.md) for the full compatibility matrix and manual steps.

Quick version on a clean Kubuntu 26.04 LTS box:

```bash
git clone https://github.com/billsecond/consolerdp.git
cd consolerdp
sudo ./install.sh --user $(whoami)
```

Then on Windows, open **mstsc** and connect to your Linux host on port 3389
with your Linux password.

---

## Architecture

```
                              Windows (mstsc)
                                   │
                    TCP/3389, TLS + NLA (CredSSP)
                                   │
        ┌──────────────────────────▼────────────────────────────┐
        │  krdpserver (patched)    -- systemd --user service    │
        │    • NLA auth against PAM                             │
        │    • Forwards mstsc inputs via Plasma fake-input      │
        │    • Creates a KRDP-virtual-N Wayland output          │
        └──────┬──────────────────────────────┬─────────────────┘
               │ (creates output)             │ (streams frames)
        ┌──────▼───────┐               ┌──────▼──────────────────┐
        │ KWin         │◄─── kpipewire │ libKPipeWireRecord      │
        │   Wayland    │     patched   │   (libx264 BT.601 VUI)  │
        └──────────────┘               └─────────────────────────┘
                                                │ H.264/AVC
                                                └──► mstsc (BT.601 YUV→RGB)

                Seat lifecycle                  consolerdp user
                (systemd system unit)           (systemd user unit)
        ┌──────────────────────┐           ┌──────────────────────────┐
        │ consolerdp.service   │           │ consolerdp-session-      │
        │   consolerdp-daemon  │           │   watcher.service        │
        │                      │           │                          │
        │ • RdpWatcher         │           │ • Polls KWin output list │
        │   /proc/net/tcp:3389 │           │ • On KRDP-virtual appear:│
        │   + 3-poll debounce  │           │   claim-screen (move     │
        │                      │           │   panel + wallpaper)     │
        │ • KrdpJournalTailer  │           │   + corral-windows       │
        │   watches krdp       │           │ • On disappear: revert   │
        │   journal for        │           │                          │
        │   "auth complete"    │           └──────────────────────────┘
        │                      │
        │ • On takeover:       │
        │   - chvt greeter tty │
        │   - xinput disable   │
        │   - unlock-session   │
        │                      │
        │ • On release:        │
        │   - chvt console tty │
        │   - lock-session     │
        │   - xinput enable    │
        │                      │
        │ • On VT→console:     │
        │   - restart krdp     │
        │     user unit        │
        │     (evicts mstsc)   │
        └──────────────────────┘
```

---

## Configuration

`/etc/consolerdp/consolerdp.conf`:

```ini
[seat]
# The single user permitted to own this seat. Only this user can RDP in
# and only this user can log in physically.
user = wdaugherty

# TTY where the live Plasma session lives. SDDM on Kubuntu 26.04 uses tty2.
console_tty = 2

# TTY shown to the displaced side (must be different from console_tty).
greeter_tty = 8

# Password file for the (legacy) x11vnc bridge. Unused by the krdp stack
# but must exist (empty is fine) for backwards compatibility.
vnc_passwd_file = /etc/consolerdp/vnc.passwd

[bridge]
# Legacy x11vnc settings; ignored by the freerdp/krdp path.
listen = 127.0.0.1
port   = 5900

[rdp]
# TCP port that krdpserver listens on. Change here AND in the krdpserver
# config if you move it.
port = 3389

# How often the RdpWatcher polls /proc/net/tcp for connection state.
watch_interval = 0.5

[policy]
# Refuse a 2nd RDP connect while one is active. If false, the new
# connection wins and the previous mstsc is dropped.
single_rdp = true

# Lock the Plasma session on mstsc disconnect. Reconnect auto-unlocks
# via `loginctl unlock-session`, so this is transparent to the user.
lock_on_release = true
```

---

## Diagnostics

```bash
sudo consolerdp-doctor        # green/yellow/red preflight check
consolerdp-ctl status         # live daemon state JSON
sudo journalctl -u consolerdp.service -f
journalctl --user -u consolerdp-session-watcher.service -f
```

---

## Security model

- **Auth**: `krdpserver` validates mstsc's NLA credentials against PAM via
  `/etc/krdpserver/sam`. mstsc password = Linux password. No second prompt.
- **Seat scope**: only the `user=` in `consolerdp.conf` is allowed to
  initiate takeover; any other user's mstsc auth is rejected by the daemon.
- **Input lockdown**: on takeover, every `xinput` device on the seat is
  disabled so a physical actor at the console can't type into the remote
  user's active desktop (belt-and-braces, since the VT is also switched
  to the greeter).
- **Session lock on disconnect**: the Plasma session is locked the moment
  mstsc disconnects, so Ctrl+Alt+F2 from the physical console lands on a
  locked screen. Legitimate reconnect via mstsc auto-unlocks (NLA already
  passed).
- **Screencast protection**: the physical `Virtual-1` output is not
  forcibly disabled (Hyper-V's `hyperv_drm` driver does not honour
  `kde_output_configuration_v2` disable requests on atomic modeset); instead
  the VT is switched to the `consolerdp-greeter@tty8` agetty, which
  displays a "seat in use remotely" banner.

---

## Repository layout

```
consolerdp/
├── bin/                      # Orchestrator + helper scripts (bash + Python)
│   ├── consolerdp-daemon         # The orchestrator (all the control logic)
│   ├── consolerdp-ctl            # CLI to talk to the daemon socket
│   ├── consolerdp-configure      # Post-install wizard
│   ├── consolerdp-doctor         # Preflight / diagnostic
│   ├── consolerdp-session-watcher # Per-user systemd watcher (Plasma-side)
│   ├── consolerdp-claim-screen   # Move panel + wallpaper to KRDP virtual
│   ├── consolerdp-corral-windows # Pull windows onto the KRDP virtual
│   ├── consolerdp-output         # KWin output enable/disable via KF6 dbus
│   └── ... (16 total)
├── systemd/
│   ├── consolerdp.service        # Main orchestrator system unit
│   ├── consolerdp-greeter@.service # Greeter agetty on tty8
│   └── user/
│       └── consolerdp-session-watcher.service
├── config/
│   ├── consolerdp.conf           # Default config template
│   └── autostart/                # XDG autostart for per-user watcher
├── patches/
│   ├── krdp/     0001..0009      # 8 functional patches on krdp 6.6.4
│   └── kpipewire/0001            # BT.601 color patch
├── packaging/
│   └── consolerdp/debian/        # Debian packaging for the consolerdp .deb
├── release/                      # Prebuilt .debs (generated by build)
├── tests/
│   └── smoke.py                  # 10 unit tests; `make test`
├── install.sh                    # Top-level installer
├── uninstall.sh                  # Removal
├── INSTALL.md                    # Detailed install + compatibility
├── README.md                     # This file
└── LICENSE                       # Apache 2.0
```

---

## Contributing

Bug reports and PRs welcome on [GitHub](https://github.com/billsecond/consolerdp).

Before submitting:

```bash
python3 tests/smoke.py  # all 10 tests must pass
make lint               # shellcheck + ruff if installed
```

## License

Apache 2.0. See [LICENSE](LICENSE).

The bundled patches against `krdp` and `kpipewire` are Apache 2.0 / LGPL-2.1
respectively — both compatible, licenses retained per upstream.
