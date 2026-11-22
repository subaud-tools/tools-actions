#!/usr/bin/env bash
# Publishes a signed receipt beside each file given (already published under
# s3://<bucket>/dl/<tool>/<version>/):
#   <file>.receipt      {"tool":"<tool>","version":"<version>","file":"<file name>","sha256":"<hex>"}
#                       exactly these fields in this order, compact, one trailing newline
#   <file>.receipt.sig  base64 of the Ed25519 signature over the receipt's exact bytes
# The signature is made by the KMS key RECEIPT_KEY_ARN with ED25519_SHA_512 over
# the RAW message: plain Ed25519, which Go's ed25519.Verify accepts (the
# prehash algorithm would not verify). Before a receipt is uploaded its
# signature is checked against the key's public half from KMS with
# verify-receipt (Go's crypto/ed25519), independent of the signer. Receipts
# are write-once like the files: a published receipt must equal this one, and
# its published signature must verify.
#
# Usage: sign-receipts.sh FILE...
# Env: DL_TOOL, BUCKET, VERSION, RECEIPT_KEY_ARN. Needs go and aws.
set -euo pipefail
sum() { if command -v shasum >/dev/null; then shasum -a 256 "$@"; else sha256sum "$@"; fi; }
: "${DL_TOOL:?}" "${BUCKET:?}" "${VERSION:?}" "${RECEIPT_KEY_ARN:?}"
here="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=go-release/dl-put.sh
source "$here/dl-put.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
GOOS='' GOARCH='' go build -o "$tmp/verify-receipt" "$here/verify-receipt/main.go"
aws kms get-public-key --key-id "$RECEIPT_KEY_ARN" --query PublicKey --output text > "$tmp/key.pub.b64"
plain='^[A-Za-z0-9._+-]+$'
for f in "$@"; do
  base="$(basename "$f")"
  # The receipt is written without a JSON encoder, so its values must need no escaping.
  [[ $DL_TOOL =~ $plain && $VERSION =~ $plain && $base =~ $plain ]] \
    || { echo "::error::go-release: cannot write a receipt for '$DL_TOOL' '$VERSION' '$base': letters, digits, . _ + - only"; exit 1; }
  hex="$(sum "$f")"; hex="${hex%% *}"
  printf '{"tool":"%s","version":"%s","file":"%s","sha256":"%s"}\n' "$DL_TOOL" "$VERSION" "$base" "$hex" > "$f.receipt"
  aws kms sign --key-id "$RECEIPT_KEY_ARN" --message "fileb://$f.receipt" --message-type RAW \
    --signing-algorithm ED25519_SHA_512 --query Signature --output text > "$f.receipt.sig"
  "$tmp/verify-receipt" "$tmp/key.pub.b64" "$f.receipt" "$f.receipt.sig" \
    || { echo "::error::go-release: the receipt signature for $base does not verify against the KMS public key"; exit 1; }
  put_once "$f.receipt" --content-type application/json
  # Whatever signature is published must be a valid one over this receipt.
  put_new "$f.receipt.sig" --content-type text/plain
  read_published "$base.receipt.sig" "$tmp/published.sig"
  "$tmp/verify-receipt" "$tmp/key.pub.b64" "$f.receipt" "$tmp/published.sig" \
    || { echo "::error::go-release: the published receipt signature for $base does not verify; cut a new version"; exit 1; }
done
echo "receipts published for ${#} file(s)"
