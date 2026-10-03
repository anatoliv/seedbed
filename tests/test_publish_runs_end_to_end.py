"""publish.sh, run for real against a fake host.

tests/test_publish_serves_the_whole_feed.py reads publish.sh's text. This runs
it: a temporary copy of macos/ with a stubbed Scripts/check-release.sh, and
scp, ssh and curl stubs on PATH that act on a local directory standing in for
the site's document root. Nothing leaves the machine, and nothing is published.

It pins what the delta fix (the feed named files that were never uploaded)
has to guarantee: every advertised file is uploaded before the feed, files
already served are not uploaded again, a file that does not arrive fails the
publish and says it was served as nothing, and a feed naming a file dist/ does
not have stops before anything is uploaded.

Republishing must keep complete live bytes visible while a copy is in progress,
preserve existing open readers, and keep the prior feed if its copy fails.
"""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor

import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PUBLISH = REPO / "macos" / "Scripts" / "publish.sh"
HELPER = REPO / "macos" / "Scripts" / "support" / "appcast_files.py"
BASE = "https://downloads.example.test"
DMG = "Seedbed_1.9_universal.dmg"
OLD_DMG = "Seedbed_1.8_universal.dmg"
DELTA = "Seedbed19-18.delta"

FEED = f"""<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <item>
      <sparkle:version>19</sparkle:version>
      <sparkle:shortVersionString>1.9</sparkle:shortVersionString>
      <enclosure url="{BASE}/{DMG}" length="3"/>
      <sparkle:deltas>
        <enclosure url="{BASE}/{DELTA}" sparkle:deltaFrom="18" length="3"/>
      </sparkle:deltas>
    </item>
    <item>
      <sparkle:version>18</sparkle:version>
      <enclosure url="{BASE}/{OLD_DMG}" length="3"/>
    </item>
  </channel>
</rss>
"""

# scp SRC HOST:/tmp/.seedbed-publish-RANDOM -> stage it in the fake host's /tmp.
SCP = """#!/usr/bin/env python3
import os, shutil, sys
args = [a for a in sys.argv[1:] if a != "-q"]
src, dest = args
name = os.path.basename(dest.split(":", 1)[1])
shutil.copyfile(src, os.path.join(os.environ["FAKE_HOST_TMP"], name))
open(os.environ["FAKE_LOG"], "a").write(f"scp {name}\\n")
"""

# Run the remote shell locally, with a sudo shim that does not change ownership.
# Uploads in the remote /tmp are mapped into the fake host's private directory.
SSH = """#!/usr/bin/env python3
import os, subprocess, sys
command = sys.argv[2].replace("/tmp/.seedbed-publish-",
                              os.environ["FAKE_HOST_TMP"] + "/.seedbed-publish-")
sys.exit(subprocess.run(["bash", "-c", command]).returncode)
"""

SUDO = """#!/usr/bin/env python3
import json, os, shutil, subprocess, sys
args = sys.argv[1:]
if args[0] == "mv" and os.path.basename(args[-1]) == os.environ.get("FAKE_DROP"):
    os.unlink(args[-2])
    sys.exit(0)
if args[0] != "install" or "-d" in args:
    # Exercise an actual rename, mktemp, directory creation and cleanup.
    if args[0] == "install":
        for option in ("-o", "-g"):
            i = args.index(option)
            del args[i:i + 2]
    sys.exit(subprocess.run(args).returncode)
src, target = args[-2:]
name = os.path.basename(target)
if "/.publish-staging/" in target:
    name = os.path.basename(target).rsplit(".", 1)[0]
with open(src, "rb") as incoming, open(target, "wb") as outgoing:
    outgoing.write(incoming.read(1))
    outgoing.flush()
    if os.environ.get("FAKE_OBSERVE"):
        for public in ("Seedbed_1.9_universal.dmg", "appcast.xml"):
            path = os.path.join(os.environ["FAKE_DOCROOT"], public)
            data = open(path, "rb").read() if os.path.exists(path) else None
            with open(os.environ["FAKE_LOG"], "a") as log:
                log.write("observe " + json.dumps([public, data.hex() if data is not None else None]) + "\\n")
    if name == os.environ.get("FAKE_FAIL_INSTALL"):
        sys.exit(1)
    shutil.copyfileobj(incoming, outgoing)
os.chmod(target, 0o644)
open(os.environ["FAKE_LOG"], "a").write(f"install {name}\\n")
"""

# The fake host runs on macOS; the deployment host has GNU stat.
STAT = """#!/usr/bin/env python3
import os, sys
path = sys.argv[-1]
device = os.stat(path).st_dev
if os.environ.get("FAKE_CROSS_DEVICE") and "/.publish-staging/" in path:
    device += 1
print(device)
"""

# curl [-fsSL|-fsSI] [--max-time N] [-o FILE] URL, served from the fake docroot.
CURL = """#!/usr/bin/env python3
import os, sys
args, out, head, url = sys.argv[1:], None, False, None
i = 0
while i < len(args):
    a = args[i]
    if a == "--max-time": i += 1
    elif a == "-o": out = args[i + 1]; i += 1
    elif a.startswith("-") and "I" in a: head = True
    elif not a.startswith("-"): url = a
    i += 1
base = os.environ["FAKE_BASE"].rstrip("/") + "/"
path = os.path.join(os.environ["FAKE_DOCROOT"], url[len(base):]) if url.startswith(base) else ""
if not path or not os.path.isfile(path):
    sys.exit(22)
if head:
    sys.stdout.write("HTTP/2 200\\r\\ncf-cache-status: DYNAMIC\\r\\n\\r\\n")
    sys.exit(0)
data = open(path, "rb").read()
if out:
    open(out, "wb").write(data)
else:
    sys.stdout.buffer.write(data)
"""


@unittest.skipUnless(PUBLISH.exists() and HELPER.exists(), "publish.sh is not in this checkout")
class PublishAgainstAFakeHost(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        self.macos = root / "macos"
        (self.macos / "Scripts" / "support").mkdir(parents=True)
        shutil.copy2(PUBLISH, self.macos / "Scripts" / "publish.sh")
        shutil.copy2(HELPER, self.macos / "Scripts" / "support" / "appcast_files.py")
        self.stub(self.macos / "Scripts" / "check-release.sh", "#!/bin/sh\nexit 0\n")
        # The release kit's main guard needs a real checkout of origin/main; the kit
        # pins it with its own checks, and this test is about the upload loop.
        guard = self.macos / "Scripts" / "release-kit" / "lib" / "main-guard.sh"
        guard.parent.mkdir(parents=True)
        guard.write_text("release_main_guard() { return 0; }\n")
        (self.macos / "Packaging").mkdir()
        with (self.macos / "Packaging" / "Info.plist").open("wb") as f:
            plistlib.dump({"CFBundleShortVersionString": "1.9", "CFBundleVersion": "19"}, f)
        self.dist = self.macos / "dist"
        self.dist.mkdir()
        for name, body in ((DMG, b"new"), (OLD_DMG, b"old"), (DELTA, b"dlt")):
            (self.dist / name).write_bytes(body)
        (self.dist / "appcast.xml").write_text(FEED)

        self.docroot = root / "docroot"
        self.docroot.mkdir()
        (self.docroot / OLD_DMG).write_bytes(b"old")   # already live from last release
        self.host_tmp = root / "host-tmp"
        self.host_tmp.mkdir()
        self.log = root / "log"
        self.log.write_text("")
        bin_dir = root / "bin"
        bin_dir.mkdir()
        for name, body in (("scp", SCP), ("ssh", SSH), ("sudo", SUDO), ("stat", STAT), ("curl", CURL)):
            self.stub(bin_dir / name, body)
        self.env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}",
                        PUBLISH_HOST="fake-host", PUBLISH_DIR=str(self.docroot), APPCAST_BASE=BASE,
                        FAKE_BASE=BASE, FAKE_DOCROOT=str(self.docroot),
                        FAKE_HOST_TMP=str(self.host_tmp), FAKE_LOG=str(self.log))

    def stub(self, path: Path, body: str) -> None:
        path.write_text(body)
        path.chmod(0o755)

    def publish(self, **env: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["bash", str(self.macos / "Scripts" / "publish.sh")],
                              env={**self.env, **env}, capture_output=True, text=True,
                              timeout=120, check=False)

    def events(self) -> list[str]:
        return self.log.read_text().split("\n")[:-1]

    def test_everything_advertised_goes_up_and_the_feed_goes_last(self) -> None:
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        installs = [e.split()[1] for e in self.events() if e.startswith("install")]
        self.assertEqual(installs, [DMG, DELTA, "appcast.xml"],
                         "the delta was not uploaded, or the feed went up before it")
        self.assertEqual((self.docroot / DELTA).read_bytes(), b"dlt")
        self.assertIn("every file the feed advertises is served as built (3)", result.stdout)

    def test_republish_never_exposes_partial_bytes_or_rewrites_open_readers(self) -> None:
        old_dmg, old_feed = b"previous complete download", b"previous complete feed"
        (self.docroot / DMG).write_bytes(old_dmg)
        (self.docroot / "appcast.xml").write_bytes(old_feed)
        with (self.docroot / DMG).open("rb") as reader:
            result = self.publish(FAKE_OBSERVE="1")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(reader.read(), old_dmg,
                             "publishing rewrote an inode an existing reader was serving")
        expected = {DMG: {old_dmg.hex(), b"new".hex()},
                    "appcast.xml": {old_feed.hex(), FEED.encode().hex()}}
        observations = [json.loads(event.removeprefix("observe "))
                        for event in self.events() if event.startswith("observe ")]
        self.assertTrue(observations, "the fake host did not observe writes in progress")
        for name, data in observations:
            self.assertIn(data, expected[name], f"a reader saw partial bytes for {name}")
        self.assertEqual((self.docroot / DMG).read_bytes(), b"new")
        self.assertEqual((self.docroot / "appcast.xml").read_text(), FEED)
        self.assertEqual((self.docroot / ".publish-staging").stat().st_mode & 0o777, 0o700)

    def test_failed_copy_keeps_the_complete_live_feed_and_cleans_staging(self) -> None:
        old_feed = b"previous complete feed"
        (self.docroot / "appcast.xml").write_bytes(old_feed)
        result = self.publish(FAKE_FAIL_INSTALL="appcast.xml")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.docroot / "appcast.xml").read_bytes(), old_feed)
        self.assertEqual(list(self.host_tmp.iterdir()), [], "upload staging leaked")
        staging = self.docroot / ".publish-staging"
        self.assertEqual(list(staging.iterdir()), [], "document-root staging leaked")

    def test_a_different_staging_filesystem_fails_without_replacing_the_live_file(self) -> None:
        old_dmg = b"previous complete download"
        (self.docroot / DMG).write_bytes(old_dmg)
        result = self.publish(FAKE_CROSS_DEVICE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.docroot / DMG).read_bytes(), old_dmg)
        self.assertEqual(list(self.host_tmp.iterdir()), [])
        self.assertEqual(list((self.docroot / ".publish-staging").iterdir()), [])

    def test_document_root_with_shell_metacharacters(self) -> None:
        quoted = self.docroot.with_name("docroot with a 'quote'")
        self.docroot.rename(quoted)
        self.docroot = quoted
        self.env.update(PUBLISH_DIR=str(quoted), FAKE_DOCROOT=str(quoted))
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.docroot / DMG).read_bytes(), b"new")

    def test_concurrent_uploads_have_distinct_temporary_paths(self) -> None:
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: self.publish(), range(2)))
        for result in results:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        uploads = [event.split()[1] for event in self.events() if event.startswith("scp ")]
        self.assertEqual(len(uploads), len(set(uploads)), "concurrent uploads shared a path")
        self.assertEqual((self.docroot / DMG).read_bytes(), b"new")
        self.assertEqual((self.docroot / "appcast.xml").read_text(), FEED)
        self.assertEqual(list(self.host_tmp.iterdir()), [])
        self.assertEqual(list((self.docroot / ".publish-staging").iterdir()), [])

    def test_a_file_already_served_is_not_uploaded_again(self) -> None:
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(f"install {OLD_DMG}", self.events())
        self.assertIn(f"{OLD_DMG} (already served)", result.stdout)

    def test_a_delta_that_never_arrives_fails_the_publish(self) -> None:
        """The 0.1.17 and 0.1.18 defect, caught at publish time instead of by an audit."""
        result = self.publish(FAKE_DROP=DELTA)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"{BASE}/{DELTA} is advertised by the feed but not served as built", result.stderr)
        self.assertIn("served nothing", result.stderr,
                      "a 404 is reported as a wrong hash instead of as missing")

    def test_a_feed_naming_a_missing_file_stops_before_any_upload(self) -> None:
        (self.dist / DELTA).unlink()
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(DELTA, result.stderr)
        self.assertEqual(self.events(), [], "something was uploaded from a feed that cannot be served")

    def test_a_failed_gate_shows_its_output_and_uploads_nothing(self) -> None:
        self.stub(self.macos / "Scripts" / "check-release.sh",
                  "#!/bin/sh\necho 'FAIL: release kit case'\necho 'gate stderr' >&2\nexit 1\n")
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FAIL: release kit case", result.stderr)
        self.assertIn("gate stderr", result.stderr)
        self.assertIn("the release gate does not pass", result.stderr)
        self.assertEqual(self.events(), [], "a failed gate uploaded release files")


if __name__ == "__main__":
    unittest.main()
