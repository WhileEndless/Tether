#!/usr/bin/env bash
# Builds Tether.app into ./dist.
#   scripts/build-app.sh            release build
#   scripts/build-app.sh debug      debug build
#   scripts/build-app.sh debug demo "Tether Demo.app" (separate bundle id, used by `make demo`)
#   UNIVERSAL=1 scripts/build-app.sh   Apple silicon and Intel in one app (release downloads)
set -euo pipefail

# The oldest macOS Tether runs on; keep in step with `platforms` in Package.swift.
MIN_MACOS="14.4"

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
build() {   # build <extra swift build arguments…>; prints the folder with the products
    # Inside "$(build)" bash does not stop at a failed command by itself (set -e does not reach
    # there): a build that fails must not package the app built before.
    swift build -c "$CONFIG" "${MAP[@]}" "$@" --product Tether >&2 || return 1
    swift build -c "$CONFIG" "${MAP[@]}" "$@" --product tether-askpass >&2 || return 1
    swift build -c "$CONFIG" "${MAP[@]}" "$@" --show-bin-path
}
if [ "${UNIVERSAL:-}" = 1 ]; then
    # One build per architecture, joined with lipo (resource bundles are the same for both).
    BIN="$(build --arch arm64)"
    INTEL="$(build --arch x86_64)"
else
    BIN="$(build)"
    INTEL=""
fi

APP="$ROOT/dist/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for exe in Tether tether-askpass; do
    if [ -n "$INTEL" ]; then
        lipo -create "$BIN/$exe" "$INTEL/$exe" -output "$APP/Contents/MacOS/$exe"
    else
        cp "$BIN/$exe" "$APP/Contents/MacOS/$exe"
    fi
done
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
    <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>com.tether.remote-files</string>
            <key>UTTypeDescription</key><string>Tether Remote Files</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string></array>
        </dict>
    </array>
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

# Signing identity: TETHER_SIGN_IDENTITY, else a "Tether Local Signing" certificate if one exists
# (make signing-identity creates it), else ad-hoc. With a fixed certificate macOS recognises every
# build as the same app, so permissions (Documents, Downloads …) and the keychain's "Always Allow"
# stay granted across updates; an ad-hoc signature is a new app to macOS with every build.
# Hardened runtime: macOS ignores DYLD_* variables for the app, so no library can be injected into
# Tether (which holds the keychain access, the recording key and the askpass socket).
IDENTITY="${TETHER_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && security find-identity -p codesigning 2>/dev/null | grep -q '"Tether Local Signing"'; then
    IDENTITY="Tether Local Signing"
fi
IDENTITY="${IDENTITY:--}"
codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/MacOS/tether-askpass"
codesign --force --options runtime --sign "$IDENTITY" "$APP"
if [ "$IDENTITY" = "-" ]; then
    echo "Built $APP (ad-hoc signature; run 'make signing-identity' once to keep macOS permissions across builds)"
else
    echo "Built $APP (signed with \"$IDENTITY\")"
fi
