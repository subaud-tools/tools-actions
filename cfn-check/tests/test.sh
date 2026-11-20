#!/usr/bin/env bash
# Tests for cfn-check/check.sh. cfn-lint and cfn-guard are fakes that record
# their arguments (the real cfn-guard is exercised by rules.sh, and both real
# tools by this repo's CI, which runs the action on a fixture).
#
# Usage: test.sh   (exit 0 = all pass)
# check() evaluates its condition later, so conditions are single-quoted on purpose.
# shellcheck disable=SC2016,SC2034  # ...and variables they read (rc) look unused to shellcheck
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
A="$(cd "$HERE/.." && pwd)"
pass=0; failn=0
ok()   { echo "  PASS $1"; pass=$((pass+1)); }
fail() { echo "  FAIL $1"; failn=$((failn+1)); sed 's/^/      | /' "$W/log" 2>/dev/null | tail -4; }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/repo"
for t in cfn-lint cfn-guard; do
  cat > "$W/bin/$t" <<FAKE
#!/usr/bin/env bash
echo "$t \$*" >> "$W/calls"
[ "$t" = cfn-guard ] && [ -n "\${GUARD_OUT:-}" ] && echo "\$GUARD_OUT"
case "$t" in cfn-lint) exit "\${LINT_EXIT:-0}";; *) exit "\${GUARD_EXIT:-0}";; esac
FAKE
  chmod +x "$W/bin/$t"
done
: > "$W/repo/a.yaml"; : > "$W/repo/b.yaml"; : > "$W/rules.guard"
run() { : > "$W/calls"; ( cd "$W/repo" && env PATH="$W/bin:$PATH" RULES="$W/rules.guard" "$@" bash "$A/check.sh" ) > "$W/log" 2>&1; }

echo "== runs both tools on the template"
run TEMPLATES=a.yaml; rc=$?
check "a clean template passes" '[ $rc -eq 0 ]'
check "cfn-lint runs on the template" 'grep -qx "cfn-lint a.yaml" "$W/calls"'
check "cfn-guard validates the template with the rule file" 'grep -q "^cfn-guard validate .*-d a.yaml .*-r $W/rules.guard" "$W/calls"'
run TEMPLATES="a.yaml b.yaml"; rc=$?
check "several templates are each linted and validated" '[ $rc -eq 0 ] && [ "$(grep -c "^cfn-lint" "$W/calls")" -eq 2 ] && grep -q "^cfn-guard .*-d b.yaml" "$W/calls"'

echo "== failures"
run TEMPLATES=a.yaml LINT_EXIT=4; rc=$?
check "a cfn-lint finding fails the check" '[ $rc -ne 0 ]'
check "cfn-guard still runs after a cfn-lint finding" 'grep -q "^cfn-guard validate" "$W/calls"'
run TEMPLATES=a.yaml GUARD_EXIT=19; rc=$?
check "a cfn-guard finding fails the check" '[ $rc -ne 0 ]'
run TEMPLATES=missing.yaml; rc=$?
check "a template that is not there fails and names it, running nothing" '[ $rc -ne 0 ] && grep -q "missing.yaml" "$W/log" && [ ! -s "$W/calls" ]'
run TEMPLATES=; rc=$?
check "no template fails and says so" '[ $rc -ne 0 ] && grep -qi "template" "$W/log"'
run TEMPLATES=a.yaml RULES="$W/none.guard"; rc=$?
check "a rule file that is not there fails and names it" '[ $rc -ne 0 ] && grep -q "none.guard" "$W/log"'

echo "== a skipped IAM rule is a failure when the template has IAM policies"
printf 'Resources:\n  R:\n    Type: AWS::IAM::Role\n    Properties:\n      Policies:\n        - PolicyName: p\n          PolicyDocument:\n            Statement: []\n' > "$W/repo/iam.yaml"
printf 'Resources:\n  R:\n    Type: AWS::IAM::Role\n    Properties:\n      AssumeRolePolicyDocument: {}\n      ManagedPolicyArns: [x]\n' > "$W/repo/iam-no-policies.yaml"
printf 'Resources:\n  B:\n    Type: AWS::S3::BucketPolicy\n    Properties:\n      PolicyDocument: {}\n' > "$W/repo/no-iam.yaml"
skip="rules.guard/no_wildcard_iam                  SKIP"
run TEMPLATES=iam.yaml GUARD_OUT="$skip"; rc=$?
check "cfn-guard exits 0 but skipped no_wildcard_iam on IAM policies: the check fails" '[ $rc -ne 0 ]'
check "the message names the rule and the template" 'grep -q "::error::cfn-check: .*no_wildcard_iam.*iam.yaml" "$W/log"'
run TEMPLATES="iam.yaml a.yaml" GUARD_OUT="$skip"; rc=$?
check "the other templates are still checked after it" '[ $rc -ne 0 ] && grep -q "^cfn-guard .*-d a.yaml" "$W/calls"'
run TEMPLATES=iam.yaml GUARD_OUT="rules.guard/no_wildcard_iam                  PASS"; rc=$?
check "the rule reported PASS on IAM policies: the check passes" '[ $rc -eq 0 ]'
run TEMPLATES=iam-no-policies.yaml GUARD_OUT="$skip"; rc=$?
check "skipped on IAM resources with no policy document: the check passes" '[ $rc -eq 0 ]'
run TEMPLATES=no-iam.yaml GUARD_OUT="$skip"; rc=$?
check "skipped on a template with no IAM resource: the check passes" '[ $rc -eq 0 ]'
run TEMPLATES=a.yaml GUARD_OUT="some cfn-guard output"; rc=$?
check "cfn-guard's own output is still shown" '[ $rc -eq 0 ] && grep -qx "some cfn-guard output" "$W/log"'

echo; echo "passed $pass, failed $failn"
[ "$failn" -eq 0 ]
