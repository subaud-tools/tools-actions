# go-release

Releases a `.tools` Go binary: build every target with the version stamped, sign and notarize the macOS binaries, check the stamp, package, create the GitHub release, and publish to the family download contract. It runs inside your job, so your `release` environment's secrets and your job's OIDC identity are used as they are: the downloads role's trust does not change.

| Step | What it guarantees |
|---|---|
| sign | Developer ID, hardened runtime, secure timestamp. **Missing certificate = the release fails**, never ships unsigned. |
| build | `dist/<name>_<os>_<arch>/<name>`, `CGO_ENABLED=0 -trimpath -ldflags "-s -w <yours>"` |
| stamp check | each binary in `stamp-check` must print exactly `<name> <version> (<commit>, <date>)`. Only listed binaries are ever run. |
| notarize | one submission for every darwin binary; anything but `Accepted` fails |
| package | `<name>_<os>_<arch>.tar.gz`, `.tar.gz.sha256` (two-space shasum, bare asset name), `checksums.txt` (+ `extra-assets`) |
| GitHub release | created when `create`, `--prerelease` for an rc; assets uploaded with `--clobber`. Skipped when `github-release: "false"` (default `"true"`), which instead pushes the annotated tag `v<VERSION>` at the commit when `create` |
| `/dl` | `/dl/<tool>/<version>/…` immutable and write-once: the tarballs, and each `extra-assets` file with its own `.sha256`, each file with a signed receipt (`.receipt`, `.receipt.sig`; see [Receipts](#receipts)); then, last, `/dl/<tool>/latest` (bare semver, 60 s) and a CloudFront invalidation **only** for a created, non-prerelease release, and only when no release tag on origin (`<prefix>X.Y.Z`, `-rc` tags not counted) is higher than its version: `latest` only moves up, compared with the tags, so an older release published late leaves it alone and says `not moving /dl/<tool>/latest: <prefix>X.Y.Z is higher` (the checkout needs origin and its credentials, as for `github-release: false`) |
| cleanup | keychain, certificate and API key destroyed with `if: always()` |

```yaml
on:
  push: { branches: [main] }
  workflow_dispatch:
    inputs:
      tag: { description: "Existing tag to rebuild; empty = rc pre-release", required: false, default: "" }
permissions: { contents: write, id-token: write }
jobs:
  release:
    runs-on: macos-26
    environment: release
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with: { ref: "${{ inputs.tag }}" }
      - id: rel
        uses: subaud-tools/tools-actions/release-version@v0.19.0
        with: { mode: version-file, dispatch-tag: "${{ inputs.tag }}" }
      - if: steps.rel.outputs.skip != 'true'
        uses: subaud-tools/tools-actions/go-release@v0.19.0
        with:
          binaries: |
            kempt=./cmd/kempt
          ldflags: >-
            -X github.com/subaud-tools/kempt/internal/version.version={version}
            -X github.com/subaud-tools/kempt/internal/version.commit={commit}
            -X github.com/subaud-tools/kempt/internal/version.date={date}
          stamp-check: kempt
          tag: ${{ steps.rel.outputs.tag }}
          version: ${{ steps.rel.outputs.version }}
          commit: ${{ steps.rel.outputs.commit }}
          date: ${{ steps.rel.outputs.date }}
          create: ${{ steps.rel.outputs.create }}
          prerelease: ${{ steps.rel.outputs.prerelease }}
          release-title: kempt ${{ steps.rel.outputs.tag }}
          apple-developer-id-p12: ${{ secrets.APPLE_DEVELOPER_ID_P12 }}
          apple-developer-id-p12-password: ${{ secrets.APPLE_DEVELOPER_ID_P12_PASSWORD }}
          apple-notary-key: ${{ secrets.APPLE_NOTARY_KEY }}
          apple-notary-key-id: ${{ secrets.APPLE_NOTARY_KEY_ID }}
          apple-notary-issuer-id: ${{ secrets.APPLE_NOTARY_ISSUER_ID }}
          dl-tool: kempt
          dl-role-arn: ${{ secrets.KEMPT_RELEASE_ROLE_ARN }}
          dl-bucket: ${{ secrets.KEMPT_DOWNLOADS_BUCKET }}
          dl-distribution-id: E309WZW10YNEN
          receipt-key-arn: ${{ vars.RELEASE_RECEIPT_KEY_ARN }}
```

`github-release` (default `"true"`): set `"false"` for a private repo whose binaries reach users only through `/dl`. It skips creating the GitHub release and uploading its assets, and nothing else: signing, notarizing, checksums and the `/dl` publish run as before. When `create` is true it pushes the annotated tag `<tag>` at the released commit itself (the tag `gh release create` would have made; a tag already on `origin`, such as a pushed prefixed tag, is left alone), so `release-version` sees the version as released and later pushes don't republish it. The job's token needs `contents: write` and checkout's default persisted credentials. `extra-assets` then land only in `dist/` and `checksums.txt`.

A step that must run before the build (galley's wasm client) goes before `go-release`; files the release should carry beyond the tarballs (muster's Lambda zip) are written into `dist/` first and listed in `extra-assets`, which attaches them to the GitHub release and publishes them beside the tarballs on `/dl/<tool>/<version>/`. An extra asset that also matches the tarball glob is selected once by its exact path for checksums, GitHub uploads and download-page copies.

## Receipts

Every file the action publishes under `/dl/<tool>/<version>/` (each tarball and each extra asset, not the `.sha256` files) gets two more files beside it:

- `<file>.receipt`: one line of JSON with exactly these fields in this order, compact, with one trailing newline. The platform is in the file name, so it has no field of its own.

  ```json
  {"tool":"kempt","version":"1.4.0","file":"kempt_darwin_arm64.tar.gz","sha256":"<hex sha256 of the file>"}
  ```

- `<file>.receipt.sig`: the base64 of the Ed25519 signature over the exact bytes of `<file>.receipt`, followed by a newline.

The signature is made by the family's KMS key, named by the input `receipt-key-arn` (the org variable `RELEASE_RECEIPT_KEY_ARN`), with `aws kms sign --message-type RAW --signing-algorithm ED25519_SHA_512`. That is plain Ed25519, so Go's `ed25519.Verify` accepts it with the key's public half; the prehash algorithm is never used. The job's role needs `kms:Sign` and `kms:GetPublicKey` on the key.

Before a receipt is uploaded, the job checks its signature with something other than the signer: it fetches the public key with `aws kms get-public-key` and verifies with Go's `crypto/ed25519` (`verify-receipt/main.go`, built with the job's Go). A release fails if signing or that check fails, and `latest` is written only after every receipt is published, so `latest` never names a version without receipts.

`receipt-key-arn` is required whenever `dl-tool` is set. Without it the action fails in its first step, before anything is built. A tool that does not publish to `/dl` (no `dl-tool`) needs nothing and is unchanged.

## A published version is write-once

Files under `/dl/<tool>/<version>/` are created with `aws s3 cp --no-overwrite` (it sends `If-None-Match: *`; AWS CLI 2.33.0 or newer, which the `macos-26` and `ubuntu-26.04` images have), and each is then read back and compared with the local file. So when something is already published at a path:

- the same bytes: it is left as it is and the run goes on. This is a re-run after a partial upload.
- different bytes: the release fails with `<tool> <version> is already published with different files (<file>); cut a new version`. Every `.sha256` goes before the first file, so a build that differs from the published one fails before any of its files is sent.

Receipts follow the same rule: a published receipt must equal the one this run wrote, and its published signature must verify. The role needs `s3:GetObject` on the bucket's `dl/*` for the comparison. Only `/dl/<tool>/latest` is ever overwritten.

What a rebuild of an existing tag (the workflow's `tag` input) means now: the GitHub release's assets may be replaced (`--clobber`), but the `/dl` files of a published version never are. A rebuild whose files come out byte-identical passes; one whose files differ, which signing and notarizing a macOS binary again normally causes, fails at the `/dl` step with the line above, after the GitHub release's assets were replaced. Use a rebuild to finish a version whose `/dl` publish never completed; to change what a version serves, cut a new version.

## Upgrading to v0.17.0

A caller that sets `dl-tool` must add one line to the step's `with:`, or the release fails in its first step:

```yaml
          receipt-key-arn: ${{ vars.RELEASE_RECEIPT_KEY_ARN }}
```

Its release role must also be able to sign with that key and read `dl/*` in its downloads bucket; tools-ops grants both to every family release role. Nothing else changes for callers.
