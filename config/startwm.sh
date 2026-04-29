#!/bin/sh
# /etc/xrdp/startwm.sh (ConsoleRDP variant)
#
# In stock xrdp, this script starts the user's window manager on the
# new Xvnc display. ConsoleRDP doesn't *use* a new display — our shim
# repoints the VNC stream at the live :0 — so we just block until
# sesman terminates the "session". Killing this process is sesman's
# signal that the RDP session has ended; our PAM close_session hook
# then runs consolerdp-release on the orchestrator.

logger -t consolerdp "startwm.sh placeholder pid=$$ user=${USER:-?} display=${DISPLAY:-?}"
exec /bin/sleep infinity
