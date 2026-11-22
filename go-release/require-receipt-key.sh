#!/usr/bin/env bash
# Fails before anything is built when the release would publish to /dl without
# signed receipts: dl-tool is set and receipt-key-arn is empty.
#
# Env: DL_TOOL, RECEIPT_KEY_ARN.
set -euo pipefail
if [ -n "${DL_TOOL:-}" ] && [ -z "${RECEIPT_KEY_ARN:-}" ]; then
  echo "::error::go-release: receipt-key-arn is required when dl-tool is set (pass \${{ vars.RELEASE_RECEIPT_KEY_ARN }}): a /dl release must publish signed receipts"
  exit 1
fi
