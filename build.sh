#!/bin/bash
# Builds NekoLyrics.app (needs Xcode command line tools, macOS 14+).
set -e
swift build -c release
APP=NekoLyrics.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/NekoLyrics "$APP/Contents/MacOS/"
mkdir -p "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"
cp Assets/AppIcon.icns Assets/MenuBarIcon.png "Assets/MenuBarIcon@2x.png" "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP — run: open $APP"
