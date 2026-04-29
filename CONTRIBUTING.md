# Contributing to ConsoleRDP

Thanks for your interest!

## Dev setup

```bash
python3 -m venv .venv && . .venv/bin/activate
pip install ruff pytest
make check
```

## Running the daemon outside systemd

```bash
sudo ./bin/consolerdp-daemon \
    --config ./config/consolerdp.conf \
    --socket /tmp/consolerdp.sock \
    --log-level DEBUG
```

(Edit the config file to point at a test seat user first.)

## Commit style

Conventional Commits:

- `feat:` user-visible feature
- `fix:` bug fix
- `docs:` README / ARCHITECTURE
- `test:` tests only
- `refactor:` no behavior change
- `chore:` tooling, CI

## Things we'd love help with

- Wayland support (gnome-remote-desktop / wayvnc bridge)
- A GUI control-panel applet for KDE
- Distro packages (`.deb`, AUR)
- Hardening — seccomp profile for the daemon
