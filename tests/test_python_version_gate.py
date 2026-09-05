"""`python3 -m promptlib` must say what is wrong on an old interpreter.

Found on a second Mac on 2026-09-05 — the first machine ever to run this without
a 3.11+ Python already installed. `/usr/bin/python3` there is Xcode's 3.9, and
the README's first instruction produced this:

    File ".../promptlib/store.py", line 10, in <module>
        import tomllib
    ModuleNotFoundError: No module named 'tomllib'

eight frames deep, naming a module nobody asked for. The macOS app never showed
it: `LibraryClient` probes candidate interpreters and picks one that can import
`tomllib`, failing with its own sentence instead. The app being the only thing
anyone had run is precisely why this survived.

The check cannot be tested by running it — the suite runs on a supported
interpreter, and `sys.version_info` is not something a test can lie about
convincingly enough to reach a module-level guard. What IS worth pinning is the
property that actually broke: **the guard has to come before the imports.**
Moved below them it still reads correctly, still looks right in review, and does
nothing at all, because `from .cli import main` raises first. That is the
regression this file exists to catch, so it is checked structurally.
"""

from __future__ import annotations

import ast
import subprocess
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MAIN = REPO / "promptlib" / "__main__.py"


class PythonVersionGate(unittest.TestCase):
    def setUp(self) -> None:
        self.tree = ast.parse(MAIN.read_text())

    def test_the_guard_runs_before_any_package_import(self) -> None:
        """A guard after the imports is decoration: the import raises first."""
        guard_line = None
        first_package_import = None
        for node in ast.walk(self.tree):
            if guard_line is None and isinstance(node, ast.Attribute) \
                    and node.attr == "version_info":
                guard_line = node.lineno
            if first_package_import is None and isinstance(node, ast.ImportFrom) \
                    and (node.level or 0) > 0:
                first_package_import = node.lineno

        self.assertIsNotNone(guard_line, "__main__.py no longer checks sys.version_info")
        self.assertIsNotNone(first_package_import, "__main__.py imports nothing from the package")
        self.assertLess(
            guard_line, first_package_import,
            "the version guard must come BEFORE `from .cli import main`; below it "
            "the ModuleNotFoundError happens first and the guard never runs")

    def test_it_names_the_version_it_needs_and_how_to_get_one(self) -> None:
        """The message is the whole point, so it has to carry both halves."""
        text = MAIN.read_text()
        self.assertIn("3.11", text, "the message must say which version is needed")
        self.assertIn("brew install python", text,
                      "the message must say how to get one; a diagnosis with no "
                      "remedy is the traceback it replaced")

    def test_the_gate_is_the_first_thing_the_module_does(self) -> None:
        """Only `sys` may be imported ahead of it, or the guard is unreachable."""
        for node in self.tree.body:
            if isinstance(node, (ast.Import, ast.ImportFrom)):
                names = [a.name for a in node.names]
                self.assertEqual(
                    names, ["sys"],
                    f"{names} is imported before the version guard; anything but "
                    "`sys` can itself fail on an old interpreter")
                break

    def test_the_supported_interpreter_still_runs_the_cli(self) -> None:
        """The guard must not have broken the path it is guarding."""
        result = subprocess.run(
            [sys.executable, "-m", "promptlib", "--help"],
            cwd=REPO, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("needs Python 3.11", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
