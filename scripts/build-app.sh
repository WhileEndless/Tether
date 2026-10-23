#!/usr/bin/env bash
# Builds Tether.app into ./dist.
#   scripts/build-app.sh            release build
#   scripts/build-app.sh debug      debug build
#   scripts/build-app.sh debug demo "Tether Demo.app" (separate bundle id, used by `make demo`)
set -euo pipefail

CONFIG="${1:-release}"
VARIANT="${2:-}"
NAME="Tether"
BUNDLE_ID="io.github.whileendless.tether"
if [ "$VARIANT" = demo ]; then
    NAME="Tether Demo"
    BUNDLE_ID="io.github.whileendless.tether.demo"
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Build paths would otherwise end up in the binary (source file names in messages, debug
# info), revealing the builder's home folder. Map them to "." and strip debug symbols.
MAP=(-Xswiftc -file-prefix-map -Xswiftc "$ROOT=." -Xswiftc -debug-prefix-map -Xswiftc "$ROOT=."
     -Xcc "-ffile-prefix-map=$ROOT=." -Xcc "-fdebug-prefix-map=$ROOT=.")
swift build -c "$CONFIG" "${MAP[@]}" --product Tether
swift build -c "$CONFIG" "${MAP[@]}" --product tether-askpass
BIN="$(swift build -c "$CONFIG" "${MAP[@]}" --show-bin-path)"

APP="$ROOT/dist/$NAME.app"
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

VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
VERSION="${VERSION#v}"
# Build number derived from the version (1.2.3 → 10203), so it always increases with it.
IFS=. read -r V_MAJOR V_MINOR V_PATCH <<< "$VERSION"
BUILD=$(( ${V_MAJOR:-0} * 10000 + ${V_MINOR:-0} * 100 + ${V_PATCH:-0} ))
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${NAME}</string>
    <key>CFBundleDisplayName</key><string>${NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>Tether</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST

if [ "$CONFIG" = release ]; then
    strip -S -x "$APP/Contents/MacOS/Tether" "$APP/Contents/MacOS/tether-askpass"
    if LC_ALL=C grep -a -q "$HOME" "$APP/Contents/MacOS/Tether" "$APP/Contents/MacOS/tether-askpass"; then
        echo "error: the binary still contains $HOME" >&2
        exit 1
    fi
fi

# Ad-hoc signature so macOS runs it locally. Sign with your own identity for distribution.
codesign --force --sign - "$APP/Contents/MacOS/tether-askpass"
codesign --force --sign - "$APP"
echo "Built $APP"
