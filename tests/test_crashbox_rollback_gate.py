"""A Crashbox release must have a retained release to fall back to.

`docs/crashbox-pilot.md` opened with four conditions that had to hold before a
Crashbox build could be published, and nothing on the release path checked any
of them. So 0.1.9 shipped past one of the four, and the only thing that noticed
was a person re-reading the file the next day. A gate that only exists in prose
is enforced by whoever happens to re-read the prose.

Two of those four still bind. `tests/test_crashbox_symbol_gate.py` pins the
first: the declared dSYM must belong to the binary that ships. This pins the
other one. Crashbox is the provider being proved here, its failure modes are
still being found, and the documented response to a bad one is to restore the
previous release. That is only a plan while the artifact still exists:
re-pinning the appcast, the cask and the site at a version nobody can download
is not a rollback.

Presence is not enough, so stapling is checked too. Without a stapled ticket
the copy dragged out of the image has to reach Apple to be verified and fails
on a Mac that is offline or behind a filter, which is not the rollback anyone
wants during an incident.

These tests read the script rather than running it. Exercising the real path
costs a signed, notarized build and five minutes of Apple's time per attempt,
which is the reason the check went missing in the first place.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RELEASE = REPO / "macos" / "Scripts" / "release.sh"
PILOT = REPO / "docs" / "crashbox-pilot.md"

# Hosts, private addresses and tracker ids. docs/crashbox-pilot.md is NOT in the
# exclude list in Scripts/publish-repo.sh, so every word of it is published.
INTERNAL = re.compile(r"192\.168\.|(?:^|[^0-9.])10\.\d+\.\d+\.\d+|"
                      r"\b(?:web|ai|db|nas|dev|tm)-\d{2}\b|TBX-\d")


class ACrashboxReleaseKeepsSomethingToRollBackTo(unittest.TestCase):
    def setUp(self) -> None:
        self.source = RELEASE.read_text()

    def test_the_check_exists_and_is_scoped_to_a_crashbox_build(self) -> None:
        self.assertIn(
            "ROLLBACK_TAG=", self.source,
            "nothing on the release path asks whether a rollback target still "
            "exists, so the documented response to a Crashbox failure is an "
            "intention rather than an artifact")
        scope = self.source.rindex('if [[ "$REPORTING_PROVIDER" == "crashbox" ]]',
                                   0, self.source.index("ROLLBACK_TAG="))
        self.assertLess(
            scope, self.source.index("ROLLBACK_TAG="),
            "the rollback check is not inside a crashbox-only branch")

    def test_the_previous_release_is_found_by_tag_not_hard_coded(self) -> None:
        """A version pinned in the script is one that stops being the previous
        one on the next release, and a gate aimed at the wrong artifact passes
        forever."""
        self.assertIn("git tag --list 'v*' --sort=-v:refname", self.source)
        self.assertIn('grep -v "^v${VERSION}\\$"', self.source,
                      "the current version's own tag must be excluded, or a "
                      "FORCE_REBUILD compares the release against itself")

    def test_the_artifact_must_actually_be_on_disk(self) -> None:
        self.assertIn('if [[ ! -f "$ROLLBACK_DMG" ]]', self.source,
                      "nothing checks that the previous release's DMG is still "
                      "there")

    def test_presence_alone_does_not_satisfy_it(self) -> None:
        """An unstapled DMG is not a release anyone can install offline."""
        self.assertIn('xcrun stapler validate "$ROLLBACK_DMG"', self.source,
                      "a rollback target is accepted on presence alone, so an "
                      "unstapled or de-notarized DMG would pass")

    def test_both_failures_stop_the_release(self) -> None:
        for anchor in ('if [[ ! -f "$ROLLBACK_DMG" ]]',
                       'if ! xcrun stapler validate "$ROLLBACK_DMG"'):
            with self.subTest(anchor=anchor):
                branch = self.source[self.source.index(anchor):][:1400]
                self.assertIn("exit 1", branch,
                              "a missing or unusable rollback target must stop "
                              "the release; warning and continuing is the "
                              "fail-open shape this gate exists to remove")

    def test_it_refuses_before_the_build(self) -> None:
        """Learning about it after a build and two notarizations costs ten
        minutes, and a gate that expensive stops being run. Same argument the
        preflight half of check-release.sh is built on."""
        self.assertLess(
            self.source.index("ROLLBACK_TAG="),
            self.source.index("./Scripts/make-app.sh"),
            "the rollback check runs only after the build")

    def test_the_first_release_is_not_refused(self) -> None:
        """Before anything has shipped there is nothing to retain. Failing
        closed there would be a gate that cannot be satisfied rather than one
        that is hard to satisfy, and the way that gets resolved is by deleting
        it."""
        start = self.source.index('if [[ -z "$ROLLBACK_TAG" ]]')
        branch = self.source[start:self.source.index("else", start)]
        self.assertNotIn("exit 1", branch)

    def test_it_reads_the_dist_and_app_variables(self) -> None:
        """A second spelling of the artifact path is a second thing to keep in
        step with the first."""
        self.assertIn('"${DIST}/${APP_NAME}_${ROLLBACK_TAG#v}_"*.dmg', self.source)


class ThePilotDocumentIsHonestAndPublishable(unittest.TestCase):
    """docs/crashbox-pilot.md ships in the public snapshot.

    Scripts/publish-repo.sh excludes the plan, the design notes and the
    experiment transcripts from docs/, and does not exclude this file. So it
    travels, and it is held to the same rule site/ is: no internal hosts, no
    private addresses, no tracker ids.
    """

    def setUp(self) -> None:
        self.text = PILOT.read_text()

    def test_it_names_nothing_internal(self) -> None:
        hit = INTERNAL.search(self.text)
        self.assertIsNone(
            hit, f"docs/crashbox-pilot.md is published and names something "
                 f"internal: {hit and hit.group(0)}")

    def test_it_records_what_shipped_rather_than_forbidding_it(self) -> None:
        """The defect this file had was not a wrong rule, it was a rule that
        had been overtaken and said nothing about it. A reader has to be able
        to tell the two apart without going to the git log."""
        self.assertIn("0.1.9", self.text,
                      "the document does not mention the release that was cut "
                      "under it, so a reader cannot tell whether the gate is "
                      "live or historical")
        self.assertNotIn(
            "Do not install or publish the Crashbox build until all of these "
            "are true", self.text,
            "the unqualified prohibition is back, and a Crashbox build has "
            "already shipped; a rule the artifact contradicts teaches its "
            "reader to disbelieve the whole file")

    def test_it_points_at_the_checks_that_actually_run(self) -> None:
        for name in ("test_crashbox_symbol_gate.py",
                     "test_crashbox_rollback_gate.py"):
            with self.subTest(name=name):
                self.assertIn(
                    name, self.text,
                    "the document should name the test that pins each "
                    "surviving condition, so a reader can tell prose from a "
                    "gate")


if __name__ == "__main__":
    unittest.main()
