"""Actually pressing "Update my client config" in the running app.

Everything else about this button is checked by reading. This presses it.

It went unpressed for a long time for a good reason: the press writes a real
file, the MCP client configuration in the home folder of whoever is running the
app, and saves a backup beside it. So a test that pressed it rewrote the
tester's own configuration. `MCPSettings.clientConfigPath` is what changed that:
with `SEEDBED_CLIENT_CONFIG_PATH` set, the write lands in a temp file, and with
it unset the app writes exactly where it always did.

The press itself goes through `tests/ui/press_by_identifier.swift`, which finds
the control by `mcp.updateClientConfig` and refuses unless exactly one thing
answers to that name. Not by position: two "Regenerate" buttons sit a few points
above, and hitting one of those rotates a bearer token and breaks every client
already configured.

**Skipped unless `SEEDBED_PRESS_UI=1`.** It launches a real app, needs a built
bundle, and needs macOS accessibility permission, none of which a plain suite
run can assume. Run it deliberately:

    macos/Scripts/make-app.sh
    SEEDBED_PRESS_UI=1 python3 -m unittest tests.test_update_config_button_press

What is asserted afterwards matters as much as the press: the temp file gained a
seedbed entry and kept every other server in it, a backup of the original sits
beside it, and the real configuration in the home folder is byte-identical and
has grown no backup.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DRIVER = ROOT / "tests" / "ui" / "press_by_identifier.swift"
BUNDLE = ROOT / "macos" / "build" / "Seedbed.app"
BINARY = BUNDLE / "Contents" / "MacOS" / "Seedbed"
SETTINGS = ROOT / "macos" / "Sources" / "Seedbed" / "MCP" / "MCPSettings.swift"

#: The one control this may press, and the environment variable that aims the
#: write somewhere harmless. Both are read off the pane below rather than
#: trusted, so a rename in the app fails this file instead of quietly turning
#: the press into a no-op or, worse, into a write of the real file.
IDENTIFIER = "mcp.updateClientConfig"
VARIABLE = "SEEDBED_CLIENT_CONFIG_PATH"

#: A configuration file with somebody else's server already in it, which is the
#: case the writer's whole splice exists for.
FIXTURE = """{
  "numStartups": 41,
  "mcpServers": {
    "somebody-elses-server": {
      "type": "http",
      "url": "http://127.0.0.1:9999",
      "headers": { "Authorization": "Bearer not-ours" }
    }
  },
  "tipsHistory": { "ide-hotkey": 3 }
}
"""

BACKUP = re.compile(r"^\.claude\.json\.bak-\d{8}-\d{6}")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def home_backups() -> list[str]:
    home = Path.home()
    return sorted(p.name for p in home.glob(".claude.json.bak-*"))


class TheHarnessNamesWhatThePaneNames(unittest.TestCase):
    """Runs always, because a driver aimed at a stale name presses nothing.

    A test that skips is allowed to be out of date only about things a run would
    catch. These two strings are not among them: the end-to-end test below is
    skipped by default, so a rename would sit unnoticed until somebody ran it
    deliberately and got a green result from a press that never happened.
    """

    def setUp(self) -> None:
        self.text = SETTINGS.read_text(encoding="utf-8")

    def test_the_identifier_pressed_is_the_one_the_button_carries(self) -> None:
        self.assertIn(f'updateConfigButtonIdentifier = "{IDENTIFIER}"', self.text)

    def test_the_variable_set_is_the_one_the_pane_reads(self) -> None:
        self.assertIn(f'clientConfigPathVariable = "{VARIABLE}"', self.text)

    def test_the_driver_refuses_to_press_an_ambiguous_name(self) -> None:
        """Pressing by identity is only safe while the identity is unique.

        Two controls answering to the same name would make the press a coin
        toss beside a button that rotates a bearer token.
        """
        driver = DRIVER.read_text(encoding="utf-8")
        self.assertIn("guard matches.count == 1", driver)
        self.assertIn("refusing to press", driver)


@unittest.skipUnless(os.environ.get("SEEDBED_PRESS_UI") == "1",
                     "launches the app and presses a button; set SEEDBED_PRESS_UI=1 to run")
class PressingTheButton(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not BINARY.exists():
            raise unittest.SkipTest(f"no bundle at {BUNDLE}; run macos/Scripts/make-app.sh")
        if shutil.which("swiftc") is None:
            raise unittest.SkipTest("swiftc is not on the path")
        cls.tools = tempfile.mkdtemp(prefix="seedbed-press-driver.")
        cls.driver = Path(cls.tools) / "press_by_identifier"
        subprocess.run(["swiftc", "-O", str(DRIVER), "-o", str(cls.driver)], check=True)

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.tools, ignore_errors=True)

    def setUp(self) -> None:
        self.sandbox = Path(tempfile.mkdtemp(prefix="seedbed-press."))
        self.addCleanup(shutil.rmtree, self.sandbox, ignore_errors=True)
        self.target = self.sandbox / ".claude.json"
        self.target.write_text(FIXTURE, encoding="utf-8")

        # The safety interlock, before anything is launched. A press aimed
        # inside the home folder is the one outcome this must never have.
        self.assertTrue(str(self.sandbox).startswith(tempfile.gettempdir()),
                        f"{self.sandbox} is not inside the temp directory")
        self.assertFalse(str(self.target).startswith(str(Path.home())),
                         "the press must never be aimed inside the home folder")

        self.real = Path.home() / ".claude.json"
        self.real_before = sha256(self.real) if self.real.exists() else None
        self.backups_before = home_backups()

    def tearDown(self) -> None:
        """The real file is what this whole design exists to protect."""
        after = sha256(self.real) if self.real.exists() else None
        self.assertEqual(self.real_before, after,
                         "the press changed the real configuration file")
        self.assertEqual(self.backups_before, home_backups(),
                         "the press left a backup in the home folder")

    def press(self, expect: str) -> subprocess.CompletedProcess:
        environment = dict(os.environ)
        environment["SEEDBED_OPEN_LIBRARY"] = "mcp"
        environment[VARIABLE] = str(self.target)
        app = subprocess.Popen([str(BINARY)], env=environment,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(app.wait)
        self.addCleanup(app.terminate)
        time.sleep(6)  # the pane, its tokens, and the first accessibility tree
        return subprocess.run(
            [str(self.driver), "--pid", str(app.pid), "--identifier", IDENTIFIER,
             "--expect", expect],
            capture_output=True, text=True,
        )

    def test_the_button_writes_the_seedbed_entry_and_says_so_on_screen(self) -> None:
        outcome = self.press(expect="Added a seedbed entry to ")
        if "no accessibility permission" in outcome.stdout:
            raise unittest.SkipTest("this process holds no accessibility permission")
        self.assertIn(f"matches for {IDENTIFIER}: 1", outcome.stdout)
        self.assertIn("AXPress: success", outcome.stdout)
        self.assertIn("on screen", outcome.stdout,
                      "the report row did not reach the screen after the press")
        self.assertEqual(outcome.returncode, 0, outcome.stdout + outcome.stderr)

        written = json.loads(self.target.read_text(encoding="utf-8"))
        entry = written["mcpServers"]["seedbed"]
        self.assertEqual(entry["type"], "http")
        self.assertTrue(entry["url"].startswith("http://127.0.0.1:"))
        self.assertTrue(entry["headers"]["Authorization"].startswith("Bearer "))

        original = json.loads(FIXTURE)
        self.assertEqual(written["mcpServers"]["somebody-elses-server"],
                         original["mcpServers"]["somebody-elses-server"],
                         "the press rewrote a server it was not asked about")
        self.assertEqual(written["numStartups"], original["numStartups"])
        self.assertEqual(written["tipsHistory"], original["tipsHistory"])

        backups = [p for p in self.sandbox.iterdir() if BACKUP.match(p.name)]
        self.assertEqual(len(backups), 1, "the press saved no backup beside the file")
        self.assertEqual(backups[0].read_text(encoding="utf-8"), FIXTURE,
                         "the backup does not hold the file as it was")


if __name__ == "__main__":
    unittest.main()
