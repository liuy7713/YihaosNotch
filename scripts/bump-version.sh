#!/bin/zsh
# Raises the app's version in Resources/Info.plist before a release.
#
#   ./scripts/bump-version.sh patch   # 1.1.0 → 1.1.1   fixes only
#   ./scripts/bump-version.sh minor   # 1.1.0 → 1.2.0   new features
#   ./scripts/bump-version.sh major   # 1.1.0 → 2.0.0   big changes
#
# The build number (CFBundleVersion) goes up by one every time, whatever the part:
# macOS compares it to tell which of two copies is newer.
set -euo pipefail

ROOT="${0:A:h:h}"
PLIST="$ROOT/Resources/Info.plist"
PART="${1:?usage: bump-version.sh patch|minor|major}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")"
[[ "$VERSION" =~ '^([0-9]+)\.([0-9]+)\.([0-9]+)$' ]] || { echo "error: unexpected version \"$VERSION\"" >&2; exit 1; }
major=$match[1] minor=$match[2] patch=$match[3]

case "$PART" in
  patch) patch=$((patch + 1)) ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  major) major=$((major + 1)); minor=0; patch=0 ;;
  *) echo "usage: bump-version.sh patch|minor|major" >&2; exit 1 ;;
esac

NEW="$major.$minor.$patch"
NEW_BUILD=$((BUILD + 1))
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $NEW" -c "Set CFBundleVersion $NEW_BUILD" "$PLIST"
echo "$VERSION ($BUILD) → $NEW ($NEW_BUILD)"
