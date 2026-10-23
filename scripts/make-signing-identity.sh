#!/bin/zsh
# Creates a local self-signed code-signing identity in .signing/ (git-ignored).
#
# Signing every build with the same identity lets macOS keep the app's permissions
# (Calendar, Camera, Automation, Accessibility) across rebuilds; ad-hoc signing would
# reset them each time.
#
# Anything that can sign with this identity is "Yihao's Notch" as far as macOS is
# concerned, and inherits those permissions. So the identity lives in its own keychain
# whose random password is kept in the login keychain with no trusted apps: reading it
# always shows a system dialog, and nothing can use the key without you clicking Allow.
set -euo pipefail

ROOT="${0:A:h:h}"
DIR="$ROOT/.signing"
SERVICE=YihaosNotchSigning
if [[ -f "$DIR/signing.keychain-db" ]]; then
  echo "A signing identity already exists in .signing/. Delete that folder to make a new one."
  exit 1
fi
# A stale item from an earlier identity would no longer match the new keychain.
security delete-generic-password -a "$USER" -s "$SERVICE" >/dev/null 2>&1 || true
mkdir -p "$DIR"
cd "$DIR"

# Absolute path: given a bare name, `security` would put the keychain in ~/Library/Keychains.
KC="$DIR/signing.keychain-db"
PASSWORD="$(openssl rand -hex 24)"
[[ "$KC" != *[[:space:]]* ]] || { echo "error: the project path must not contain spaces" >&2; exit 1; }

# Every command that takes the password goes through `security -i` on stdin, so the
# password never appears on a command line, where `ps` would show it to any process.
# `security -i` exits 0 even when a command fails, so look at what it printed instead.
# Only the command's name is reported, never the line itself (it holds the password).
sec() {
  local out
  out="$(print -r -- "$1" | security -i 2>&1)"
  if [[ "$out" == *"returned -"* || "$out" == *"security: "* ]]; then
    print -r -- "error: security ${1%% *} failed" >&2
    return 1
  fi
}

# -T "" trusts no application, so every read prompts (click Allow, not Always Allow).
sec "add-generic-password -a $USER -s $SERVICE -l YihaosNotchSigning -w $PASSWORD -T \"\" $HOME/Library/Keychains/login.keychain-db"

cat > cert.cnf <<'CNF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Yihaos Notch Local Signing
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -config cert.cnf 2>/dev/null
print -r -- "$PASSWORD" | openssl pkcs12 -export -out id.p12 -inkey key.pem -in cert.pem -passout stdin -legacy 2>/dev/null \
  || print -r -- "$PASSWORD" | openssl pkcs12 -export -out id.p12 -inkey key.pem -in cert.pem -passout stdin

sec "create-keychain -p $PASSWORD $KC"
# Lock on sleep and after 5 minutes, in case a build is interrupted before it locks.
security set-keychain-settings -l -u -t 300 "$KC"
sec "unlock-keychain -p $PASSWORD $KC"
sec "import id.p12 -k $KC -P $PASSWORD -T /usr/bin/codesign"
sec "set-key-partition-list -S apple-tool:,apple:,codesign: -s -k $PASSWORD $KC"
rm -f key.pem id.p12

# Self-check: the keychain must unlock with the password just stored in the login
# keychain, or every build would fail later with no way to recover the key.
security lock-keychain "$KC"
if ! sec "unlock-keychain -p $PASSWORD $KC"; then
  echo "error: the new keychain doesn't unlock with its password; delete .signing/ and try again." >&2
  exit 1
fi
unset PASSWORD
security lock-keychain "$KC"
chmod 600 "$DIR"/*

echo "Created a signing identity in .signing/. Build with ./scripts/build.sh"
