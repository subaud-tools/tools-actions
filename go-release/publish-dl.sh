#!/usr/bin/env bash
# Publishes every packaged tarball and its .sha256, and each EXTRA_ASSETS file
# with a .sha256 written here, to the family download contract:
# s3://<bucket>/dl/<tool>/<version>/<asset> (immutable, long TTL), then a
# signed receipt beside each (sign-receipts.sh). A version is write-once
# (dl-put.sh): what is already published is compared, never overwritten, so
# a re-run or an asset rebuild with the same files passes and one with
# different files fails.
# With PROMOTE=true (a created, non-prerelease release) it also writes
# /dl/<tool>/latest = the bare semver (short TTL) and invalidates it, but
# only when no release tag on origin (<prefix>X.Y.Z, the prefix being TAG
# without v$VERSION) is higher than VERSION: latest only moves up. A failed
# tag listing fails the step. An rc pre-release or an asset rebuild publishes
# versioned paths only. latest is written last, so it never names a version
# without receipts.
#
# Env: DL_TOOL, BUCKET, VERSION, RECEIPT_KEY_ARN, TAG (with PROMOTE=true), PROMOTE (true|false), DISTRIBUTION_ID,
#      EXTRA_ASSETS (newline/space-separated globs, already in dist/).
set -euo pipefail
sum() { if command -v shasum >/dev/null; then shasum -a 256 "$@"; else sha256sum "$@"; fi; }
: "${DL_TOOL:?}" "${BUCKET:?}" "${VERSION:?}" "${RECEIPT_KEY_ARN:?RECEIPT_KEY_ARN is required: a /dl release publishes signed receipts}"
shopt -s nullglob
files=(dist/*.tar.gz)
[ ${#files[@]} -gt 0 ] || { echo "::error::go-release: no tarballs in dist/ to publish"; exit 1; }
# shellcheck source=go-release/assets.sh
source "$(dirname "${BASH_SOURCE[0]}")/assets.sh"
collect_assets "${files[@]}"
for f in ${extras[@]+"${extras[@]}"}; do
  ( cd dist && sum "$(basename "$f")" > "$(basename "$f").sha256" )
done
# shellcheck source=go-release/dl-put.sh
source "$(dirname "${BASH_SOURCE[0]}")/dl-put.sh"
# The sidecars go first: a version published with different files fails
# here, before any of this run's files is sent.
for f in "${assets[@]}"; do put_once "$f.sha256" --content-type text/plain; done
for f in "${assets[@]}"; do put_once "$f"; done
bash "$(dirname "${BASH_SOURCE[0]}")/sign-receipts.sh" "${assets[@]}"
if [ "${PROMOTE:-false}" = true ]; then
  : "${DISTRIBUTION_ID:?DISTRIBUTION_ID is required to move latest}"
  semver='^[0-9]+\.[0-9]+\.[0-9]+$'
  [[ $VERSION =~ $semver ]] || { echo "::error::go-release: cannot promote '$VERSION': not a bare semver"; exit 1; }
  : "${TAG:?TAG is required to move latest}"
  # The tag prefix: v for v1.2.3, proj/v for proj/v1.2.3.
  [[ $TAG == *"v$VERSION" ]] || { echo "::error::go-release: TAG '$TAG' does not end with v$VERSION"; exit 1; }
  prefix="${TAG%"v$VERSION"}v"
  # ls-remote's pattern matches ref tails (refs/tags/v* also lists proj/v1.0.0),
  # so the exact <prefix>X.Y.Z filter below is what counts.
  refs="$(git ls-remote --tags --refs origin "refs/tags/${prefix}*")" \
    || { echo "::error::go-release: could not list the release tags on origin"; exit 1; }
  # higher A B: A > B, comparing major, minor and patch numerically.
  higher() {
    local IFS=. i; local -a a b
    read -r -a a <<<"$1"; read -r -a b <<<"$2"
    for i in 0 1 2; do
      if ((10#${a[i]} != 10#${b[i]})); then ((10#${a[i]} > 10#${b[i]})); return; fi
    done
    return 1
  }
  while read -r _ ref; do
    [[ $ref == "refs/tags/$prefix"* ]] || continue
    v="${ref#"refs/tags/$prefix"}"
    if [[ $v =~ $semver ]] && higher "$v" "$VERSION"; then
      echo "not moving /dl/$DL_TOOL/latest: $prefix$v is higher"
      exit 0
    fi
  done <<<"$refs"
  printf '%s' "$VERSION" | aws s3 cp - "s3://$BUCKET/dl/$DL_TOOL/latest" \
    --content-type text/plain --cache-control 'public,max-age=60,must-revalidate'
  aws cloudfront create-invalidation --distribution-id "$DISTRIBUTION_ID" --paths "/dl/$DL_TOOL/latest"
  echo "latest -> $VERSION"
else
  echo "not moving /dl/$DL_TOOL/latest (pre-release or asset rebuild)"
fi
