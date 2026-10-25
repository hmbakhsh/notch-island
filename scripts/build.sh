#!/bin/bash
# Builds build/Island.app and build/Island.zip.
#   VERSION=0.2.0 stamps the version (CI passes the tag); UNIVERSAL=1 builds for Apple silicon and Intel.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/Island.app

if [[ -n "${UNIVERSAL:-}" ]]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=.build/apple/Products/Release/Island
else
  swift build -c release
  BIN=.build/release/Island
fi

rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Island"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -n "${VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
# Ad-hoc signed, but matched by bundle id rather than build hash, so macOS
# keeps the calendar and Spotify permissions across rebuilds and updates.
codesign --force --sign - -r='designated => identifier "dev.notchisland.Island"' "$APP"
(cd build && rm -f Island.zip && ditto -c -k --keepParent Island.app Island.zip)
echo "Built $APP ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist"))"
