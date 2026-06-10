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

# Ad-hoc sign so it launches cleanly via Finder / `open`.
codesign --force --sign - "$APP" 2>/dev/null || true

echo "✓ Built $APP"
echo "  Launch with:  open $APP"
echo "  (Look for the \$ amount in your menu bar.)"
