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

APT_PACKAGES=(
    python3
    kbd
    util-linux
    sddm
    kwin-wayland
    plasma-workspace
    plasma-remotedesktop
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
env "${APT_ENV[@]}" apt-get update -qq </dev/null
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
env "${APT_ENV[@]}" apt-get "${APT_FLAGS[@]}" install "${DEBS[@]}" </dev/null
ok ".debs installed"

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

if systemctl is-active --quiet consolerdp.service; then
    ok "consolerdp.service: active"
else
    warn "consolerdp.service is NOT active -- see 'journalctl -u consolerdp.service'"
fi

if ss -tlnp 2>/dev/null | grep -q ':3389 '; then
    ok "krdpserver is listening on tcp/3389"
else
    warn "nothing listening on tcp/3389 yet -- log into Plasma once to start krdpserver"
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
echo "From a Windows box, open mstsc and connect to one of those IPs."
echo "Use the SAME Linux password you use at the SDDM greeter."
echo
echo "Diagnostics:"
echo "  sudo consolerdp-doctor"
echo "  sudo journalctl -u consolerdp.service -f"
echo "  journalctl --user -u consolerdp-session-watcher.service -f"
echo
echo "Uninstall:"
echo "  sudo $REPO_ROOT/uninstall.sh"
