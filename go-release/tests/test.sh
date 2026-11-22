#!/usr/bin/env bash
# Tests for go-release's scripts. Real `go build` of a tiny module; fakes for
# codesign, xcrun, security, aws and gh record their calls in $W/calls.
#
# Usage: test.sh   (needs go on PATH; exit 0 = all pass)
# check() evaluates its condition later, so conditions are single-quoted on purpose.
# shellcheck disable=SC2016,SC2034  # ...and variables they read (rc) look unused to shellcheck
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
A="$(cd "$HERE/.." && pwd)"

pass=0; failn=0
ok()   { echo "  PASS $1"; pass=$((pass+1)); }
fail() { echo "  FAIL $1"; failn=$((failn+1)); }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

command -v go >/dev/null || { echo "test.sh: needs go" >&2; exit 2; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
for t in codesign xcrun security aws gh ditto; do
  cat > "$W/bin/$t" <<FAKE
#!/usr/bin/env bash
echo "$t \$*" >> "$W/calls"
case "$t \$1" in
  "xcrun notarytool") [ "\$2" = submit ] && echo "  status: \${FAKE_NOTARY_STATUS:-Accepted}"; exit 0;;
  "security find-identity") echo '  1) ABC "Developer ID Application: Test (TEAM)"'; exit 0;;
  "aws s3") [ "\$2" = cp ] && [ "\$3" = - ] && cat > "$W/latest-body"; exit 0;;
esac
exit 0
FAKE
  chmod +x "$W/bin/$t"
done
cat > "$W/bin/gh" <<'FAKE'
#!/usr/bin/env bash
echo "gh $*" >> "$W/calls"
if [ "$1 $2" = "release upload" ]; then
  shift 3
  seen=()
  for arg in "$@"; do
    case "$arg" in dist/*)
      for previous in ${seen[@]+"${seen[@]}"}; do
        if [ "$arg" = "$previous" ]; then
          echo "HTTP 422: ReleaseAsset.name already exists: $arg" >&2
          exit 1
        fi
      done
      seen+=("$arg")
    esac
  done
fi
FAKE
# Fake git for publish-dl: ls-remote prints every tag in FAKE_TAGS, unfiltered
# by the pattern (so the script's own exact filter is what's tested), or fails
# with FAKE_LSREMOTE_FAIL; anything else goes to the real git.
mkdir -p "$W/gitbin"
cat > "$W/gitbin/git" <<FAKE
#!/usr/bin/env bash
if [ "\$1" = ls-remote ]; then
  echo "git \$*" >> "$W/calls"
  if [ -n "\${FAKE_LSREMOTE_FAIL:-}" ]; then echo "\$FAKE_LSREMOTE_FAIL" >&2; exit 128; fi
  for t in \${FAKE_TAGS:-}; do printf '0123abcd\trefs/tags/%s\n' "\$t"; done
  exit 0
fi
exec "$(command -v git)" "\$@"
FAKE
chmod +x "$W/gitbin/git"
# Fake aws for publish-dl: a bucket under $W/s3 (--no-overwrite keeps an
# existing object, as S3 does on If-None-Match), and a KMS that signs with a
# real Ed25519 test key, so the script's own verification is real.
# FAKE_KMS_BAD signs other bytes, as a wrong key would.
mkdir -p "$W/fakekms"
cat > "$W/fakekms/main.go" <<'GOSRC'
package main

import (
	"crypto/ed25519"
	"crypto/x509"
	"encoding/base64"
	"fmt"
	"os"
)

func main() {
	key := ed25519.NewKeyFromSeed([]byte("go-release-test-receipt-key-seed"))
	switch os.Args[1] {
	case "pub":
		der, err := x509.MarshalPKIXPublicKey(key.Public())
		if err != nil {
			panic(err)
		}
		fmt.Println(base64.StdEncoding.EncodeToString(der))
	case "sign":
		msg, err := os.ReadFile(os.Args[2])
		if err != nil {
			panic(err)
		}
		if os.Getenv("FAKE_KMS_BAD") != "" {
			msg = append(msg, 'x')
		}
		fmt.Println(base64.StdEncoding.EncodeToString(ed25519.Sign(key, msg)))
	}
}
GOSRC
( cd "$W/fakekms" && go build -o "$W/bin/fakekms" main.go ) || { echo "test.sh: could not build the fake KMS" >&2; exit 2; }
cat > "$W/bin/aws" <<'FAKE'
#!/usr/bin/env bash
echo "aws $*" >> "$W/calls"
obj() { printf '%s' "$W/s3/${1#s3://}"; }
case "$1 $2" in
  "s3 cp")
    src="$3"; dst="$4"
    if [ "$src" = - ]; then cat > "$W/latest-body"; exit 0; fi
    if [[ $src == s3://* ]]; then
      [ -z "${FAKE_S3_NOREAD:-}" ] && [ -f "$(obj "$src")" ] || { echo "fatal error: An error occurred (403) when calling the HeadObject operation: Forbidden" >&2; exit 1; }
      if [ "$dst" = - ]; then cat "$(obj "$src")"; else cp "$(obj "$src")" "$dst"; fi
      exit 0
    fi
    case " $* " in *" --no-overwrite "*) [ -e "$(obj "$dst")" ] && exit 0;; esac
    mkdir -p "$(dirname "$(obj "$dst")")"
    cp "$src" "$(obj "$dst")";;
  "kms get-public-key") fakekms pub;;
  "kms sign")
    while [ $# -gt 0 ]; do [ "$1" = --message ] && msg="${2#fileb://}"; shift; done
    fakekms sign "$msg";;
esac
FAKE
export W
export RECEIPT_KEY_ARN=arn:aws:kms:us-east-1:111122223333:key/test
export PATH="$W/bin:$PATH"

# A tiny module whose binary prints the family version line.
mod="$W/repo"; mkdir -p "$mod/cmd/demo" "$mod/cmd/demo-deploy"
cat > "$mod/go.mod" <<'GOMOD'
module example.com/demo

go 1.22
GOMOD
for b in demo demo-deploy; do
cat > "$mod/cmd/$b/main.go" <<GOSRC
package main

import (
	"fmt"
	"os"
)

var version, commit, date string

func main() {
	if len(os.Args) > 1 && os.Args[1] == "version" {
		if "$b" == "demo-deploy" {
			fmt.Println("I AM NOT A TOOLS.APP BINARY AND MUST NOT BE RUN")
			os.Exit(9)
		}
		s := version + " (" + commit
		if date != "" {
			s += ", " + date
		}
		fmt.Println("$b " + s + ")")
	}
}
GOSRC
done


common=(VERSION=1.2.3 COMMIT=abc1234 DATE=2026-09-28
  LDFLAGS='-X main.version={version} -X main.commit={commit} -X main.date={date}'
  TARGETS="darwin/arm64 darwin/amd64 linux/amd64 linux/arm64")

echo "== build"
: > "$W/calls"
( cd "$mod" && env "${common[@]}" BINARIES=$'demo=./cmd/demo\ndemo-deploy=./cmd/demo-deploy' SIGN=true \
    GO_RELEASE_SIGN_IDENTITY="Developer ID Application: Test (TEAM)" bash "$A/build.sh" ) > "$W/log" 2>&1
check "build succeeds" '[ $? -eq 0 ] || true; [ -f "$mod/dist/demo_linux_amd64/demo" ]'
n=0; for b in demo demo-deploy; do for t in darwin_arm64 darwin_amd64 linux_amd64 linux_arm64; do [ -x "$mod/dist/${b}_${t}/$b" ] && n=$((n+1)); done; done
check "all 8 binaries built (2 bins x 4 targets)" '[ $n -eq 8 ]'
check "only darwin binaries are signed (4 codesign calls)" '[ "$(grep -c "^codesign" "$W/calls")" -eq 4 ] && ! grep "^codesign" "$W/calls" | grep -q linux'
check "codesign uses hardened runtime + timestamp" 'grep "^codesign" "$W/calls" | head -1 | grep -q -- "--options runtime --timestamp"'

: > "$W/calls"; rm -rf "$mod/dist"
( cd "$mod" && env "${common[@]}" BINARIES='demo=./cmd/demo' SIGN=false bash "$A/build.sh" ) > "$W/log" 2>&1
check "SIGN=false builds without codesign" '[ -x "$mod/dist/demo_darwin_arm64/demo" ] && ! grep -q "^codesign" "$W/calls"'

echo "== stamp-check"
rm -rf "$mod/dist"
( cd "$mod" && env "${common[@]}" BINARIES=$'demo=./cmd/demo\ndemo-deploy=./cmd/demo-deploy' SIGN=false bash "$A/build.sh" ) > "$W/log" 2>&1
( cd "$mod" && env VERSION=1.2.3 COMMIT=abc1234 DATE=2026-09-28 STAMP_CHECK=demo bash "$A/stamp-check.sh" ) > "$W/log" 2>&1
check "stamp matches: passes" '[ $? -eq 0 ] || grep -q "stamp ok" "$W/log"'
( cd "$mod" && env VERSION=1.2.3 COMMIT=abc1234 DATE=2026-09-28 STAMP_CHECK=demo bash "$A/stamp-check.sh" ) > "$W/log" 2>&1; rc=$?
check "stamp check reports ok" '[ $rc -eq 0 ] && grep -q "demo 1.2.3 (abc1234, 2026-09-28)" "$W/log"'
( cd "$mod" && env VERSION=1.2.3 COMMIT=abc1234 DATE=2026-09-29 STAMP_CHECK=demo bash "$A/stamp-check.sh" ) > "$W/log" 2>&1; rc=$?
check "wrong date fails" '[ $rc -ne 0 ]'
( cd "$mod" && env VERSION=1.2.3 COMMIT=abc1234 DATE=2026-09-28 STAMP_CHECK=demo bash "$A/stamp-check.sh" ) > "$W/log" 2>&1
check "an unlisted binary is never executed" '! grep -q "NOT A TOOLS.APP" "$W/log"'
( cd "$mod" && env VERSION=1.2.3 COMMIT=abc1234 DATE=2026-09-28 STAMP_CHECK=nothere bash "$A/stamp-check.sh" ) > "$W/log" 2>&1; rc=$?
check "a listed binary that was not built fails" '[ $rc -ne 0 ]'

echo "== notarize"
: > "$W/calls"
( cd "$mod" && env NOTARY_KEY="$(printf key | base64)" NOTARY_KEY_ID=kid NOTARY_ISSUER_ID=iss RUNNER_TEMP="$W" bash "$A/notarize.sh" ) > "$W/log" 2>&1; rc=$?
check "notarize submits and accepts" '[ $rc -eq 0 ] && grep -q "^xcrun notarytool submit" "$W/calls"'
( cd "$mod" && env FAKE_NOTARY_STATUS=Invalid NOTARY_KEY="$(printf key | base64)" NOTARY_KEY_ID=kid NOTARY_ISSUER_ID=iss RUNNER_TEMP="$W" bash "$A/notarize.sh" ) > "$W/log" 2>&1; rc=$?
check "notarize fails when not Accepted" '[ $rc -ne 0 ]'
( cd "$mod" && env NOTARY_KEY= RUNNER_TEMP="$W" bash "$A/notarize.sh" ) > "$W/log" 2>&1; rc=$?
check "notarize fails without a key" '[ $rc -ne 0 ] && grep -qi "notary" "$W/log"'

echo "== package"
printf 'zipdata' > "$mod/dist/lambda.zip"
( cd "$mod" && env EXTRA_ASSETS='dist/*.zip' bash "$A/package.sh" ) > "$W/log" 2>&1; rc=$?
check "package succeeds" '[ $rc -eq 0 ]'
n=$(find "$mod/dist" -maxdepth 1 -name '*.tar.gz' | wc -l | tr -d " ")
check "8 tarballs" '[ "$n" -eq 8 ]'
check "each tarball has a .sha256 naming the bare asset" '( for f in "$mod"/dist/*.tar.gz; do grep -qE "^[0-9a-f]{64}  $(basename "$f")$" "$f.sha256" || exit 1; done )'
check ".sha256 verifies" '( cd "$mod/dist" && shasum -a 256 -c demo_linux_amd64.tar.gz.sha256 >/dev/null )'
check "tarball holds just the binary" '[ "$(tar -tzf "$mod/dist/demo_linux_amd64.tar.gz")" = "demo" ]'
check "checksums.txt covers tarballs and extra assets" '[ "$(wc -l < "$mod/dist/checksums.txt" | tr -d " ")" -eq 9 ] && grep -q "  lambda.zip$" "$mod/dist/checksums.txt"'

echo "== github-release"
: > "$W/calls"
( cd "$mod" && env TAG=v1.2.3 CREATE=true PRERELEASE=false TITLE="demo v1.2.3" EXTRA_ASSETS='dist/*.zip' GITHUB_REPOSITORY=o/r GITHUB_SHA=deadbeef bash "$A/github-release.sh" ) > "$W/log" 2>&1; rc=$?
check "creates the release at the commit, with notes" '[ $rc -eq 0 ] && grep -q "^gh release create v1.2.3 --repo o/r --target deadbeef --title demo v1.2.3 --generate-notes$" "$W/calls"'
check "uploads tarballs, .sha256, checksums.txt and extras with --clobber" 'grep "^gh release upload v1.2.3" "$W/calls" | grep -q "checksums.txt" && grep "^gh release upload" "$W/calls" | grep -q "lambda.zip" && grep "^gh release upload" "$W/calls" | grep -q "demo_linux_amd64.tar.gz.sha256" && grep "^gh release upload" "$W/calls" | grep -q -- "--clobber"'
: > "$W/calls"
( cd "$mod" && env TAG=v1.2.3-rc.4 CREATE=true PRERELEASE=true GITHUB_REPOSITORY=o/r GITHUB_SHA=deadbeef bash "$A/github-release.sh" ) > "$W/log" 2>&1
check "an rc is created as a pre-release" 'grep "^gh release create" "$W/calls" | grep -q -- "--prerelease"'
: > "$W/calls"
( cd "$mod" && env TAG=v1.1.0 CREATE=false GITHUB_REPOSITORY=o/r GITHUB_SHA=deadbeef bash "$A/github-release.sh" ) > "$W/log" 2>&1
check "an asset rebuild creates nothing, only uploads" '! grep -q "^gh release create" "$W/calls" && grep -q "^gh release upload v1.1.0" "$W/calls"'
: > "$W/calls"
( cd "$mod" && env TAG=v1.2.3 CREATE=true PRERELEASE=false GITHUB_RELEASE=true GITHUB_REPOSITORY=o/r GITHUB_SHA=deadbeef bash "$A/github-release.sh" ) > "$W/log" 2>&1; rc=$?
check "GITHUB_RELEASE=true creates and uploads" '[ $rc -eq 0 ] && grep -q "^gh release create v1.2.3" "$W/calls" && grep -q "^gh release upload v1.2.3" "$W/calls"'
# GITHUB_RELEASE=false still tags the released commit: the tag is what
# release-version reads to skip a VERSION that is already out.
tr="$W/tagrepo"; rm -rf "$tr" "$W/tagorigin.git"; git init -q --bare "$W/tagorigin.git"
git init -q "$tr" && ( cd "$tr" && git remote add origin "$W/tagorigin.git" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m one && git push -q origin HEAD:refs/heads/main )
sha="$(git -C "$tr" rev-parse HEAD)"
: > "$W/calls"
( cd "$tr" && env TAG=v1.2.3 CREATE=true PRERELEASE=false GITHUB_RELEASE=false GITHUB_REPOSITORY=o/r GITHUB_SHA="$sha" bash "$A/github-release.sh" ) > "$W/log" 2>&1; rc=$?
check "GITHUB_RELEASE=false pushes an annotated tag v<VERSION> at the commit" '[ $rc -eq 0 ] && [ "$(git -C "$W/tagorigin.git" cat-file -t refs/tags/v1.2.3 2>/dev/null)" = tag ] && [ "$(git -C "$W/tagorigin.git" rev-parse "refs/tags/v1.2.3^{commit}")" = "$sha" ] && ! grep -q "^gh " "$W/calls"'
( cd "$tr" && git tag -d v1.2.3 >/dev/null 2>&1; env TAG=v1.2.3 CREATE=true PRERELEASE=false GITHUB_RELEASE=false GITHUB_REPOSITORY=o/r GITHUB_SHA="$sha" bash "$A/github-release.sh" ) > "$W/log" 2>&1; rc=$?
check "GITHUB_RELEASE=false with the tag already on origin (a pushed prefixed tag) succeeds" '[ $rc -eq 0 ] && [ "$(git -C "$W/tagorigin.git" rev-parse "refs/tags/v1.2.3^{commit}")" = "$sha" ]'
( cd "$tr" && env TAG=v1.1.0 CREATE=false GITHUB_RELEASE=false GITHUB_REPOSITORY=o/r GITHUB_SHA="$sha" bash "$A/github-release.sh" ) > "$W/log" 2>&1; rc=$?
check "GITHUB_RELEASE=false asset rebuild (CREATE=false) creates no tag" '[ $rc -eq 0 ] && ! git -C "$W/tagorigin.git" rev-parse -q --verify refs/tags/v1.1.0 >/dev/null'
check "action.yml: github-release input defaults to true and reaches the script" 'grep -A3 "^  github-release:" "$A/action.yml" | grep -q "default: \"true\"" && grep -q "GITHUB_RELEASE: \${{ inputs.github-release }}" "$A/action.yml"'

echo "== publish-dl"
# Uploads to the version's path; reads of what is published are the other lines.
ups='grep -E "^aws s3 cp dist/[^ ]+ s3://bkt/dl/demo/1\.2\.3/" "$W/calls"'
: > "$W/calls"; rm -rf "$W/s3"
( cd "$mod" && env PATH="$W/gitbin:$PATH" FAKE_TAGS="v1.2.3 v1.2.2" DL_TOOL=demo BUCKET=bkt VERSION=1.2.3 TAG=v1.2.3 PROMOTE=true DISTRIBUTION_ID=EDIST EXTRA_ASSETS='dist/*.zip' bash "$A/publish-dl.sh" ) > "$W/log" 2>&1; rc=$?
check "publish succeeds" '[ $rc -eq 0 ]'
check "36 versioned uploads (8 tarballs + 1 extra asset, each with a .sha256, a .receipt and a .receipt.sig)" '[ "$('"$ups"' | wc -l | tr -d " ")" -eq 36 ]'
check "versioned paths are immutable" '[ "$('"$ups"' | grep -vc "max-age=31536000,immutable")" -eq 0 ]'
check "every versioned upload is create-only (--no-overwrite)" '[ "$('"$ups"' | grep -vc -- " --no-overwrite")" -eq 0 ]'
check ".sha256 is text/plain" '[ "$('"$ups"' | grep "\.sha256 s3://" | grep -vc "content-type text/plain")" -eq 0 ]'
check "extra assets are published beside the tarballs" 'grep -q "dist/lambda.zip s3://bkt/dl/demo/1.2.3/lambda.zip " "$W/calls" && grep -q "dist/lambda.zip.sha256 s3://bkt/dl/demo/1.2.3/lambda.zip.sha256 " "$W/calls"'
check "an extra asset's .sha256 names the bare asset and verifies" 'grep -qE "^[0-9a-f]{64}  lambda.zip$" "$mod/dist/lambda.zip.sha256" && ( cd "$mod/dist" && shasum -a 256 -c lambda.zip.sha256 >/dev/null )'
check "latest written with the bare semver" 'grep -q "s3://bkt/dl/demo/latest" "$W/calls" && [ "$(cat "$W/latest-body")" = "1.2.3" ]'
check "latest is short-TTL" 'grep "dl/demo/latest" "$W/calls" | grep -q "max-age=60,must-revalidate"'
check "latest invalidated" 'grep -q "cloudfront create-invalidation --distribution-id EDIST --paths /dl/demo/latest" "$W/calls"'
check "the release tags are listed from origin" 'grep -q "^git ls-remote --tags --refs origin refs/tags/v\*$" "$W/calls" && grep -q "^latest -> 1.2.3$" "$W/log"'
# promote VERSION as TAG ($2) against origin's tags FAKE_TAGS (or FAKE_LSREMOTE_FAIL)
promote() { : > "$W/calls"; rm -rf "$W/latest-body" "$W/s3"; ( cd "$mod" && env PATH="$W/gitbin:$PATH" DL_TOOL=demo BUCKET=bkt VERSION="$1" TAG="$2" PROMOTE=true DISTRIBUTION_ID=EDIST "${@:3}" bash "$A/publish-dl.sh" ) > "$W/log" 2>&1; rc=$?; }
moved='grep -q "^aws s3 cp - s3://bkt/dl/demo/latest " "$W/calls" && grep -q "create-invalidation" "$W/calls"'
left='! grep -q "^aws s3 cp - s3://bkt/dl/demo/latest " "$W/calls" && ! grep -q "create-invalidation" "$W/calls"'
promote 1.10.0 v1.10.0 FAKE_TAGS="v1.9.0 v1.10.0 v1.2.0"
check "the newest tag moves latest (numerically: 1.10.0 over 1.9.0)" '[ $rc -eq 0 ] && '"$moved"' && [ "$(cat "$W/latest-body")" = "1.10.0" ]'
promote 1.9.9 v1.9.9 FAKE_TAGS="v1.9.9 v1.10.0"
check "a version lower than an existing tag leaves latest and says so" '[ $rc -eq 0 ] && '"$left"' && grep -q "^not moving /dl/demo/latest: v1.10.0 is higher$" "$W/log" && grep -q "s3://bkt/dl/demo/1.9.9/" "$W/calls"'
promote 1.2.3 v1.2.3 FAKE_TAGS="v1.2.3 v1.3.0-rc.1 v2.0.0-rc.4"
check "a higher -rc tag does not hold latest back" '[ $rc -eq 0 ] && '"$moved"''
promote 1.2.3 demo/v1.2.3 FAKE_TAGS="demo/v1.2.3 other/v9.0.0 v9.0.0 xdemo/v9.0.0"
check "a <tool>/v prefix only counts its own tool's tags" '[ $rc -eq 0 ] && '"$moved"' && grep -q "^git ls-remote --tags --refs origin refs/tags/demo/v\*$" "$W/calls"'
promote 1.2.3 v1.2.3 FAKE_TAGS="v1.2.3 proj/v9.0.0 v9.0.0x"
check "a plain v prefix ignores proj/v tags" '[ $rc -eq 0 ] && '"$moved"''
promote 1.2.3 v1.2.3 FAKE_LSREMOTE_FAIL="fatal: could not read Username for 'https://github.com'"
check "a failed ls-remote fails the step" '[ $rc -ne 0 ] && '"$left"' && grep -q "could not read Username" "$W/log"'
promote 1.2.3 v1.2.4 FAKE_TAGS="v1.2.3"
check "a TAG that does not end with v<VERSION> fails the step" '[ $rc -ne 0 ] && '"$left"''
: > "$W/calls"
( cd "$mod" && env DL_TOOL=demo BUCKET=bkt VERSION=1.2.3-rc.4 PROMOTE=false DISTRIBUTION_ID=EDIST bash "$A/publish-dl.sh" ) > "$W/log" 2>&1
check "PROMOTE=false never touches latest" '! grep -q "dl/demo/latest" "$W/calls" && ! grep -q "create-invalidation" "$W/calls"'
: > "$W/calls"
( cd "$mod" && env DL_TOOL=demo BINARY_PREFIXES="demo" BUCKET=bkt VERSION=1.2.3 PROMOTE=false DISTRIBUTION_ID=EDIST bash "$A/publish-dl.sh" ) > "$W/log" 2>&1
check "tarballs of every packaged binary go under the tool's path" 'grep -q "dl/demo/1.2.3/demo-deploy_linux_amd64.tar.gz" "$W/calls"'

echo "== receipts"
# publish [ENV=...]: a full release of demo 1.2.3 into the fake bucket as it stands.
publish() { : > "$W/calls"; rm -f "$W/latest-body"; ( cd "$mod" && env PATH="$W/gitbin:$PATH" FAKE_TAGS="v1.2.3" DL_TOOL=demo BUCKET=bkt VERSION=1.2.3 TAG=v1.2.3 PROMOTE=true DISTRIBUTION_ID=EDIST EXTRA_ASSETS='dist/*.zip' "$@" bash "$A/publish-dl.sh" ) > "$W/log" 2>&1; rc=$?; }
line() { grep -n -- "$1" "$W/calls" | "$2" -1 | cut -d: -f1; }
rm -rf "$W/s3"; publish
hex="$(shasum -a 256 "$mod/dist/demo_linux_amd64.tar.gz" | cut -d' ' -f1)"
check "a receipt is exactly tool, version, file, sha256 in that order, compact, one trailing newline" '[ $rc -eq 0 ] && printf "{\"tool\":\"demo\",\"version\":\"1.2.3\",\"file\":\"demo_linux_amd64.tar.gz\",\"sha256\":\"%s\"}\n" "$hex" | cmp -s - "$W/s3/bkt/dl/demo/1.2.3/demo_linux_amd64.tar.gz.receipt"'
check "an extra asset gets a receipt; a .sha256 sidecar gets none" '[ -f "$W/s3/bkt/dl/demo/1.2.3/lambda.zip.receipt" ] && [ -f "$W/s3/bkt/dl/demo/1.2.3/lambda.zip.receipt.sig" ] && [ "$(find "$W/s3" -name "*.receipt" | wc -l | tr -d " ")" -eq 9 ] && [ -z "$(find "$W/s3" -name "*.sha256.receipt*")" ]'
check "the receipt is signed with plain Ed25519 over its raw bytes (never the prehash algorithm)" '[ "$(grep -c "^aws kms sign " "$W/calls")" -eq 9 ] && grep -qx "aws kms sign --key-id $RECEIPT_KEY_ARN --message fileb://dist/demo_linux_amd64.tar.gz.receipt --message-type RAW --signing-algorithm ED25519_SHA_512 --query Signature --output text" "$W/calls" && ! grep -q "ED25519_PH" "$W/calls" "$A"/*.sh'
check "the public key is fetched from KMS for the check" 'grep -qx "aws kms get-public-key --key-id $RECEIPT_KEY_ARN --query PublicKey --output text" "$W/calls"'
check "the published .receipt.sig is the base64 signature KMS returned" 'cmp -s "$mod/dist/demo_linux_amd64.tar.gz.receipt.sig" "$W/s3/bkt/dl/demo/1.2.3/demo_linux_amd64.tar.gz.receipt.sig" && [ "$(base64 -d < "$W/s3/bkt/dl/demo/1.2.3/demo_linux_amd64.tar.gz.receipt.sig" | wc -c | tr -d " ")" -eq 64 ]'
check "receipts are JSON, signatures text" '[ "$('"$ups"' | grep "\.receipt s3://" | grep -vc "content-type application/json")" -eq 0 ] && [ "$('"$ups"' | grep "\.receipt\.sig s3://" | grep -vc "content-type text/plain")" -eq 0 ]'
check "files and sidecars first, receipts next, latest last" '[ "$('"$ups"' | grep -v "\.receipt" | wc -l | tr -d " ")" -eq 18 ] && [ "$(line "^aws s3 cp dist/[^ ]*\(gz\|zip\|sha256\) s3://" tail)" -lt "$(line "^aws kms " head)" ] && [ "$(line "dl/demo/1\.2\.3/" tail)" -lt "$(line "^aws s3 cp - s3://bkt/dl/demo/latest " head)" ]'

rm -rf "$W/s3"; publish FAKE_KMS_BAD=1
check "a signature that does not verify fails the release: no receipt published, latest not moved" '[ $rc -ne 0 ] && grep -q "::error::go-release: the receipt signature for demo.*does not verify" "$W/log" && [ -z "$(find "$W/s3" -name "*.receipt*")" ] && ! grep -q "dl/demo/latest" "$W/calls"'

rm -rf "$W/s3"; publish RECEIPT_KEY_ARN=
check "publish-dl without the receipt key uploads nothing" '[ $rc -ne 0 ] && ! grep -q "^aws " "$W/calls"'
( env DL_TOOL=demo RECEIPT_KEY_ARN= bash "$A/require-receipt-key.sh" ) > "$W/log" 2>&1; rc=$?
check "dl-tool without receipt-key-arn fails, naming the input" '[ $rc -ne 0 ] && grep -q "::error::go-release: receipt-key-arn is required when dl-tool is set" "$W/log"'
( env DL_TOOL=demo bash "$A/require-receipt-key.sh" ) > "$W/log" 2>&1; rc=$?
check "dl-tool with receipt-key-arn passes" '[ $rc -eq 0 ]'
( env DL_TOOL= RECEIPT_KEY_ARN= bash "$A/require-receipt-key.sh" ) > "$W/log" 2>&1; rc=$?
check "no dl-tool needs no receipt key" '[ $rc -eq 0 ]'
check "action.yml: the receipt-key check is the first step, before anything is built" '[ "$(grep -n "require-receipt-key.sh" "$A/action.yml" | cut -d: -f1)" -lt "$(grep -n "actions/setup-go@" "$A/action.yml" | cut -d: -f1)" ] && grep -q "RECEIPT_KEY_ARN: \${{ inputs.receipt-key-arn }}" "$A/action.yml" && [ "$(grep -c "RECEIPT_KEY_ARN: \${{ inputs.receipt-key-arn }}" "$A/action.yml")" -eq 2 ]'

rm -rf "$W/s3"; publish
before="$(cd "$W/s3" && find . -type f -exec shasum -a 256 {} + | sort -k2)"
publish
check "a version already published with the same files is left as it is, and the run passes" '[ $rc -eq 0 ] && [ "$(cd "$W/s3" && find . -type f -exec shasum -a 256 {} + | sort -k2)" = "$before" ] && grep -q "^latest -> 1.2.3$" "$W/log"'
cp "$mod/dist/demo_linux_amd64.tar.gz" "$W/keep.tar.gz"; cp "$mod/dist/demo_linux_amd64.tar.gz.sha256" "$W/keep.sha256"
printf 'rebuilt' >> "$mod/dist/demo_linux_amd64.tar.gz"
( cd "$mod/dist" && shasum -a 256 demo_linux_amd64.tar.gz > demo_linux_amd64.tar.gz.sha256 )
publish
check "a version already published with different files fails with one clear line and changes nothing" '[ $rc -ne 0 ] && [ "$(grep -c "::error::" "$W/log")" -eq 1 ] && grep -q "^::error::go-release: demo 1.2.3 is already published with different files (demo_linux_amd64.tar.gz.sha256); cut a new version$" "$W/log" && [ "$(cd "$W/s3" && find . -type f -exec shasum -a 256 {} + | sort -k2)" = "$before" ] && ! grep -q "dl/demo/latest" "$W/calls"'
cp "$W/keep.sha256" "$mod/dist/demo_linux_amd64.tar.gz.sha256"
publish
check "a published file that differs under a matching sidecar fails too" '[ $rc -ne 0 ] && grep -q "already published with different files (demo_linux_amd64.tar.gz); cut a new version$" "$W/log" && ! grep -q "dl/demo/latest" "$W/calls"'
cp "$W/keep.tar.gz" "$mod/dist/demo_linux_amd64.tar.gz"
printf '{"tool":"demo","version":"1.2.3","file":"lambda.zip","sha256":"00"}\n' > "$W/s3/bkt/dl/demo/1.2.3/lambda.zip.receipt"
publish
check "a published receipt that differs fails" '[ $rc -ne 0 ] && grep -q "already published with different files (lambda.zip.receipt); cut a new version$" "$W/log" && ! grep -q "dl/demo/latest" "$W/calls"'
rm -rf "$W/s3"; publish
cp "$W/s3/bkt/dl/demo/1.2.3/demo_linux_amd64.tar.gz.receipt.sig" "$W/s3/bkt/dl/demo/1.2.3/lambda.zip.receipt.sig"
publish
check "a published signature that does not verify fails" '[ $rc -ne 0 ] && grep -q "::error::go-release: the published receipt signature for lambda.zip does not verify" "$W/log" && ! grep -q "dl/demo/latest" "$W/calls"'
rm -rf "$W/s3"; publish FAKE_S3_NOREAD=1
check "a role that cannot read what is published fails, saying so" '[ $rc -ne 0 ] && [ "$(grep -c "::error::" "$W/log")" -eq 1 ] && grep -q "^::error::go-release: could not read s3://bkt/dl/demo/1.2.3/.*\.sha256 back (the role needs s3:GetObject on dl/\*)$" "$W/log" && ! grep -q "dl/demo/latest" "$W/calls"'
rm -rf "$W/s3"

echo "== overlapping setup TAR extra"
printf 'setup' > "$W/setup.toml"
tar -C "$W" -czf "$mod/dist/demo_setup.tar.gz" setup.toml
( cd "$mod" && env EXTRA_ASSETS='dist/demo_setup.tar.gz dist/*.zip' bash "$A/package.sh" ) > "$W/log" 2>&1; rc=$?
check "overlapping TAR has exactly one aggregate checksum" '[ $rc -eq 0 ] && [ "$(grep -c "  demo_setup.tar.gz$" "$mod/dist/checksums.txt")" -eq 1 ] && [ "$(wc -l < "$mod/dist/checksums.txt")" -eq 10 ]'
: > "$W/calls"
( cd "$mod" && env TAG=v1.2.3 CREATE=false EXTRA_ASSETS='dist/demo_setup.tar.gz dist/*.zip' GITHUB_REPOSITORY=o/r bash "$A/github-release.sh" ) > "$W/log" 2>&1; rc=$?
cat "$W/log"
check "overlapping TAR uploads without duplicate argument HTTP422" '[ $rc -eq 0 ] && [ "$(grep "^gh release upload" "$W/calls" | tr " " "\n" | grep -cx "dist/demo_setup.tar.gz")" -eq 1 ]'
: > "$W/calls"
( cd "$mod" && env DL_TOOL=demo BUCKET=bkt VERSION=1.2.3 PROMOTE=false EXTRA_ASSETS='dist/demo_setup.tar.gz dist/*.zip' bash "$A/publish-dl.sh" ) > "$W/log" 2>&1; rc=$?
check "overlapping TAR and sidecar each copied once" '[ $rc -eq 0 ] && [ "$(grep -c "^aws s3 cp dist/demo_setup.tar.gz " "$W/calls")" -eq 1 ] && [ "$(grep -c "^aws s3 cp dist/demo_setup.tar.gz.sha256 " "$W/calls")" -eq 1 ] && [ "$('"$ups"' | wc -l | tr -d " ")" -eq 40 ]'
check "setup sidecar verifies and rebuild does not promote" '( cd "$mod/dist" && shasum -a 256 -c demo_setup.tar.gz.sha256 >/dev/null ) && ! grep -q "latest" "$W/calls"'

echo "== sign-setup and cleanup"
( env P12= GITHUB_ENV="$W/env" RUNNER_TEMP="$W" bash "$A/sign-setup.sh" ) > "$W/log" 2>&1; rc=$?
check "sign-setup fails without the certificate" '[ $rc -ne 0 ] && grep -q "APPLE_DEVELOPER_ID_P12" "$W/log"'
: > "$W/env"; : > "$W/calls"
( env P12="$(printf p12 | base64)" P12_PASSWORD= GITHUB_ENV="$W/env" RUNNER_TEMP="$W" bash "$A/sign-setup.sh" ) > "$W/log" 2>&1; rc=$?
check "sign-setup exports the identity and keychain" '[ $rc -eq 0 ] && grep -q "^GO_RELEASE_SIGN_IDENTITY=Developer ID Application: Test (TEAM)$" "$W/env" && grep -q "^GO_RELEASE_KEYCHAIN=" "$W/env"'
check "sign-setup removes the decoded certificate" '[ ! -e "$W/cert.p12" ]'
: > "$W/calls"; touch "$W/notary.p8" "$W/cert.p12" "$W/notarize.zip"
( env GO_RELEASE_KEYCHAIN="$W/k.keychain-db" RUNNER_TEMP="$W" bash "$A/cleanup.sh" ) > "$W/log" 2>&1; rc=$?
check "cleanup deletes key files and the keychain" '[ $rc -eq 0 ] && [ ! -e "$W/notary.p8" ] && [ ! -e "$W/cert.p12" ] && grep -q "^security delete-keychain" "$W/calls"'
( env RUNNER_TEMP="$W" bash "$A/cleanup.sh" ) > "$W/log" 2>&1; rc=$?
check "cleanup succeeds when nothing was set up" '[ $rc -eq 0 ]'

echo; echo "passed $pass, failed $failn"
[ "$failn" -eq 0 ]
