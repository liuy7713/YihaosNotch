#!/bin/zsh
# Builds the disk image to send to other people: dist/YihaosNotch-<version>.dmg, with
# the usual "drag the app into Applications" window.
#
#   ./scripts/release.sh
#
# With a Developer ID certificate in your login keychain (Apple Developer Program), the
# app and disk image are signed with it and notarized by Apple, so they open on any
# Mac without warnings. Notarizing needs your Apple ID credentials stored once:
#
#   xcrun notarytool store-credentials YihaosNotch --apple-id YOU@EXAMPLE.COM --team-id TEAMID
#
# (it asks for an app-specific password from account.apple.com). Without a Developer ID
# the image is signed with the local identity instead: it works, but each person has
# to allow it once in System Settings (see the HOW-TO-OPEN.txt written next to it).
#
# Environment: CODESIGN_IDENTITY picks a certificate when there are several;
# NOTARY_PROFILE names the stored credentials (default YihaosNotch).
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

APP_NAME="Yihao's Notch"
VOLUME_NAME="$APP_NAME"
APP="$HOME/Library/Caches/YihaosNotch/$APP_NAME.app"
PLIST="$ROOT/Resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")"
DIST="$ROOT/dist"
DMG="$DIST/YihaosNotch-$VERSION.dmg"
NOTARY_PROFILE="${NOTARY_PROFILE:-YihaosNotch}"

[[ ! -e "$DMG" ]] || { echo "error: $DMG already exists; raise the version in Resources/Info.plist first." >&2; exit 1; }
[[ ! -e "/Volumes/$VOLUME_NAME" ]] || { echo "error: eject the mounted \"$VOLUME_NAME\" disk image first." >&2; exit 1; }
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  echo "warning: there are uncommitted changes; this release won't match any commit."
fi

# A Developer ID identity, if there is one.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | head -1)"
fi
NOTARIZE=false
if [[ -n "$IDENTITY" ]]; then
  echo "Releasing $VERSION ($BUILD), signed with: $IDENTITY"
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "error: no notarization credentials named \"$NOTARY_PROFILE\". Store them once with:" >&2
    echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id YOU@EXAMPLE.COM --team-id TEAMID" >&2
    exit 1
  fi
  NOTARIZE=true
  CODESIGN_IDENTITY="$IDENTITY" "$ROOT/scripts/build.sh"
else
  echo "Releasing $VERSION ($BUILD) without a Developer ID: it won't be notarized."
  "$ROOT/scripts/build.sh"
fi

WORK="$(mktemp -d)"
DEVICE=""
cleanup() {
  [[ -n "$DEVICE" ]] && hdiutil detach "$DEVICE" -quiet -force 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

notarize() {
  echo "Notarizing ${1:t} (usually a few minutes)…"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}

if $NOTARIZE; then
  # Notarize and staple the app itself too, so it opens without a network check even
  # after it's been copied out of the disk image.
  ditto -c -k --keepParent "$APP" "$WORK/app.zip"
  notarize "$WORK/app.zip"
  xcrun stapler staple "$APP"
fi

# Lay out the disk image's contents.
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
swift "$ROOT/scripts/dmg/render-background.swift" "$WORK/bg.png" 1
swift "$ROOT/scripts/dmg/render-background.swift" "$WORK/bg@2x.png" 2
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$STAGE/.background/background.tiff" >/dev/null 2>&1
# The disk's own icon (in Finder's sidebar and on the desktop) is the app icon.
cp "$ROOT/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"

hdiutil create -quiet -volname "$VOLUME_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg"
DEVICE="$(hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen 2>/dev/null | awk '/Apple_HFS/ {print $1}')"
[[ -n "$DEVICE" ]] || { echo "error: couldn't mount the disk image to lay it out." >&2; exit 1; }
# Finder's "has custom icon" flag on the volume, so it uses .VolumeIcon.icns.
xattr -wx com.apple.FinderInfo 0000000000000000040000000000000000000000000000000000000000000000 "/Volumes/$VOLUME_NAME"

# Finder records the window's look in the image's .DS_Store. macOS asks once whether
# this script may control Finder; without that the image works, just unstyled.
# Window: 560×360 points of content (keep in step with render-background.swift).
if ! osascript <<OSA
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 760, 508}
    set viewOptions to icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 112
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "$APP_NAME.app" of container window to {150, 175}
    set position of item "Applications" of container window to {410, 175}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
then
  echo "warning: couldn't style the disk image window (was controlling Finder allowed?)."
fi
chflags hidden "/Volumes/$VOLUME_NAME/.background" 2>/dev/null || true
sync
hdiutil detach "$DEVICE" -quiet
DEVICE=""

mkdir -p "$DIST"
hdiutil convert -quiet "$WORK/rw.dmg" -format ULFO -o "$DMG"

if $NOTARIZE; then
  codesign --sign "$IDENTITY" --timestamp "$DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
  rm -f "$DIST/HOW-TO-OPEN.txt"
else
  cat > "$DIST/HOW-TO-OPEN.txt" <<'TXT'
Installing Yihao's Notch

1. Open the .dmg and drag Yihao's Notch into Applications.
2. Open it from Applications. macOS will say it can't check the app for malicious
   software, because it isn't from the App Store or a registered developer.
   Click Done.
3. Open System Settings > Privacy & Security, scroll down to the message about
   Yihao's Notch, and click Open Anyway. Confirm with your password or Touch ID.

You only need to do this once. It needs a MacBook with a notch and macOS 15 or later.
TXT
fi

echo
echo "Built $DMG"
echo "SHA-256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
$NOTARIZE || echo "Not notarized: send HOW-TO-OPEN.txt (next to it) along with it."
open -R "$DMG"
