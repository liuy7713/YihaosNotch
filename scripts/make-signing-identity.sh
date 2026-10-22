#!/bin/zsh
# Creates a local self-signed code-signing identity in .signing/ (git-ignored).
#
# Signing every build with the same identity lets macOS keep the app's permissions
# (Calendar, Camera, Automation, Accessibility) across rebuilds; ad-hoc signing would
# reset them each time. The identity lives in its own keychain, unlocked with a
# random password stored next to it, so the login keychain is never touched.
set -euo pipefail

ROOT="${0:A:h:h}"
DIR="$ROOT/.signing"
if [[ -f "$DIR/signing.keychain-db" ]]; then
  echo "A signing identity already exists in .signing/. Delete that folder to make a new one."
  exit 1
fi
mkdir -p "$DIR"
cd "$DIR"

PASSWORD="$(openssl rand -hex 24)"
print -r -- "$PASSWORD" > password
chmod 600 password

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
openssl pkcs12 -export -out id.p12 -inkey key.pem -in cert.pem -passout "pass:$PASSWORD" -legacy 2>/dev/null \
  || openssl pkcs12 -export -out id.p12 -inkey key.pem -in cert.pem -passout "pass:$PASSWORD"

security create-keychain -p "$PASSWORD" signing.keychain-db
security set-keychain-settings signing.keychain-db
security unlock-keychain -p "$PASSWORD" signing.keychain-db
security import id.p12 -k signing.keychain-db -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" signing.keychain-db >/dev/null
rm -f key.pem id.p12

echo "Created a signing identity in .signing/. Build with ./scripts/build.sh"
