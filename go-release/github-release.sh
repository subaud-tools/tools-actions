#!/usr/bin/env bash
# Creates the GitHub release (CREATE=true) and uploads the packaged assets:
# tarballs, their .sha256 files, checksums.txt and EXTRA_ASSETS. --clobber, so
# an asset-rebuild run replaces a release's assets in place.
# GITHUB_RELEASE=false skips all of it (a private repo publishes only to /dl)
# but still, when CREATE=true, pushes the annotated tag TAG at GITHUB_SHA (the
# tag gh release create would have made): release-version reads that tag to
# know the version is out. A tag already on origin (a pushed prefixed tag) is
# left as it is.
#
# Env: TAG, CREATE, PRERELEASE, TITLE, EXTRA_ASSETS, GITHUB_RELEASE,
#      GITHUB_REPOSITORY, GITHUB_SHA, GH_TOKEN.
set -euo pipefail
shopt -s nullglob
if [ "${GITHUB_RELEASE:-true}" = false ]; then
  echo "github-release is false: no GitHub release created or uploaded."
  if [ "${CREATE:-false}" = true ]; then
    rc=0; git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null || rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "tag $TAG is already on origin."
    elif [ "$rc" -eq 2 ]; then
      git -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
        tag -a "$TAG" "$GITHUB_SHA" -m "$TAG"
      git push origin "refs/tags/$TAG"
    else
      echo "::error::github-release: cannot tell whether $TAG is on origin" >&2; exit 1
    fi
  fi
  exit 0
fi
if [ "${CREATE:-false}" = true ]; then
  args=(release create "$TAG" --repo "$GITHUB_REPOSITORY" --target "$GITHUB_SHA" --title "${TITLE:-$TAG}" --generate-notes)
  [ "${PRERELEASE:-false}" = true ] && args+=(--prerelease)
  gh "${args[@]}"
fi
# shellcheck source=go-release/assets.sh
source "$(dirname "${BASH_SOURCE[0]}")/assets.sh"
collect_assets dist/*.tar.gz dist/*.tar.gz.sha256 dist/checksums.txt
gh release upload "$TAG" "${assets[@]}" --clobber --repo "$GITHUB_REPOSITORY"
