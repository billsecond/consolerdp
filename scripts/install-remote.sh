#!/usr/bin/env bash
# install-remote.sh -- one-liner bootstrap for ConsoleRDP.
#
#   curl -fsSL https://github.com/billsecond/consolerdp/releases/latest/download/install-remote.sh | sudo bash
#
# What it does:
#   1. Detects the latest ConsoleRDP GitHub release.
#   2. Downloads consolerdp-<version>.tar.gz (source + prebuilt .debs).
#   3. Extracts to /opt/consolerdp-<version>/.
#   4. Runs `install.sh --user <seat-user>` from the extracted tree.
#
# Customisation:
#   CONSOLERDP_REPO=<owner/repo>   default: billsecond/consolerdp
#   CONSOLERDP_TAG=<tag>           default: latest release
#   CONSOLERDP_SEAT_USER=<user>    default: $SUDO_USER (or prompt)
#   CONSOLERDP_EXTRA_ARGS=<flags>  extra args passed to install.sh

set -euo pipefail

REPO="${CONSOLERDP_REPO:-billsecond/consolerdp}"
TAG="${CONSOLERDP_TAG:-}"
SEAT="${CONSOLERDP_SEAT_USER:-${SUDO_USER:-}}"
EXTRA="${CONSOLERDP_EXTRA_ARGS:-}"

[[ $EUID -eq 0 ]] || { echo "must run as root (pipe to sudo bash)" >&2; exit 1; }

if [[ -z "$SEAT" ]]; then
    if [[ -t 0 ]]; then
        read -r -p "Seat user (whose Plasma session accepts RDP): " SEAT
    else
        echo "CONSOLERDP_SEAT_USER not set and SUDO_USER is empty." >&2
        echo "Re-run as: CONSOLERDP_SEAT_USER=<name> sudo -E bash install-remote.sh" >&2
        exit 1
    fi
fi
id -u "$SEAT" >/dev/null 2>&1 || \
    { echo "user '$SEAT' does not exist" >&2; exit 1; }

# Sanity deps for downloading.
apt-get update -qq
apt-get install -y -qq curl jq tar </dev/null

# Resolve the tag (latest if unset).
if [[ -z "$TAG" ]]; then
    TAG="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
           | jq -r .tag_name)"
    [[ -n "$TAG" && "$TAG" != "null" ]] || \
        { echo "could not resolve latest tag from github.com/$REPO" >&2; exit 1; }
fi

# Normalise the tarball name convention: consolerdp-<tag>.tar.gz.
STRIPPED="${TAG#v}"
TARBALL="consolerdp-$STRIPPED.tar.gz"
URL="https://github.com/$REPO/releases/download/$TAG/$TARBALL"

echo ">>> ConsoleRDP $TAG"
echo ">>> Downloading $URL"

DEST="/opt/consolerdp-$STRIPPED"
rm -rf "$DEST"
mkdir -p "$DEST"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fsSL -o "$TMP/$TARBALL" "$URL"
tar -xzf "$TMP/$TARBALL" -C "$DEST" --strip-components=1

echo ">>> Extracted to $DEST"

# Run the real installer.
set -x
exec "$DEST/install.sh" --user "$SEAT" $EXTRA
