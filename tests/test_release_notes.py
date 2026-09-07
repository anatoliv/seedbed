"""Sparkle's update dialog shows the same notes the app does.

Until 2026-09-07 every item in the feed had no `<description>`, so a user was
asked to accept a new binary against an empty pane — while `WhatsNew.swift`
carried notes for all nine releases and the release gate already refused to ship
a version without one. `Scripts/support/release-notes.py` writes those notes
where generate_appcast looks, which keeps one source for both surfaces.

The parser is the fragile part (it reads Swift with regular expressions), so
these tests exercise it against the real file rather than a fixture.
"""

import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "macos" / "Scripts" / "support" / "release-notes.py"
WHATS_NEW = ROOT / "macos" / "Sources" / "Seedbed" / "WhatsNew.swift"
RELEASE = ROOT / "macos" / "Scripts" / "release.sh"
PLIST = ROOT / "macos" / "Packaging" / "Info.plist"


def load():
    spec = importlib.util.spec_from_file_location("release_notes", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ReleaseNotes(unittest.TestCase):
    def setUp(self) -> None:
        self.rn = load()
        self.releases = self.rn.releases()

    def test_every_release_in_the_source_is_parsed(self) -> None:
        # One entry per `WhatsNewRelease(` in the Swift, so a release that stops
        # parsing is caught here rather than by an empty pane on someone's Mac.
        declared = WHATS_NEW.read_text(encoding="utf-8").count("WhatsNewRelease(\n")
        self.assertEqual(len(self.releases), declared)
        self.assertGreater(len(self.releases), 0)

    def test_no_release_loses_a_change(self) -> None:
        # The first parser dropped the last change of every release: its regex
        # looked ahead for another entry or the end of the block, and the block
        # ends with a trailing comma. Count per release instead of trusting it.
        text = WHATS_NEW.read_text(encoding="utf-8")
        self.assertEqual(sum(len(r["changes"]) for r in self.releases),
                         text.count("WhatsNewChange("))
        for release in self.releases:
            with self.subTest(version=release["version"]):
                self.assertTrue(release["changes"], "a release with no changes listed")
                self.assertTrue(release["highlight"])
                self.assertTrue(release["date"])

    def test_the_current_version_has_notes(self) -> None:
        version = ""
        for line in PLIST.read_text(encoding="utf-8").splitlines():
            if version == "PENDING":
                version = line.strip().removeprefix("<string>").removesuffix("</string>")
                break
            if "CFBundleShortVersionString" in line:
                version = "PENDING"
        self.assertIn(version, [r["version"] for r in self.releases],
                      f"no What's New entry for {version}, so its update dialog would be empty")

    def test_the_rendered_notes_are_an_embeddable_fragment(self) -> None:
        # generate_appcast embeds a notes file as CDATA in <description> only
        # when it has no DOCTYPE and no body tags; with them it wants a URL
        # prefix and separate hosting instead, and silently emits neither.
        body = self.rn.render(self.releases[0]).lower()
        for tag in ("<!doctype", "<html", "<body", "</body>", "</html>"):
            with self.subTest(tag=tag):
                self.assertNotIn(tag, body)
        self.assertIn("<h3>", body)
        self.assertIn("<li>", body)

    def test_notes_are_escaped(self) -> None:
        # The notes contain apostrophes and could contain angle brackets; an
        # unescaped one would break the feed for every installed copy at once.
        rendered = self.rn.render({
            "version": "9.9.9", "date": "1 January 2026",
            "highlight": "A <script> & an \"apostrophe's\" test",
            "changes": [("fixed", "5 < 6 & 7 > 2")],
        })
        self.assertNotIn("<script>", rendered)
        self.assertIn("&lt;script&gt;", rendered)
        self.assertIn("&amp;", rendered)

    def test_release_writes_the_notes_before_generating_the_feed(self) -> None:
        text = RELEASE.read_text(encoding="utf-8")
        self.assertIn("Scripts/support/release-notes.py", text)
        self.assertLess(text.index("Scripts/support/release-notes.py"),
                        text.index('"$GA_BIN" "$DIST"'),
                        "the notes must exist before generate_appcast reads the directory")


if __name__ == "__main__":
    unittest.main()
