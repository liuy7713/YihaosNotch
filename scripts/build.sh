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

# Sign with the local self-signed identity so macOS keeps permissions
# (Calendar, Camera, Automation) across rebuilds. Falls back to ad-hoc.
# The password below only unlocks the throwaway keychain in .signing/ (git-ignored),
# which holds nothing but this one self-signed certificate.
KEYCHAIN="$ROOT/.signing/signing.keychain-db"
if [[ -f "$KEYCHAIN" ]]; then
  security unlock-keychain -p yihaosnotch-local "$KEYCHAIN"
  IDENTITY=$(openssl x509 -in "$ROOT/.signing/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)
  codesign --force --keychain "$KEYCHAIN" --sign "$IDENTITY" "$APP"
else
  echo "warning: no local signing identity, signing ad-hoc (permissions reset on every build)"
  codesign --force --sign - "$APP"
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
