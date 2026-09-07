"""THIRD-PARTY-NOTICES.md lists what the app actually links, and ships with it.

Sparkle is embedded in the bundle as a framework and the Sentry SDK is linked
into the binary. Both are MIT, and MIT requires its copyright and permission
notice to be included "in all copies or substantial portions of the Software".
Until 2026-09-07 neither notice travelled with the app: there was no notices
file, and the DMG carried only the app and an instructions text.

A notices file is the kind of document that is written once and then quietly
stops matching the dependency list, so this compares it to `Package.resolved`
rather than trusting it.
"""

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NOTICES = ROOT / "THIRD-PARTY-NOTICES.md"
RESOLVED = ROOT / "macos" / "Package.resolved"
RELEASE = ROOT / "macos" / "Scripts" / "release.sh"

# Swift package identity -> the name the notices table uses for it. A package
# added to Package.resolved and missing here fails the test below, which is the
# point: the failure names the dependency nobody attributed.
EXPECTED = {"sparkle": "Sparkle", "sentry-cocoa": "Sentry Cocoa SDK"}


def linked_packages() -> set[str]:
    data = json.loads(RESOLVED.read_text(encoding="utf-8"))
    pins = data.get("pins") or data.get("object", {}).get("pins", [])
    return {p.get("identity") or p.get("package", "") for p in pins}


class ThirdPartyNotices(unittest.TestCase):
    def setUp(self) -> None:
        self.text = NOTICES.read_text(encoding="utf-8")

    def test_every_linked_package_is_attributed(self) -> None:
        for identity in linked_packages():
            with self.subTest(package=identity):
                self.assertIn(identity, EXPECTED,
                              f"{identity} is linked but this test does not know its "
                              f"display name; add it to EXPECTED and to the notices table")
                self.assertIn(EXPECTED[identity], self.text,
                              f"{identity} is linked but THIRD-PARTY-NOTICES.md does not "
                              f"mention {EXPECTED[identity]}")

    def test_nothing_is_attributed_that_is_not_linked(self) -> None:
        # The opposite drift: a dependency removed from the build and left in
        # the notices, which reads as a component the app still ships.
        linked = linked_packages()
        for identity, display in EXPECTED.items():
            if display in self.text:
                with self.subTest(package=identity):
                    self.assertIn(identity, linked,
                                  f"{display} is attributed but is not in Package.resolved")

    def test_the_mit_permission_notice_is_reproduced_in_full(self) -> None:
        # Referencing MIT by name does not satisfy it; the notice itself has to
        # be present. These two sentences are the operative ones.
        for phrase in (
            "The above copyright notice and this permission notice shall be included",
            'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND',
        ):
            with self.subTest(phrase=phrase[:40]):
                self.assertIn(phrase, self.text)

    def test_the_bundled_fonts_are_attributed_and_their_licences_exist(self) -> None:
        fonts = ROOT / "promptlib" / "web" / "fonts"
        for name, licence in (("Inter", "Inter-LICENSE.txt"),
                              ("JetBrains Mono", "JetBrainsMono-LICENSE.txt")):
            with self.subTest(font=name):
                self.assertIn(name, self.text)
                self.assertTrue((fonts / licence).is_file(),
                                f"{licence} is referenced by the notices but is not present")
        self.assertIn("SIL Open Font License", self.text)

    def test_the_notices_ship_in_the_dmg(self) -> None:
        # A notices file that stays in the repository does not satisfy a licence
        # that requires the notice to travel with the copy.
        release = RELEASE.read_text(encoding="utf-8")
        self.assertRegex(
            release, r'THIRD-PARTY-NOTICES\.md"?\s+"\$STAGE',
            "release.sh does not copy THIRD-PARTY-NOTICES.md into the DMG staging directory")
        self.assertRegex(
            release, r'LICENSE"?\s+"\$STAGE',
            "release.sh does not copy LICENSE into the DMG staging directory")


if __name__ == "__main__":
    unittest.main()
