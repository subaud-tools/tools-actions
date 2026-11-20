#!/usr/bin/env bash
# Tests for cfn-check/local.sh: it reads the cfn-check pin from ci.yml, fetches
# that version's check into a cache, checks the tools on PATH are the versions
# that version pins, and runs the check. Fetches are served from a local
# directory via TOOLS_ACTIONS_BASE (file:// URL), so no network is used.
#
# Usage: local.sh   (exit 0 = all pass)
# check() evaluates its condition later, so conditions are single-quoted.
# shellcheck disable=SC2016,SC2034
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
A="$(cd "$HERE/.." && pwd)"
pass=0; failn=0
ok()   { echo "  PASS $1"; pass=$((pass+1)); }
fail() { echo "  FAIL $1"; failn=$((failn+1)); sed 's/^/      | /' "$W/log" 2>/dev/null | tail -4; }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
# A fake published tools-actions: <base>/v9.9.9/cfn-check/{check.sh,family.guard,versions.lock}
publish() {
  mkdir -p "$W/pub/v9.9.9/cfn-check"
  cat > "$W/pub/v9.9.9/cfn-check/check.sh" <<'GATE'
#!/usr/bin/env bash
echo "check v9.9.9 ran in $PWD with TEMPLATES=$TEMPLATES RULES=$RULES"
[ -f "$RULES" ] || { echo "no rules"; exit 3; }
exit "${GATE_EXIT:-0}"
GATE
  printf '# rules\n' > "$W/pub/v9.9.9/cfn-check/family.guard"
  printf 'cfn-lint 1.2.3\ncfn-guard 4.5.6\n' > "$W/pub/v9.9.9/cfn-check/versions.lock"
}
publish
repo="$W/repo"; mkdir -p "$repo/.github/workflows"
pin() { printf '      - uses: subaud-tools/tools-actions/cfn-check@%s\n' "$1" > "$repo/.github/workflows/ci.yml"; }
pin v9.9.9
# tool <name> <version>: a fake on PATH that reports that version.
mkdir -p "$W/bin"
tool() { printf '#!/bin/sh\necho "%s %s"\n' "$1" "$2" > "$W/bin/$1"; chmod +x "$W/bin/$1"; }
tool cfn-lint 1.2.3; tool cfn-guard 4.5.6
# A PATH with the fakes and the system tools only, so a real cfn-lint or
# cfn-guard on this machine is never the one found.
P="$W/bin:/usr/bin:/bin"
mkdir -p "$W/tmp"
run() { ( cd "$repo" && env PATH="$P" TMPDIR="$W/tmp" TOOLS_ACTIONS_BASE="file://$W/pub" XDG_CACHE_HOME="$W/cache" "$@" bash "$A/local.sh" contrib/t.yaml ) > "$W/log" 2>&1; }

echo "== runs the pinned version"
run; rc=$?
check "runs the check at the ci.yml pin" '[ $rc -eq 0 ] && grep -q "check v9.9.9 ran in $repo" "$W/log"'
check "passes the template it was given" 'grep -q "TEMPLATES=contrib/t.yaml " "$W/log"'
check "passes the fetched rule file" 'grep -q "RULES=$W/cache/tools-actions/v9.9.9/cfn-check/family.guard" "$W/log"'
check "caches the fetched files" '[ -f "$W/cache/tools-actions/v9.9.9/cfn-check/check.sh" ] && [ -f "$W/cache/tools-actions/v9.9.9/cfn-check/versions.lock" ]'
check "leaves no temporary files behind" '[ -z "$(ls -A "$W/tmp")" ]'

echo "== uses the cache"
rm -rf "$W/pub/v9.9.9"
run; rc=$?
check "a cached version runs offline" '[ $rc -eq 0 ] && grep -q "check v9.9.9 ran" "$W/log"'

echo "== failures"
run GATE_EXIT=1; rc=$?
check "the check's failure is the exit code" '[ $rc -eq 1 ]'
( cd "$repo" && env PATH="$P" TOOLS_ACTIONS_BASE="file://$W/pub" XDG_CACHE_HOME="$W/cache" bash "$A/local.sh" ) > "$W/log" 2>&1; rc=$?
check "no template argument fails and says so" '[ $rc -ne 0 ] && grep -qi "template" "$W/log" && ! grep -q "check v9.9.9 ran" "$W/log"'
printf 'jobs: {}\n' > "$repo/.github/workflows/ci.yml"
run; rc=$?
check "no cfn-check pin in ci.yml fails and says so" '[ $rc -ne 0 ] && grep -q "cfn-check@" "$W/log"'
rm -rf "$repo/.github"
run; rc=$?
check "no ci.yml fails and says so" '[ $rc -ne 0 ] && grep -q "ci.yml" "$W/log"'
mkdir -p "$repo/.github/workflows"; pin v8.0.0
run; rc=$?
check "a version that cannot be fetched fails and names it" '[ $rc -ne 0 ] && grep -q "v8.0.0" "$W/log"'
check "a failed fetch leaves no temporary files behind" '[ -z "$(ls -A "$W/tmp")" ]'
check "a failed fetch leaves nothing in the cache" '[ ! -e "$W/cache/tools-actions/v8.0.0/cfn-check/.complete" ]'

echo "== the tools on PATH must be the pinned versions"
pin v9.9.9; publish; rm -rf "$W/cache"
tool cfn-lint 1.0.0
run; rc=$?
check "another cfn-lint stops with the install line, running nothing" '[ $rc -ne 0 ] && grep -q "cfn-lint==1.2.3" "$W/log" && grep -q "1.0.0" "$W/log" && ! grep -q "check v9.9.9 ran" "$W/log"'
tool cfn-lint 1.2.3; tool cfn-guard 4.0.0
run; rc=$?
check "another cfn-guard stops with the install line, running nothing" '[ $rc -ne 0 ] && grep -q "cfn-guard 4.5.6" "$W/log" && grep -q "releases/tag/4.5.6" "$W/log" && ! grep -q "check v9.9.9 ran" "$W/log"'
rm "$W/bin/cfn-guard"
run; rc=$?
check "a missing cfn-guard stops with the install line" '[ $rc -ne 0 ] && grep -q "releases/tag/4.5.6" "$W/log" && ! grep -q "check v9.9.9 ran" "$W/log"'
tool cfn-guard 4.5.6; rm "$W/bin/cfn-lint"
run; rc=$?
check "a missing cfn-lint stops with the install line" '[ $rc -ne 0 ] && grep -q "cfn-lint==1.2.3" "$W/log" && ! grep -q "check v9.9.9 ran" "$W/log"'
tool cfn-lint 1.2.3
run; rc=$?
check "the pinned versions run the check again" '[ $rc -eq 0 ] && grep -q "check v9.9.9 ran" "$W/log"'

echo; echo "passed $pass, failed $failn"
[ "$failn" -eq 0 ]
