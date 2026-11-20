#!/usr/bin/env bash
# Runs the family CloudFormation template check locally, at exactly the
# tools-actions version this repo's CI pins, so `just verify` and CI can never
# disagree. A repo's justfile calls this through one standard recipe.
#
# Usage: local.sh <template>...   (from the repo root)
#
# 1. Read the `subaud-tools/tools-actions/cfn-check@vX.Y.Z` pin from
#    .github/workflows/ci.yml (the one pin Dependabot bumps).
# 2. Fetch that version's check.sh, family.guard and versions.lock into
#    ~/.cache/tools-actions/vX.Y.Z/cfn-check/ (kept; later runs work offline).
# 3. Stop with the install line unless cfn-lint and cfn-guard on PATH are the
#    versions that lock names. Nothing is installed for you.
# 4. Run the check with the same rule file CI uses.
#
# Env: TOOLS_ACTIONS_BASE (default https://raw.githubusercontent.com/subaud-tools/tools-actions),
#      XDG_CACHE_HOME.
set -euo pipefail
die() { echo "cfn-check local: $*" >&2; exit 2; }

[ "$#" -gt 0 ] || die "name the template to check: local.sh <template>..."
ci=.github/workflows/ci.yml
[ -f "$ci" ] || die "no $ci here: run from the repo root (the check runs at the version $ci pins)"
ver="$(grep -oE 'subaud-tools/tools-actions/cfn-check@v[0-9]+\.[0-9]+\.[0-9]+' "$ci" | head -1 | cut -d@ -f2 || true)"
[ -n "$ver" ] || die "$ci has no subaud-tools/tools-actions/cfn-check@vX.Y.Z pin"

base="${TOOLS_ACTIONS_BASE:-https://raw.githubusercontent.com/subaud-tools/tools-actions}"
dir="${XDG_CACHE_HOME:-$HOME/.cache}/tools-actions/$ver/cfn-check"
if [ ! -f "$dir/.complete" ]; then
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cfn-check.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
  for f in check.sh family.guard versions.lock; do
    curl -fsSL "$base/$ver/cfn-check/$f" -o "$tmp/$f" || die "could not fetch tools-actions $ver cfn-check/$f from $base"
  done
  mkdir -p "$dir" && cp "$tmp"/* "$dir/" && touch "$dir/.complete"
  # Removed here, not in the trap alone: the exec below replaces this shell,
  # and an EXIT trap does not run then.
  rm -rf "$tmp"; trap - EXIT
fi

# have <tool>: the version of <tool> on PATH, or nothing.
have() { command -v "$1" >/dev/null 2>&1 && "$1" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true; }
lint="$(awk '$1=="cfn-lint"{print $2}' "$dir/versions.lock")"
guard="$(awk '$1=="cfn-guard"{print $2}' "$dir/versions.lock")"
[ -n "$lint" ] && [ -n "$guard" ] || die "$dir/versions.lock names no cfn-lint or cfn-guard version"
got="$(have cfn-lint)"
[ "$got" = "$lint" ] || die "tools-actions $ver needs cfn-lint $lint; PATH has ${got:-none}. Install it:
  pipx install --force cfn-lint==$lint"
got="$(have cfn-guard)"
[ "$got" = "$guard" ] || die "tools-actions $ver needs cfn-guard $guard; PATH has ${got:-none}. Install it:
  brew install cloudformation-guard   (when Homebrew's version is $guard), or the binary from
  https://github.com/aws-cloudformation/cloudformation-guard/releases/tag/$guard"

echo "cfn-check local: tools-actions $ver, cfn-lint $lint, cfn-guard $guard"
TEMPLATES="$*" RULES="$dir/family.guard" exec bash "$dir/check.sh"
