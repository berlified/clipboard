#!/bin/zsh
# LiveDocs release packager: .app bundle + ad-hoc signature + DMG.
# Usage: ./scripts/package.sh [version]   (default 0.1.0)
set -euo pipefail

VERSION="${1:-0.1.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
STAGE="$DIST/stage"
APP="$STAGE/LiveDocs.app"
RES="$ROOT/Sources/Aura/Resources"

echo "==> building release binary"
swift build -c release --package-path "$ROOT" 2>&1 | tail -n 2

echo "==> rendering app icon"
mkdir -p "$RES"
rm -rf /tmp/livedocs.iconset && mkdir -p /tmp/livedocs.iconset
swift "$ROOT/scripts/render-icon.swift" /tmp/livedocs-master.png
for spec in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" \
            "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" \
            "512:icon_256x256@2x" "512:icon_512x512" "1024:icon_512x512@2x"; do
  px="${spec%%:*}"; name="${spec##*:}"
  sips -z "$px" "$px" /tmp/livedocs-master.png --out "/tmp/livedocs.iconset/${name}.png" >/dev/null
done
xattr -cr /tmp/livedocs.iconset
iconutil -c icns /tmp/livedocs.iconset -o "$RES/AppIcon.icns"
echo "    AppIcon.icns: $(du -h "$RES/AppIcon.icns" | cut -f1)"

echo "==> assembling LiveDocs.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/Aura" "$APP/Contents/MacOS/Aura"
cp "$RES/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>LiveDocs</string>
    <key>CFBundleDisplayName</key><string>LiveDocs</string>
    <key>CFBundleIdentifier</key><string>com.berlified.livedocs</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleExecutable</key><string>Aura</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc signing"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP" 2>&1 | tail -n 1 || true

echo "==> building DMG"
mkdir -p "$STAGE"
ln -sfn /Applications "$STAGE/Applications"
rm -f "$DIST/LiveDocs-${VERSION}.dmg"
hdiutil create -volname "LiveDocs" -srcfolder "$STAGE" -ov -format UDZO \
  "$DIST/LiveDocs-${VERSION}.dmg" >/dev/null
rm "$STAGE/Applications"
echo "    $(ls -lh "$DIST/LiveDocs-${VERSION}.dmg" | awk '{print $9, $5}')"
echo "DONE: $DIST/LiveDocs-${VERSION}.dmg"
