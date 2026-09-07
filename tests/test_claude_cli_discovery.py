"""The `claude` CLI is found from an app, not only from a shell.

Reported 2026-09-07 as "failed: the `claude` CLI is not on PATH" on a Mac with
Claude Code installed. `shutil.which` was the whole lookup, and an app launched
from Finder inherits roughly `/usr/bin:/bin:/usr/sbin:/sbin` — so a binary in
`~/.local/bin` or a Homebrew prefix is invisible to it while working perfectly
in a terminal. The failure reads as "not installed" to someone who has it.

This is the same defect the interpreter probe already existed for: that one
resolves `python3` by absolute path for exactly this reason, and the enhancer
was still trusting PATH.
"""

import os
import unittest
from pathlib import Path

from promptlib.enhance import CLAUDE_CANDIDATES, find_claude_cli

ROOT = Path(__file__).resolve().parent.parent
LIBRARY = ROOT / "macos" / "Sources" / "Seedbed" / "Library.swift"


class ClaudeCLIDiscovery(unittest.TestCase):
    def test_the_candidates_cover_where_it_actually_installs(self) -> None:
        for path in ("~/.local/bin/claude", "/opt/homebrew/bin/claude",
                     "/usr/local/bin/claude"):
            self.assertIn(path, CLAUDE_CANDIDATES)

    def test_an_empty_path_still_finds_an_installed_cli(self) -> None:
        # The reported failure, reproduced: PATH stripped to what Finder gives.
        installed = [p for p in CLAUDE_CANDIDATES
                     if os.access(os.path.expanduser(p), os.X_OK)]
        if not installed:
            self.skipTest("the claude CLI is not installed in a known location here")
        original = os.environ.get("PATH")
        try:
            os.environ["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            self.assertIsNotNone(find_claude_cli(),
                                 "a Finder-like PATH hides the CLI again")
        finally:
            if original is None:
                os.environ.pop("PATH", None)
            else:
                os.environ["PATH"] = original

    def test_an_explicit_override_wins_and_a_bad_one_does_not_pretend(self) -> None:
        original = os.environ.get("SEEDBED_CLAUDE_BIN")
        try:
            os.environ["SEEDBED_CLAUDE_BIN"] = "/bin/sh"     # executable, exists
            self.assertEqual(find_claude_cli(), "/bin/sh")
            os.environ["SEEDBED_CLAUDE_BIN"] = "/nonexistent/claude"
            self.assertIsNone(find_claude_cli(),
                              "a broken override must report not-found, not fall back "
                              "to a different binary than the one that was named")
        finally:
            if original is None:
                os.environ.pop("SEEDBED_CLAUDE_BIN", None)
            else:
                os.environ["SEEDBED_CLAUDE_BIN"] = original

    def test_the_error_says_where_it_looked(self) -> None:
        from promptlib import enhance
        original = os.environ.get("SEEDBED_CLAUDE_BIN")
        try:
            os.environ["SEEDBED_CLAUDE_BIN"] = "/nonexistent/claude"
            with self.assertRaises(enhance.EnhancerError) as caught:
                enhance._via_claude_cli("hello")
            message = str(caught.exception)
            self.assertIn("~/.local/bin/claude", message)
            self.assertIn("SEEDBED_CLAUDE_BIN", message)
        finally:
            if original is None:
                os.environ.pop("SEEDBED_CLAUDE_BIN", None)
            else:
                os.environ["SEEDBED_CLAUDE_BIN"] = original

    def test_the_app_hands_its_child_a_usable_path(self) -> None:
        # The other half: the app spawns the package, so the package's lookup
        # only helps if the app has not stripped the environment first.
        swift = LIBRARY.read_text(encoding="utf-8")
        self.assertIn("process.environment = Self.childEnvironment", swift)
        self.assertIn("childEnvironment", swift)
        for path in ("/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"):
            self.assertIn(path, swift)


if __name__ == "__main__":
    unittest.main()
