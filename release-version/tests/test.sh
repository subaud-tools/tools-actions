#!/usr/bin/env bash
# Tests for release-version/resolve.sh. Each run gets a real bare `origin`
# holding the tags in $REMOTE_TAGS (space-separated); NO_ORIGIN=1 leaves the
# remote unreachable. A fake `gh` on PATH fails any call, so "already released"
# can only come from the tag on the remote, never from a GitHub release.
#
# Usage: test.sh   (exit 0 = all pass)
# check() evaluates its condition later, so conditions are single-quoted on purpose.
# shellcheck disable=SC2016,SC2034  # ...and variables they read (rc) look unused to shellcheck
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RESOLVE="$(cd "$HERE/.." && pwd)/resolve.sh"

pass=0; failn=0
ok()   { echo "  PASS $1"; pass=$((pass+1)); }
fail() { echo "  FAIL $1"; failn=$((failn+1)); }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
cat > "$W/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "release not found" >&2; exit 1
GH
chmod +x "$W/bin/gh"

# run <label> <env assignments...>: runs resolve.sh in a fresh repo dir with
# VERSION 1.2.3 and cmd/scratch, capturing GITHUB_OUTPUT into $W/out.
run() {
  local repo="$W/repo"; rm -rf "$repo"; mkdir -p "$repo/cmd/scratch"
  ( cd "$repo" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m x )
  rm -rf "$W/origin.git"
  if [ -z "${NO_ORIGIN:-}" ]; then
    git init -q --bare "$W/origin.git"
    ( cd "$repo" && git remote add origin "$W/origin.git"
      for t in ${REMOTE_TAGS:-}; do git tag "$t" && git push -q origin "refs/tags/$t"; git tag -d "$t" >/dev/null; done )
  else
    git -C "$repo" remote add origin "$W/missing.git"
  fi
  printf '1.2.3\n' > "$repo/VERSION"
  : > "$W/out"
  ( cd "$repo" && env PATH="$W/bin:$PATH" GITHUB_OUTPUT="$W/out" GITHUB_REPOSITORY=o/r \
      GITHUB_RUN_NUMBER=42 "$@" bash "$RESOLVE" ) > "$W/log" 2>&1
}
out() { sed -n "s/^$1=//p" "$W/out"; }
expect() { # expect <label> <key> <want>
  local got; got="$(out "$2")"
  if [ "$got" = "$3" ]; then ok "$1: $2=$3"; else fail "$1: $2 want '$3' got '$got' ($(tail -1 "$W/log"))"; fi
}

echo "== version-file mode"
run MODE=version-file EVENT=push
expect "push, new VERSION" tag v1.2.3
expect "push, new VERSION" version 1.2.3
expect "push, new VERSION" create true
expect "push, new VERSION" prerelease false
expect "push, new VERSION" skip false
if [ -n "$(out commit)" ]; then ok "commit is set"; else fail "commit is set"; fi
if [[ "$(out date)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then ok "date is YYYY-MM-DD"; else fail "date is YYYY-MM-DD ($(out date))"; fi

REMOTE_TAGS="v1.2.3" run MODE=version-file EVENT=push
expect "push, tag v<VERSION> on origin (no GitHub release)" skip true
expect "push, tag v<VERSION> on origin (no GitHub release)" create false

REMOTE_TAGS="scratch/v1.2.3 v1.2.30" run MODE=version-file EVENT=push
expect "push, only look-alike tags on origin" skip false
expect "push, only look-alike tags on origin" create true

run MODE=version-file EVENT=workflow_dispatch DISPATCH_TAG=
expect "dispatch, no tag" tag v1.2.3-rc.42
expect "dispatch, no tag" version 1.2.3-rc.42
expect "dispatch, no tag" create true
expect "dispatch, no tag" prerelease true

run MODE=version-file EVENT=workflow_dispatch DISPATCH_TAG=v1.1.0
expect "dispatch, rebuild tag" tag v1.1.0
expect "dispatch, rebuild tag" version 1.1.0
expect "dispatch, rebuild tag" create false
expect "dispatch, rebuild tag" skip false

NO_ORIGIN=1 run MODE=version-file EVENT=push
if [ -z "$(out tag)$(out skip)" ] && grep -q "cannot tell whether v1.2.3 exists" "$W/log"; then ok "unreachable origin fails, never re-cuts or skips"; else fail "unreachable origin fails ($(cat "$W/out"))"; fi

echo "== prefixed-tag mode"
run MODE=prefixed-tag EVENT=push GITHUB_REF=refs/tags/scratch/v0.5.4
expect "scratch tag" tool scratch
expect "scratch tag" version 0.5.4
expect "scratch tag" tag scratch/v0.5.4
expect "scratch tag" create true
expect "scratch tag" prerelease false

run MODE=prefixed-tag EVENT=push GITHUB_REF=refs/tags/scratch/v1.0.0-rc.1
expect "scratch rc tag" prerelease true
expect "scratch rc tag" version 1.0.0-rc.1

run MODE=prefixed-tag EVENT=push GITHUB_REF=refs/tags/nope/v1.0.0
if [ -z "$(out tool)" ] && grep -q "cmd/nope" "$W/log"; then ok "tag for a missing cmd/<tool> fails"; else fail "tag for a missing cmd/<tool> fails"; fi

run MODE=bogus EVENT=push
if [ -z "$(out tag)" ] && grep -q "mode" "$W/log"; then ok "unknown mode fails"; else fail "unknown mode fails"; fi

echo; echo "passed $pass, failed $failn"
[ "$failn" -eq 0 ]
