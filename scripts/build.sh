#!/bin/zsh
# Builds "Yihao's Notch.app" into ./build.
#   --install   also copy it to ~/Applications and (re)launch it
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

# Use full Xcode when present (SwiftUI's @State macro needs its plugins), without
# requiring `xcode-select` to be switched system-wide.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

APP_NAME="Yihao's Notch"
APP="$ROOT/build/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"

swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/YihaosNotch" "$APP/Contents/MacOS/YihaosNotch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Sign with the local self-signed identity (see scripts/make-signing-identity.sh) so
# macOS keeps permissions across rebuilds. Falls back to ad-hoc signing.
# Hardened runtime: blocks DYLD_INSERT_LIBRARIES-style injection, which would otherwise
# let other software borrow the app's Camera, Calendar and Accessibility permissions.
ENTITLEMENTS="$ROOT/Resources/YihaosNotch.entitlements"
KEYCHAIN="$ROOT/.signing/signing.keychain-db"
if [[ -f "$KEYCHAIN" && -f "$ROOT/.signing/password" ]]; then
  security unlock-keychain -p "$(<"$ROOT/.signing/password")" "$KEYCHAIN"
  IDENTITY=$(openssl x509 -in "$ROOT/.signing/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)
  codesign --force --options runtime --entitlements "$ENTITLEMENTS" \
           --keychain "$KEYCHAIN" --sign "$IDENTITY" "$APP"
  # Lock again straight away, so the key can't be used by anything else between builds.
  security lock-keychain "$KEYCHAIN"
else
  echo "warning: no local signing identity, signing ad-hoc (permissions reset on every build)."
  echo "         Run ./scripts/make-signing-identity.sh once to fix that."
  codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign - "$APP"
fi

echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x YihaosNotch 2>/dev/null && sleep 0.5 || true
  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALL_DIR/$APP_NAME.app"
  ditto "$APP" "$INSTALL_DIR/$APP_NAME.app"
  open "$INSTALL_DIR/$APP_NAME.app"
  echo "Installed and launched $INSTALL_DIR/$APP_NAME.app"
fi
