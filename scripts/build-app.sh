#!/usr/bin/env bash
# Builds Tether.app into ./dist.
#   scripts/build-app.sh            release build
#   scripts/build-app.sh debug      debug build
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c "$CONFIG" --product Tether
swift build -c "$CONFIG" --product tether-askpass
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="$ROOT/dist/Tether.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/Tether" "$APP/Contents/MacOS/Tether"
cp "$BIN/tether-askpass" "$APP/Contents/MacOS/tether-askpass"
# SwiftPM resource bundles (e.g. SwiftTerm's Metal shaders)
for bundle in "$BIN"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/"

VERSION="$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.1.1)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Tether</string>
    <key>CFBundleDisplayName</key><string>Tether</string>
    <key>CFBundleIdentifier</key><string>io.github.whileendless.tether</string>
    <key>CFBundleExecutable</key><string>Tether</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION#v}</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS runs it locally. Sign with your own identity for distribution.
codesign --force --sign - "$APP/Contents/MacOS/tether-askpass"
codesign --force --sign - "$APP"
echo "Built $APP"
