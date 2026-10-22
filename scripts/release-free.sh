#!/bin/bash
# Builds tinywm.app signed with the self-signed identity and zips it for a GitHub release.
# Free: no Apple Developer ID, no notarization. Downloaded copies need "Open Anyway" once;
# the Homebrew cask clears the quarantine flag instead.
#   scripts/release-free.sh 0.1.0   → build/release/tinywm-0.1.0.zip
#
# Every release must be signed by the same identity, or users lose their Accessibility grant.
# Create it once with scripts/make-signing-identity.sh and keep a .p12 backup.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release-free.sh <version>}"
IDENTITY="${TINYWM_SIGN_IDENTITY:-tinywm self-signed}"
security find-certificate -c "$IDENTITY" >/dev/null 2>&1 \
    || { echo "No \"$IDENTITY\" certificate. Run scripts/make-signing-identity.sh first."; exit 1; }

TINYWM_VERSION="$VERSION" TINYWM_SIGN_IDENTITY="$IDENTITY" scripts/bundle-tinywm.sh
OUT="build/release"
rm -rf "$OUT"
mkdir -p "$OUT"
# ditto keeps the signature and extended attributes intact, unlike plain zip.
ditto build/tinywm.app "$OUT/tinywm.app"
codesign --verify --strict --verbose=2 "$OUT/tinywm.app"
ditto -c -k --keepParent "$OUT/tinywm.app" "$OUT/tinywm-$VERSION.zip"
cp "$OUT/tinywm-$VERSION.zip" "$OUT/tinywm.zip"
shasum -a 256 "$OUT/tinywm-$VERSION.zip"
