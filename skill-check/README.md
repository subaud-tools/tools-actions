# skill-check

Fails on any `SKILL.md` that pi cannot load or warns about, before it is
merged, released or installed. pi skips such a skill with only a warning (one
unquoted `: ` in a description is enough), so nothing else notices.

It reads every `SKILL.md` git tracks (`git ls-files '*SKILL.md'`, in any
folder: `skills/`, `.claude/skills/`, testdata) exactly as pi reads it: pi's
front-matter split (line endings normalised, a byte-order mark dropped, from
the opening `---` to the next line starting `---`), parsed with the npm `yaml`
package at the version pi ships (pinned in [`package-lock.json`](package-lock.json)),
and pi's own rules for a skill. It fails on:

- no front matter, or no closing `---` line;
- front matter `yaml` cannot parse;
- a description that is missing, empty, or over 1024 characters;
- a name (the `name` field, else the folder's name) that is over 64
  characters, holds anything but `a-z`, `0-9` and `-`, starts or ends with a
  hyphen, or holds `--`.

It adds no rules of its own: a name that differs from its folder passes, as it
does in pi. Each failure is a GitHub error annotation on the file and line with
pi's own message, and a plain `file:line: message` line; the step exits 1 if any
file fails and 0 otherwise, saying how many files it checked. A repo with no
`SKILL.md` passes.

```yaml
jobs:
  ci:
    runs-on: ubuntu-26.04
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: subaud-tools/tools-actions/skill-check@v0.19.0
```

Pin it to an exact release tag, never a branch or `@main`. It needs `node` and
`npm` on the runner (GitHub's hosted images carry both); it installs `yaml` with
`npm ci --ignore-scripts` into `$RUNNER_TEMP/skill-check`, or the directory the
optional `cache` input names.

The Go repos need no step of their own: [`go-ci`](../go-ci/README.md) runs this
check first whenever the repo tracks a `SKILL.md`, in CI and through `local.sh`.

Locally, from the repo root: `bash skill-check/run.sh` (it installs into
`~/.cache/tools-actions/skill-check`, or `$SKILL_CHECK_CACHE`).
