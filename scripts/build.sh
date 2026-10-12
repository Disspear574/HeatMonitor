#!/bin/zsh
# Builds build/HeatMonitor.app (arm64, macOS 14+), signed ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/HeatMonitor.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/tmp
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 \
  Sources/HeatMonitor.swift Sources/Advice.swift Sources/MenuLogic.swift -o "$APP/Contents/MacOS/HeatMonitor"
if [[ ! -f Resources/AppIcon.icns ]]; then
  swiftc -O scripts/make-icon.swift -o build/tmp/make-icon
  build/tmp/make-icon build/tmp/AppIcon.iconset
  iconutil -c icns build/tmp/AppIcon.iconset -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/en.lproj Resources/ru.lproj "$APP/Contents/Resources/"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  Sources/FanTool/main.swift -o "$APP/Contents/MacOS/heatmonitor-fan"
codesign -s - --force "$APP/Contents/MacOS/heatmonitor-fan"
codesign -s - --force "$APP"
echo "$APP"
