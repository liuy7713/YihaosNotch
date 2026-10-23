#!/bin/zsh
# Checks that a signing backup opens with its passphrase and holds the same identity
# the app is signed with (and so the one its permissions are tied to).
#
#   ./scripts/verify-signing-backup.sh [BACKUP.p12]
set -euo pipefail

ROOT="${0:A:h:h}"
BACKUP="${1:-$HOME/Documents/YihaosNotch-signing-backup.p12}"
[[ -f "$BACKUP" ]] || { echo "error: $BACKUP not found" >&2; exit 1; }
[[ -f "$ROOT/.signing/cert.pem" ]] || { echo "error: no signing identity in .signing/" >&2; exit 1; }

read -rs "PASS?Backup passphrase: "; echo
# The passphrase goes through stdin, never the command line.
backup_fp="$( { print -r -- "$PASS" | openssl pkcs12 -in "$BACKUP" -nokeys -clcerts -passin stdin -legacy 2>/dev/null \
  || print -r -- "$PASS" | openssl pkcs12 -in "$BACKUP" -nokeys -clcerts -passin stdin 2>/dev/null; } \
  | openssl x509 -noout -fingerprint -sha1 2>/dev/null || true)"
key_ok="$( { print -r -- "$PASS" | openssl pkcs12 -in "$BACKUP" -nocerts -nodes -passin stdin -legacy 2>/dev/null \
  || print -r -- "$PASS" | openssl pkcs12 -in "$BACKUP" -nocerts -nodes -passin stdin 2>/dev/null; } \
  | grep -c "PRIVATE KEY-----" || true)"
unset PASS
app_fp="$(openssl x509 -in "$ROOT/.signing/cert.pem" -noout -fingerprint -sha1)"

if [[ -z "$backup_fp" ]]; then
  echo "Couldn't open the backup: wrong passphrase, or the file is damaged."
  exit 1
elif [[ "$backup_fp" != "$app_fp" ]]; then
  echo "The backup holds a DIFFERENT identity from the one the app is signed with."
  exit 1
elif (( key_ok < 1 )); then
  echo "The backup has the right certificate but no private key; it can't be restored."
  exit 1
fi
echo "Backup OK: same identity as the app (${${app_fp#*=}[1,11]}…), with its private key."
