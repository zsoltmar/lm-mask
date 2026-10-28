#!/bin/bash
# Build a drag-to-install DMG from an exported "LM Mask.app".
# No signing or notarization here (see notarize.sh, to be added later).
#
# Usage: scripts/make_dmg.sh /path/to/"LM Mask.app" [output.dmg] [background.png]
#   output.dmg      default: ./LM-Mask-<version>.dmg
#   background.png  optional Finder window background (recommended 600x400 px)
set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 ]]; then
  echo "usage: $0 /path/to/\"LM Mask.app\" [output.dmg] [background.png]" >&2
  exit 64
fi

APP="${1%/}"
[[ -d "$APP" && "$APP" == *.app ]] || { echo "error: not an .app bundle: $APP" >&2; exit 66; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0)"
OUT="${2:-LM-Mask-$VERSION.dmg}"
BACKGROUND="${3:-}"
[[ -z "$BACKGROUND" || -f "$BACKGROUND" ]] || { echo "error: background not found: $BACKGROUND" >&2; exit 66; }

VOLNAME="LM Mask"
APPNAME="$(basename "$APP")"
STAGE="$(mktemp -d)"
RW_DMG="$(mktemp -u).dmg"
trap 'hdiutil detach "/Volumes/$VOLNAME" -quiet 2>/dev/null || true; rm -rf "$STAGE" "$RW_DMG"' EXIT

echo "Staging $APPNAME"
# ditto preserves code signatures, extended attributes and symlinks inside the bundle.
ditto "$APP" "$STAGE/$APPNAME"
ln -s /Applications "$STAGE/Applications"
if [[ -n "$BACKGROUND" ]]; then
  mkdir "$STAGE/.background"
  cp "$BACKGROUND" "$STAGE/.background/background.png"
fi

rm -f "$OUT"

if [[ -z "$BACKGROUND" ]]; then
  # Plain DMG: no window styling needed.
  hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$OUT"
else
  # Styled DMG: create read-write, lay out the Finder window with AppleScript, then compress.
  hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW "$RW_DMG"
  hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen -quiet
  osascript <<EOF || echo "warning: Finder layout failed (grant Terminal automation access); DMG still works" >&2
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 800, 520}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 96
    set background picture of opts to file ".background:background.png"
    set position of item "$APPNAME" of container window to {160, 200}
    set position of item "Applications" of container window to {440, 200}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
  sync
  hdiutil detach "/Volumes/$VOLNAME" -quiet
  hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUT" -quiet
fi

echo "Created $OUT"
