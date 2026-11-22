#!/usr/bin/env bash
# A published version is write-once. Sourced by publish-dl.sh and
# sign-receipts.sh.
#
# put_new FILE [aws s3 cp options]: publishes FILE to the version's path,
#   s3://$BUCKET/dl/$DL_TOOL/$VERSION/<name>, only if nothing is there yet.
#   --no-overwrite sends If-None-Match: * (AWS CLI 2.33.0 or newer); an
#   existing object is kept and the command still exits 0.
# read_published NAME OUT: downloads what is published as NAME to OUT.
# put_once FILE [options]: put_new, then requires the published object to
#   equal FILE: the same bytes pass, different bytes fail the release.
#
# Env: BUCKET, DL_TOOL, VERSION.
put_new() {
  local file="$1"; shift
  aws s3 cp "$file" "s3://$BUCKET/dl/$DL_TOOL/$VERSION/$(basename "$file")" \
    --no-overwrite --cache-control 'public,max-age=31536000,immutable' "$@"
}
read_published() {
  local url="s3://$BUCKET/dl/$DL_TOOL/$VERSION/$1"
  aws s3 cp "$url" - > "$2" \
    || { echo "::error::go-release: could not read $url back (the role needs s3:GetObject on dl/*)"; exit 1; }
}
put_once() {
  local file="$1" name published
  name="$(basename "$file")"
  put_new "$@"
  published="$(mktemp)"
  read_published "$name" "$published"
  if ! cmp -s "$published" "$file"; then
    rm -f "$published"
    echo "::error::go-release: $DL_TOOL $VERSION is already published with different files ($name); cut a new version"
    exit 1
  fi
  rm -f "$published"
}
