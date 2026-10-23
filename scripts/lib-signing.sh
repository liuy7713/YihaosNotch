# Shared by the signing scripts (sourced, not run). Expects ROOT to be set.
#
# The identity lives in its own keychain in .signing/. Its random password is kept in
# the login keychain with no trusted apps, so reading it always shows a system dialog.

SIGNING_DIR="$ROOT/.signing"
SIGNING_SERVICE=YihaosNotchSigning

# Runs one `security` command line through stdin, so passwords in it never appear on
# a command line (where `ps` would show them to any process). `security -i` exits 0
# even when the command fails, so its output is checked instead; only the command's
# name is reported, never the line (which holds the secret).
sec() {
  local out
  out="$(print -r -- "$1" | security -i 2>&1)"
  if [[ "$out" == *"returned -"* || "$out" == *"security: "* ]]; then
    print -r -- "error: security ${1%% *} failed" >&2
    return 1
  fi
}

# The identity's keychain. Each identity gets its own file name: macOS keeps state per
# keychain path, and recreating a keychain at a path it has seen before can leave it
# rejecting its own password.
signing_keychain() {
  local keychains=("$SIGNING_DIR"/*.keychain-db(N))
  (( ${#keychains} == 1 )) || return 1
  [[ "${keychains[1]}" != *[[:space:]]* ]] || { print -r -- "error: the project path must not contain spaces" >&2; return 1; }
  print -r -- "${keychains[1]}"
}

# Shows the macOS dialog; click Allow (not Always Allow).
read_signing_password() {
  security find-generic-password -a "$USER" -s "$SIGNING_SERVICE" -w
}
