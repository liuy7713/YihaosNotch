#!/bin/zsh
# Saves the signing identity to an encrypted .p12, so it can be restored with
# `make-signing-identity.sh --restore FILE.p12` if its keychain ever breaks.
# Restoring the same identity keeps every permission the app has been granted.
#
#   ./scripts/backup-signing-identity.sh [OUTPUT.p12]
#
# Keep the file somewhere safe outside this repo, and its passphrase in your password
# manager: together they let anyone sign as this app.
set -euo pipefail
umask 077

ROOT="${0:A:h:h}"
source "$ROOT/scripts/lib-signing.sh"

KC="$(signing_keychain)" || { echo "error: no signing keychain in $SIGNING_DIR" >&2; exit 1; }
OUT="${1:-$HOME/Documents/YihaosNotch-signing-backup.p12}"
OUT="${OUT:A}"
[[ ! -e "$OUT" ]] || { echo "error: $OUT already exists" >&2; exit 1; }
[[ "$OUT" != *[[:space:]]* ]] || { echo "error: choose an output path without spaces" >&2; exit 1; }

echo "Choose a passphrase for the backup (at least 12 characters; letters, digits and"
echo "symbols, but no spaces or quotes). Keep it in your password manager."
read -rs "PASS1?Backup passphrase: "; echo
read -rs "PASS2?Again: "; echo
[[ "$PASS1" == "$PASS2" ]] || { echo "error: the passphrases don't match" >&2; exit 1; }
(( ${#PASS1} >= 12 )) || { echo "error: use at least 12 characters" >&2; exit 1; }
[[ "$PASS1" != *[[:space:]\"\']* ]] || { echo "error: no spaces or quotes, please" >&2; exit 1; }

echo "macOS will ask to let \"security\" use \"$SIGNING_SERVICE\". Click Allow."
PASSWORD="$(read_signing_password)"
# Lock the keychain and wipe the clipboard however the script ends.
trap 'security lock-keychain "$KC" 2>/dev/null; pbcopy </dev/null' EXIT
sec "unlock-keychain -p $PASSWORD $KC"

# macOS always asks for the signing keychain's own password before a private key can
# be exported. That password is random and never shown, so while the export dialog is
# open the script keeps it on the clipboard (marked concealed, so clipboard-history
# apps skip it; refreshed every second in case something else gets copied), and wipes
# the clipboard as soon as the export ends.
copy_concealed() {
  print -rn -- "$1" | osascript -l JavaScript -e '
    ObjC.import("AppKit");
    var data = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
    var pb = $.NSPasteboard.generalPasteboard;
    pb.clearContents;
    pb.setStringForType($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding), $.NSPasteboardTypeString);
    pb.setStringForType($(""), $("org.nspasteboard.ConcealedType"));' >/dev/null
}
echo
echo "Next, a dialog asks for the password of the \"signing\" keychain. It's on your"
echo "clipboard: click into the password field, press Cmd-V, then click Allow."
echo
sec "export -k $KC -t identities -f pkcs12 -P $PASS1 -o $OUT" &
export_pid=$!
while kill -0 $export_pid 2>/dev/null; do
  copy_concealed "$PASSWORD"
  sleep 1
done
pbcopy </dev/null
unset PASSWORD
wait $export_pid || { echo "error: the export didn't complete (was the dialog denied?)" >&2; exit 1; }
unset PASS1 PASS2
[[ -s "$OUT" ]] || { echo "error: no backup was written" >&2; exit 1; }

echo "Saved $OUT. Move it somewhere safe (a password manager can store it as an attachment)."
