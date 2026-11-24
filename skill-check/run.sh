#!/usr/bin/env bash
# Runs check.mjs on the repo in the current directory: installs the locked npm
# `yaml` (npm ci --ignore-scripts) into a cache dir keyed by package-lock.json,
# once, then runs the check from there so it resolves that copy.
#
# Env: SKILL_CHECK_CACHE (default ${XDG_CACHE_HOME:-~/.cache}/tools-actions/skill-check):
#      installs go to <cache>/<lockfile hash>/, npm's own cache to <cache>/npm-cache.
# Exit: check.mjs's (0 pass, 1 a skill fails, 2 could not run); 2 when node or
# npm is missing or the install fails.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "::error::skill-check: $*"; echo "skill-check: $*" >&2; exit 2; }
hash() { (shasum -a 256 "$1" 2>/dev/null || sha256sum "$1") | cut -c1-16; }

command -v node >/dev/null 2>&1 || die "needs node on PATH (pi runs on it; GitHub's runners carry it)"
command -v npm >/dev/null 2>&1 || die "needs npm on PATH (it comes with node)"

cache="${SKILL_CHECK_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/tools-actions/skill-check}"
inst="$cache/$(hash "$here/package-lock.json")"
if [ ! -f "$inst/.complete" ]; then
  rm -rf "$inst"; mkdir -p "$inst"
  cp "$here/package.json" "$here/package-lock.json" "$inst/"
  ( cd "$inst" && npm ci --ignore-scripts --no-audit --no-fund --cache "$cache/npm-cache" ) >&2 \
    || die "npm ci failed in $inst (see above)"
  touch "$inst/.complete"
fi
# Beside its node_modules, so `import "yaml"` resolves the locked copy; named
# by its own hash, so two versions sharing a lockfile never overwrite each other.
script="$inst/check-$(hash "$here/check.mjs").mjs"
[ -f "$script" ] || { cp "$here/check.mjs" "$script.tmp.$$" && mv "$script.tmp.$$" "$script"; }
exec node "$script"
