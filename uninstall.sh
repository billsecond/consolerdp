#!/usr/bin/env bash
# uninstall.sh — remove ConsoleRDP, restore stock xrdp config (best effort).
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }

GREETER_TTY="${GREETER_TTY:-8}"

echo "[1/6] Stopping services…"
systemctl disable --now consolerdp.service 2>/dev/null || true
systemctl disable --now "consolerdp-greeter@tty${GREETER_TTY}.service" 2>/dev/null || true
systemctl enable  --now "getty@tty${GREETER_TTY}.service" 2>/dev/null || true

echo "[2/6] Removing executables…"
rm -f /usr/local/sbin/consolerdp-daemon \
      /usr/local/sbin/consolerdp-takeover \
      /usr/local/sbin/consolerdp-release \
      /usr/local/sbin/consolerdp-ctl \
      /usr/local/sbin/consolerdp-doctor \
      /usr/local/sbin/consolerdp-reclaim-self \
      /usr/local/sbin/consolerdp-greeter-login \
      /usr/local/sbin/consolerdp-xvnc-shim \
      /usr/local/sbin/Xvnc

echo "[3/6] Removing systemd units + sockets…"
rm -f /etc/systemd/system/consolerdp.service \
      /etc/systemd/system/consolerdp-greeter@.service \
      /run/consolerdp.sock
systemctl daemon-reload

echo "[4/6] Removing user autostart entries…"
for HOME_DIR in /home/*; do
    [[ -d "$HOME_DIR" ]] || continue
    rm -f "$HOME_DIR/.config/autostart/consolerdp-reclaim.desktop"
done

echo "[5/6] Restoring stock xrdp PAM (apt --reinstall)…"
if dpkg -V xrdp 2>/dev/null | grep -q '/etc/pam.d/xrdp-sesman'; then
    apt-get install --reinstall -y xrdp >/dev/null
fi

echo "[6/6] Done."
echo "  /etc/consolerdp left in place (contains your bridge password)."
echo "  Remove with:  rm -rf /etc/consolerdp"
echo "  ufw rule for 3389/tcp left in place; remove with:  ufw delete allow 3389/tcp"
