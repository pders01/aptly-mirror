#!/usr/bin/env bash
# Create a sign-only subkey for aptly publishing, export to ./gnupg/ for the
# mirror host. Master key stays on the operator's machine — never copied to the
# server. Subkey expires in 1 year; rotate by re-running with --rotate.
#
# Usage:
#   ./scripts/setup-signing-subkey.sh <master-fingerprint>
#   ./scripts/setup-signing-subkey.sh --rotate <master-fingerprint>
#
# After running:
#   - ./gnupg/ contains a keyring with the master pubkey + signing subkey priv.
#   - ./gnupg/passphrase has the subkey passphrase, mode 0600.
#   - ./gnupg/<fp>.rev is the revocation certificate. Move it OFFLINE.
#   - export GPG_KEY=<subkey fingerprint printed at end>

set -euo pipefail

ROTATE=0
if [[ "${1:-}" == "--rotate" ]]; then
  ROTATE=1
  shift
fi

MASTER_FP="${1:?usage: $0 [--rotate] <master-fingerprint>}"
EXPIRY="${SUBKEY_EXPIRY:-1y}"
OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/gnupg"

if [[ ! -d "$HOME/.gnupg" ]]; then
  echo "no ~/.gnupg on this machine — run on the operator workstation, not the server" >&2
  exit 1
fi

if ! gpg --list-secret-keys "$MASTER_FP" >/dev/null 2>&1; then
  echo "master key $MASTER_FP not found in ~/.gnupg" >&2
  exit 1
fi

echo "==> Adding sign-only subkey, expiry=$EXPIRY"
gpg --quick-add-key "$MASTER_FP" default sign "$EXPIRY"

# Newest signing subkey = the one we just made.
SUBKEY_FP="$(gpg --list-keys --with-colons "$MASTER_FP" \
  | awk -F: '$1=="sub" && $12 ~ /s/ {print $5}' \
  | tail -n1)"

if [[ -z "$SUBKEY_FP" ]]; then
  echo "could not locate new signing subkey" >&2
  exit 1
fi
echo "==> New signing subkey: $SUBKEY_FP"

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

if [[ $ROTATE -eq 0 && -n "$(ls -A "$OUT_DIR" 2>/dev/null)" ]]; then
  echo "$OUT_DIR not empty. Pass --rotate to overwrite." >&2
  exit 1
fi
rm -rf "$OUT_DIR"/* "$OUT_DIR"/.??* 2>/dev/null || true

# Build a fresh keyring inside ./gnupg/ containing only:
#   - master pubkey (verification only)
#   - signing subkey private material
TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT
chmod 700 "$TMP_HOME"

gpg --export "$MASTER_FP"          | gpg --homedir "$TMP_HOME" --import
gpg --export-secret-subkeys "$SUBKEY_FP!" \
                                   | gpg --homedir "$TMP_HOME" --import

# Generate revocation certificate for the subkey. Keep OFFLINE.
gpg --homedir "$TMP_HOME" --output "$OUT_DIR/${SUBKEY_FP}.rev" \
    --gen-revoke "$SUBKEY_FP" <<<$'y\n0\nsubkey rotation\n\ny\n' || true

cp -a "$TMP_HOME"/. "$OUT_DIR"/

# Passphrase for non-interactive aptly publish. Different from master.
read -rsp "Subkey passphrase (will be stored in $OUT_DIR/passphrase): " PASS
echo
printf '%s' "$PASS" > "$OUT_DIR/passphrase"
chmod 600 "$OUT_DIR/passphrase"
unset PASS

# Container UID 1000 needs to read these.
if command -v stat >/dev/null && [[ "$(uname)" == "Linux" ]]; then
  chown -R 1000:1000 "$OUT_DIR" || \
    echo "note: could not chown $OUT_DIR to 1000:1000 — run as root on deploy host"
fi

cat <<EOF

==> Done.

   GPG_KEY=$SUBKEY_FP

Next:
  1. Move $OUT_DIR/${SUBKEY_FP}.rev to OFFLINE storage (USB, paper, password manager).
     If subkey is compromised, import + push this cert to revoke.
  2. Copy $OUT_DIR to the deploy host (rsync / scp). Do NOT commit to git.
  3. On deploy host: chown -R 1000:1000 ./gnupg && chmod 700 ./gnupg
  4. export GPG_KEY=$SUBKEY_FP and run ./update.sh.

EOF
