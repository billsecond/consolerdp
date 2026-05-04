#!/usr/bin/env bash
# mkrelease.sh -- assemble a release tarball.
#
# Produces build/consolerdp-<version>.tar.gz containing:
#   - bin/, config/, systemd/, patches/, tests/, packaging/, scripts/
#   - install.sh, uninstall.sh, INSTALL.md, README.md, LICENSE
#   - release/*.deb           (the 7 prebuilt .debs from ./release/)
#
# The tarball is what gets attached to a GitHub Release so the
# one-liner `curl | sudo bash` can pull and install everything.
#
# Usage:
#   ./scripts/mkrelease.sh            # uses version from debian/changelog
#   ./scripts/mkrelease.sh v1.0.0     # explicit tag

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

TAG="${1:-}"
if [[ -z "$TAG" ]]; then
    # Derive from the consolerdp .deb's Version.
    VERSION="$(dpkg-parsechangelog -l packaging/consolerdp/debian/changelog \
               -S Version 2>/dev/null)"
    TAG="v$VERSION"
fi
STRIPPED="${TAG#v}"

# Ensure the prebuilt .debs exist.
mapfile -t DEBS < <(ls release/*.deb 2>/dev/null || true)
if [[ ${#DEBS[@]} -lt 7 ]]; then
    echo "!! release/ only has ${#DEBS[@]} .debs; expected 7" >&2
    echo "   Rebuild via: ./scripts/buildall.sh" >&2
    exit 1
fi

OUT="build/consolerdp-${STRIPPED}.tar.gz"
mkdir -p build

echo ">>> Packing $OUT"

# We use --transform so the tarball extracts as consolerdp-<version>/...
tar --transform "s,^,consolerdp-${STRIPPED}/," \
    -czf "$OUT" \
    --exclude='.git' \
    --exclude='build' \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    --exclude='kpipewire-*' \
    --exclude='krdp-*' \
    --exclude='kwin-*' \
    --exclude='*.orig.tar.xz' \
    --exclude='*.debian.tar.xz' \
    --exclude='*.dsc' \
    --exclude='*.buildinfo' \
    --exclude='*.changes' \
    --exclude='docs/legacy' \
    bin/ config/ systemd/ patches/ tests/ packaging/ scripts/ docs/ \
    install.sh uninstall.sh INSTALL.md README.md LICENSE Makefile \
    PLAN.md CONTRIBUTING.md .gitignore \
    release/

ls -la "$OUT"
echo ">>> done."
echo "   Upload to GitHub: gh release upload $TAG $OUT scripts/install-remote.sh"
