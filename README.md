# tools-actions

Versioned, pinned GitHub composite actions for the `.tools` tool family and
for republished npm forks.

## What's published

Every directory at the repo root that contains an `action.yml` is a
standalone composite action, published as part of a single repo-wide
release:

- [`fork-sync`](fork-sync/README.md): keeps a republished npm fork rebased on
  upstream and publishes it to npm with trusted publishing.
- [`tested-tree`](tested-tree/README.md): tells a deploy workflow whether this
  exact tree already passed the repo's PR CI, so it can skip mirrored checks.
- [`release-version`](release-version/README.md): resolves a Go tool's release
  run (tag, semver, stamp, create / pre-release / skip) for the VERSION-file
  and `<tool>/vX.Y.Z` tag models.
- [`go-release`](go-release/README.md): builds, signs, notarizes, stamps,
  packages and publishes a Go tool to its GitHub release and download page.
- [`go-ci`](go-ci/README.md): the family Go gate (gofmt, vet, golangci-lint,
  race tests, cross-build), and `go-ci/local.sh` to run it locally.
- [`skill-check`](skill-check/README.md): fails on any tracked `SKILL.md` pi
  cannot load or warns about, read exactly as pi reads it (go-ci runs it too).
- [`cfn-check`](cfn-check/README.md): the family CloudFormation template check
  (cfn-lint, then cfn-guard with the family rule file), and `cfn-check/local.sh`
  to run it locally.
- [`images`](images/README.md): builds a CDK project's container images once in
  CI, guards deploys (assert-present), promotes dev→prod by digest, and checks
  what's deployed (container Lambda + AWS Batch).
- [`version-guard`](version-guard/README.md): fails a release-bound PR whose
  VERSION was not raised.
- [`bump`](bump/README.md): the consumer half of the automated producer-first
  pin-bump chain — rewrites a pin to a published version, relocks, opens a PR and
  lands it via GitHub-native auto-merge, superseding older bump PRs and opening a
  loud stall issue on any un-merged ending. Ships with the reusable
  `.github/workflows/bump-pin.yml` callers pin at the same release tag.
- [`dependabot-automerge`](dependabot-automerge/README.md): arms GitHub-native
  auto-merge on Dependabot PRs that meet a policy (patch/minor, docker digests),
  so they land when the required checks pass; majors wait for review.
- [`dependabot-stale`](dependabot-stale/README.md): a weekly sweep that keeps one
  labelled tracking issue for Dependabot PRs held open past a threshold, so the
  majors that auto-merge deliberately holds don't rot silently.
- [`toolchain`](toolchain/README.md): fails CI when a repo's declared toolchain
  versions disagree anywhere (`.python-version`/`.nvmrc` vs Dockerfile base
  images and `setup-python`/`setup-node` steps) — one exact version everywhere,
  test what ships.

Each action's README describes its inputs, outputs, and usage.

## Pinning

Callers must pin the action to an exact release tag, never a branch or
`@main`:

```yaml
- uses: subaud-tools/tools-actions/<action>@vX.Y.Z
```

`<action>` is the directory name, e.g. `subaud-tools/tools-actions/fork-sync@v0.19.0`.
Floating references (`@main`, `@v1`, no tag at all) are not supported and
must not be used.

Two kinds of reference, two rules:

- **Our own actions, by release tag.** `subaud-tools/tools-actions/<action>@vX.Y.Z`,
  as above.
- **Outside actions, by commit with a version comment.** Every GitHub-owned or
  third-party action that this repo runs, in a composite `action.yml` or a
  workflow, is pinned to a full 40-character commit with its version in a
  trailing comment, the form Dependabot maintains:

  ```yaml
  - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
  ```

  A tag in someone else's repo can be moved; a commit cannot. The commit is
  taken from the action's own repo at that tag. `testlib/tests/test_outside_pins.py`
  fails a tag-pinned outside action.

## Releases

`main` is protected; every change lands through a PR. The `VERSION` file at
the repo root is the release knob: a merge to `main` that bumps `VERSION`
triggers the release workflow, which tags `v<VERSION>` and creates a GitHub
release for that commit. A merge that doesn't bump `VERSION` releases
nothing. All actions in the repo share one version; there is no per-action
versioning.

## Dependabot

This repo's workflows and composite actions pin outside `uses:` references
by commit (see Pinning). Dependabot's `github-actions` ecosystem entry (see
`.github/dependabot.yml`) opens PRs on a weekly cadence with a cooldown that
move each commit and its version comment together. It lists `/` for
`.github/workflows` and the directory of every composite action that runs an
outside action, since Dependabot reads an `action.yml` only in a listed
directory.

Consumers of these actions get updates the same way: point Dependabot's
`github-actions` ecosystem at the caller repo, and it will propose bumping
`subaud-tools/tools-actions/<action>@vX.Y.Z` pins as new releases are cut here.

## License

MIT. See `LICENSE`.
