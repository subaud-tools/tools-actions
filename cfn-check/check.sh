#!/usr/bin/env bash
# The family CloudFormation template check: cfn-lint, then cfn-guard with the
# family rule file, on each template. Both run on every template even when one
# finds something, so one run reports everything.
#
# Env: TEMPLATES (template paths, separated by spaces or newlines),
#      RULES (the cfn-guard rule file: family.guard).
# cfn-lint and cfn-guard are taken from PATH.
set -euo pipefail
die() { echo "::error::cfn-check: $*"; exit 2; }
# shellcheck disable=SC2206  # TEMPLATES is a list
templates=(${TEMPLATES:-})
[ "${#templates[@]}" -gt 0 ] || die "no template named (TEMPLATES is empty)"
rules="${RULES:?cfn-check: RULES is not set}"
[ -f "$rules" ] || die "no rule file at $rules"
for t in "${templates[@]}"; do [ -f "$t" ] || die "no template at $t"; done

# has_iam_policies <template>: it declares an IAM resource and a policy document
# (a PolicyDocument key; AssumeRolePolicyDocument is not one), so the IAM rule
# has statements to judge.
has_iam_policies() {
  grep -q 'AWS::IAM::' "$1" && grep -qE '(^|[^A-Za-z0-9])PolicyDocument["'\'']?[[:space:]]*:' "$1"
}

out="$(mktemp "${TMPDIR:-/tmp}/cfn-check.XXXXXX")"; trap 'rm -f "$out"' EXIT
rc=0
for t in "${templates[@]}"; do
  echo "::group::cfn-lint $t"
  cfn-lint "$t" || { echo "::error::cfn-check: cfn-lint found problems in $t"; rc=1; }
  echo "::endgroup::"
  echo "::group::cfn-guard $t"
  # --show-summary all: a rule cfn-guard skipped is listed, not left out.
  grc=0; cfn-guard validate --show-summary all -d "$t" -r "$rules" > "$out" 2>&1 || grc=$?
  cat "$out"
  [ "$grc" -eq 0 ] || { echo "::error::cfn-check: cfn-guard: $t breaks a family rule"; rc=1; }
  # cfn-guard skips a rule, with exit 0, when a query in it finds nothing to
  # read. On a template with IAM policies that is a rule that judged nothing.
  if grep -qE '/no_wildcard_iam +SKIP$' "$out" && has_iam_policies "$t"; then
    echo "::error::cfn-check: cfn-guard skipped no_wildcard_iam on $t, which declares IAM policies: no IAM statement was judged. A policy with no statement, or one cfn-guard cannot read, does this; give every policy document a literal Statement."
    rc=1
  fi
  echo "::endgroup::"
done
[ "$rc" -eq 0 ] || exit "$rc"
echo "cfn-check: all checks passed"
