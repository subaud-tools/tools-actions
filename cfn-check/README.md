# cfn-check

The `.tools` family check for a CloudFormation template, one step:

1. `cfn-lint` 1.60.1 on the template (your repo's `.cfnlintrc` applies).
2. `cfn-guard` 3.3.0 with the family rule file, [`family.guard`](family.guard).

Both versions are pinned in [`versions.lock`](versions.lock). cfn-guard is
installed from its GitHub release and checksum-verified (linux amd64 and
arm64); cfn-lint is installed with `pipx`. Both run on every template even
when one finds something, so one run reports everything.

```yaml
jobs:
  cfn:
    runs-on: ubuntu-26.04
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: subaud-tools/tools-actions/cfn-check@v0.17.0
        with:
          template: contrib/cloudformation/stack.yaml
```

Input: `template` (required): the template's path from the repo root. Several
paths may be given, separated by spaces or newlines.

## The rules

| Rule | A template fails when |
| --- | --- |
| `no_wildcard_iam` | an IAM statement has `Action: "*"`, or has `Resource: "*"` with an action that could name a resource |
| `s3_block_public_access` | a bucket does not set all four public access blocks |
| `dynamodb_ttl_and_pitr` | a table has expiry (TTL) or point-in-time recovery off |
| `cloudfront_viewer_https_only` | a distribution's cache behavior serves plain HTTP |
| `cloudfront_min_tls_not_legacy` | a distribution's own certificate accepts an old TLS version |
| `apigw_domain_no_legacy_tls` | an API Gateway domain name accepts TLS 1.0 |
| `log_groups_have_retention` | a declared log group sets no `RetentionInDays` |

No rule names a resource of any one template. A rule about a resource type the
template does not declare is skipped.

### Resource `"*"`

`Resource: "*"` (alone, or in a list) is allowed in a statement only when
**every** action in it is one AWS gives no resource to name:

- a read action: `service:Describe...`, `service:List...` or `service:Get...`,
  including a trailing wildcard such as `ec2:Describe*`;
- an action on the short list in `family.guard`, each of which the
  [AWS Service Authorization Reference](https://docs.aws.amazon.com/service-authorization/latest/reference/reference_policies_actions-resources-contextkeys.html)
  shows with no resource type: `acm:RequestCertificate`, and CloudFront's
  `CreateDistribution`, `CreateKeyGroup`, `CreatePublicKey`, `CreateVpcOrigin`,
  `DeleteKeyGroup`, `DeletePublicKey` and `UpdateKeyGroup`.

So a statement that mixes reads and writes on `"*"` fails: split it, keep the
reads on `"*"`, and give each other action its resources (or conditions on
tags). To add an action to the list, find it on its service's page in the
reference and add it only if its "Resource types" cell is empty, with a comment
naming the page.

The rule reads the inline policies of roles, users and groups, and the document
of `AWS::IAM::Policy`, `ManagedPolicy`, `RolePolicy`, `UserPolicy` and
`GroupPolicy`. `Statement` may be a list or a single map.

- A statement with no literal `Action` fails: one that uses `NotAction`, one
  built by a function (an `!If` item in `Statement`, or `Statement: !If`), and
  one whose `Action` is built by a function (`Action: !If [...]`).
- Not judged: `Effect` (a `Deny` on `"*"` fails too), `NotResource`, a wildcard
  inside an ARN (`arn:aws:s3:::*`), a resource built by a function
  (`!Sub "*"`), and resource policies such as a bucket policy.

cfn-guard skips a rule, with exit 0, when it finds nothing to read. So the
check also fails when `no_wildcard_iam` is reported `SKIP` on a template that
declares an IAM resource and a `PolicyDocument`: no statement was judged (for
example the only policy has `Statement: []`).

## The same check locally

`cfn-check/local.sh` runs this check on your machine at exactly the version
your `ci.yml` pins: it reads the `cfn-check@vX.Y.Z` pin, fetches that version's
`check.sh`, `family.guard` and `versions.lock` into `~/.cache/tools-actions/`
(later runs work offline), and runs the same two commands. It installs nothing:
when `cfn-lint` or `cfn-guard` on your PATH is missing or is not the pinned
version, it stops with the install line. A repo's justfile calls it through one
recipe, so `just verify` and CI cannot disagree:

```just
# The family template check, at the tools-actions version ci.yml pins (same as CI).
cfn-check:
    #!/usr/bin/env bash
    set -euo pipefail
    v="$(grep -oE 'cfn-check@v[0-9]+\.[0-9]+\.[0-9]+' .github/workflows/ci.yml | head -1 | cut -d@ -f2)"
    f="${XDG_CACHE_HOME:-$HOME/.cache}/tools-actions/$v/cfn-check/local.sh"
    [ -f "$f" ] || { mkdir -p "$(dirname "$f")"; curl -fsSL "https://raw.githubusercontent.com/subaud-tools/tools-actions/$v/cfn-check/local.sh" -o "$f"; }
    bash "$f" contrib/cloudformation/stack.yaml
```

## Tests

- `tests/rules.sh` (needs `cfn-guard`): every `tests/fixtures/bad-*.yaml` fails
  exactly the rule its first line names, `good.yaml` and every `ok-*.yaml`
  pass with `no_wildcard_iam` reported `PASS` (not skipped), every rule has a
  failing fixture, and `check.sh` fails each `skipped-*.yaml`.
- `tests/test.sh`: `check.sh` with fake tools.
- `tests/local.sh`: `local.sh` against a fake published version.
