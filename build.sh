#!/bin/bash
# Builds Watched.app next to this script. Needs Xcode Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"

APP="Watched.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -parse-as-library -target "$(uname -m)-apple-macos14.0" main.swift -o "$APP/Contents/MacOS/Watched"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "Built $APP. Drag it into /Applications."
