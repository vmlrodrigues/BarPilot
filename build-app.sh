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
# sets these). Prefer the owner's stable Developer ID for local builds when it is
# installed: ad-hoc identities change on every rebuild and cause macOS Keychain
# to ask for access again. Other contributors still fall back to ad-hoc signing.
LOCAL_SIGN_IDENTITY="${LOCAL_SIGN_IDENTITY:-Developer ID Application: Victor Rodrigues (9N354A3UZK)}"
if [ -z "${SIGN_IDENTITY+x}" ]; then
    REQUESTED_SIGN_IDENTITY="$LOCAL_SIGN_IDENTITY"
    ALLOW_ADHOC_FALLBACK=1
else
    REQUESTED_SIGN_IDENTITY="$SIGN_IDENTITY"
    ALLOW_ADHOC_FALLBACK=""
fi

# Resolve names through `find-identity` and pass the valid certificate fingerprint
# to codesign. This avoids ambiguous/transient name lookup behaviour and makes the
# exact identity used by local and release builds deterministic.
SIGN_IDENTITY="$REQUESTED_SIGN_IDENTITY"
if [ "$REQUESTED_SIGN_IDENTITY" != "-" ]; then
    RESOLVED_SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null |
        awk -v identity="\"$REQUESTED_SIGN_IDENTITY\"" 'index($0, identity) { print $2; exit }')"
    if [ -n "$RESOLVED_SIGN_IDENTITY" ]; then
        SIGN_IDENTITY="$RESOLVED_SIGN_IDENTITY"
    elif [ -n "$ALLOW_ADHOC_FALLBACK" ]; then
        SIGN_IDENTITY="-"
    fi
fi
ENTITLEMENTS="${ENTITLEMENTS:-}"      # optional path to a .entitlements plist
HARDENED="${HARDENED:-}"              # non-empty → Hardened Runtime + secure timestamp
VERSION="${VERSION:-$(cat VERSION 2>/dev/null)}"   # stamp into the bundle Info.plist
BUILD_CHANNEL="${BUILD_CHANNEL:-development}"

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

# Signature type is no longer a reliable development marker because local builds
# may be Developer ID-signed for stable Keychain access. The release target
# explicitly overrides this value.
/usr/libexec/PlistBuddy -c "Add :BarPilotBuildChannel string $BUILD_CHANNEL" "$APP/Contents/Info.plist"

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

# Code-sign. Local builds use the stable identity above when available; `make
# release` additionally enables entitlements, Hardened Runtime and timestamping.
echo "▸ Signing ($REQUESTED_SIGN_IDENTITY) …"
set -- --force --sign "$SIGN_IDENTITY"
[ -n "$HARDENED" ]     && set -- "$@" --options runtime --timestamp
[ -n "$ENTITLEMENTS" ] && set -- "$@" --entitlements "$ENTITLEMENTS"
if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign "$@" "$APP" 2>/dev/null || true
else
    codesign "$@" "$APP"
    codesign --verify --deep --strict "$APP"
fi

echo "✓ Built $APP"
echo "  Launch with:  open $APP"
echo "  (Look for the \$ amount in your menu bar.)"
