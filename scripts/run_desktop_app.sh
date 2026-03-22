#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CleanMacApp.app"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME"
DESKTOP_PRODUCT="CleanMacApp"
EXECUTABLE_NAME="CleanMacApp"
ICON_ICNS="$ROOT_DIR/dist/icon/AppIcon.icns"
ICON_GENERATOR="$ROOT_DIR/scripts/generate_app_icon.sh"

echo "[1/5] Building desktop binary..."
(
  cd "$ROOT_DIR"
  swift build --product "$DESKTOP_PRODUCT" >/dev/null
)

BIN_DIR="$(cd "$ROOT_DIR" && swift build --show-bin-path)"
BIN_PATH="$BIN_DIR/$DESKTOP_PRODUCT"

if [[ ! -x "$BIN_PATH" ]]; then
  echo "Desktop binary not found: $BIN_PATH" >&2
  exit 1
fi

echo "[2/5] Building app icon..."
"$ICON_GENERATOR"

echo "[3/5] Packaging .app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
cp "$ICON_ICNS" "$APP_DIR/Contents/Resources/AppIcon.icns"

cat >"$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>CleanMacApp</string>
    <key>CFBundleDisplayName</key>
    <string>CleanMacApp</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.davidou84.cleanmacapp</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>CleanMacApp</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo -n "APPL????" >"$APP_DIR/Contents/PkgInfo"

echo "[4/5] Launching app bundle..."
open "$APP_DIR"

echo "[5/5] Done."
echo "App bundle: $APP_DIR"
