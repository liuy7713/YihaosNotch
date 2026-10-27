#!/bin/zsh
# Creates the local code-signing identity in ~/.yihaos-notch/signing (see lib-signing.sh).
#
#   ./scripts/make-signing-identity.sh                    new identity, and its backup
#   ./scripts/make-signing-identity.sh --restore FILE.p12 restore that backup
#
# Signing every build with the same identity lets macOS keep the app's permissions
# (Calendar, Camera, Automation, Accessibility) across rebuilds. Restoring a backup
# keeps the *same* identity, so no permission has to be granted again; a new identity
# means granting them all once more.
#
# Anything that can sign with this identity is "Yihao's Notch" as far as macOS is
# concerned, and inherits those permissions. So the identity lives in its own keychain
# whose random password is kept in the login keychain with no trusted apps: reading it
# always shows a system dialog, and nothing can use the key without you clicking Allow.
#
# A new identity's backup is written here, while the private key is still a file:
# once it's in the keychain, exporting it means typing the keychain's password into a
# dialog, and that password is never shown (or put on the clipboard) by design.
set -euo pipefail
umask 077

ROOT="${0:A:h:h}"
source "$ROOT/scripts/lib-signing.sh"

RESTORE=""
if [[ "${1:-}" == "--restore" ]]; then
  RESTORE="${2:?usage: make-signing-identity.sh --restore FILE.p12}"
  [[ -f "$RESTORE" ]] || { echo "error: $RESTORE not found" >&2; exit 1; }
  RESTORE="${RESTORE:A}"
  [[ "$RESTORE" != *[[:space:]]* ]] || { echo "error: move the backup to a path without spaces" >&2; exit 1; }
fi

existing=("$SIGNING_DIR"/*.keychain-db(N))
if (( ${#existing} )); then
  echo "A signing keychain already exists in $SIGNING_DIR. To replace it, first run:"
  echo "  security delete-keychain \"${existing[1]}\" && rm -rf \"$SIGNING_DIR\""
  exit 1
fi
mkdir -p "$SIGNING_DIR"
chmod 700 "$SIGNING_DIR:h" "$SIGNING_DIR"
cd "$SIGNING_DIR"
# A unique name per identity (see signing_keychain in lib-signing.sh).
KC="$SIGNING_DIR/signing-$(date +%Y%m%d-%H%M%S).keychain-db"
[[ "$KC" != *[[:space:]]* ]] || { echo "error: the project path must not contain spaces" >&2; exit 1; }
PASSWORD="$(openssl rand -hex 24)"

BACKUP="$HOME/Documents/YihaosNotch-signing-backup-$(date +%Y%m%d-%H%M%S).p12"
if [[ -n "$RESTORE" ]]; then
  read -rs "BACKUP_PASS?Backup passphrase: "; echo
  # The certificate, for build.sh to find the identity by fingerprint.
  print -r -- "$BACKUP_PASS" | openssl pkcs12 -in "$RESTORE" -clcerts -nokeys -passin stdin -out cert.pem -legacy 2>/dev/null \
    || print -r -- "$BACKUP_PASS" | openssl pkcs12 -in "$RESTORE" -clcerts -nokeys -passin stdin -out cert.pem
  P12="$RESTORE"
  P12_PASS="$BACKUP_PASS"
else
  echo "Choose a passphrase for the identity's backup (at least 12 characters). Keep it"
  echo "in your password manager, with the backup file."
  read -rs "BACKUP_PASS?Backup passphrase: "; echo
  read -rs "BACKUP_PASS2?Again: "; echo
  [[ "$BACKUP_PASS" == "$BACKUP_PASS2" ]] || { echo "error: the passphrases don't match" >&2; exit 1; }
  (( ${#BACKUP_PASS} >= 12 )) || { echo "error: use at least 12 characters" >&2; exit 1; }
  # Restoring hands it to `security` in a command string (see `sec`).
  [[ "$BACKUP_PASS" != *[[:space:]\"\']* ]] || { echo "error: no spaces or quotes, please" >&2; exit 1; }
  unset BACKUP_PASS2
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
  P12="$SIGNING_DIR/id.p12"
  P12_PASS="$PASSWORD"
  # The backup, from the same key file, under the user's passphrase (through stdin,
  # never the command line).
  print -r -- "$BACKUP_PASS" | openssl pkcs12 -export -out "$BACKUP" -inkey key.pem -in cert.pem -passout stdin -legacy 2>/dev/null \
    || print -r -- "$BACKUP_PASS" | openssl pkcs12 -export -out "$BACKUP" -inkey key.pem -in cert.pem -passout stdin
fi

sec "create-keychain -p $PASSWORD $KC"
# Lock on sleep and after 5 minutes, in case a build is interrupted before it locks.
security set-keychain-settings -l -u -t 300 "$KC"
sec "unlock-keychain -p $PASSWORD $KC"
sec "import $P12 -k $KC -P $P12_PASS -T /usr/bin/codesign"
sec "set-key-partition-list -S apple-tool:,apple:,codesign: -s -k $PASSWORD $KC"
rm -f key.pem id.p12
unset P12_PASS BACKUP_PASS

# Self-check: the keychain must unlock with its password before that password is
# stored, or every build would fail later with no way back to the key.
security lock-keychain "$KC"
if ! sec "unlock-keychain -p $PASSWORD $KC"; then
  echo "error: the new keychain doesn't unlock with its password; delete $SIGNING_DIR and try again." >&2
  exit 1
fi
security lock-keychain "$KC"

# Replace any item left by an earlier identity. -T "" trusts no application, so every
# read prompts (click Allow, not Always Allow).
security delete-generic-password -a "$USER" -s "$SIGNING_SERVICE" >/dev/null 2>&1 || true
sec "add-generic-password -a $USER -s $SIGNING_SERVICE -l $SIGNING_SERVICE -w $PASSWORD -T \"\" $HOME/Library/Keychains/login.keychain-db"
unset PASSWORD
chmod 600 "$SIGNING_DIR"/*

echo "Signing identity ready in $SIGNING_DIR ($(openssl x509 -in cert.pem -noout -fingerprint -sha1 | cut -d= -f2 | tr -d : | cut -c1-8)…)."
if [[ -z "$RESTORE" ]]; then
  echo "Its backup is $BACKUP. Move it into your password manager, with its passphrase,"
  echo "and check it once with ./scripts/verify-signing-backup.sh \"$BACKUP\"."
fi
