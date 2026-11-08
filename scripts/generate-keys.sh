#!/bin/bash
# Generates the GraphiteOS release signing keys on a Mac and uploads them to GitHub secrets.
#
# The output matches GrapheneOS script/generate-keys followed by script/encrypt-keys:
#   - every <key>.pk8 is DER PKCS#8, encrypted with scrypt using one shared passphrase
#   - avb.pem is PEM PKCS#8, encrypted the same way
#   - <key>.x509.pem certificates and avb_pkmd.bin are public
# This lets GrapheneOS script/decrypt-keys and generate-release.sh read the keys unmodified.
# Private keys are never written to disk unencrypted.
#
# Run this ONCE. If the keys change later, the phone can't install updates unless it is wiped.
#
# Usage: scripts/generate-keys.sh [backup-dir]     (default: ~/GraphiteOS-keys)

set -o errexit -o nounset -o pipefail

readonly REPO=ThreeMuskets12/GraphiteOS
readonly DEVICE=caiman
readonly OUT="${1:-$HOME/GraphiteOS-keys}/$DEVICE"
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly OPENSSL=/opt/homebrew/opt/openssl@3/bin/openssl
# GrapheneOS platform_external_avb, branch 17
readonly AVBTOOL_URL=https://raw.githubusercontent.com/GrapheneOS/platform_external_avb/f95721048ae85220ed80b76b7626982455e53d2a/avbtool.py
readonly AVBTOOL_SHA256=1aa6f2b462aa67aa3fdf488bee83ab517de8ad9d8228c7b45c35267ab2cf6781
# Must match signing_keys in GrapheneOS script/common.sh
readonly signing_keys=(bluetooth gmscompat_lib media networkstack nfc platform releasekey sdk_sandbox shared)

die() { echo "error: $*" >&2; exit 1; }

# --- preflight -------------------------------------------------------------------------------
[[ -x $OPENSSL ]] || die "OpenSSL 3 not found at $OPENSSL (brew install openssl@3)"
command -v gh >/dev/null || die "gh CLI not found"
[[ $(gh api user --jq .login) == ThreeMuskets12 ]] || die "active gh account must be ThreeMuskets12 (gh auth switch -u ThreeMuskets12)"
[[ -e $OUT ]] && die "$OUT already exists, refusing to overwrite existing keys"
if gh secret list --repo "$REPO" | grep -q '^SIGNING_KEYS_'; then
    die "SIGNING_KEYS_* secrets already exist in $REPO, refusing to replace keys"
fi

read -rsp "New key passphrase (20+ characters): " password; echo
read -rsp "Confirm passphrase: " confirm; echo
[[ $password == "$confirm" ]] || die "passphrases do not match"
[[ ${#password} -ge 20 ]] || die "passphrase must be at least 20 characters"
unset confirm
export password

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"; unset password' EXIT

# --- signing keys ----------------------------------------------------------------------------
mkdir -p "$OUT" && chmod 700 "$OUT" && cd "$OUT"
for key in "${signing_keys[@]}"; do
    echo "generating $key"
    pem="$("$OPENSSL" genrsa 4096 2>/dev/null)"
    printf '%s\n' "$pem" | "$OPENSSL" req -new -x509 -sha256 -key /dev/stdin -out "$key.x509.pem" \
        -days 10000 -subj "/CN=GraphiteOS/"
    printf '%s\n' "$pem" | "$OPENSSL" pkcs8 -topk8 -outform DER -out "$key.pk8" -passout env:password -scrypt
    unset pem
done

echo "generating avb"
"$OPENSSL" genrsa 4096 2>/dev/null | "$OPENSSL" pkcs8 -topk8 -scrypt -passout env:password -out avb.pem
"$OPENSSL" pkey -in avb.pem -passin env:password -pubout -out "$tmp/avb_pub.pem"
curl -fsSL "$AVBTOOL_URL" -o "$tmp/avbtool.py"
echo "$AVBTOOL_SHA256  $tmp/avbtool.py" | shasum -a 256 -c --quiet || die "avbtool.py checksum mismatch"
PATH="$(dirname "$OPENSSL"):$PATH" python3 -I "$tmp/avbtool.py" extract_public_key \
    --key "$tmp/avb_pub.pem" --output avb_pkmd.bin
chmod 600 ./*

# --- verify: every encrypted key decrypts with the passphrase and matches its certificate ----
for key in "${signing_keys[@]}"; do
    a="$("$OPENSSL" pkcs8 -inform DER -in "$key.pk8" -passin env:password | "$OPENSSL" pkey -pubout)"
    b="$("$OPENSSL" x509 -in "$key.x509.pem" -pubkey -noout)"
    [[ $a == "$b" ]] || die "verification failed for $key"
done
"$OPENSSL" pkey -in avb.pem -passin env:password -noout || die "verification failed for avb.pem"
echo "all keys verified"

# --- upload encrypted private keys + passphrase to GitHub secrets ----------------------------
tar -czf "$tmp/keys.tgz" ./*.pk8 avb.pem
base64 -i "$tmp/keys.tgz" -o "$tmp/keys.b64"
size=$(wc -c < "$tmp/keys.b64")
[[ $size -lt 48000 ]] || die "key bundle is $size bytes, over GitHub's 48 KB secret limit"
gh secret set SIGNING_KEYS_TGZ_B64 --repo "$REPO" < "$tmp/keys.b64"
printf '%s' "$password" | gh secret set SIGNING_KEYS_PASSPHRASE --repo "$REPO"

# --- public certificates go into the repo ----------------------------------------------------
mkdir -p "$REPO_ROOT/certs/$DEVICE"
cp ./*.x509.pem avb_pkmd.bin "$REPO_ROOT/certs/$DEVICE/"

cat <<EOF

Done.
  Encrypted keys (BACK THESE UP): $OUT
  Public certificates copied to:  $REPO_ROOT/certs/$DEVICE
  GitHub secrets set:             SIGNING_KEYS_TGZ_B64, SIGNING_KEYS_PASSPHRASE
  avb_pkmd.bin SHA-256:           $(shasum -a 256 avb_pkmd.bin | cut -d' ' -f1)

Next:
  1. Copy $OUT to a USB drive and store the passphrase in your password manager.
  2. Without both, the phone can't be updated again without being wiped.
EOF
