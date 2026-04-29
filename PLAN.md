# ConsoleRDP v2 — Rebuild Plan

> Drafted 2026-04-29 after multiple days fighting xrdp+sesman+x11vnc.
> Scope: throw out the entire xrdp control plane, keep what works,
> rebuild around `freerdp-shadow-x11` as the RDP engine.

## 1. What we keep, what we burn

### Keep (proven working)

| Component | Why keep | File |
|---|---|---|
| `consolerdp-daemon` orchestrator | Sole-instance lock, VT switching, xinput control, session lookup, Unix-socket protocol — all this works and is generic. | `bin/consolerdp-daemon` |
| `consolerdp-ctl` | CLI for status/reclaim/release. | `bin/consolerdp-ctl` |
| `consolerdp-doctor` | Diagnostic — adapts to the new backend trivially. | `bin/consolerdp-doctor` |
| `consolerdp-greeter-login` | Banner on the local console TTY. | `bin/consolerdp-greeter-login` |
| `consolerdp-reclaim-self` | Local-user "I want my session back" hook. | `bin/consolerdp-reclaim-self` |
| `.RDP` profile generator | Still useful — pre-fills host/user. | `bin/consolerdp-make-rdp` |
| KDE autostart entries, systemd unit for `consolerdp.service`, AppArmor/PAM stubs | All re-usable. | `config/systemd/`, `config/autostart/` |

### Burn (replaced)

| Component | Why burn | Replacement |
|---|---|---|
| `xrdp` daemon | No NLA, login dialog you can't suppress, sesman complexity. | `freerdp-shadow-cli` (real RDP server, supports NLA). |
| `xrdp-sesman` | Spawns Xvnc, runs PAM session, executes `startwm.sh` — all of it unnecessary because shadow-cli runs as the seat user already. | Gone. |
| `bin/consolerdp-xvnc-shim` | Existed solely to satisfy sesman. | Gone. |
| `bin/consolerdp-startwm` | Existed solely to keep sesman from tearing down the session. | Gone. |
| `config/sesman.ini`, `config/xrdp.ini`, `config/pam.d/xrdp-sesman` | Configure the burned daemons. | Gone. |
| `/etc/consolerdp/vnc.passwd` | x11vnc bridge auth. | Gone (shadow-cli uses /etc/freerdp/server creds or NLA). |

### Add

| Component | Role | File (new) |
|---|---|---|
| `consolerdp-rdp.service` | systemd unit that runs `freerdp-shadow-cli` as the seat user, restarts on failure. | `config/systemd/consolerdp-rdp.service` |
| `consolerdp-rdp-wrapper` | Tiny shell that exports `XAUTHORITY` and `DISPLAY=:0` from the live login session, then `exec`s `freerdp-shadow-cli` with our standard flags. | `bin/consolerdp-rdp-wrapper` |
| `consolerdp-rdp-cred` | Writes the SAM-style credentials file `freerdp-shadow-cli` reads for NLA. Pluggable: PAM-bridge or local file. | `bin/consolerdp-rdp-cred` |
| `consolerdp-pam-bridge` (PAM service file) | A custom PAM-aware authenticator that turns "user types Linux password into mstsc NLA" into "PAM authenticates that against the real Linux user". | `config/pam.d/consolerdp` |

## 2. Target architecture

```
            ┌────────────────── Windows / mstsc ───────────────────┐
            │                                                       │
            │  TCP/3389  ── TLS + CredSSP/NLA ──→ freerdp-shadow-cli │
            │                                            │          │
            └────────────────────────────────────────────┼──────────┘
                                                         │
                       ┌─────────────────────────────────▼────────────┐
                       │  consolerdp-rdp.service  (User=wdaugherty)    │
                       │     ↳ freerdp-shadow-cli                       │
                       │         /port:3389                             │
                       │         /sec:tls + /sam-file:…                 │
                       │         /monitors:0                            │
                       │         /shadow:0   ← attaches to live :0     │
                       └────┬─────────────────────────────────────┬────┘
                            │ (notifies on connect/disconnect)    │
                            │                                     │
                ┌───────────▼─────────┐               ┌───────────▼──────────┐
                │ consolerdp-daemon    │               │ user's live X11 :0   │
                │  - VT-switch tty1↔8  │               │  Plasma running      │
                │  - xinput disable    │               │  Real cursor / kbd   │
                │  - greeter banner    │               └──────────────────────┘
                │  - lock on release   │
                └──────────────────────┘
```

### What's gone vs. before

- No xrdp, no sesman, no PAM-session-creation, no Xvnc, no Xvfb decoy, no startwm.sh, no chansrv, no xorgxrdp.
- One process owns the RDP socket: `freerdp-shadow-cli`.
- It already supports NLA, so **no second login dialog** ever appears in mstsc.

## 3. Authentication strategy (the part that drove us crazy)

`freerdp-shadow-cli` accepts credentials three ways:

1. **`/sam-file:PATH`** — a file with `username:domain:LMhash:NThash:::` lines. NLA validates against this. Generated once at install from the user's Linux password (we hash it on the fly).
2. **`/sec:tls`** + cleartext password from `/sam-file` — same as 1 but TLS-only.
3. **No auth flags** — server prompts on each connect.

We pick **option 1** because:
- mstsc's NLA pre-auth means the user types creds in mstsc, **never** sees a server-side dialog.
- Credentials saved in Windows Credential Manager → future connects are zero-prompt (the actual Windows-RDP UX).
- No PAM session creation overhead — orchestrator handles VT/lock separately.

### Trust boundary

The SAM file is `0600 root:root` at `/etc/consolerdp/sam`. `freerdp-shadow-cli` runs as root *only briefly* to read it, then drops to the seat user (UID 1000) before touching the X server. Or we run it as the seat user and `chmod 0640 root:wdaugherty` the SAM file.

### Password sync

`bin/consolerdp-rdp-cred --user wdaugherty --prompt` runs once at install:
- Prompts for the Linux password
- Generates the NTLM hash via `python3 -c "from hashlib import md4; ..."` (or uses Python's `passlib.hash.nthash` if available)
- Writes the SAM file
- Provides `--sync-from-pam` mode (future) that updates the SAM file whenever the user changes their Linux password, via a `pam_unix` post-hook

## 4. Phased delivery

### Phase 0 — kill the old code (30 min)

- `apt-get remove --purge xrdp xorgxrdp xrdp-pulseaudio-installer`.
- `rm /usr/local/sbin/{Xvnc,consolerdp-xvnc-shim,consolerdp-startwm}`.
- `rm /etc/xrdp/*`.
- `rm /etc/consolerdp/vnc.passwd`.
- `systemctl disable --now xrdp.service xrdp-sesman.service` (if still installed).
- `git rm bin/consolerdp-xvnc-shim bin/consolerdp-startwm config/sesman.ini config/xrdp.ini config/pam.d/xrdp-sesman`.
- Update `consolerdp-doctor` to drop xrdp checks.

### Phase 1 — minimum viable RDP (1–2 h)

1. Install `freerdp-shadow-x11`.
2. Write `bin/consolerdp-rdp-cred`:
   - `--user U --password P --out FILE` → writes the SAM file.
   - `--user U --prompt` → reads stdin securely via `getpass` and calls the same.
3. Write `bin/consolerdp-rdp-wrapper`:
   - Exports `DISPLAY=:0`, `XAUTHORITY=/run/user/$(id -u)/xauth_*` (re-using our `discover_xauth` from the shim).
   - `exec /usr/bin/freerdp-shadow-cli /port:3389 /sec:tls /sam-file:/etc/consolerdp/sam`.
4. Write `config/systemd/consolerdp-rdp.service`:
   - `User=wdaugherty Group=wdaugherty`.
   - `Type=simple Restart=on-failure`.
   - `After=graphical-session.target` (only starts after a real X11 session is up).
   - `ExecStart=/usr/local/sbin/consolerdp-rdp-wrapper`.
5. Update `install.sh`:
   - Install `freerdp-shadow-x11` instead of `xrdp`.
   - Generate SAM file interactively at install time (or skip with `--sam-file=PATH`).
   - Enable `consolerdp-rdp.service`.
6. Verify: `mstsc 10.1.60.181`, type creds in Windows Credential Manager → live desktop.

### Phase 2 — orchestrator integration (1 h)

Currently `consolerdp-takeover` and `consolerdp-release` were called by `pam_exec` inside sesman. With sesman gone, we trigger them differently.

`freerdp-shadow-cli` doesn't have a "user connected" hook out of the box, but it does emit log lines like `[INFO][com.freerdp.shadow] Client … connected` and `… disconnected`. We watch its stdout from the wrapper:

```bash
exec stdbuf -oL /usr/bin/freerdp-shadow-cli ... 2>&1 | \
  /usr/local/sbin/consolerdp-rdp-eventer
```

`consolerdp-rdp-eventer`:
- Parses lines.
- On `client connected` → `consolerdp-ctl takeover wdaugherty`.
- On `client disconnected` → `consolerdp-ctl release wdaugherty`.
- Idempotent — daemon already handles double-takeover.

### Phase 3 — Wayland sessions (later, optional)

`freerdp-shadow-cli` is the X11 variant; it explicitly cannot capture Wayland.

For Wayland sessions, FreeRDP 3.x has experimental `freerdp-shadow-cli` + GNOME's RDP integration, but in 2026 the cleanest answer remains "log out of Wayland, log into Plasma X11". We surface this with a clear message in `consolerdp-doctor` and in the takeover error path.

A future phase 3 could integrate `gnome-remote-desktop` or `kdeconnect`-style PipeWire screencast into a custom shadow subsystem — that's a real engineering project (1–2 weeks). Not in scope now.

### Phase 4 — productionization (later)

- AppArmor profile for `freerdp-shadow-cli` (it has a CVE history).
- ufw rule scoped to LAN only (we already do this in `install.sh`).
- Single-session enforcement: `freerdp-shadow-cli` actually allows multiple shadow clients by default. We pass `/max-connections:1` and the daemon drops a TAKEOVER on each new connect.
- TLS cert: by default shadow-cli generates a self-signed cert per launch; we provide `/tls-cert` and `/tls-key` from `/etc/consolerdp/tls/`.
- Rotation/logging: `journalctl -u consolerdp-rdp.service`.
- Update `consolerdp-make-rdp` to set `enablecredsspsupport:i:1` (NLA) — was `0` because xrdp couldn't.

## 5. Test plan

A `tests/` directory with:

| Test | What it asserts | Tooling |
|---|---|---|
| `test_smoke.py` | Daemon imports, parses config, opens socket. | stdlib only |
| `test_sam.py` | `consolerdp-rdp-cred` produces the right NTLM hash for known input. | stdlib `hashlib.new("md4")` |
| `test_eventer.py` | Connected/disconnected line parsing → correct daemon command. | unittest with stub socket |
| `test_takeover_dryrun.py` | Daemon's `_resolve_seat_session` returns the X11 session, NOT Wayland. | mock `loginctl` |
| `manual_e2e.md` | Doc: connect from mstsc, see desktop, disconnect, see local greeter, reclaim, see cursor return. | human |

CI script `bin/run-tests`:
```bash
#!/bin/bash
set -e
python3 -m unittest discover -s tests -p 'test_*.py'
shellcheck bin/consolerdp-{takeover,release,greeter-login,reclaim-self,rdp-wrapper}
```

## 6. File-level diff

```
DELETED
  bin/consolerdp-xvnc-shim
  bin/consolerdp-startwm
  config/sesman.ini
  config/xrdp.ini
  config/pam.d/xrdp-sesman

ADDED
  bin/consolerdp-rdp-wrapper
  bin/consolerdp-rdp-cred
  bin/consolerdp-rdp-eventer
  config/systemd/consolerdp-rdp.service
  config/freerdp-shadow.cfg            (placeholders for tls cert paths)
  tests/test_sam.py
  tests/test_eventer.py

MODIFIED
  install.sh                            ← swap apt deps, drop xrdp config copies
  uninstall.sh                          ← drop xrdp restoration
  bin/consolerdp-doctor                 ← drop xrdp/sesman checks, add freerdp-shadow checks
  bin/consolerdp-make-rdp               ← enablecredsspsupport:i:1
  bin/consolerdp-daemon                 ← strip x11vnc references (it never managed x11vnc anyway)
  README.md                             ← rewrite "How it works"
  docs/ARCHITECTURE.md                  ← redraw the diagram
  config/consolerdp.conf                ← drop bridge=127.0.0.1:5900
```

## 7. Risk register

| Risk | Likelihood | Mitigation |
|---|---|---|
| `freerdp-shadow-cli` 3.24.2 has the same NLA quirks we hit before | Low — FreeRDP is the *reference* NLA implementation | We test with mstsc first thing |
| Shadow capture is slow on 4K @ 60Hz | Medium | NSCodec + GFX H.264 path is the same as xrdp; not worse |
| Multi-monitor doesn't span | Medium | `/monitors:0` requests all; verify on user's box |
| Audio doesn't pass through | High by default | Phase 4 adds `/audio-mode` with PulseAudio module |
| Wayland users see immediate failure | Certain | doctor + greeter explain how to switch to Plasma X11 |
| User's Linux password contains chars that break NTLM hashing | Low | We test the hash function with edge-case input |
| systemd-logind kills shadow-cli on session change | Medium | `Type=simple` + `Restart=on-failure` recovers; PAM session is not used |

## 8. Rollback

A single `--rollback` flag on `install.sh`:

```bash
sudo ./install.sh --rollback
```

restores xrdp from apt, reinstalls our previous shim/sesman.ini from the git tag `v1-xrdp-final`, restarts services. We tag the current state in git **before** Phase 0.

## 9. Timeline

| Phase | Effort | Cumulative |
|---|---|---|
| 0  Tag + burn | 30 min | 0:30 |
| 1  MVP RDP    | 2 h    | 2:30 |
| 2  Eventer    | 1 h    | 3:30 |
| 3  Tests      | 1 h    | 4:30 |
| 4  Docs       | 30 min | 5:00 |
| **Production-ready single-session takeover via mstsc** | | **~5 hours** |

(Compare to estimated 3–6 months for a from-scratch RDP server in .NET.)

## 10. Open questions for you

1. **NLA password source** — pull from PAM at install time (we ask once, hash it), or always prompt the user via mstsc and skip the SAM file? (PAM hash is the Windows-like UX.)
2. **Single connection enforcement** — kick the previous remote connection if a new one comes in (Windows behavior), or refuse the new one?
3. **TLS cert** — let shadow-cli auto-generate, or use Let's Encrypt / a corporate cert if you have one?

---

When you've reviewed, say "go" and I start with Phase 0 (tag the repo + remove xrdp).
