#!/bin/zsh
# Publishes the current version as a GitHub Release, after release.sh has built it and
# the branch and tag are pushed:
#
#   ./scripts/publish-release.sh [NOTES.md]
#
# NOTES.md is what's new, in words for people using the app; without it the tagged
# commit's message is used.
#
# Uploads the disk image twice, as YihaosNotch-<version>.dmg and as YihaosNotch.dmg, so
# releases/latest/download/YihaosNotch.dmg (the README's download link) always gets the
# newest one, plus HOW-TO-OPEN.txt when the build isn't notarized. The notes give the
# image's SHA-256 and the signing certificate's hash, so people can check their copy.
# Needs the GitHub CLI (gh), signed in.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

PLIST="$ROOT/Resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
TAG="v$VERSION"
DMG="$ROOT/dist/YihaosNotch-$VERSION.dmg"
HOW_TO="$ROOT/dist/HOW-TO-OPEN.txt"
APP="$HOME/Library/Caches/YihaosNotch/Yihao's Notch.app"

[[ -f "$DMG" ]] || { echo "error: $DMG not found; run scripts/release.sh first" >&2; exit 1; }
git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null \
  || { echo "error: $TAG isn't on GitHub yet: git push origin HEAD $TAG" >&2; exit 1; }
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "error: a release for $TAG already exists" >&2; exit 1
fi

SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
# The leaf hash names the certificate that signed this build; it's public, not a secret.
LEAF="$(codesign -d -r- "$APP" 2>&1 | grep -o 'certificate leaf = H"[0-9a-f]*"' || true)"
if [[ -n "${1:-}" ]]; then
  CHANGES="$(<"$1")"
else
  CHANGES="$(git log -1 --format=%B "$TAG")"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$DMG" "$WORK/YihaosNotch.dmg"

{
  print -r -- "$CHANGES"
  print
  print -r -- "**Download:** YihaosNotch.dmg below. Needs a MacBook with a notch and macOS 15 or later."
  if [[ -f "$HOW_TO" ]]; then
    print
    print -r -- "This build isn't notarized by Apple, so macOS asks you to allow it once: open the app,"
    print -r -- "click Done (not the blue Move to Bin button), then System Settings › Privacy & Security ›"
    print -r -- "Open Anyway. Step by step: HOW-TO-OPEN.txt below, or the README."
  fi
  print
  print -r -- "Only download it from this page. To check your copy:"
  print
  print -r -- '```'
  print -r -- "shasum -a 256 ~/Downloads/YihaosNotch.dmg"
  print -r -- "→ $SHA"
  if [[ -n "$LEAF" ]]; then
    print -r -- "codesign -d -r- \"/Applications/Yihao's Notch.app\""
    print -r -- "→ … $LEAF"
  fi
  print -r -- '```'
} > "$WORK/notes.md"

ASSETS=("$DMG" "$WORK/YihaosNotch.dmg")
[[ -f "$HOW_TO" ]] && ASSETS+=("$HOW_TO")

gh release create "$TAG" --verify-tag --title "Yihao's Notch $VERSION" \
  --notes-file "$WORK/notes.md" "${ASSETS[@]}"
echo "Published $TAG: https://github.com/liuy7713/YihaosNotch/releases/tag/$TAG"
