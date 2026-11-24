#!/bin/zsh
# Everything worth checking before a commit or a release, in under a minute and with no
# signing (so no Allow dialog): a debug build, the tests, the plists and the scripts'
# syntax.
#
#   ./scripts/check.sh
#
# Tests never touch Calendar, the camera, Apple events or event taps (those would ask
# for permissions on behalf of Terminal, or control the real Music app).
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
# Outside the project, which may sync to iCloud (see build.sh).
SCRATCH="$HOME/Library/Caches/YihaosNotch/.build-check"
# On GitHub Actions (CI is set), a failure also prints the full output, folded.
full_output() {
  [[ -z "${CI:-}" ]] && return
  print "::group::Full output"; print -r -- "$1"; print "::endgroup::"
}

echo "› Plists"
plutil -lint -s Resources/*.plist Resources/*.entitlements
echo "› Script syntax"
for script in scripts/*.sh; do zsh -n "$script"; done
# Quiet unless something's wrong: warnings are shown, failures show the full output.
echo "› Build"
if ! out="$(swift build --scratch-path "$SCRATCH" 2>&1)"; then
  # The compiler's messages, without the build system's command lines.
  print -r -- "$out" | grep -E "(error|warning): " | grep -v "nonzero exit code" | head -40 || true
  full_output "$out"
  exit 1
fi
print -r -- "$out" | grep "warning:" || true
echo "› Tests"
if ! out="$(swift test --scratch-path "$SCRATCH" 2>&1)"; then
  # Compiler errors, or the failing tests and their issues.
  print -r -- "$out" | grep -E "(error|warning): |✘|↳" | grep -v "nonzero exit code" | head -60 || true
  full_output "$out"
  exit 1
fi
print -r -- "$out" | grep -E "^.*Test run with" || true
echo "All checks passed."
