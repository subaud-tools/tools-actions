#!/usr/bin/env bash
# Publishes every packaged tarball and its .sha256, and each EXTRA_ASSETS file
# with a .sha256 written here, to the family download contract:
# s3://<bucket>/dl/<tool>/<version>/<asset> (immutable, long TTL).
# With PROMOTE=true (a created, non-prerelease release) it also writes
# /dl/<tool>/latest = the bare semver (short TTL) and invalidates it, but only
# when there is no pointer yet or VERSION is higher than the one there: latest
# only moves up. Any failure to read the pointer other than a missing object
# fails the step. An rc pre-release or an asset rebuild publishes versioned
# paths only.
#
# Env: DL_TOOL, BUCKET, VERSION, PROMOTE (true|false), DISTRIBUTION_ID,
#      EXTRA_ASSETS (newline/space-separated globs, already in dist/).
set -euo pipefail
sum() { if command -v shasum >/dev/null; then shasum -a 256 "$@"; else sha256sum "$@"; fi; }
: "${DL_TOOL:?}" "${BUCKET:?}" "${VERSION:?}"
shopt -s nullglob
files=(dist/*.tar.gz)
[ ${#files[@]} -gt 0 ] || { echo "::error::go-release: no tarballs in dist/ to publish"; exit 1; }
# shellcheck source=go-release/assets.sh
source "$(dirname "${BASH_SOURCE[0]}")/assets.sh"
collect_assets "${files[@]}"
for f in ${extras[@]+"${extras[@]}"}; do
  ( cd dist && sum "$(basename "$f")" > "$(basename "$f").sha256" )
done
immutable='public,max-age=31536000,immutable'
for f in "${assets[@]}"; do
  base="$(basename "$f")"
  aws s3 cp "$f"        "s3://$BUCKET/dl/$DL_TOOL/$VERSION/$base"        --cache-control "$immutable"
  aws s3 cp "$f.sha256" "s3://$BUCKET/dl/$DL_TOOL/$VERSION/$base.sha256" --cache-control "$immutable" --content-type text/plain
done
if [ "${PROMOTE:-false}" = true ]; then
  : "${DISTRIBUTION_ID:?DISTRIBUTION_ID is required to move latest}"
  semver='^[0-9]+\.[0-9]+\.[0-9]+$'
  [[ $VERSION =~ $semver ]] || { echo "::error::go-release: cannot promote '$VERSION': not a bare semver"; exit 1; }
  err="$(mktemp)"; trap 'rm -f "$err"' EXIT
  if current="$(aws s3 cp "s3://$BUCKET/dl/$DL_TOOL/latest" - 2>"$err")"; then
    current="$(printf '%s' "$current" | tr -d '[:space:]')"
    [[ $current =~ $semver ]] || { echo "::error::go-release: /dl/$DL_TOOL/latest holds '$current', not a bare semver"; exit 1; }
  elif grep -qE 'NoSuchKey|\(404\)|does not exist' "$err"; then
    current=""
  else
    cat "$err" >&2
    echo "::error::go-release: could not read /dl/$DL_TOOL/latest"; exit 1
  fi
  # higher A B: A > B, comparing major, minor and patch numerically.
  higher() {
    local IFS=. i; local -a a b
    read -r -a a <<<"$1"; read -r -a b <<<"$2"
    for i in 0 1 2; do
      if ((10#${a[i]} != 10#${b[i]})); then ((10#${a[i]} > 10#${b[i]})); return; fi
    done
    return 1
  }
  if [ -n "$current" ] && ! higher "$VERSION" "$current"; then
    echo "not moving /dl/$DL_TOOL/latest: it is already $current"
    exit 0
  fi
  printf '%s' "$VERSION" | aws s3 cp - "s3://$BUCKET/dl/$DL_TOOL/latest" \
    --content-type text/plain --cache-control 'public,max-age=60,must-revalidate'
  aws cloudfront create-invalidation --distribution-id "$DISTRIBUTION_ID" --paths "/dl/$DL_TOOL/latest"
  echo "latest -> $VERSION"
else
  echo "not moving /dl/$DL_TOOL/latest (pre-release or asset rebuild)"
fi
