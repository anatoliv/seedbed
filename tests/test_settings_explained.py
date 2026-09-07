"""Every Settings section explains its own controls.

Seedbed's Settings had explanation where somebody happened to write it. Pasting,
Library folder, Updates and Diagnostics had a paragraph; "Starting up" had
nothing, the MCP server section had nothing, and the Building pane, which holds
the only controls in the app that spend money, had nothing above the fields.

The gap is invisible by inspection because a group with no prose looks
deliberate: the reader cannot tell "needs no explanation" from "nobody wrote
one". So this pins the property rather than the prose. A new section with no
bullets fails here, at the moment it is added, instead of shipping unexplained.

It does not check what the text says. Wording is a judgement call and pinning it
would make every edit a test change, which is how a test stops being read.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "macos" / "Sources" / "Seedbed"

#: Files that render Settings sections, and the call that opens one in each.
#: `section(` is MCPSettings' own local helper; `SettingsGroup(` is the shared
#: component. Both take the section's visible title as their first argument.
SURFACES = [
    (SOURCES / "SettingsWindow.swift", r'SettingsGroup\("([^"]+)"\)'),
    (SOURCES / "MCP" / "MCPSettings.swift", r'\bsection\("([^"]+)"\)'),
]


def sections(text: str, pattern: str) -> list[tuple[str, str]]:
    """[(title, the source from this section to the next)] in file order."""
    marks = [(m.start(), m.group(1)) for m in re.finditer(pattern, text)]
    out = []
    for index, (start, title) in enumerate(marks):
        end = marks[index + 1][0] if index + 1 < len(marks) else len(text)
        out.append((title, text[start:end]))
    return out


class SettingsSectionsAreExplained(unittest.TestCase):
    def test_every_section_carries_bullets(self) -> None:
        missing = []
        checked = 0
        for path, pattern in SURFACES:
            if not path.exists():                       # pragma: no cover
                continue
            for title, body in sections(path.read_text(encoding="utf-8"), pattern):
                checked += 1
                if "SettingsBullets" not in body and "note(" not in body:
                    missing.append(f"{path.name}: {title}")
        self.assertTrue(checked, "no Settings sections were found to check")
        self.assertEqual(missing, [], "these Settings sections explain nothing:\n"
                         + "\n".join(missing))

    def test_the_building_pane_explains_its_fields(self) -> None:
        """The Building pane is a form, not sections, so it is checked by name.

        It is also the one pane whose controls spend money, and the one where a
        reader looked for a way to point at a model on another machine, found no
        preset named for it, and concluded it was unsupported. It is supported:
        the endpoint is editable and `enhancer.py` accepts a private address.
        """
        text = (SOURCES / "EnhancerEditor.swift").read_text(encoding="utf-8")
        self.assertIn("SettingsBullets", text,
                      "the Building pane lost its explanations")
        self.assertIn("another machine", text,
                      "the Building pane no longer says a remote endpoint is possible, "
                      "which is the thing its preset list does not reveal")

    def test_bullets_name_controls_rather_than_restating_the_heading(self) -> None:
        """A bullet's term should be a control, so it can be matched on screen.

        Cheap proxy for that: a term is never empty and never the literal
        section heading text, which would make the bullet a second title.
        """
        for path, pattern in SURFACES:
            if not path.exists():                       # pragma: no cover
                continue
            text = path.read_text(encoding="utf-8")
            for title, body in sections(text, pattern):
                for term in re.findall(r'\(\s*"([^"]+)",\s*$', body, re.MULTILINE):
                    with self.subTest(section=title, term=term):
                        self.assertTrue(term.strip(), "a bullet has an empty term")
                        self.assertNotEqual(term.strip().lower(), title.strip().lower(),
                                            "a bullet just repeats its section heading")


if __name__ == "__main__":
    unittest.main()
