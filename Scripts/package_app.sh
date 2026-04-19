#!/usr/bin/env bash
# Build a redistributable LLimit.app from the SwiftPM target.
#
# Output: build/release/LLimit.app  (universal arm64 + x86_64, ad-hoc signed)
# Optional second arg writes a versioned .zip next to the .app.
#
# Usage:
#   Scripts/package_app.sh                # default version 0.1.0
#   Scripts/package_app.sh 1.2.3           # explicit version
#   Scripts/package_app.sh 1.2.3 zip       # also emit LLimit-1.2.3.zip
set -euo pipefail

VERSION="${1:-0.1.0}"
EMIT_ZIP="${2:-}"
BUNDLE_ID="com.rntlqvnf.llimit"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT_DIR="build/release"
APP_DIR="$OUT_DIR/LLimit.app"
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

BIN="$(swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)/LLimit"
if [ ! -x "$BIN" ]; then
  echo "build did not produce $BIN" >&2
  exit 1
fi

echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"
cp "$BIN" "$MACOS_DIR/LLimit"
chmod +x "$MACOS_DIR/LLimit"

# Optional app icon: if Resources/icon.png exists (square, ideally 1024×1024),
# build an .icns from it and reference it in Info.plist. Skipped silently
# otherwise so the build still works without an icon.
ICON_SRC="$ROOT/Resources/icon.png"
ICON_REF=""
if [ -f "$ICON_SRC" ]; then
  echo "==> building LLimit.icns from $ICON_SRC"
  ICONSET="$OUT_DIR/LLimit.iconset"
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  for spec in \
      "16 icon_16x16.png"          "32 icon_16x16@2x.png" \
      "32 icon_32x32.png"          "64 icon_32x32@2x.png" \
      "128 icon_128x128.png"       "256 icon_128x128@2x.png" \
      "256 icon_256x256.png"       "512 icon_256x256@2x.png" \
      "512 icon_512x512.png"       "1024 icon_512x512@2x.png"; do
    set -- $spec
    sips -z "$1" "$1" "$ICON_SRC" --out "$ICONSET/$2" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$RES_DIR/LLimit.icns"
  rm -rf "$ICONSET"
  ICON_REF="<key>CFBundleIconFile</key><string>LLimit</string>"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>LLimit</string>
    ${ICON_REF}
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>LLimit</string>
    <key>CFBundleDisplayName</key><string>LLimit</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

ENTITLEMENTS="$OUT_DIR/LLimit.entitlements"
cat > "$ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><false/>
    <key>com.apple.security.network.client</key><true/>
    <key>com.apple.security.cs.allow-jit</key><true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
    <key>com.apple.security.cs.disable-library-validation</key><true/>
</dict>
</plist>
PLIST

echo "==> ad-hoc codesigning (hardened runtime + entitlements)"
codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign - "$APP_DIR"
codesign --verify --verbose=2 "$APP_DIR" || true

if [ "$EMIT_ZIP" = "zip" ]; then
  ZIP_PATH="$OUT_DIR/LLimit-${VERSION}.zip"
  echo "==> zipping to $ZIP_PATH"
  rm -f "$ZIP_PATH"
  (cd "$OUT_DIR" && /usr/bin/ditto -c -k --keepParent LLimit.app "LLimit-${VERSION}.zip")
fi

echo
echo "done."
echo "  app: $APP_DIR"
[ "$EMIT_ZIP" = "zip" ] && echo "  zip: $OUT_DIR/LLimit-${VERSION}.zip"
