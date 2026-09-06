"""No em or en dashes in the copy this app shows people.

The house rule is that published copy carries no em dash (—) or en dash (–),
and that a replacement is the punctuation the sentence actually wants: a colon
before a definition, a period between two independent clauses, parentheses for a
true aside, a comma only for a tight pair. A blanket dash-to-comma swap produces
comma splices and reads worse than the dash did.

**Found by looking, not by reading the code.** A screenshot of Settings → Building
came back with six em dashes on one screen, in labels that had been there for
weeks. Forty-six of them were in shipped UI strings across ten files. No test saw
them, because every test here reads structure and values rather than prose.

The one exception is a numeric range. `⌘1–9` is an en dash doing the job an en
dash is for, and the app's own key caps use it.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

SOURCES = Path(__file__).resolve().parent.parent / "macos" / "Sources" / "Seedbed"

#: A range like `⌘1–9`: a digit, an en dash, a digit. Correct typography, and the
#: only place a dash belongs in this app's copy.
RANGE = re.compile(r"[0-9]–[0-9]")

#: A Swift string literal, roughly. Good enough to tell copy from comments, which
#: is the distinction that matters: a dash in a doc comment is prose for
#: developers and none of this rule's business.
STRING = re.compile(r'"(?:[^"\\]|\\.)*"')


PROMPTLIB = Path(__file__).resolve().parent.parent / "promptlib"


def _python_user_strings(path: Path) -> list[tuple[int, str]]:
    """Every string literal in a module that is NOT a docstring.

    Parsed rather than grepped, because a docstring is a string literal in the
    first statement position and no regex tells the two apart reliably. A
    docstring here is prose for developers; anything else may be printed, raised
    or returned to the macOS app, which displays it verbatim.
    """
    import ast
    tree = ast.parse(path.read_text(encoding="utf-8"))
    docstrings = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            body = getattr(node, "body", None)
            if body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant) \
                    and isinstance(body[0].value.value, str):
                docstrings.add(id(body[0].value))
    out = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and isinstance(node.value, str) and id(node) not in docstrings:
            out.append((node.lineno, node.value))
    return out


class UICopyHasNoDashes(unittest.TestCase):
    def test_no_em_or_en_dash_in_any_displayed_string(self) -> None:
        offenders: list[str] = []
        for path in sorted(SOURCES.rglob("*.swift")):
            for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                stripped = line.lstrip()
                if stripped.startswith("//"):
                    continue          # a comment is for developers, not users
                for literal in STRING.findall(line):
                    body = RANGE.sub("", literal)
                    if "—" in body or "–" in body:
                        offenders.append(f"{path.name}:{n}  {literal.strip()[:90]}")
        self.assertEqual(
            offenders, [],
            "em or en dash in copy the app displays. Replace each with the "
            "punctuation that sentence wants (a colon before a definition, a "
            "period between two clauses, parentheses for an aside, a comma only "
            "for a tight pair) rather than swapping them all for commas:\n  "
            + "\n  ".join(offenders))


    def test_no_dash_in_a_python_string_the_app_or_cli_shows(self) -> None:
        """The copy lives in two languages.

        The macOS app is a front end: it prints what `promptlib` returns, so a
        dash composed in Python reaches the same window as one written in Swift.
        The first version of this test scanned only Swift and passed while
        Settings still displayed "Claude Code CLI (model opus) — no key needed",
        which is built in `enhancer.py`.
        """
        offenders: list[str] = []
        for path in sorted(PROMPTLIB.rglob("*.py")):
            if path.name == "__pycache__":
                continue
            for lineno, value in _python_user_strings(path):
                body = RANGE.sub("", value)
                if "—" in body or "–" in body:
                    offenders.append(f"{path.name}:{lineno}  {value.strip()[:90]}")
        self.assertEqual(
            offenders, [],
            "em or en dash in a Python string the app or the CLI displays:\n  "
            + "\n  ".join(offenders))


if __name__ == "__main__":
    unittest.main()
