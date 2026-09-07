"""Support links say the same thing in all three places they appear.

The handles live in `SupportLinks` (the app), `.github/FUNDING.yml` (the
Sponsor button on the repository) and the site's support section. Three copies
of one list is three places to forget, so this compares them.

`site/supporters.json` is the opt-in recognition list the About page fetches.
It is deliberately deployable without an app release — adding a name should not
cost a build, two notarizations and an update everyone installs.
"""

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SUPPORT = ROOT / "macos" / "Sources" / "Seedbed" / "Support.swift"
FUNDING = ROOT / ".github" / "FUNDING.yml"
SITE = ROOT / "site" / "index.html"
FEED = ROOT / "site" / "supporters.json"
ABOUT = ROOT / "macos" / "Sources" / "Seedbed" / "InfoWindow.swift"


def handle(name: str) -> str | None:
    match = re.search(rf'{name}:\s*String\?\s*=\s*"([^"]+)"', SUPPORT.read_text(encoding="utf-8"))
    return match.group(1) if match else None


class SupportLinks(unittest.TestCase):
    def test_the_app_and_the_funding_file_name_the_same_handles(self) -> None:
        funding = FUNDING.read_text(encoding="utf-8")
        self.assertIn(f"github: [{handle('gitHubSponsorsHandle')}]", funding)
        self.assertIn(f"ko_fi: {handle('koFiHandle')}", funding)
        self.assertIn(f"paypal.me/{handle('payPalHandle')}", funding)

    def test_the_site_points_at_the_same_places(self) -> None:
        site = SITE.read_text(encoding="utf-8")
        self.assertIn(f"https://github.com/sponsors/{handle('gitHubSponsorsHandle')}", site)
        self.assertIn(f"https://ko-fi.com/{handle('koFiHandle')}", site)
        self.assertIn(f"https://paypal.me/{handle('payPalHandle')}", site)

    def test_the_about_page_says_it_unlocks_nothing(self) -> None:
        # The licence line is what makes the support line honest, and both are
        # on the same screen for that reason.
        about = ABOUT.read_text(encoding="utf-8")
        self.assertIn("MIT licence", about)
        self.assertIn("nothing to unlock", about)

    def test_the_supporters_feed_is_valid_and_starts_empty_of_names(self) -> None:
        data = json.loads(FEED.read_text(encoding="utf-8"))
        self.assertEqual(data["version"], 1)
        self.assertIsInstance(data["supporters"], list)
        for person in data["supporters"]:
            with self.subTest(person=person):
                self.assertIn("name", person)      # a url is optional; a name is not

    def test_the_app_reads_the_feed(self) -> None:
        self.assertIn("https://seedbed.dev/supporters.json", SUPPORT.read_text(encoding="utf-8"))

    def test_the_feed_is_deployed(self) -> None:
        # The deploy script names the host's document root, so it is private
        # ops tooling and absent from a public checkout by design. The public
        # snapshot runs this suite as its build gate, so a test that reads a
        # private-only file fails the publish rather than finding a defect.
        script = ROOT / "Scripts" / "publish-site.sh"
        if not script.is_file():
            self.skipTest("the deploy script is not in this checkout")
        self.assertIn("supporters.json", script.read_text(encoding="utf-8"))

    def test_an_empty_or_missing_list_shows_nothing(self) -> None:
        # A thank-you that turns into an error message is worse than no
        # thank-you, so every failure path here is silence.
        swift = SUPPORT.read_text(encoding="utf-8")
        self.assertIn("else { return }", swift)
        about = ABOUT.read_text(encoding="utf-8")
        self.assertIn("if !supporters.people.isEmpty", about)


if __name__ == "__main__":
    unittest.main()
