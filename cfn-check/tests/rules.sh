#!/usr/bin/env bash
# Tests for cfn-check/family.guard with the real cfn-guard: every bad-*.yaml
# fixture fails exactly the one rule its "# rule:" header names, and good.yaml
# and every ok-*.yaml pass, with no_wildcard_iam reported PASS (not skipped) on
# each that declares an IAM resource. A rule with no failing fixture fails the
# suite. check.sh then runs with the real cfn-guard on skipped-*.yaml: templates
# cfn-guard exits 0 on that the check must still fail.
#
# Usage: rules.sh   (needs cfn-guard on PATH; exit 0 = all pass)
# Env: RULES (default ../family.guard)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
A="$(cd "$HERE/.." && pwd)"
RULES="${RULES:-$A/family.guard}"
pass=0; failn=0
ok()   { echo "  PASS $1"; pass=$((pass+1)); }
fail() { echo "  FAIL $1"; failn=$((failn+1)); }
command -v cfn-guard >/dev/null || { echo "rules.sh: needs cfn-guard" >&2; exit 2; }
[ -f "$RULES" ] || { echo "rules.sh: no rule file at $RULES" >&2; exit 2; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# failed <fixture>: the rules it fails, one per line, sorted.
failed() { cfn-guard validate -d "$1" -r "$RULES" 2>&1 | sed -n 's/^[^ ]*\.guard\/\([a-z_0-9]*\) *FAIL$/\1/p' | sort -u; }

echo "== each failing fixture fails its rule, and only that rule"
: > "$W/covered"
for f in "$HERE"/fixtures/bad-*.yaml; do
  n="$(basename "$f")"
  want="$(sed -n '1s/^# rule: //p' "$f")"
  [ -n "$want" ] || { fail "$n has no '# rule:' header"; continue; }
  cfn-guard validate -d "$f" -r "$RULES" >/dev/null 2>&1; rc=$?
  got="$(failed "$f" | tr '\n' ' ' | sed 's/ $//')"
  if [ "$rc" -ne 0 ] && [ "$got" = "$want" ]; then ok "$n fails $want"; else fail "$n: want $want, got '${got:-nothing}' (exit $rc)"; fi
  echo "$want" >> "$W/covered"
done

echo "== passing fixtures pass"
for f in "$HERE"/fixtures/good.yaml "$HERE"/fixtures/ok-*.yaml; do
  n="$(basename "$f")"
  if cfn-guard validate --show-summary all -d "$f" -r "$RULES" > "$W/log" 2>&1; then ok "$n passes"; else fail "$n: fails $(failed "$f" | tr '\n' ' ')"; fi
  # Exit 0 is not enough: a rule cfn-guard skipped judged nothing.
  if grep -q 'AWS::IAM::' "$f"; then
    if grep -qE '/no_wildcard_iam +PASS$' "$W/log"; then ok "$n: no_wildcard_iam reported PASS"; else fail "$n: no_wildcard_iam not reported PASS ($(grep -oE 'no_wildcard_iam +[A-Z]+' "$W/log" | head -1))"; fi
  fi
done

echo "== check.sh fails a template with IAM policies on which cfn-guard skips the IAM rule"
# The real cfn-guard; cfn-lint is not under test here, so it is a stub.
mkdir -p "$W/bin"; printf '#!/bin/sh\nexit 0\n' > "$W/bin/cfn-lint"; chmod +x "$W/bin/cfn-lint"
for f in "$HERE"/fixtures/skipped-*.yaml; do
  n="$(basename "$f")"
  cfn-guard validate -d "$f" -r "$RULES" >/dev/null 2>&1; grc=$?
  PATH="$W/bin:$PATH" TEMPLATES="$f" RULES="$RULES" bash "$A/check.sh" > "$W/log" 2>&1; rc=$?
  if [ "$grc" -eq 0 ] && [ "$rc" -ne 0 ] && grep -q '::error::cfn-check: .*no_wildcard_iam' "$W/log"; then ok "$n: cfn-guard exits 0, check.sh fails naming the rule"; else fail "$n: cfn-guard exit $grc, check.sh exit $rc"; fi
done
PATH="$W/bin:$PATH" TEMPLATES="$HERE/fixtures/good.yaml" RULES="$RULES" bash "$A/check.sh" > "$W/log" 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then ok "good.yaml passes check.sh"; else fail "good.yaml: check.sh exit $rc"; fi

echo "== every rule has a failing fixture"
while read -r r; do
  if grep -qx "$r" "$W/covered"; then ok "$r has a failing fixture"; else fail "$r has no failing fixture"; fi
done < <(sed -n 's/^rule \([a-z_0-9]*\) .*/\1/p' "$RULES")

echo; echo "passed $pass, failed $failn"
[ "$failn" -eq 0 ]
