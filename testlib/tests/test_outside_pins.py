"""Every outside action this repo runs is pinned by commit.

A tag in someone else's repo can be moved; a commit cannot. So every ``uses:``
in a composite ``action.yml`` or a workflow that names an action outside this
repo carries a full 40-hex commit and the version in a trailing comment, the
form Dependabot maintains: ``owner/action@<sha> # vX.Y.Z``. Our own actions
(``subaud-tools/tools-actions/...`` and local ``./``) stay on release tags.
"""

from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

_USES = re.compile(r"^\s*(?:-\s+)?uses:\s*(\S+)(.*)$")
_COMMIT_PIN = re.compile(r"^[\w.-]+/[\w./-]+@[0-9a-f]{40}$")
_VERSION_COMMENT = re.compile(r"^ # v\d+\.\d+\.\d+$")


def _files() -> list[Path]:
    files = sorted(REPO_ROOT.glob("*/action.yml"))
    files += sorted((REPO_ROOT / ".github" / "workflows").glob("*.yml"))
    return files


def test_outside_actions_are_pinned_by_commit_with_a_version_comment():
    seen = 0
    bad = []
    for path in _files():
        for number, line in enumerate(path.read_text().splitlines(), 1):
            match = _USES.match(line)
            if not match:
                continue
            ref, rest = match.groups()
            if ref.startswith("./") or ref.startswith("subaud-tools/tools-actions/"):
                continue
            seen += 1
            if not (_COMMIT_PIN.match(ref) and _VERSION_COMMENT.match(rest)):
                bad.append(f"{path.relative_to(REPO_ROOT)}:{number}: {line.strip()}")
    assert seen, "expected outside actions in action.yml files and workflows"
    assert not bad, "not pinned as owner/action@<40-hex> # vX.Y.Z:\n" + "\n".join(bad)


def test_dependabot_covers_every_action_that_runs_an_outside_action():
    """Dependabot reads a composite's ``action.yml`` only when its directory is
    listed; an unlisted one keeps its commit pin forever."""
    config = (REPO_ROOT / ".github" / "dependabot.yml").read_text()
    listed = set(re.findall(r'^\s+- "(/[\w-]*)"$', config, re.M))
    assert "/" in listed, "the workflows directory must be listed"
    missing = []
    for path in sorted(REPO_ROOT.glob("*/action.yml")):
        refs = [m.group(1) for m in map(_USES.match, path.read_text().splitlines()) if m]
        outside = [r for r in refs if not r.startswith(("./", "subaud-tools/tools-actions/"))]
        if outside and f"/{path.parent.name}" not in listed:
            missing.append(path.parent.name)
    assert not missing, f"add to .github/dependabot.yml directories: {missing}"
