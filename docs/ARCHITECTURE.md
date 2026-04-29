# Architecture

## Goal

Replicate the **Windows console-session takeover** semantics on Linux:
one user, one desktop, smoothly migrating between the physical monitor
and an RDP client. Whoever authenticates most recently owns the seat.

## Component diagram

```
            ┌────────────────────────────────────────────────────┐
            │                       seat                         │
            │                                                    │
   ┌────────┴────────┐                              ┌────────────┴────────────┐
   │ Physical mon +  │                              │       RDP client        │
   │ keyboard/mouse  │                              │  (mstsc, FreeRDP, …)    │
   └────────┬────────┘                              └────────────┬────────────┘
            │ tty1 (Xorg :0) | tty8 (SDDM greeter)               │ tcp/3389
            ▼                                                    ▼
   ┌─────────────────┐         chvt / xinput              ┌─────────────┐
   │      Xorg       │◀───────────────────────────────────│    xrdp     │
   │      :0         │                                    │ (Apache-2.0)│
   │  (KDE/Plasma)   │             attach :0              │             │
   │                 │◀───────────────────────────────────│             │
   └────────┬────────┘   localhost RFB     ┌──────────────┤  vnc-conn   │
            │             127.0.0.1:5900   │              └──────┬──────┘
            ▼                              ▼                     │
   ┌─────────────────┐               ┌──────────┐                │
   │     x11vnc      │◀──────────────│ xrdp-    │                │
   │   (GPL-2.0)     │   PAM auth    │  sesman  │◀───────────────┘
   └─────────────────┘               └─────┬────┘
                                           │ pam_exec
                                           ▼
                                  ┌───────────────────┐
                                  │  consolerdp-      │  root daemon
                                  │      daemon       │  /run/consolerdp.sock
                                  │   (Apache-2.0)    │
                                  └─────────┬─────────┘
                                            │ chvt / xinput / loginctl
                                            ▼
                                       (the seat)
```

## Sequence: RDP takeover

1. RDP client connects to `xrdp` on `:3389`.
2. `xrdp-sesman` authenticates the user against PAM. The PAM stack at
   `/etc/pam.d/xrdp-sesman` enforces *seat owner only* via
   `pam_succeed_if`.
3. PAM `session` stack runs `pam_exec /usr/local/sbin/consolerdp-takeover`.
   That helper writes a `TAKEOVER user=<name> pid=<sesman_pid>` line to
   `/run/consolerdp.sock`.
4. `consolerdp-daemon` (running as root) receives the request and:
   1. Confirms `<name>` matches `seat.user` from the config.
   2. Locates Xorg `:0` and its `Xauthority` (parsed from
      `loginctl show-session $(loginctl list-sessions ...)`).
   3. Disables every physical `xinput` device on `:0`
      (so a local attacker cannot drive the remote desktop).
   4. Issues `chvt <greeter_tty>`, switching the physical screen to the
      configured greeter TTY. SDDM's `Generic` config spawns a greeter
      there (or, if no greeter is wanted, an `agetty` with a banner).
   5. Starts `x11vnc` bound to `127.0.0.1:<bridge.port>` attached to
      `:0` using the user's `Xauthority`, with the install-time random
      RFB password.
5. `xrdp`'s VNC connector dials `127.0.0.1:5900`, authenticates with
   the bridge password, and proxies RDP ↔ RFB.

The user now sees their **live** desktop with all its open apps.

## Sequence: RDP release (logout/disconnect)

1. xrdp-sesman terminates → PAM `close_session` runs
   `consolerdp-release`.
2. The daemon:
   1. Stops `x11vnc`.
   2. Re-enables physical `xinput` devices.
   3. If `policy.lock_on_release = true`, calls
      `loginctl lock-session <id>` to lock the KDE/GNOME screen.
   4. `chvt <console_tty>` — physical screen returns to the desktop
      (lock screen up).

## Sequence: local takeover while RDP is active

The local user moves mouse on the physical monitor, sees the SDDM
greeter (because we VT-switched there at step 4), enters their
password. SDDM is configured to *not* spawn a new session — instead it
runs `consolerdp-reclaim` which:

1. Authenticates via PAM (`session` hook included).
2. Tells the daemon to `RECLAIM`.
3. Daemon kills the active xrdp-sesman PID, stops x11vnc, re-enables
   input, `chvt <console_tty>`. Remote client gets disconnected.

## Why VT-switch instead of compositor screen-share?

Compositor-level sharing (e.g., wayvnc, gnome-remote-desktop) requires
the compositor's cooperation and either shows the same pixels to both
viewers (bad: local can shoulder-surf the remote) or duplicates the
session (bad: not a single session anymore). VT-switch + xinput-disable
gives us the strict isolation that mirrors Windows behavior, at the
cost of being Xorg-only for now.

## Wayland road map

Once `xdg-desktop-portal-rdp` is available across distros and
`systemd-logind` exposes a way to detach a session's input from the
seat, ConsoleRDP can run unchanged on Wayland. The orchestration logic
in `consolerdp-daemon` is compositor-agnostic; only the bridge
component (currently `x11vnc`) would change.

## Trust boundaries

| Component                | Privilege          | Trust source            |
| ------------------------ | ------------------ | ----------------------- |
| `consolerdp-daemon`      | root               | code review + tests     |
| `xrdp` / `xrdp-sesman`   | xrdp user, PAM     | distro package          |
| `x11vnc`                 | seat user          | distro package          |
| RDP client               | network attacker   | TLS + PAM password      |
| Local console attacker   | physical access    | xinput-disable + chvt   |

The daemon trusts only inputs that come over `/run/consolerdp.sock`
(mode `0660`, group `xrdp`). The socket is intentionally not
network-reachable.
