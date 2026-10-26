#!/bin/zsh
# Build Watt into build/Watt.app, ad-hoc signed.
# Needs only Apple's Command Line Tools (xcode-select --install). Run: zsh build.sh
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/build/Watt.app"
MACOS="$APP/Contents/MacOS"

rm -rf "$HERE/build"
mkdir -p "$MACOS"

# Build for the Mac's real chip, even from a Terminal running under Rosetta.
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ]; then ARCH=arm64; else ARCH=x86_64; fi

# Compile the one source file, runnable on macOS 13 or later.
swiftc -swift-version 5 -O \
    -target "$ARCH-apple-macos13.0" \
    "$HERE/src/main.swift" \
    -framework AppKit -framework IOKit -framework CoreGraphics -framework Foundation \
    -framework ServiceManagement \
    -o "$MACOS/Watt"

cp "$HERE/Info.plist" "$APP/Contents/Info.plist"

# Network drives and downloads tag files with extra metadata that codesign
# refuses. Strip it from the bundle before signing.
xattr -cr "$APP"

# Ad-hoc signature so macOS will run it on this Mac (no Developer ID needed).
codesign --force --sign - "$APP"

echo "Built: $APP"
echo "Install:  ditto \"$APP\" ~/Applications/Watt.app && open ~/Applications/Watt.app"
