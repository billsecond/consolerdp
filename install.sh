#!/usr/bin/env bash
# install.sh -- ConsoleRDP installer for Kubuntu 26.04 LTS amd64.
#
# What it does (in order):
#   1. Verifies the OS is Ubuntu 26.04 LTS amd64 and that KDE Plasma 6
#      is present. Refuses to run on anything else.
#   2. Installs runtime apt dependencies (kbd, util-linux, python3, ufw...).
#   3. Installs 7 custom .debs from ./release/ :
#        - libkpipewire6                (patched: BT.601 color)
#        - libkpipewirerecord6          (patched: BT.601 color)
#        - libkpipewire-data            (runtime data files)
#        - libkpipewiredmabuf6          (pipewire dmabuf support)
#        - qml6-module-org-kde-pipewire (QML bindings)
#        - krdp                         (patched: NLA, full color, clipboard)
#        - consolerdp                   (the orchestrator + helper scripts)
#   4. Holds those packages so a future `apt upgrade` will not silently
#      replace them with stock Kubuntu versions.
#   5. Runs `consolerdp-configure --user <SEAT_USER>` which wires up
#      /etc/consolerdp/consolerdp.conf, groups, greeter tty, UFW, and
#      enables consolerdp.service + the per-user session watcher.
#   6. Prints consolerdp-doctor output.
#
# Usage:
#   sudo ./install.sh --user <seat-user> \
#        [--console-tty N] [--greeter-tty M] [--no-firewall] [--no-hold]
#
# Re-runnable: safe to invoke multiple times (idempotent).

set -euo pipefail

# --------------------------------------------------------------------------- #
# stdin self-heal: when invoked via `curl ... | sudo bash` the script's
# stdin is the curl pipe, not the user's terminal.  Reattach stdin to
# /dev/tty so prompts work correctly.
# --------------------------------------------------------------------------- #
if [[ ! -t 0 ]] && [[ -r /dev/tty ]]; then
    exec </dev/tty
fi

# --------------------------------------------------------------------------- #
# arg parsing
# --------------------------------------------------------------------------- #
SEAT_USER=""
CONSOLE_TTY="2"
GREETER_TTY="8"
DO_FIREWALL=1
DO_HOLD=1

usage() {
    sed -n '2,30p' "$0"
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)         SEAT_USER="$2"; shift 2 ;;
        --console-tty)  CONSOLE_TTY="$2"; shift 2 ;;
        --greeter-tty)  GREETER_TTY="$2"; shift 2 ;;
        --no-firewall)  DO_FIREWALL=0; shift ;;
        --no-hold)      DO_HOLD=0; shift ;;
        -h|--help)      usage 0 ;;
        *)              echo "unknown arg: $1" >&2; usage 1 ;;
    esac
done

# If --user wasn't passed, default to SUDO_USER (who ran `sudo ./install.sh`).
if [[ -z "$SEAT_USER" && -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
    SEAT_USER="$SUDO_USER"
fi

[[ $EUID -eq 0 ]] || { echo "must run as root (use sudo)" >&2; exit 1; }
[[ -n "$SEAT_USER" ]] || { echo "--user is required (no SUDO_USER detected)" >&2; exit 1; }
id -u "$SEAT_USER" >/dev/null 2>&1 || \
    { echo "user '$SEAT_USER' does not exist" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
RELEASE_DIR="$REPO_ROOT/release"

step()  { printf '\n\033[1;36m[%s] %s\033[0m\n' "$1" "$2"; }
ok()    { printf '       \033[1;32m✓ %s\033[0m\n' "$1"; }
warn()  { printf '       \033[1;33m! %s\033[0m\n' "$1"; }
fail()  { printf '       \033[1;31m✗ %s\033[0m\n' "$1"; exit 1; }

# --------------------------------------------------------------------------- #
step "1/6" "Verifying host OS compatibility"

OS_ID="$(. /etc/os-release && echo "${ID:-}")"
OS_VER="$(. /etc/os-release && echo "${VERSION_ID:-}")"
ARCH="$(dpkg --print-architecture)"

if [[ "$OS_ID" != "ubuntu" ]]; then
    fail "OS is '$OS_ID', not 'ubuntu'. ConsoleRDP supports only Ubuntu/Kubuntu."
fi
if [[ "$OS_VER" != "26.04" ]]; then
    warn "OS is Ubuntu $OS_VER; this release was built against 26.04."
    warn "The patched libraries may be ABI-incompatible. Proceeding anyway."
fi
if [[ "$ARCH" != "amd64" ]]; then
    fail "Architecture is '$ARCH'. The .debs are amd64-only."
fi
ok "Ubuntu $OS_VER $ARCH (compatible)"

# Require KDE Plasma. If absent, offer to install kubuntu-desktop.
if ! dpkg -s plasma-desktop >/dev/null 2>&1; then
    warn "KDE Plasma is not installed."
    if [[ -t 0 ]]; then
        read -r -p "Install kubuntu-desktop now? [y/N] " ans
        if [[ "$ans" =~ ^[Yy] ]]; then
            DEBIAN_FRONTEND=noninteractive apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y \
                kubuntu-desktop plasma-desktop kwin-wayland sddm \
                </dev/null
            ok "Plasma + SDDM installed (reboot before continuing)"
        else
            fail "KDE Plasma is required. Install 'kubuntu-desktop' and re-run."
        fi
    else
        fail "KDE Plasma is required. Install 'kubuntu-desktop' and re-run."
    fi
fi
ok "KDE Plasma is installed"

# --------------------------------------------------------------------------- #
step "2/6" "Installing runtime apt dependencies"

# Note: there is no separate `plasma-remotedesktop` package on Plasma 6 /
# Kubuntu 26.04. The System Settings RDP KCM (kcm_krdpserver.so) ships
# inside the krdp .deb itself, which we install in step 4/6.
APT_PACKAGES=(
    python3
    kbd
    util-linux
    sddm
    kwin-wayland
    plasma-workspace
    openssl   # consolerdp-configure uses it to generate the krdpserver TLS cert
)
APT_ENV=(
    DEBIAN_FRONTEND=noninteractive
    NEEDRESTART_MODE=a
    NEEDRESTART_SUSPEND=1
    DEBCONF_NONINTERACTIVE_SEEN=true
)
APT_FLAGS=(
    -y
    -o Dpkg::Options::=--force-confdef
    -o Dpkg::Options::=--force-confold
)
# Extra flags ONLY for the local-.deb install step (3/6). We use
# --allow-downgrades so apt will replace a stock Kubuntu krdp /
# kpipewire that happens to have a higher version number than our
# patched ones (e.g. if stock 26.04 ships 6.6.5 and our .debs are
# 6.6.4-0ubuntu1+consolerdpN, apt would otherwise skip the install
# silently and leave the system unpatched). force-overwrite handles
# the case where another package owns one of the same files.
DEB_INSTALL_FLAGS=(
    "${APT_FLAGS[@]}"
    --allow-downgrades
    --reinstall
    -o Dpkg::Options::=--force-overwrite
)
# apt-get update can return non-zero on transient mirror issues (broken
# IPv6 routing, mirror syncing, stale InRelease).  We don't want that
# to torpedo the install when the actual package archives are still
# reachable, so we warn rather than fail.  The subsequent `apt-get
# install` will hard-fail if anything is genuinely unreachable.
env "${APT_ENV[@]}" apt-get update -qq </dev/null \
    || warn "apt-get update had warnings (likely transient mirror issues) -- continuing"
env "${APT_ENV[@]}" apt-get "${APT_FLAGS[@]}" install "${APT_PACKAGES[@]}" </dev/null
ok "apt dependencies present"

# --------------------------------------------------------------------------- #
step "3/6" "Installing ConsoleRDP .deb bundle (from $RELEASE_DIR)"

# Order matters: libkpipewire* must precede krdp (krdp depends on them).
# apt-get install treats arguments starting with '.' or '/' as local
# .deb paths; anything else is a package name to pull from archives.
# Our absolute "$RELEASE_DIR" path starts with '/' so apt recognises
# each item as a local .deb.
DEBS=(
    "$RELEASE_DIR"/libkpipewire-data_*.deb
    "$RELEASE_DIR"/libkpipewire6_*.deb
    "$RELEASE_DIR"/libkpipewirerecord6_*.deb
    "$RELEASE_DIR"/libkpipewiredmabuf6_*.deb
    "$RELEASE_DIR"/qml6-module-org-kde-pipewire_*.deb
    "$RELEASE_DIR"/krdp_*.deb
    "$RELEASE_DIR"/consolerdp_*.deb
)
for d in "${DEBS[@]}"; do
    [[ -f "$d" ]] || fail "missing bundled .deb: $d  (is release/ populated?)"
done

# Install via apt-get to let it resolve and pull any missing dependencies.
# Use DEB_INSTALL_FLAGS (with --allow-downgrades --reinstall --force-overwrite)
# so apt is guaranteed to replace whatever stock packages are present,
# even if their version number happens to be higher than ours.
env "${APT_ENV[@]}" apt-get "${DEB_INSTALL_FLAGS[@]}" install "${DEBS[@]}" </dev/null
ok ".debs installed"

# Immediately verify each one actually landed at the expected patched
# version.  Without this check, a silent skip would mean the user goes
# all the way to the end of the install thinking it worked.
for pkg in libkpipewire-data libkpipewire6 libkpipewirerecord6 \
           libkpipewiredmabuf6 qml6-module-org-kde-pipewire krdp \
           consolerdp; do
    status=$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || echo "missing")
    ver=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || echo "?")
    if [[ "$status" != "install ok installed" ]]; then
        fail "$pkg is not installed (status='$status'); see 'apt-get install' output above"
    fi
    # All ConsoleRDP-patched packages have a "+consolerdpN" version
    # suffix (or are the consolerdp package itself, which is just 1.x).
    if [[ "$pkg" != "consolerdp" && "$ver" != *consolerdp* ]]; then
        fail "$pkg installed at $ver but expected a +consolerdp suffix.  Stock Kubuntu version is in place; the patched version was not applied."
    fi
    ok "$pkg $ver"
done

# --------------------------------------------------------------------------- #
step "4/6" "Pinning ConsoleRDP packages against apt upgrades"

if [[ "$DO_HOLD" -eq 1 ]]; then
    for pkg in libkpipewire-data libkpipewire6 libkpipewirerecord6 \
               libkpipewiredmabuf6 qml6-module-org-kde-pipewire krdp \
               consolerdp; do
        apt-mark hold "$pkg" >/dev/null 2>&1 || true
    done
    ok "apt-mark hold set on 7 packages (prevents silent overwrite)"
else
    warn "apt-mark hold skipped (--no-hold); future upgrades MAY overwrite patches"
fi

# --------------------------------------------------------------------------- #
step "5/6" "Configuring ConsoleRDP for user '$SEAT_USER'"

CONFIGURE_ARGS=(
    --user "$SEAT_USER"
    --console-tty "$CONSOLE_TTY"
    --greeter-tty "$GREETER_TTY"
)
[[ "$DO_FIREWALL" -eq 0 ]] && CONFIGURE_ARGS+=(--no-firewall)

if ! command -v consolerdp-configure >/dev/null 2>&1; then
    fail "consolerdp-configure missing from PATH -- did the .deb install correctly?"
fi
/usr/sbin/consolerdp-configure "${CONFIGURE_ARGS[@]}"

# --------------------------------------------------------------------------- #
step "6/6" "Final sanity check"

# Each of these is fail-loud: if the install hadn't really worked, we
# want the user to see exactly what's broken on the last screenful of
# install output rather than discover it later from mstsc errors.

# 1. KCM .so file -- this is the System Settings "Remote Desktop" page.
#    If it's missing, kcm_krdpserver wasn't shipped by the krdp .deb.
KCM_SO=/usr/lib/x86_64-linux-gnu/qt6/plugins/plasma/kcms/systemsettings/kcm_krdpserver.so
if [[ -f "$KCM_SO" ]]; then
    ok "Remote Desktop KCM in place ($KCM_SO)"
else
    warn "KCM file MISSING at $KCM_SO -- System Settings will not show Remote Desktop"
fi

# 2. Patched krdp binary marker.  Our build embeds a build-info JSON
#    string containing "consolerdp"; if the binary on disk has it,
#    the patched build is what's executing.  If it doesn't, apt has
#    silently kept a stock krdp in place and mstsc will fail at NLA.
if strings /usr/bin/krdpserver 2>/dev/null | grep -q '"consolerdp'; then
    ok "/usr/bin/krdpserver is the consolerdp-patched build"
else
    warn "/usr/bin/krdpserver is NOT the patched build -- mstsc will fail at NLA"
fi

# 3. consolerdp.service running.
if systemctl is-active --quiet consolerdp.service; then
    ok "consolerdp.service: active"
else
    warn "consolerdp.service is NOT active -- see 'journalctl -u consolerdp.service'"
fi

# 4. krdpserverrc + cert in place for the seat user.
SEAT_HOME=$(getent passwd "$SEAT_USER" | cut -d: -f6)
if [[ -s "$SEAT_HOME/.local/share/krdpserver/krdp.crt" \
   && -s "$SEAT_HOME/.local/share/krdpserver/krdp.key" \
   && -s "$SEAT_HOME/.config/krdpserverrc" ]] && \
   grep -q SystemUserEnabled=true "$SEAT_HOME/.config/krdpserverrc" 2>/dev/null; then
    ok "krdpserverrc + TLS cert provisioned for $SEAT_USER"
else
    warn "krdpserver config for $SEAT_USER incomplete -- consolerdp-configure step 7 may have skipped"
fi

# 5. Listening on 3389?
if ss -tlnp 2>/dev/null | grep -q ':3389 '; then
    ok "krdpserver is listening on tcp/3389"
else
    warn "nothing listening on tcp/3389 yet -- log into Plasma once and re-check (Autostart=true will handle it)"
fi

# 6. UFW rule (if active).
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -qi 'Status: active'; then
    if ufw status 2>/dev/null | grep -qE '^3389/tcp\s+ALLOW'; then
        ok "ufw allows 3389/tcp"
    else
        warn "ufw is active but 3389/tcp is NOT allowed -- run 'sudo ufw allow 3389/tcp'"
    fi
fi

echo
echo "================================================================"
echo " ConsoleRDP installed and configured."
echo "================================================================"
echo "  Seat user     : $SEAT_USER"
echo "  Console TTY   : tty${CONSOLE_TTY}"
echo "  Greeter TTY   : tty${GREETER_TTY}"
echo "  RDP listener  : tcp/3389"
echo "  Host IPs      : $(hostname -I 2>/dev/null | tr -s ' ' || echo '?')"
echo
echo "================================================================"
echo " Connect from Windows mstsc:"
echo "   host     : <one of the IPs above>:3389"
echo "   username : $SEAT_USER"
echo "   password : $SEAT_USER's Linux password (same as SDDM/sudo)"
echo
echo " mstsc will warn about the self-signed cert on first connect."
echo " Tick 'Don't ask again for this computer' and you're done."
echo "================================================================"
echo
echo "Diagnostics:"
echo "  sudo consolerdp-doctor"
echo "  sudo journalctl -u consolerdp.service -f"
echo "  journalctl --user -u consolerdp-session-watcher.service -f"
echo
echo "Uninstall:"
echo "  sudo $REPO_ROOT/uninstall.sh"
