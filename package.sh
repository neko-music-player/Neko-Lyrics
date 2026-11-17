#!/bin/bash
# Builds Neko Lyrics and packages it as a drag-to-Applications .dmg.
# Needs macOS 14+ and Xcode command line tools. Output: dist/Neko Lyrics-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")"

BIN=NekoLyrics
APP="Neko Lyrics"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
STAGE=dist/stage
DMG="dist/Neko Lyrics-${VERSION}.dmg"

echo "==> Building release binary"
swift build -c release

echo "==> Assembling ${APP}.app"
rm -rf dist
mkdir -p "${STAGE}/${APP}.app/Contents/MacOS"
cp ".build/release/${BIN}" "${STAGE}/${APP}.app/Contents/MacOS/"
mkdir -p "${STAGE}/${APP}.app/Contents/Resources"
cp Info.plist "${STAGE}/${APP}.app/Contents/"
cp Assets/AppIcon.icns Assets/MenuBarIcon.png "Assets/MenuBarIcon@2x.png" "${STAGE}/${APP}.app/Contents/Resources/"
# Ad-hoc signature: fine for use on this Mac (see README for sharing with others).
codesign --force --sign - "${STAGE}/${APP}.app"

echo "==> Creating disk image"
ln -s /Applications "${STAGE}/Applications"
hdiutil create -volname "Neko Lyrics" -srcfolder "${STAGE}" -ov -format UDZO "${DMG}" >/dev/null

echo
echo "Done: ${DMG}"
echo "Open it, then drag Neko Lyrics onto Applications."
open dist
