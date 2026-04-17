#!/usr/bin/env bash
# Build a redistributable LLMBar.app from the SwiftPM target.
#
# Output: build/release/LLMBar.app  (universal arm64 + x86_64, ad-hoc signed)
# Optional second arg writes a versioned .zip next to the .app.
#
# Usage:
#   Scripts/package_app.sh                # default version 0.1.0
#   Scripts/package_app.sh 1.2.3           # explicit version
#   Scripts/package_app.sh 1.2.3 zip       # also emit LLMBar-1.2.3.zip
set -euo pipefail

VERSION="${1:-0.1.0}"
EMIT_ZIP="${2:-}"
BUNDLE_ID="com.rntlqvnf.llmbar"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT_DIR="build/release"
APP_DIR="$OUT_DIR/LLMBar.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"

# Multi-arch (`--arch arm64 --arch x86_64`) requires a full Xcode install.
# When only Command Line Tools are present we fall back to a single-arch
# native build so contributors don't need Xcode just to package.
if /usr/bin/xcrun --find xcodebuild >/dev/null 2>&1 \
   && [ -x "/Library/Developer/SharedFrameworks/XCBuild.framework/Versions/A/Support/xcbuild" ]; then
  ARCH_ARGS=(--arch arm64 --arch x86_64)
  ARCH_LABEL="universal (arm64 + x86_64)"
else
  ARCH_ARGS=()
  ARCH_LABEL="$(uname -m) only — install Xcode for a universal binary"
fi

echo "==> swift build (release, $ARCH_LABEL)"
swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}

BIN="$(swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)/LLMBar"
if [ ! -x "$BIN" ]; then
  echo "build did not produce $BIN" >&2
  exit 1
fi

echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"
cp "$BIN" "$MACOS_DIR/LLMBar"
chmod +x "$MACOS_DIR/LLMBar"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>LLMBar</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>LLMBar</string>
    <key>CFBundleDisplayName</key><string>LLMBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc codesigning"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --verbose=2 "$APP_DIR" || true

if [ "$EMIT_ZIP" = "zip" ]; then
  ZIP_PATH="$OUT_DIR/LLMBar-${VERSION}.zip"
  echo "==> zipping to $ZIP_PATH"
  rm -f "$ZIP_PATH"
  (cd "$OUT_DIR" && /usr/bin/ditto -c -k --keepParent LLMBar.app "LLMBar-${VERSION}.zip")
fi

echo
echo "done."
echo "  app: $APP_DIR"
[ "$EMIT_ZIP" = "zip" ] && echo "  zip: $OUT_DIR/LLMBar-${VERSION}.zip"
