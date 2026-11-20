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

rc=0
for t in "${templates[@]}"; do
  echo "::group::cfn-lint $t"
  cfn-lint "$t" || { echo "::error::cfn-check: cfn-lint found problems in $t"; rc=1; }
  echo "::endgroup::"
  echo "::group::cfn-guard $t"
  # --show-summary all: a rule cfn-guard skipped is listed, not left out.
  cfn-guard validate --show-summary all -d "$t" -r "$rules" || { echo "::error::cfn-check: cfn-guard: $t breaks a family rule"; rc=1; }
  echo "::endgroup::"
done
[ "$rc" -eq 0 ] || exit "$rc"
echo "cfn-check: all checks passed"
