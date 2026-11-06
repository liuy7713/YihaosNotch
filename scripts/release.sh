#!/bin/zsh
# Builds the disk image to send to other people: dist/YihaosNotch-<version>.dmg, with
# the usual "drag the app into Applications" window.
#
#   ./scripts/release.sh                 needs a clean, committed tree
#   ./scripts/release.sh --allow-dirty   a trial image from uncommitted changes (not tagged)
#
# It runs scripts/check.sh first, and on success tags the commit v<version> (pushing
# is left to you).
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

TAG="v$VERSION"
ALLOW_DIRTY=false
[[ "${1:-}" == "--allow-dirty" ]] && ALLOW_DIRTY=true

[[ ! -e "$DMG" ]] || { echo "error: $DMG already exists; raise the version with scripts/bump-version.sh first." >&2; exit 1; }
[[ ! -e "/Volumes/$VOLUME_NAME" ]] || { echo "error: eject the mounted \"$VOLUME_NAME\" disk image first." >&2; exit 1; }
# Every release matches a commit, and each version is released from one commit only.
if [[ -n "$(git status --porcelain)" ]] && ! $ALLOW_DIRTY; then
  echo "error: there are uncommitted changes; commit them first (or pass --allow-dirty for a trial image)." >&2
  exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
   && [[ "$(git rev-parse "$TAG^{commit}")" != "$(git rev-parse HEAD)" ]]; then
  echo "error: $TAG already tags another commit; raise the version with scripts/bump-version.sh first." >&2
  exit 1
fi
"$ROOT/scripts/check.sh"

# A Developer ID identity, if there is one.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | head -1)"
fi
if [[ -n "$IDENTITY" && "$IDENTITY" != "Developer ID Application: "* ]]; then
  echo "error: CODESIGN_IDENTITY must be a \"Developer ID Application: …\" certificate; only those can be notarized." >&2
  exit 1
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

# notarytool can finish with "Invalid" and still exit 0, so the status is checked.
notarize() {
  echo "Notarizing ${1:t} (usually a few minutes)…"
  local out
  out="$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || true
  print -r -- "$out"
  if [[ "$out" != *"status: Accepted"* ]]; then
    local id="$(print -r -- "$out" | sed -n 's/^ *id: //p' | head -1)"
    echo "error: Apple didn't accept ${1:t}. The reason:" >&2
    echo "  xcrun notarytool log ${id:-<id>} --keychain-profile $NOTARY_PROFILE" >&2
    exit 1
  fi
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
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$STAGE/.background/background.tiff" >/dev/null 2>&1 \
  || { echo "error: couldn't combine the background images." >&2; exit 1; }

hdiutil create -quiet -volname "$VOLUME_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg"
DEVICE="$(hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen 2>/dev/null | awk '/Apple_HFS/ {print $1}')"
[[ -n "$DEVICE" ]] || { echo "error: couldn't mount the disk image to lay it out." >&2; exit 1; }

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
    close
  end tell
end tell
OSA
then
  echo "warning: couldn't style the disk image window (was controlling Finder allowed?)."
fi
# Finder writes .DS_Store on its own schedule; give it up to 10 s.
for _ in {1..20}; do
  [[ -f "/Volumes/$VOLUME_NAME/.DS_Store" ]] && break
  sleep 0.5
done
[[ -f "/Volumes/$VOLUME_NAME/.DS_Store" ]] || echo "warning: Finder didn't save the window layout; the image will be unstyled."
chflags hidden "/Volumes/$VOLUME_NAME/.background" 2>/dev/null || true
# The disk's own icon (in Finder's sidebar and on the desktop) is the app icon: the
# icon file plus Finder's "has custom icon" flag on the volume. Added after Finder's
# turn, because Finder deletes both while it lays out the window.
cp "$ROOT/Resources/AppIcon.icns" "/Volumes/$VOLUME_NAME/.VolumeIcon.icns"
xattr -wx com.apple.FinderInfo 0000000000000000040000000000000000000000000000000000000000000000 "/Volumes/$VOLUME_NAME"
rm -rf "/Volumes/$VOLUME_NAME/.fseventsd"
sync
# Spotlight or Finder can hold the new volume for a moment.
for attempt in {1..5}; do
  hdiutil detach "$DEVICE" -quiet 2>/dev/null && { DEVICE=""; break; }
  sleep 1
done
if [[ -n "$DEVICE" ]]; then
  hdiutil detach "$DEVICE" -quiet -force
  DEVICE=""
fi

# Everything up to notarization happens in the scratch folder; only a finished image
# reaches dist/, so a failed run never leaves one behind that could be sent out.
OUT="$WORK/${DMG:t}"
hdiutil convert -quiet "$WORK/rw.dmg" -format ULFO -o "$OUT"
if $NOTARIZE; then
  codesign --sign "$IDENTITY" --timestamp "$OUT"
  notarize "$OUT"
  xcrun stapler staple "$OUT"
  spctl --assess --type open --context context:primary-signature --verbose "$OUT"
fi
mkdir -p "$DIST"
mv "$OUT" "$DMG"

if $NOTARIZE; then
  rm -f "$DIST/HOW-TO-OPEN.txt"
else
  cat > "$DIST/HOW-TO-OPEN.txt" <<'TXT'
Installing Yihao's Notch

It isn't from the App Store or a registered Apple developer, so macOS can't check who
made it and asks you to confirm once that you trust it. That's expected, not a fault.

1. Open the .dmg file and drag Yihao's Notch into the Applications folder. (Without
   an administrator account, drag it into the Applications folder inside your home
   folder instead, or ask an administrator.)

2. Open Yihao's Notch from Applications. macOS says:
     "Yihao's Notch" Not Opened. Apple could not verify "Yihao's Notch" is free of
     malware that may harm your Mac or compromise your privacy.
   Click Done (not Move to Trash).

3. Open System Settings > Privacy & Security and scroll to the bottom, under
   Security. Next to "Yihao's Notch" was blocked..., click Open Anyway and enter your
   Mac's password (or use Touch ID). If you don't see it, open the app once more and
   come back: the button only shows for about an hour after macOS blocks the app.

4. macOS asks one last time: click Open Anyway.

The welcome screen takes it from there. You'll need an administrator account for step
3, and to repeat steps 2-4 for each new version. It works on MacBooks with a notch
running macOS 15 or later.

Updating: drag the new version into Applications as before, replacing the old one,
then open it. If it says "Not Opened", repeat steps 2-4. Versions before 1.3.2 don't
notice an update while they're running: if the notch still shows the old version,
right-click the gear in the notch, choose Quit, and open the app again.

Only download it from https://github.com/liuy7713/YihaosNotch/releases: copies from
anywhere else aren't mine. Free and open source under the MIT licence.
TXT
fi

echo
echo "Built $DMG"
echo "SHA-256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
if $ALLOW_DIRTY && [[ -n "$(git status --porcelain)" ]]; then
  echo "A trial image from uncommitted changes: not tagged. Delete it before the real release."
else
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git tag "$TAG"
  echo "Tagged $TAG. Publish with: git push origin HEAD $TAG"
fi
$NOTARIZE || echo "Not notarized: send HOW-TO-OPEN.txt (next to it) along with it."
open -R "$DMG"
