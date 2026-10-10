#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP="dist/CrossMouseMac.app"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/CrossMouseMac" "$APP/Contents/MacOS/CrossMouseMac"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>CrossMouse</string>
    <key>CFBundleDisplayName</key><string>CrossMouse</string>
    <key>CFBundleIdentifier</key><string>io.crossmouse.mac</string>
    <key>CFBundleExecutable</key><string>CrossMouseMac</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.4.1</string>
    <key>CFBundleVersion</key><string>9</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>CrossMouse connects to your paired Windows PC on your local network to share mouse and keyboard input.</string>
    <key>NSHumanReadableCopyright</key><string>CrossMouse contributors</string>
</dict>
</plist>
PLIST

# Default to an ad-hoc signature (suitable for CI). Local developers can use
# their own persistent Apple Development certificate so Accessibility approval
# survives rebuilding. Never check a signing identity or private key into git.
SIGN_IDENTITY="${CROSSMOUSE_CODESIGN_IDENTITY:--}"
codesign --force --sign "$SIGN_IDENTITY" "$APP"
echo "Built: $APP"
echo "Configure ~/.config/crossmouse/{key,host}, then open $APP"
