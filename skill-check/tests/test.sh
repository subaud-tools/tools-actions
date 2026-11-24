#!/usr/bin/env bash
# Tests for skill-check/run.sh and check.mjs against tiny real git repos. The
# real npm `yaml` (the lockfile's version) is installed once into a scratch
# cache, so the first run needs the npm registry.
#
# Usage: test.sh   (needs git, node, npm; exit 0 = all pass)
# check() evaluates its condition later, so conditions are single-quoted on purpose.
# shellcheck disable=SC2016,SC2034  # ...and variables they read (rc) look unused to shellcheck
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
A="$(cd "$HERE/.." && pwd)"
pass=0; failn=0
ok()   { echo "  PASS $1"; pass=$((pass+1)); }
fail() { echo "  FAIL $1"; failn=$((failn+1)); sed 's/^/      | /' "$W/log" 2>/dev/null | tail -6; }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }
for t in git node npm; do command -v "$t" >/dev/null || { echo "test.sh: needs $t" >&2; exit 2; }; done

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
export SKILL_CHECK_CACHE="$W/cache"

# mkrepo <dir>: an empty git repo. skill <repo> <path> <content>: a tracked file.
mkrepo() { rm -rf "$1"; mkdir -p "$1"; git -C "$1" init -q .; }
skill() { mkdir -p "$(dirname "$1/$2")"; printf '%s' "$3" > "$1/$2"; git -C "$1" add -- "$2"; }
run() { ( cd "$1" && bash "$A/run.sh" ) > "$W/log" 2>&1; }

# billet's description on 2026-11-23: an unquoted ": " makes a nested mapping.
broken='---
name: billet
description: Sets billet up in your AWS account. Use when the user says: set up billet
---

# billet
'
fixed='---
name: billet
description: "Sets billet up in your AWS account. Use when the user says: set up billet"
---

# billet
'

echo "== the billet case"
mkrepo "$W/r"; skill "$W/r" skills/billet/SKILL.md "$broken"
run "$W/r"; rc=$?
check "an unquoted colon in the description fails" '[ $rc -eq 1 ]'
check "it is reported as a GitHub error on the description line" 'grep -q "^::error file=skills/billet/SKILL.md,line=3::" "$W/log"'
check "with the yaml package message pi shows" 'grep -q "Nested mappings are not allowed in compact mappings" "$W/log"'
check "and as a plain line" 'grep -q "^skills/billet/SKILL.md:3: " "$W/log"'
skill "$W/r" skills/billet/SKILL.md "$fixed"
run "$W/r"; rc=$?
check "the same file, quoted, passes" '[ $rc -eq 0 ] && grep -q "1 SKILL.md" "$W/log"'

echo "== what pi skips or warns about"
mkrepo "$W/r"; skill "$W/r" skills/x/SKILL.md $'---\nname: x\n---\n\nbody\n'
run "$W/r"; rc=$?
check "a missing description fails" '[ $rc -eq 1 ] && grep -q "^::error file=skills/x/SKILL.md,line=1::description is required" "$W/log"'
skill "$W/r" skills/x/SKILL.md $'---\nname: x\ndescription: "  "\n---\n'
run "$W/r"; rc=$?
check "an empty description fails" '[ $rc -eq 1 ] && grep -q "description is required" "$W/log"'
long="$(printf 'a%.0s' $(seq 1 1025))"
skill "$W/r" skills/x/SKILL.md "$(printf -- '---\nname: x\ndescription: %s\n---\n' "$long")"
run "$W/r"; rc=$?
check "a description over 1024 characters fails on its line" '[ $rc -eq 1 ] && grep -q "line=3::description exceeds 1024 characters (1025)" "$W/log"'
skill "$W/r" skills/x/SKILL.md $'---\nname: Bad_Name\ndescription: ok\n---\n'
run "$W/r"; rc=$?
check "a name outside [a-z0-9-] fails on its line" '[ $rc -eq 1 ] && grep -q "line=2::name contains invalid characters" "$W/log"'
skill "$W/r" skills/x/SKILL.md $'---\nname: -a--b-\ndescription: ok\n---\n'
run "$W/r"; rc=$?
check "a name with edge or double hyphens fails" '[ $rc -eq 1 ] && grep -q "must not start or end with a hyphen" "$W/log" && grep -q "must not contain consecutive hyphens" "$W/log"'
skill "$W/r" skills/x/SKILL.md "$(printf -- '---\nname: %s\ndescription: ok\n---\n' "$(printf 'a%.0s' $(seq 1 65))")"
run "$W/r"; rc=$?
check "a name over 64 characters fails" '[ $rc -eq 1 ] && grep -q "name exceeds 64 characters (65)" "$W/log"'
mkrepo "$W/r"; skill "$W/r" skills/Bad_Dir/SKILL.md $'---\ndescription: ok\n---\n'
run "$W/r"; rc=$?
check "with no name, the folder name is checked (as pi does)" '[ $rc -eq 1 ] && grep -q "name contains invalid characters" "$W/log"'
mkrepo "$W/r"; skill "$W/r" skills/x/SKILL.md $'---\nname: x\ndescription: ok\n'
run "$W/r"; rc=$?
check "no closing --- fails" '[ $rc -eq 1 ] && grep -q "^::error file=skills/x/SKILL.md,line=1::.*closing ---" "$W/log"'
skill "$W/r" skills/x/SKILL.md $'# x\n\nno front matter\n'
run "$W/r"; rc=$?
check "no front matter fails" '[ $rc -eq 1 ] && grep -q "line=1::.*no front matter" "$W/log"'

echo "== reading as pi reads"
mkrepo "$W/r"; skill "$W/r" skills/x/SKILL.md $'\xef\xbb\xbf---\r\nname: x\r\ndescription: ok\r\n---\r\n'
run "$W/r"; rc=$?
check "a byte-order mark and CRLF line ends pass" '[ $rc -eq 0 ]'
skill "$W/r" skills/aws/SKILL.md $'---\nname: aws-pack\ndescription: ok\n---\n'
run "$W/r"; rc=$?
check "a name that differs from its folder passes (pi adds no such rule)" '[ $rc -eq 0 ] && grep -q "2 SKILL.md" "$W/log"'
skill "$W/r" docs/NOTSKILL.md $'no front matter\n'
run "$W/r"; rc=$?
check "only files named exactly SKILL.md are checked" '[ $rc -eq 0 ]'

echo "== which files"
mkrepo "$W/r"; printf 'x\n' > "$W/r/README.md"; git -C "$W/r" add README.md
run "$W/r"; rc=$?
check "a repo with no SKILL.md passes" '[ $rc -eq 0 ] && grep -q "0 SKILL.md" "$W/log"'
skill "$W/r" .claude/skills/x/SKILL.md "$broken"
run "$W/r"; rc=$?
check "a nested .claude/skills/x/SKILL.md is checked" '[ $rc -eq 1 ] && grep -q "file=.claude/skills/x/SKILL.md,line=3" "$W/log"'
mkdir -p "$W/r/skills/y"; printf '%s' "$broken" > "$W/r/skills/y/SKILL.md"; git -C "$W/r" rm -q --cached .claude/skills/x/SKILL.md
run "$W/r"; rc=$?
check "an untracked SKILL.md is not checked" '[ $rc -eq 0 ]'
mkrepo "$W/r"; skill "$W/r" skills/a/SKILL.md "$broken"; skill "$W/r" skills/b/SKILL.md $'---\nname: b\n---\n'; skill "$W/r" skills/c/SKILL.md "$fixed"
run "$W/r"; rc=$?
check "every failing file is reported, not only the first" '[ $rc -eq 1 ] && grep -q "file=skills/a/" "$W/log" && grep -q "file=skills/b/" "$W/log" && ! grep -q "file=skills/c/" "$W/log"'

echo "== run.sh"
check "the install is cached by lockfile" '[ -f "$(ls -d "$SKILL_CHECK_CACHE"/*/node_modules/yaml/package.json | head -1)" ]'
check "the installed yaml is the locked version" 'grep -q "\"version\": \"$(node -p "require(\"$A/package-lock.json\").packages[\"node_modules/yaml\"].version")\"" "$(ls -d "$SKILL_CHECK_CACHE"/*/node_modules/yaml/package.json | head -1)"'
mkdir -p "$W/nonode"; for t in bash git dirname cat mkdir cp rm sed head cut shasum sha256sum mktemp; do p="$(command -v "$t" || true)"; [ -n "$p" ] && ln -sf "$p" "$W/nonode/$t"; done
( cd "$W/r" && env PATH="$W/nonode" "$W/nonode/bash" "$A/run.sh" ) > "$W/log" 2>&1; rc=$?
check "no node on PATH fails and says so" '[ $rc -ne 0 ] && grep -q "needs node" "$W/log"'
check "the action runs run.sh from beside its action.yml" 'grep -q "\$GITHUB_ACTION_PATH/run.sh" "$A/action.yml"'

echo; echo "passed $pass, failed $failn"
[ "$failn" -eq 0 ]
