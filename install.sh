#!/usr/bin/env bash
# Install LLimit on macOS.
#
# Downloads the latest GitHub Release zip, strips the quarantine flag (so
# Gatekeeper doesn't block the first launch), drops the .app into
# /Applications, and opens it.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/githajae/LLimit/main/install.sh | bash
set -euo pipefail

REPO="githajae/LLimit"
APP_NAME="LLimit"
DEST="/Applications/${APP_NAME}.app"

if [ "$(uname)" != "Darwin" ]; then
  echo "LLimit is macOS-only." >&2
  exit 1
fi

# The current build is arm64-only. Intel users would download a binary
# they can't run, so fail loudly with a clear next step instead.
if [ "$(uname -m)" != "arm64" ]; then
  echo "This build is Apple Silicon (arm64) only." >&2
  echo "Intel Mac support is planned — for now, build from source:" >&2
  echo "  git clone https://github.com/${REPO}.git && cd ${APP_NAME}" >&2
  echo "  Scripts/package_app.sh && open build/release/${APP_NAME}.app" >&2
  exit 1
fi

echo "==> finding latest release"
ZIP_URL="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
  | /usr/bin/grep -o '"browser_download_url": *"[^"]*\.zip"' \
  | head -1 \
  | /usr/bin/sed 's/.*"\(https:[^"]*\)"/\1/')"
if [ -z "$ZIP_URL" ]; then
  echo "Could not find a release zip on github.com/${REPO}/releases/latest." >&2
  exit 1
fi
echo "    $ZIP_URL"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> downloading"
curl -fL --progress-bar "$ZIP_URL" -o "$TMP/llimit.zip"

echo "==> unzipping"
/usr/bin/ditto -x -k "$TMP/llimit.zip" "$TMP"
if [ ! -d "$TMP/${APP_NAME}.app" ]; then
  echo "Unexpected zip contents — bailing." >&2
  exit 1
fi

if [ -d "$DEST" ]; then
  echo "==> replacing existing $DEST"
  # Quit the running instance first so the rm doesn't race a live binary.
  /usr/bin/pkill -f "${DEST}/Contents/MacOS" 2>/dev/null || true
  sleep 0.5
  rm -rf "$DEST"
fi

echo "==> installing to $DEST"
/usr/bin/ditto "$TMP/${APP_NAME}.app" "$DEST"

# Strip Apple's quarantine xattr so Gatekeeper doesn't show the
# "cannot be opened" dialog. brew --cask does the same thing for casks.
echo "==> stripping quarantine flag"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "==> launching"
open "$DEST"

echo
echo "Done. ${APP_NAME} is in /Applications and running."
echo "Look for the gauge icon in your menu bar."
