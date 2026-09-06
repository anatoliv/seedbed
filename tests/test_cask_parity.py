"""The Homebrew cask and the DMG readme must tell people the same thing.

Seedbed is a front end. Installed on its own it opens, finds no library and no
interpreter, and reports `0 prompts · 0 models` — which is why both install
paths carry the same two instructions: clone the repository, and have Python
3.11+. The DMG says it in *Before you start.txt*; the cask says it in `caveats`.

Written twice they drift, and they drift in the direction nobody notices: the
owner installs from neither. `brew install --cask seedbed` is the one path this
house never exercises, so a caveats block that has gone stale, lost its second
half, or been hand-edited to say something the DMG does not is invisible until a
stranger hits it.

So the cask is GENERATED from `macos/Packaging/dmg-readme.txt` by
`macos/Scripts/support/cask.py`, and this file pins the properties that make
that generation worth anything:

  * the committed cask really is what the generator produces (a generator
    nothing checks is a suggestion);
  * the derived body still carries both instructions, so a restructured readme
    fails here rather than shipping three lines of nothing;
  * the version stays pinned as "<short>,<build>", because the appcast carries
    both fields and Homebrew's Sparkle livecheck reports them joined — pinning
    only the short version fails `brew audit --online` and breaks autobumping.

`macos/Scripts/check-release.sh` enforces the same generation against the real
DMG at release time. This suite runs everywhere and needs no artifacts, so it
catches the drift at the moment it is introduced instead of at the next release.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SUPPORT = REPO / "macos" / "Scripts" / "support"
CASK = REPO / "Casks" / "seedbed.rb"
README = REPO / "macos" / "Packaging" / "dmg-readme.txt"

sys.path.insert(0, str(SUPPORT))
import cask as cask_tool  # noqa: E402


class CaskParity(unittest.TestCase):
    def setUp(self) -> None:
        self.cask_text = CASK.read_text()
        self.body = cask_tool.shared_body(README.read_text())

    def test_the_committed_cask_is_what_the_readme_generates(self) -> None:
        """Hand-editing the caveats block is the normal way this drifts."""
        version = re.search(r'^  version "([^"]+)"$', self.cask_text, re.M)
        sha = re.search(r'^  sha256 "([0-9a-f]{64})"$', self.cask_text, re.M)
        self.assertIsNotNone(version, "the cask has no pinned version")
        self.assertIsNotNone(sha, "the cask has no pinned sha256")

        short, build = version.group(1).split(",")
        regenerated = cask_tool.render(
            self.cask_text, short, build, sha.group(1), self.body)
        self.assertEqual(
            regenerated, self.cask_text,
            "Casks/seedbed.rb is not what macos/Packaging/dmg-readme.txt "
            "generates. Edit the readme and run macos/Scripts/sync-cask.sh; do "
            "not edit the caveats block by hand.")

    def test_the_derived_body_still_carries_both_instructions(self) -> None:
        """A silently truncated derivation is worse than no caveats at all."""
        cask_tool.assert_shared_body(self.body)
        self.assertIn("git clone", self.body)
        self.assertIn("3.11", self.body)
        # And they have to survive into the cask, not merely exist upstream.
        self.assertIn("git clone", self.cask_text)
        self.assertIn("Python 3.11", self.cask_text)

    def test_the_version_is_pinned_as_short_comma_build(self) -> None:
        """`brew audit --online` fails on a bare short version, and autobump breaks."""
        version = re.search(r'^  version "([^"]+)"$', self.cask_text, re.M).group(1)
        self.assertRegex(
            version, r"^\d+\.\d+\.\d+,\d+$",
            "pin '<short>,<build>': the appcast carries both "
            "sparkle:shortVersionString and sparkle:version, and Homebrew's "
            "Sparkle livecheck reports them as one comma value")

    def test_the_url_uses_the_short_version_only(self) -> None:
        """`#{version}` in the URL would ask seedbed.dev for `Seedbed_0.1.4,5_…`."""
        url = re.search(r'^  url "([^"]+)"', self.cask_text, re.M)
        self.assertIsNotNone(url, "the cask has no url")
        self.assertIn("version.csv.first", url.group(1),
                      "the pinned version carries the build number, so the "
                      "download URL has to take only the first CSV field")

    def test_the_dmg_and_the_cask_agree_word_for_word(self) -> None:
        """The whole point: one source, two surfaces, no divergence."""
        for line in self.body.splitlines():
            if line.strip():
                self.assertIn(line.strip(), self.cask_text,
                              f"the DMG readme says {line.strip()!r} and the cask does not")

    def test_zap_never_touches_the_prompt_library(self) -> None:
        """It is a git checkout the user chose the location of, not app state.

        `zap` removing someone's repository would be a data-loss bug wearing an
        uninstall's clothes, and the cask cannot know where they put it.
        """
        zap = re.search(r"zap trash: \[(.*?)\]", self.cask_text, re.S)
        self.assertIsNotNone(zap, "the cask has no zap stanza")
        for path in re.findall(r'"([^"]+)"', zap.group(1)):
            self.assertTrue(
                path.startswith("~/Library/"),
                f"{path} is outside ~/Library — zap removes app state, not a user's files")


if __name__ == "__main__":
    unittest.main()
