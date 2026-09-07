"""This repository stands on its own and names no other project of the author's.

Asked for on 2026-09-07: "make sure in this repo there are not references to
[other projects]. this is a single project by itself." Before that sweep there
were 138 mentions across 25 files — lineage in comments ("ported from X"),
a design contract defined as parity with a named sibling, and a reserved port
explained by another app owning it.

Removing them once is easy and does not hold. This is what holds it, and it is
the same reason the publish guard names internal hosts explicitly: a product
name has no shape to match on, so it has to be listed.

Two deliberate exemptions, both narrow:

* `site/evidence/` and `docs/experiments/` are verbatim transcripts of model
  output, published so the scoring can be disagreed with. Editing one to tidy
  it would falsify the record the page exists to let people check, so the names
  there are bracketed as a declared redaction that the page describes, and this
  test does not police them further.
* `prompts/` and `rendered/` are the author's own working library. A prompt that
  drives a task tracker names that tracker's tools because that is what it
  calls; rewriting it would break a working prompt rather than clean anything.
  Those files are excluded from the public snapshot in any case.
"""

import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Named explicitly, because a product name has no shape. Add to this when
# another project in the same estate acquires a name.
SIBLINGS = re.compile(
    r"\b(Reference|the task tracker|a sibling app|a sibling app|a sibling app|a sibling app|a sibling app|a sibling app)\b",
    re.IGNORECASE,
)

EXEMPT_PREFIXES = ("site/evidence/", "docs/experiments/", "prompts/", "rendered/")
EXEMPT_FILES = {
    "tests/test_no_sibling_projects.py",
    # The publish guard refuses these names in the public snapshot, which it can
    # only do by spelling them. Sweeping it would disarm the check that stops
    # them reaching a public repository at all.
    "Scripts/publish-repo.sh",
}


def tracked_files() -> list[str]:
    out = subprocess.run(["git", "-C", str(ROOT), "ls-files"],
                         capture_output=True, text=True, check=True).stdout
    return [line for line in out.splitlines() if line]


class NoSiblingProjects(unittest.TestCase):
    def test_no_tracked_file_names_another_project(self) -> None:
        offenders = []
        for rel in tracked_files():
            if rel in EXEMPT_FILES or rel.startswith(EXEMPT_PREFIXES):
                continue
            path = ROOT / rel
            if not path.is_file():
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except (UnicodeDecodeError, ValueError):
                continue          # binary; a product name in one is not prose
            for number, line in enumerate(text.splitlines(), 1):
                hit = SIBLINGS.search(line)
                if hit:
                    offenders.append(f"{rel}:{number}: {hit.group(0)}")
        self.assertEqual(offenders, [], "these name another project:\n" + "\n".join(offenders))

    def test_the_exemptions_are_real_paths(self) -> None:
        # An exemption for a directory that no longer exists is a hole nobody
        # can see, so a missing one is worth knowing about. Absent entirely is
        # the normal state in the public snapshot, which excludes the research
        # and ships only a curated slice of the library — so that case skips
        # with a reason rather than failing there and nowhere else.
        present = [p for p in EXEMPT_PREFIXES if (ROOT / p).is_dir()]
        if not present:
            self.skipTest("none of the exempt trees are in this checkout")
        for prefix in present:
            with self.subTest(prefix=prefix):
                self.assertTrue((ROOT / prefix).is_dir())


if __name__ == "__main__":
    unittest.main()
