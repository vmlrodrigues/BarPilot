#!/bin/sh
# Build BarPilot.app — a self-contained menu-bar agent bundle.
#
# No Xcode required: compiles with Swift Package Manager (`swift build`) and
# assembles the result into a .app bundle with an Info.plist so it runs as a
# LSUIElement (menu-bar-only) agent.
set -e

cd "$(dirname "$0")"

CONFIG=release
APP="BarPilot.app"
BIN_NAME="BarPilot"

# Signing is configurable via the environment (the Makefile's `release` target
# sets these). Defaults produce an ad-hoc-signed local/dev build.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # "-" = ad-hoc
ENTITLEMENTS="${ENTITLEMENTS:-}"      # optional path to a .entitlements plist
HARDENED="${HARDENED:-}"              # non-empty → Hardened Runtime + secure timestamp
VERSION="${VERSION:-$(cat VERSION 2>/dev/null)}"   # stamp into the bundle Info.plist

echo "▸ Building ($CONFIG) …"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$BIN_NAME"
if [ ! -f "$BIN_PATH" ]; then
    echo "✗ Build output not found at $BIN_PATH" >&2
    exit 1
fi

echo "▸ Assembling $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$BIN_NAME"
cp Info.plist "$APP/Contents/Info.plist"

# Stamp the release version into the bundle (source Info.plist left untouched).
if [ -n "$VERSION" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION"            "$APP/Contents/Info.plist"
fi

# Generate the app icon (.icns) from AppIcon.png, if present.
if [ -f AppIcon.png ]; then
    echo "▸ Generating app icon …"
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size"             AppIcon.png --out "$ICONSET/icon_${size}x${size}.png"    >/dev/null
        sips -z "$((size*2))" "$((size*2))" AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$ICONSET")"
fi

# Code-sign. Defaults to ad-hoc ("-") for local/dev builds; `make release`
# overrides SIGN_IDENTITY / ENTITLEMENTS / HARDENED for a Developer ID signature.
echo "▸ Signing ($SIGN_IDENTITY) …"
set -- --force --sign "$SIGN_IDENTITY"
[ -n "$HARDENED" ]     && set -- "$@" --options runtime --timestamp
[ -n "$ENTITLEMENTS" ] && set -- "$@" --entitlements "$ENTITLEMENTS"
if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign "$@" "$APP" 2>/dev/null || true
else
    codesign "$@" "$APP"
fi

echo "✓ Built $APP"
echo "  Launch with:  open $APP"
echo "  (Look for the \$ amount in your menu bar.)"
