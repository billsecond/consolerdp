#!/usr/bin/env bash
# uninstall.sh -- remove ConsoleRDP from a Kubuntu 26.04 host.
#
# What it does:
#   1. Stops consolerdp.service + consolerdp-greeter@tty*.service.
#   2. Disables the per-user consolerdp-session-watcher.service.
#   3. apt-mark unhold + apt-get remove the 7 ConsoleRDP .debs.
#   4. Reverts /etc/default/getty so getty@tty8 can return to default.
#   5. Leaves /etc/consolerdp/consolerdp.conf in place so reinstall
#      can preserve config; use --purge to wipe it too.
#
# Does NOT:
#   - Touch SDDM / Plasma / KDE packages.
#   - Reinstall stock kpipewire / krdp -- you must do that manually:
#         sudo apt install --reinstall libkpipewire6 libkpipewirerecord6 krdp
#     otherwise stock Ubuntu builds won't come back automatically.

set -euo pipefail

PURGE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --purge) PURGE=1; shift ;;
        -h|--help)
            sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

[[ $EUID -eq 0 ]] || { echo "must run as root (use sudo)" >&2; exit 1; }

step()  { printf '\n\033[1;36m[%s] %s\033[0m\n' "$1" "$2"; }
ok()    { printf '       \033[1;32m✓ %s\033[0m\n' "$1"; }
warn()  { printf '       \033[1;33m! %s\033[0m\n' "$1"; }

# --------------------------------------------------------------------------- #
step "1/4" "Stopping services"

systemctl stop consolerdp.service 2>/dev/null || true
for unit in $(systemctl list-units --no-legend 'consolerdp-greeter@*' \
              2>/dev/null | awk '{print $1}'); do
    systemctl stop "$unit"    2>/dev/null || true
    systemctl disable "$unit" 2>/dev/null || true
done
# Re-enable stock getty on whatever tty the greeter was using.
for tty in tty7 tty8 tty9; do
    if systemctl list-unit-files "getty@${tty}.service" \
       2>/dev/null | grep -q "$tty"; then
        systemctl enable "getty@${tty}.service" 2>/dev/null || true
    fi
done
ok "services stopped"

# --------------------------------------------------------------------------- #
step "2/4" "Disabling per-user session-watcher (best-effort)"

# Walk /run/user/*/bus and try to disable the user unit in each live session.
for busdir in /run/user/*/bus; do
    [[ -S "$busdir" ]] || continue
    uid="$(basename "$(dirname "$busdir")")"
    user="$(getent passwd "$uid" | cut -d: -f1)" || continue
    [[ -n "$user" ]] || continue
    sudo -u "$user" \
        XDG_RUNTIME_DIR="/run/user/$uid" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$busdir" \
        systemctl --user disable --now consolerdp-session-watcher.service \
        2>/dev/null || true
done
ok "user-level watchers disabled"

# --------------------------------------------------------------------------- #
step "3/4" "Removing ConsoleRDP .debs + unholding"

PKGS=(
    consolerdp
    krdp
    libkpipewirerecord6
    libkpipewire6
    libkpipewiredmabuf6
    libkpipewire-data
    qml6-module-org-kde-pipewire
)
# Unhold first or apt-mark will refuse.
for pkg in "${PKGS[@]}"; do
    apt-mark unhold "$pkg" >/dev/null 2>&1 || true
done

APT_FLAGS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
if [[ "$PURGE" -eq 1 ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get "${APT_FLAGS[@]}" \
        purge "${PKGS[@]}" </dev/null || true
    rm -rf /etc/consolerdp 2>/dev/null || true
    ok "purged .debs + /etc/consolerdp"
else
    DEBIAN_FRONTEND=noninteractive apt-get "${APT_FLAGS[@]}" \
        remove "${PKGS[@]}" </dev/null || true
    ok "removed .debs (config kept in /etc/consolerdp)"
fi

# --------------------------------------------------------------------------- #
step "4/4" "Restoring stock kpipewire / krdp (optional)"

echo "To re-install stock Ubuntu builds of the libraries we replaced, run:"
echo
echo "    sudo apt install --reinstall libkpipewire6 libkpipewirerecord6 \\"
echo "                                 libkpipewire-data libkpipewiredmabuf6 \\"
echo "                                 qml6-module-org-kde-pipewire krdp"
echo
echo "Otherwise mstsc color will be stock-Limited again and krdp NLA may"
echo "not work. This step is left manual so you can choose the timing."
