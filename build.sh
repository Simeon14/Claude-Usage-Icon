#!/bin/bash
# Build "Claude Usage Icon.app" from Sources/main.swift — no Xcode project required.
# Produces an ad-hoc-signed .app bundle in ./build/.
#
# Usage:
#   ./build.sh            build into ./build/
#   ./build.sh install    build, then copy to /Applications and launch it
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Claude Usage Icon"          # bundle + display name
EXEC_NAME="ClaudeUsageIcon"           # executable filename (no spaces)
BUNDLE_ID="com.local.claude-usage-icon"
DEPLOY_TARGET="13.0"

BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"

echo "==> Cleaning"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"

echo "==> Compiling (arm64, macOS $DEPLOY_TARGET+)"
swiftc \
  -swift-version 5 \
  -O \
  -target "arm64-apple-macos$DEPLOY_TARGET" \
  -framework Cocoa \
  -framework Security \
  -framework ServiceManagement \
  -o "$MACOS_DIR/$EXEC_NAME" \
  Sources/main.swift

echo "==> Writing Info.plist"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>      <string>$EXEC_NAME</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>$DEPLOY_TARGET</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc signing (stable identity so the Keychain 'Always Allow' sticks)"
codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 \
  && echo "    signed" \
  || echo "    (codesign skipped — app still runs)"

echo "==> Done: $APP_DIR"

if [ "${1:-}" = "install" ]; then
  DEST="/Applications/$APP_NAME.app"
  echo "==> Installing to $DEST"
  pkill -x "$EXEC_NAME" 2>/dev/null || true
  rm -rf "$DEST"
  cp -R "$APP_DIR" "$DEST"
  echo "==> Launching (it registers itself as a login item on first run)"
  open "$DEST"
  echo "    Installed and running from /Applications."
else
  echo "    Run it:   open \"$APP_DIR\""
  echo "    Install:  ./build.sh install   (copies to /Applications + starts at login)"
fi
