# Installing ConsoleRDP

Target platform: **Kubuntu 26.04 LTS "Resolute Raccoon", amd64, KDE Plasma 6.6 Wayland.**

Anything else (different Ubuntu version, GNOME, Plasma 5, X11, ARM) is
**not supported** by the prebuilt `.deb` bundle. See
[Compatibility](#compatibility) for details.

---

## TL;DR — two commands

On a fresh Kubuntu 26.04 box, as the user you want to RDP into:

```bash
curl -fsSL https://github.com/billsecond/consolerdp/releases/latest/download/install-remote.sh -o /tmp/install-remote.sh
sudo bash /tmp/install-remote.sh
```

That script:

1. Downloads the latest release tarball from GitHub.
2. Unpacks it into `/opt/consolerdp-<version>/`.
3. Runs `./install.sh --user $SUDO_USER`.

> **Why two commands instead of `curl ... | sudo bash`?** Piping into `sudo bash`
> attaches the script's stdin to the curl pipe, which silently breaks
> any interactive prompt (sudo password prompt, y/n confirmations).
> Downloading first, then running with `sudo bash`, leaves stdin
> attached to your terminal so every prompt behaves normally. The
> bootstrap script also tries to self-heal by reattaching `/dev/tty`,
> but the two-command form is the reliable pattern.

Once it finishes, from any Windows machine open **mstsc** and connect to
the Linux host on port **3389** using your Linux user/password.

---

## Manual install (from a git clone)

If you cloned the repo to a Linux box instead of using the release tarball:

```bash
git clone https://github.com/billsecond/consolerdp.git
cd consolerdp
sudo ./install.sh --user $(whoami)
```

### install.sh options

| Flag | Default | Meaning |
|------|---------|---------|
| `--user <name>` | `$SUDO_USER` | The single user permitted to hold the seat. Only this user can log in via RDP and only this user's local login is honored. |
| `--console-tty <N>` | `2` | TTY where your Plasma session lives. SDDM on Kubuntu 26.04 uses tty2. |
| `--greeter-tty <N>` | `8` | TTY shown on the physical display while mstsc owns the seat. Must be different from `--console-tty`. |
| `--no-firewall` | off | Skip the `ufw allow 3389/tcp` step. Use this if you manage firewall rules some other way. |
| `--no-hold` | off | Skip the `apt-mark hold` step. Not recommended — without the hold, a future `apt upgrade` will silently reinstall stock Kubuntu `kpipewire` / `krdp` and break mstsc color + NLA. |

### What gets installed

The installer drops seven custom `.deb` packages from `release/`:

| Package | Purpose |
|---------|---------|
| `libkpipewire6`, `libkpipewirerecord6`, `libkpipewire-data`, `libkpipewiredmabuf6`, `qml6-module-org-kde-pipewire` | Patched to fix the washed-out color on mstsc (BT.601 color matrix, correct H.264 VUI metadata, init-order fix for full/limited range). |
| `krdp` | KDE's RDP server, patched with 8 fixes: NLA auth, fake-input authorization, virtual-monitor stream size, pointer motion fixes, pointer-to-global coordinate translation, deferred virtual monitor, Plasma clipboard bridge, color-range forwarding. |
| `consolerdp` | Orchestrator daemon + helper scripts + systemd units + config templates. This is the glue that makes takeover / release / VT switching / session locking work. |

And adds these apt packages for runtime (only if missing):

- `plasma-workspace`, `kwin-wayland`, `sddm` (Plasma session bits)
- `python3`, `kbd`, `util-linux` (orchestrator runtime)

The System Settings RDP page (`kcm_krdpserver.so`) ships inside the
patched `krdp` .deb itself, so there is no separate Plasma-side package
to install — that was a Plasma-5-era split.

### What gets configured

- `/etc/consolerdp/consolerdp.conf` — seat user, TTYs, RDP port, policy.
- `/lib/systemd/system/consolerdp.service` — enabled and started.
- `/lib/systemd/system/consolerdp-greeter@tty<N>.service` — enabled on the greeter TTY; the stock `getty@tty<N>` is disabled there.
- `/lib/systemd/user/consolerdp-session-watcher.service` — enabled for the seat user (starts with Plasma).
- `ufw allow 3389/tcp` (if UFW is active).
- `adduser <seat-user> krdp` so the user can read `/etc/krdpserver/sam`.

---

## Verification

After install:

```bash
sudo consolerdp-doctor
```

Expected green checks:

```
[ok] OS: Ubuntu 26.04 amd64
[ok] krdp >= 6.6.4-0ubuntu1+consolerdp5 installed
[ok] libkpipewirerecord6 contains BT.601 VUI patch marker
[ok] consolerdp.service is active
[ok] tcp/3389 listening (krdpserver)
[ok] consolerdp-greeter@tty8.service is active
[ok] seat user wdaugherty is in 'krdp' group
```

Then from Windows:

1. Open **mstsc** (Remote Desktop Connection).
2. Computer: the Linux host's IP or hostname.
3. User: your Linux username (same as the `--user` you passed).
4. Password: your Linux password (mstsc sends it over NLA).
5. Connect. You should see your Plasma desktop.

The physical Linux display will now show the ConsoleRDP greeter
("this seat is in use remotely"). When you close mstsc, the greeter
still shows and the Plasma session is locked. Re-connecting via mstsc
auto-unlocks and reclaims the seat — no password re-prompt.

---

## Compatibility

| Target | Supported? | Notes |
|--------|:----------:|-------|
| Kubuntu 26.04 LTS amd64 | ✅ **Yes** | Exact match — use the prebuilt `.deb`s. |
| Ubuntu 26.04 (GNOME) amd64 | ⚠️ Partial | Needs `apt install kubuntu-desktop` first. The installer will offer to do this. |
| Ubuntu 26.04 Server + self-installed KDE | ⚠️ Maybe | As above but untested. |
| Kubuntu 24.04 LTS | ❌ No | Plasma version mismatch — rebuild required. |
| Kubuntu 26.10+ (future) | ❓ | When Ubuntu 26.10 ships, rebuild the patched .debs against the new Plasma version. See `docs/BUILD.md`. |
| Debian 13 Trixie | ❓ | Plasma 6.x is there but ABI may differ. Untested. |
| Non-KDE Linux (Fedora KDE, Arch, ...) | ❌ No | The orchestrator scripts are portable; the patched `.deb`s are Debian-only. You'd need to port the patches to your distro's packaging. |
| ARM64 / any non-amd64 | ❌ No | The `.deb`s are amd64-only. Rebuild on target arch if needed. |
| Plasma 5 | ❌ No | `krdpserver` is Plasma-6-only. |
| X11 session | ❌ No | Screencast path requires Wayland. |

---

## Rebuilding for a different Ubuntu version

If you need to run this on, say, Kubuntu 26.10 or 27.04, you have to
rebuild the patched `kpipewire` and `krdp` `.deb`s against the new
Plasma version:

```bash
# 1. Grab the upstream source for YOUR Kubuntu version:
apt source kpipewire krdp

# 2. Apply our patches:
cd kpipewire-*
cp ../../patches/kpipewire/*.patch debian/patches/
echo 'libx264-bt601-color-init-order.patch' >> debian/patches/series
quilt push -a
dch -v "<new-version>+consolerdp1" "ConsoleRDP color patches"
dpkg-buildpackage -us -uc -b
cd ../krdp-*
# ...same pattern, 8 patches from patches/krdp/

# 3. Drop the rebuilt .debs into release/ and re-run install.sh
```

See `docs/BUILD.md` (TODO) for the full rebuild recipe.

---

## Uninstall

```bash
sudo ./uninstall.sh          # keeps /etc/consolerdp and config
sudo ./uninstall.sh --purge  # removes /etc/consolerdp too
```

The uninstaller does NOT reinstall the stock Kubuntu `kpipewire` /
`krdp` libraries. To get those back, run:

```bash
sudo apt install --reinstall libkpipewire6 libkpipewirerecord6 \
                              libkpipewire-data libkpipewiredmabuf6 \
                              qml6-module-org-kde-pipewire krdp
```

---

## Troubleshooting

**mstsc fails with "internal error" after my network dropped:**
Wait a few seconds for the ConsoleRDP daemon to clean up, then retry.
The `RdpWatcher` debounces disconnect detection over 1.5s.

**Physical display shows the Plasma lockscreen after I disconnect mstsc:**
That's intentional. With `lock_on_release = true`, whoever walks up to
the host sees a lockscreen (not your desktop). You can change the
policy in `/etc/consolerdp/consolerdp.conf`.

**After reconnect, mstsc asks me for my Plasma password:**
The auto-unlock requires `loginctl unlock-session` to reach Plasma's
KScreenLocker. If it's not working, check
`journalctl -u consolerdp.service` for `unlock-session failed`.

**Color is still washed out in mstsc:**
The kpipewire patch marker should appear in the shared library. Verify:

```bash
strings /usr/lib/x86_64-linux-gnu/libKPipeWireRecord.so.6 | grep CONSOLERDP
```

Expected output:
```
CONSOLERDP-LIBX264-FILTER-GRAPH
CONSOLERDP-BT601-VUI-PATCH-ACTIVE
```

If those strings are missing, stock Kubuntu kpipewire is installed. Re-run:
```bash
sudo dpkg -i release/libkpipewire*.deb
sudo apt-mark hold libkpipewire6 libkpipewirerecord6
```
