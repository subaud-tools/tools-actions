# release-version

Resolves what a Go tool's release run does: tag, bare semver, the commit and
date to stamp, and create / prerelease / skip. Feed its outputs to
[`go-release`](../go-release/README.md).

| Mode | Trigger | Result |
|---|---|---|
| `version-file` | push to the release branch | `v<VERSION>`; **skip** if tag `v<VERSION>` is on `origin` |
| `version-file` | `workflow_dispatch`, no tag | `v<VERSION>-rc.<run>` **pre-release** (never `latest`) |
| `version-file` | `workflow_dispatch`, `tag: vX.Y.Z` | rebuild that release's assets (`create=false`) |
| `prefixed-tag` | push of `<tool>/vX.Y.Z` | one tool's release; a `-` in the version = pre-release |

```yaml
- uses: actions/checkout@v7.0.1
- id: rel
  uses: subaud-tools/tools-actions/release-version@v0.15.0
  with:
    mode: version-file
    dispatch-tag: ${{ inputs.tag }}
```

Released means the tag `v<VERSION>` is on `origin` (`git ls-remote`), so a
repo that publishes with `go-release`'s `github-release: "false"` (no GitHub
release, only the tag) skips as well. Not being able to read `origin` fails the
job rather than re-cutting or silently skipping a release. The `github-token`
input is unused since v0.15.0 and kept so existing callers don't break.
