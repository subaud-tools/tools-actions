#!/usr/bin/env bash
# Tests for cfn-check/family.guard with the real cfn-guard: every bad-*.yaml
# fixture fails exactly the one rule its "# rule:" header names, and good.yaml
# and every ok-*.yaml pass. A rule with no failing fixture fails the suite.
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
  if cfn-guard validate -d "$f" -r "$RULES" > "$W/log" 2>&1; then ok "$n passes"; else fail "$n: fails $(failed "$f" | tr '\n' ' ')"; fi
done

echo "== every rule has a failing fixture"
while read -r r; do
  if grep -qx "$r" "$W/covered"; then ok "$r has a failing fixture"; else fail "$r has no failing fixture"; fi
done < <(sed -n 's/^rule \([a-z_0-9]*\) .*/\1/p' "$RULES")

echo; echo "passed $pass, failed $failn"
[ "$failn" -eq 0 ]
