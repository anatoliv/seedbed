"""publish.sh serves every file the appcast advertises, deltas included.

generate_appcast writes a Sparkle delta for each older DMG left in dist/ and
lists it in the feed. publish.sh uploaded only the new DMG and the feed, so from
0.1.17 on the live feed named delta files that were 404 on seedbed.dev, and
the served-hash check covered only the DMG, so nothing noticed.

`macos/Scripts/support/appcast_files.py` reads the upload list out of the feed
itself; publish.sh uploads that list before the feed and checks each file as
served.
"""

from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
HELPER = REPO / "macos" / "Scripts" / "support" / "appcast_files.py"
PUBLISH = REPO / "macos" / "Scripts" / "publish.sh"
BASE = "https://downloads.example.test"

FEED = """<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <item>
      <sparkle:version>19</sparkle:version>
      <enclosure url="{base}/App_1.9.dmg" length="10" type="application/octet-stream"/>
      <sparkle:deltas>
        <enclosure url="{base}/App19-18.delta" sparkle:deltaFrom="18" length="3"/>
        <enclosure url="{base}/App19-17.delta" sparkle:deltaFrom="17" length="3"/>
      </sparkle:deltas>
    </item>
    <item>
      <sparkle:version>18</sparkle:version>
      <enclosure url="{base}/App_1.8.dmg" length="10" type="application/octet-stream"/>
    </item>
  </channel>
</rss>
"""


@unittest.skipUnless(HELPER.exists(), "appcast_files.py is not in this checkout")
class TheUploadListComesFromTheFeed(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dist = Path(tmp.name)
        self.appcast = self.dist / "appcast.xml"

    def feed(self, base: str = BASE, files=("App_1.9.dmg", "App19-18.delta",
                                             "App19-17.delta", "App_1.8.dmg")) -> None:
        self.appcast.write_text(FEED.format(base=base))
        for name in files:
            (self.dist / name).write_bytes(b"x")

    def run_helper(self, prefix: str = BASE) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["python3", str(HELPER), str(self.appcast), prefix, str(self.dist)],
                              capture_output=True, text=True, check=False)

    def test_deltas_are_on_the_list_not_just_the_dmg(self) -> None:
        """The defect: the deltas the feed advertises were never uploaded."""
        self.feed()
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split(),
                         ["App_1.9.dmg", "App19-18.delta", "App19-17.delta", "App_1.8.dmg"])

    def test_a_trailing_slash_on_the_prefix_changes_nothing(self) -> None:
        self.feed()
        self.assertEqual(self.run_helper(BASE + "/").returncode, 0)

    def test_a_named_file_missing_from_dist_is_refused(self) -> None:
        """A feed that names what cannot be uploaded is the 404 waiting to happen."""
        self.feed(files=("App_1.9.dmg", "App19-18.delta", "App_1.8.dmg"))
        result = self.run_helper()
        self.assertEqual(result.returncode, 1)
        self.assertIn("App19-17.delta", result.stderr)
        self.assertEqual(result.stdout, "", "a partial list would be uploaded as if complete")

    def test_a_download_hosted_elsewhere_is_refused(self) -> None:
        self.feed(base="https://elsewhere.example.test")
        result = self.run_helper()
        self.assertEqual(result.returncode, 1)
        self.assertIn("not a file directly under", result.stderr)

    def test_an_unreadable_feed_is_refused(self) -> None:
        self.appcast.write_text("<rss><channel>")
        self.assertEqual(self.run_helper().returncode, 1)


@unittest.skipUnless(PUBLISH.exists(), "publish.sh is not in this checkout")
class PublishUploadsAndChecksTheWholeList(unittest.TestCase):
    """publish.sh itself needs the real host, so its wiring is read, not run."""

    def setUp(self) -> None:
        self.source = PUBLISH.read_text()

    def test_the_list_comes_from_the_helper(self) -> None:
        self.assertIn("Scripts/support/appcast_files.py", self.source)

    def test_every_listed_file_is_uploaded_before_the_feed(self) -> None:
        loop = self.source.index('for name in "${ORDERED[@]}"; do')
        upload = self.source.index('publish_atomic "dist/$name"', loop)
        feed = self.source.index('publish_atomic "$APPCAST"')
        self.assertLess(upload, feed, "the feed goes up before the files it names")
        self.assertNotIn('publish_atomic "$DMG"\n', self.source,
                         "the DMG is uploaded outside the list again")

    def test_every_listed_file_is_checked_as_served(self) -> None:
        check = self.source.index("is advertised by the feed but not served as built")
        self.assertGreater(check, self.source.index("Origin verify"))


if __name__ == "__main__":
    unittest.main()
