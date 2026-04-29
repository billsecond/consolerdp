#!/usr/bin/env bash
# install.sh — set up ConsoleRDP on a Kubuntu / Ubuntu 24.04+ host.
#
# Usage:
#   sudo ./install.sh --user <seat-user> [--console-tty N] [--greeter-tty M]
#                     [--no-firewall] [--no-greeter-tty] [--no-x11-default]
#
# Re-running this script is safe (idempotent).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
SEAT_USER=""
CONSOLE_TTY="1"
GREETER_TTY="8"
DO_FIREWALL=1
DO_GREETER=1
DO_X11_DEFAULT=1
DO_X11_INSTALL=1
APT_PACKAGES=(xrdp x11vnc xinput kbd python3 socat util-linux xvfb net-tools x11-xserver-utils)
# Plasma 6 on Kubuntu 26.04 is Wayland-only by default. ConsoleRDP needs an
# Xorg session, so we pull in the X11 backend packages unless --no-x11-install.
APT_X11_PACKAGES=(plasma-session-x11 kwin-x11)

usage() {
    sed -n '2,12p' "$0"
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user) SEAT_USER="$2"; shift 2 ;;
        --console-tty) CONSOLE_TTY="$2"; shift 2 ;;
        --greeter-tty) GREETER_TTY="$2"; shift 2 ;;
        --no-firewall) DO_FIREWALL=0; shift ;;
        --no-greeter-tty) DO_GREETER=0; shift ;;
        --no-x11-default) DO_X11_DEFAULT=0; shift ;;
        --no-x11-install) DO_X11_INSTALL=0; shift ;;
        -h|--help) usage 0 ;;
        *) echo "unknown arg: $1" >&2; usage 1 ;;
    esac
done

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
[[ -n "$SEAT_USER" ]] || { echo "--user is required" >&2; exit 1; }
id -u "$SEAT_USER" >/dev/null 2>&1 || \
    { echo "user '$SEAT_USER' does not exist" >&2; exit 1; }

step()  { printf '\n\033[1;36m[%s] %s\033[0m\n' "$1" "$2"; }
note()  { printf '       \033[1;33m! %s\033[0m\n' "$1"; }
ok()    { printf '       \033[1;32m✓ %s\033[0m\n' "$1"; }

# All apt invocations are wrapped to suppress every interactive prompt
# Ubuntu can throw at us: debconf, needrestart service-restart picker,
# and dpkg's "modified config file?" dialog.
APT_NONINTERACTIVE_ENV=(
    DEBIAN_FRONTEND=noninteractive
    NEEDRESTART_MODE=a
    NEEDRESTART_SUSPEND=1
    DEBCONF_NONINTERACTIVE_SEEN=true
)
APT_FLAGS=(
    -y
    --no-install-recommends
    -o Dpkg::Options::=--force-confdef
    -o Dpkg::Options::=--force-confold
)
apt_run() {
    env "${APT_NONINTERACTIVE_ENV[@]}" apt-get "${APT_FLAGS[@]}" "$@" </dev/null
}

# --------------------------------------------------------------------------- #
step "1/10" "Installing distro packages…"
env "${APT_NONINTERACTIVE_ENV[@]}" apt-get update -qq </dev/null
apt_run install "${APT_PACKAGES[@]}"
ok "apt packages present"

if [[ "$DO_X11_INSTALL" -eq 1 && ! -d /usr/share/xsessions ]]; then
    note "no /usr/share/xsessions — installing X11 desktop packages"
    apt_run install "${APT_X11_PACKAGES[@]}" || \
        note "X11 packages failed; install manually: ${APT_X11_PACKAGES[*]}"
fi

# --------------------------------------------------------------------------- #
step "2/10" "Installing executables → /usr/local/sbin/"
install -d -m 0755 /usr/local/sbin
install -m 0755 "$REPO_ROOT/bin/consolerdp-daemon"        /usr/local/sbin/
install -m 0755 "$REPO_ROOT/bin/consolerdp-takeover"      /usr/local/sbin/
install -m 0755 "$REPO_ROOT/bin/consolerdp-release"       /usr/local/sbin/
install -m 0755 "$REPO_ROOT/bin/consolerdp-ctl"           /usr/local/sbin/
install -m 0755 "$REPO_ROOT/bin/consolerdp-doctor"        /usr/local/sbin/
install -m 0755 "$REPO_ROOT/bin/consolerdp-reclaim-self"  /usr/local/sbin/
install -m 0755 "$REPO_ROOT/bin/consolerdp-greeter-login" /usr/local/sbin/
install -m 0755 "$REPO_ROOT/bin/consolerdp-xvnc-shim"     /usr/local/sbin/
install -m 0755 "$REPO_ROOT/bin/consolerdp-make-rdp"      /usr/local/sbin/
install -m 0755 "$REPO_ROOT/bin/consolerdp-startwm"       /usr/local/sbin/
# Override the system Xvnc with our shim by placing a symlink earlier
# in the systemd-default PATH (/usr/local/sbin precedes /usr/bin).
ln -sf consolerdp-xvnc-shim /usr/local/sbin/Xvnc
ok "binaries installed (Xvnc → consolerdp-xvnc-shim)"

# --------------------------------------------------------------------------- #
step "3/10" "Installing config → /etc/consolerdp/"
install -d -m 0755 /etc/consolerdp
if [[ ! -e /etc/consolerdp/consolerdp.conf ]]; then
    install -m 0644 "$REPO_ROOT/config/consolerdp.conf" \
        /etc/consolerdp/consolerdp.conf
fi
sed -i \
    -e "s|^user = .*|user = $SEAT_USER|" \
    -e "s|^console_tty = .*|console_tty = $CONSOLE_TTY|" \
    -e "s|^greeter_tty = .*|greeter_tty = $GREETER_TTY|" \
    /etc/consolerdp/consolerdp.conf
ok "/etc/consolerdp/consolerdp.conf written"

# --------------------------------------------------------------------------- #
step "4/10" "Generating loopback VNC bridge password (one-time)…"
if [[ ! -s /etc/consolerdp/vnc.passwd ]]; then
    PW="$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 32)"
    echo -n "$PW" | x11vnc -storepasswd - /etc/consolerdp/vnc.passwd >/dev/null
    chgrp xrdp /etc/consolerdp/vnc.passwd 2>/dev/null || true
    chmod 0640 /etc/consolerdp/vnc.passwd
    ok "/etc/consolerdp/vnc.passwd generated (root:xrdp 0640)"
else
    ok "/etc/consolerdp/vnc.passwd already present (kept)"
fi

# --------------------------------------------------------------------------- #
step "5/10" "Installing xrdp + sesman + PAM config…"
install -m 0644 "$REPO_ROOT/config/xrdp.ini"   /etc/xrdp/xrdp.ini
install -m 0644 "$REPO_ROOT/config/sesman.ini" /etc/xrdp/sesman.ini
install -m 0755 "$REPO_ROOT/config/startwm.sh" /etc/xrdp/startwm.sh
sed "s|SEAT_USER|$SEAT_USER|g" \
    "$REPO_ROOT/config/pam.d/xrdp-sesman" \
    > /etc/pam.d/xrdp-sesman
chmod 0644 /etc/pam.d/xrdp-sesman
ok "xrdp.ini, sesman.ini, pam.d/xrdp-sesman in place"

# --------------------------------------------------------------------------- #
step "6/10" "Installing systemd units…"
install -m 0644 "$REPO_ROOT/systemd/consolerdp.service" \
    /etc/systemd/system/consolerdp.service
install -m 0644 "$REPO_ROOT/systemd/consolerdp-greeter@.service" \
    /etc/systemd/system/consolerdp-greeter@.service
systemctl daemon-reload
ok "consolerdp.service + consolerdp-greeter@.service installed"

# --------------------------------------------------------------------------- #
step "7/10" "Adding $SEAT_USER to ssl-cert + xrdp groups…"
adduser "$SEAT_USER" ssl-cert >/dev/null 2>&1 || true
adduser "$SEAT_USER" xrdp     >/dev/null 2>&1 || true
ok "groups: $(id -nG "$SEAT_USER" | tr ' ' ',')"

# --------------------------------------------------------------------------- #
step "8/10" "Installing KDE/GNOME autostart for local reclaim…"
SEAT_HOME="$(getent passwd "$SEAT_USER" | cut -d: -f6)"
if [[ -d "$SEAT_HOME" ]]; then
    install -d -m 0755 -o "$SEAT_USER" -g "$SEAT_USER" \
        "$SEAT_HOME/.config/autostart"
    install -m 0644 -o "$SEAT_USER" -g "$SEAT_USER" \
        "$REPO_ROOT/config/autostart/consolerdp-reclaim.desktop" \
        "$SEAT_HOME/.config/autostart/consolerdp-reclaim.desktop"
    ok "$SEAT_HOME/.config/autostart/consolerdp-reclaim.desktop"
else
    note "could not locate home for $SEAT_USER, skipping autostart"
fi

# --------------------------------------------------------------------------- #
step "9/10" "Configuring runtime: firewall, X11 default, greeter TTY…"

if [[ "$DO_GREETER" -eq 1 ]]; then
    systemctl disable --now "getty@tty${GREETER_TTY}.service" 2>/dev/null || true
    systemctl enable --now "consolerdp-greeter@tty${GREETER_TTY}.service"
    ok "greeter on tty${GREETER_TTY} enabled"
else
    note "skipped greeter-tty configuration (--no-greeter-tty)"
fi

if [[ "$DO_FIREWALL" -eq 1 ]] && command -v ufw >/dev/null; then
    if ufw status 2>/dev/null | grep -qi 'Status: active'; then
        ufw allow 3389/tcp >/dev/null
        ok "ufw: allow 3389/tcp"
    else
        ok "ufw inactive — no rule needed"
    fi
else
    note "skipped firewall (--no-firewall or ufw absent)"
fi

if [[ "$DO_X11_DEFAULT" -eq 1 ]]; then
    X11_SESSION=""
    for cand in plasmax11 plasma-x11 plasma kde-plasma gnome-xorg ubuntu-xorg; do
        if [[ -f "/usr/share/xsessions/${cand}.desktop" ]]; then
            X11_SESSION="${cand}.desktop"; break
        fi
    done
    if [[ -n "$X11_SESSION" ]]; then
        if [[ -f /var/lib/sddm/state.conf ]]; then
            python3 - "$X11_SESSION" "$SEAT_USER" <<'PY' || true
import configparser, sys, pathlib
sess, user = sys.argv[1], sys.argv[2]
p = pathlib.Path('/var/lib/sddm/state.conf')
cp = configparser.ConfigParser()
cp.optionxform = str
cp.read(p)
if 'Last' not in cp: cp['Last'] = {}
cp['Last']['Session'] = sess
cp['Last']['User']    = user
with p.open('w') as f: cp.write(f)
PY
            ok "SDDM /var/lib/sddm/state.conf -> Session=$X11_SESSION"
        fi
        if [[ -d "$SEAT_HOME" ]]; then
            cat > "$SEAT_HOME/.dmrc" <<EOF
[Desktop]
Session=${X11_SESSION%.desktop}
EOF
            chown "$SEAT_USER:$SEAT_USER" "$SEAT_HOME/.dmrc"
            chmod 0644 "$SEAT_HOME/.dmrc"
            ok "$SEAT_HOME/.dmrc -> ${X11_SESSION%.desktop}"
        fi
    else
        note "no X11 session file found in /usr/share/xsessions/."
        note "install plasma-workspace + a Plasma X11 session if you want X11."
    fi
else
    note "skipped X11-default configuration (--no-x11-default)"
fi

# --------------------------------------------------------------------------- #
step "10/10" "Enabling & starting services…"
systemctl reset-failed consolerdp.service 2>/dev/null || true
rm -f /run/consolerdp.sock
systemctl enable --now consolerdp.service
systemctl restart xrdp.service xrdp-sesman.service 2>/dev/null \
    || systemctl restart xrdp || true
ok "consolerdp + xrdp services live"

# --------------------------------------------------------------------------- #
echo
echo "================================================================"
echo "ConsoleRDP installed."
echo "================================================================"
echo "  Seat user      : $SEAT_USER"
echo "  Console TTY    : $CONSOLE_TTY"
echo "  Greeter TTY    : $GREETER_TTY  (banner login)"
echo "  RDP listener   : tcp/3389"
echo "  Bridge passwd  : /etc/consolerdp/vnc.passwd  (root:xrdp 0640)"
echo "  Host IPs       : $(hostname -I | tr -s ' ')"
echo
echo "Generating .RDP profile for Windows clients…"
RDP_OUT="/etc/consolerdp/consolerdp-$(hostname -I | awk '{print $1}').rdp"
/usr/local/sbin/consolerdp-make-rdp --user "$SEAT_USER" --out "$RDP_OUT" 2>&1 | sed 's/^/       /'
chmod 0644 "$RDP_OUT"
ok "$RDP_OUT — copy to your Windows box and double-click"
echo
echo "Running diagnostic…"
echo "----------------------------------------------------------------"
/usr/local/sbin/consolerdp-doctor || true
echo "----------------------------------------------------------------"
echo
if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
    echo -e "\033[1;33m! IMPORTANT: your CURRENT session is Wayland.\033[0m"
    echo "  Log out and pick 'Plasma (X11)' at SDDM before testing RDP."
    echo "  (X11 has been set as your default for next login.)"
fi
echo "Uninstall: sudo $REPO_ROOT/uninstall.sh"
