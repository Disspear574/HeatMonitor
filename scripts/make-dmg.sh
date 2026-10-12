#!/bin/zsh
# Builds build/HeatMonitor.dmg (the version lives in the release tag): background with logo, app -> Applications, custom volume and file icon.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh >/dev/null
VOL="Heat Monitor"
TMP=build/tmp
# Outside the home folder: Finder stores the image path in the volume's .DS_Store.
WORK=$(mktemp -d /tmp/heatmonitor-dmg.XXXXXX)
STAGE=$WORK/stage
RW=$WORK/rw.dmg
OUT=build/HeatMonitor.dmg

swiftc -O scripts/make-dmg-background.swift -o $TMP/make-dmg-background
$TMP/make-dmg-background $TMP/bg.png 1 Resources/icon-256.png
$TMP/make-dmg-background $TMP/bg@2x.png 2 Resources/icon-256.png
tiffutil -cathidpicheck $TMP/bg.png $TMP/bg@2x.png -out $TMP/background.tiff >/dev/null

mkdir -p $STAGE/.background
cp -R build/HeatMonitor.app $STAGE/
cp $TMP/background.tiff $STAGE/.background/background.tiff
ln -s /Applications $STAGE/Applications

if [[ -d "/Volumes/$VOL" ]]; then hdiutil detach "/Volumes/$VOL" -quiet || true; fi
hdiutil create -srcfolder $STAGE -volname "$VOL" -fs HFS+ -format UDRW -size 40m $RW -quiet
MOUNT=$(hdiutil attach -readwrite -noverify -noautoopen $RW | awk -F'\t' '/\/Volumes\//{print $NF}')

osascript <<OSA
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 840, 568}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 96
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "HeatMonitor.app" of container window to {170, 255}
    set position of item "Applications" of container window to {470, 255}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA

# After Finder: opening the window deletes .VolumeIcon.icns and clears the custom icon flag.
cp Resources/AppIcon.icns "$MOUNT/.VolumeIcon.icns"
SetFile -a V "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT"
rm -r "$MOUNT/.fseventsd" 2>/dev/null || true
sync
hdiutil detach "$MOUNT" -quiet
rm -f "$OUT"
hdiutil convert $RW -format UDZO -imagekey zlib-level=9 -o "$OUT" -quiet
rm -r "$WORK"

# Icon on the .dmg file itself (kept by AirDrop and zip; messengers may drop it).
swift -e 'import AppKit; NSWorkspace.shared.setIcon(NSImage(contentsOfFile: CommandLine.arguments[1]), forFile: CommandLine.arguments[2], options: [])' Resources/AppIcon.icns "$OUT" 2>/dev/null || true
echo "$OUT"
