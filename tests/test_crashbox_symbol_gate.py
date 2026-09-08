"""A Crashbox release must name its dSYM, and the name must be checked.

Crashbox pairs a binary with a dSYM by build UUID and by nothing else. A dSYM
from a near-identical build produces reports with no function names while every
other signal looks healthy: the upload succeeded, the artifact is `ready`, the
catalog holds both architectures. Nobody finds out until a real crash arrives
months later with an empty stack.

The upload itself cannot happen here — it is OS-authenticated on the Crashbox
host and no upload credential belongs in a published script — so `release.sh`
takes the operator's word for what was uploaded and then checks that word
against the binary it just built. The declaration alone would be a rubber
stamp; the comparison is what makes it a gate.

Between 2026-09-05 and 2026-09-08 the script simply refused every Crashbox
build outright, which is why the first Crashbox release could not be cut at
all. These tests pin the replacement: still fails closed, but on something it
can actually verify.
"""

from __future__ import annotations

import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RELEASE = REPO / "macos" / "Scripts" / "release.sh"


class ACrashboxReleaseDeclaresItsSymbols(unittest.TestCase):
    def setUp(self) -> None:
        self.source = RELEASE.read_text()

    def test_it_refuses_without_a_declared_artifact(self) -> None:
        self.assertIn(
            'if [[ -z "${CRASHBOX_DSYM_ARTIFACT:-}" || -z "${CRASHBOX_DSYM_UUIDS:-}" ]]',
            self.source,
            "a Crashbox build can be released without naming the dSYM that "
            "would symbolicate it")

    def test_the_refusal_is_before_the_build(self) -> None:
        """Refusing after the build wastes a notarization and teaches people to
        set the variable blind rather than go and read the catalog."""
        refusal = self.source.index('CRASHBOX_DSYM_ARTIFACT:-')
        build = self.source.index("./Scripts/make-app.sh")
        self.assertLess(refusal, build)

    def test_the_uuids_are_compared_against_the_shipped_binary(self) -> None:
        """The declaration is a claim. This is the part that tests it."""
        self.assertIn('dwarfdump --uuid "$APP/Contents/MacOS/Seedbed"', self.source,
                      "nothing asks the shipped binary what its UUIDs are, so "
                      "the declared ones are never contradicted")
        self.assertIn('if [[ "$BUILT_UUIDS" != "$DECLARED_UUIDS" ]]', self.source)

    def test_the_comparison_happens_after_the_build(self) -> None:
        build = self.source.index("./Scripts/make-app.sh")
        compare = self.source.index('if [[ "$BUILT_UUIDS" != "$DECLARED_UUIDS" ]]')
        self.assertLess(
            build, compare,
            "the UUID comparison reads a binary that does not exist yet")

    def test_a_mismatch_stops_the_release(self) -> None:
        start = self.source.index('if [[ "$BUILT_UUIDS" != "$DECLARED_UUIDS" ]]')
        branch = self.source[start:start + 1200]
        self.assertIn("exit 1", branch,
                      "a dSYM that belongs to another build must stop the "
                      "release, not warn and continue")

    def test_both_sides_are_normalized_before_comparing(self) -> None:
        """dwarfdump prints upper case and a pasted catalog row may not.

        A gate that fails on a correct value is a gate someone switches off, so
        the case and the ordering are normalized on both sides rather than
        assumed to agree."""
        self.assertEqual(
            2, self.source.count("tr 'a-f' 'A-F'"),
            "the declared UUIDs and the built ones must be normalized the same "
            "way, or the comparison is between two different shapes")
        self.assertEqual(2, self.source.count("LC_ALL=C sort -u"))

    def test_no_upload_credential_is_present(self) -> None:
        """The reason the upload is out of band in the first place."""
        for token in ("CRASHBOX_ARTIFACT_ROOT", "PGPASSWORD", "crashbox-artifact-upload"):
            self.assertNotIn(
                token, self.source,
                f"{token} in a published release script moves a private "
                "credential or a private path into the public repository")


if __name__ == "__main__":
    unittest.main()
