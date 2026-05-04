# ConsoleRDP

**Windows-style RDP for Linux: single seat, single session, seamless takeover.**

ConsoleRDP makes a Linux desktop behave like a Windows workstation with
Remote Desktop enabled:

- There is exactly **one** desktop session at any time.
- Logging in physically opens the session on the attached monitor.
- Connecting via RDP **takes the session over** — without prompting the
  remote user, and without the remote user seeing the local screen.
- The displaced side (local or remote) is shown a fresh login greeter.
- Whoever authenticates last wins, just like Windows console session
  takeover.

It is a thin orchestration layer on top of well-known FOSS components
(`xrdp`, `x11vnc`, `xinput`, `chvt`, `loginctl`). No forks, no patches
to upstream. Tested on Ubuntu / Kubuntu 24.04+ with Xorg.

> **Status:** alpha. Works on Xorg sessions only. Wayland is not yet
> supported because there is no portable way to attach a remote
> framebuffer to an arbitrary running Wayland compositor; see
> `docs/ARCHITECTURE.md` for the road map.

---

## How it differs from stock xrdp

| Behavior                               | Stock xrdp | ConsoleRDP |
| -------------------------------------- | :--------: | :--------: |
| Spawns a *new* X session on RDP login  |     ✔      |     ✘      |
| Attaches to the user's *live* `:0`     |     ✘      |     ✔      |
| Local console keeps the desktop visible during RDP | ✔ |  ✘   |
| Local console is locked / hidden       |     ✘      |     ✔      |
| Multiple simultaneous sessions allowed |     ✔      |     ✘      |
| RDP password = system password         |     ✔      |     ✔      |

---

## Quick install (Kubuntu / Ubuntu 24.04+)

```bash
git clone https://github.com/<you>/consolerdp.git
cd consolerdp
sudo ./install.sh --user $(whoami)
```

The installer is **fully non-interactive** (no debconf / needrestart prompts) and:

1. `apt install` the runtime: `xrdp x11vnc xinput kbd python3 socat`.
2. If `/usr/share/xsessions` is empty (Plasma 6 on Kubuntu 26.04 is
   Wayland-only by default), it pulls in `plasma-session-x11` and
   `kwin-x11` so an X11 session is available at SDDM.
3. Drops our config into `/etc/xrdp/`, `/etc/pam.d/`, `/etc/consolerdp/`.
4. Installs `consolerdp-daemon`, `consolerdp-doctor`, etc. into
   `/usr/local/sbin/`.
5. Generates a 256-bit random `vnc.passwd` (root:xrdp, mode 0640).
6. Adds the seat user to `xrdp` and `ssl-cert` groups.
7. Drops a per-user XDG autostart entry that calls
   `consolerdp-ctl reclaim` on KDE/GNOME login (so logging in locally
   automatically kicks the remote session).
8. Enables a banner agetty (`consolerdp-greeter@tty8`) on the displaced
   TTY so the local user sees a "session in use remotely" prompt when
   RDP has the seat.
9. Sets the seat user's default SDDM session to X11
   (`/var/lib/sddm/state.conf` + `~/.dmrc`).
10. Opens UFW for tcp/3389 if UFW is active.
11. Enables `consolerdp.service` and restarts `xrdp.service`.
12. Runs `consolerdp-doctor` and prints a green/yellow/red preflight
    report.

After install, RDP to the box on port **3389** as the configured user.

To remove cleanly:

```bash
sudo ./uninstall.sh
```

---

## Configuration

`/etc/consolerdp/consolerdp.conf`:

```ini
[seat]
# The single user permitted to own this seat. Only this user can RDP in
# and only this user can log in physically.
user = alice

# TTY where the live X session lives (SDDM default = tty1 or tty7).
console_tty = 1

# TTY shown to the displaced side. SDDM will be told to spawn a fresh
# greeter here on demand.
greeter_tty = 8

[bridge]
# Address the x11vnc bridge listens on (always loopback in production).
listen = 127.0.0.1
port   = 5900

[policy]
# When set, a second RDP attempt while one is active is refused.
# When unset, the new connection wins and the previous RDP is dropped.
single_rdp = true

# Lock the KDE/GNOME session before handing back to the local console
# (so the user must re-enter the password to resume).
lock_on_release = true
```

---

## Diagnostics

```bash
consolerdp-doctor      # prints OK/WARN/FAIL for every precondition
consolerdp-ctl status  # what does the daemon think it's doing right now?
sudo journalctl -u consolerdp.service -f
```

`consolerdp-doctor` checks all installed packages, X11 session
availability, current `XDG_SESSION_TYPE` (or the seat user's via
`loginctl` when run under sudo), all four services, the daemon socket
ping, the TCP/3389 listener, UFW rule presence, and config sanity.

## Security notes

- The xrdp listener authenticates the user via PAM against the host's
  real account database — RDP password = login password.
- The x11vnc bridge between xrdp and `:0` is bound to `127.0.0.1` and
  protected by a 256-bit random password generated at install time
  (`/etc/consolerdp/vnc.passwd`, mode `0640`, group `xrdp`). It is
  never reachable from the network.
- Physical input devices are disabled via `xinput disable` for the
  duration of every RDP takeover, so even a TTY-switch back to the X
  session by a local actor cannot interact with the remote desktop.
- Single-user enforcement is implemented in PAM (`pam_succeed_if`) and
  reinforced in the daemon — both must agree before a session is
  granted.

See `docs/ARCHITECTURE.md` for the threat model and trust boundaries.

---

## Repository layout

```
.
├── bin/                       # Orchestrator executables (Python + shell)
│   ├── consolerdp-daemon
│   ├── consolerdp-takeover
│   └── consolerdp-release
├── config/                    # Templates dropped under /etc/
│   ├── consolerdp.conf
│   ├── xrdp.ini
│   ├── sesman.ini
│   ├── startwm.sh
│   └── pam.d/
│       └── xrdp-sesman
├── systemd/                   # Unit files
│   ├── consolerdp.service
│   └── consolerdp-vncbridge.service
├── docs/
│   └── ARCHITECTURE.md
├── tests/                     # pytest + shellcheck targets
├── install.sh
├── uninstall.sh
├── Makefile
├── LICENSE                    # Apache-2.0
└── README.md
```

---

## Contributing

Issues and PRs welcome. Run `make lint test` before submitting.
The project follows [Conventional Commits](https://www.conventionalcommits.org/).

## License

Apache 2.0. ConsoleRDP composes (does not vendor) GPL-2.0 components at
runtime; see `LICENSE` for the full notice.
