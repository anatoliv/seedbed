"""A failed client-config write must not reach the screen looking like a success.

`ClaudeConfigInstaller.Report` carries a `succeeded` flag because a write that
reports nothing is indistinguishable from one that failed. Returning the flag
only half settles that. The other half is the pane: the report still has to be
drawn differently depending on which happened, and for a long time nothing
checked that it was. The button had never been pressed in the UI, and the pane
cannot be screenshotted to find out, because it renders both bearer tokens in
cleartext.

The difference itself is checked where it lives, as a value, by
`macos/Tests/SeedbedTests/MCPReportRowStyleTests.swift`, which runs the shipped
mapping. What that cannot reach is the view body around it, which is private and
which nothing can render here. Two seams in it are load-bearing and are read off
the source instead:

* the pane derives the row's style from the report's **own** outcome, rather
  than from a constant or from something beside it;
* the row draws the style it was handed, rather than a symbol of its own. A row
  with a hardcoded checkmark would draw every failure as a success and every
  value test would still pass, which is exactly the shape of defect that gets
  through a green suite.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SETTINGS = ROOT / "macos" / "Sources" / "Seedbed" / "MCP" / "MCPSettings.swift"

#: `Image(systemName: "…")` with a literal name, which is how a row would come
#: to draw one outcome's icon for both.
LITERAL_SYMBOL = re.compile(r'Image\(systemName:\s*"')


def body_of(text: str, signature: str) -> str:
    """The source of one function, from its signature to the closing brace."""
    start = text.index(signature)
    depth = 0
    for offset in range(start, len(text)):
        if text[offset] == "{":
            depth += 1
        elif text[offset] == "}":
            depth -= 1
            if depth == 0:
                return text[start:offset + 1]
    raise AssertionError(f"{signature} is not a balanced function")


class TheOutcomeReachesTheScreen(unittest.TestCase):
    def setUp(self) -> None:
        self.text = SETTINGS.read_text(encoding="utf-8")

    def test_the_pane_styles_the_row_by_the_reports_own_outcome(self) -> None:
        """The one expression that decides which of the two a person sees."""
        self.assertIn(
            "MCPReportRowStyle.forOutcome(succeeded: configReport.succeeded)", self.text,
            "the pane no longer takes the row's style from the report's own outcome, "
            "so a failed write can be shown in the row a successful one uses",
        )

    def test_the_row_draws_the_style_it_was_handed_and_no_symbol_of_its_own(self) -> None:
        """A hardcoded icon here would survive every test of the mapping."""
        row = body_of(self.text, "private func reportRow(")
        for expected in ("style.symbol", "style.tint", "style.border"):
            self.assertIn(expected, row,
                          f"the report row ignores {expected}, so both outcomes can draw alike")
        found = LITERAL_SYMBOL.search(row)
        self.assertIsNone(
            found,
            "the report row draws a literal symbol name rather than the one its style "
            "carries, which shows one outcome's icon for both",
        )

    def test_nothing_asks_for_a_fixed_outcome(self) -> None:
        """A row style pinned to a constant is the same defect, spelled differently."""
        for banned in ("forOutcome(succeeded: true)", "forOutcome(succeeded: false)"):
            self.assertNotIn(banned, self.text,
                             f"{banned} fixes the row's style regardless of what happened")


class TheButtonCanBePressedByIdentity(unittest.TestCase):
    """The button had never been pressed in the UI, and could not safely be.

    SwiftUI published no usable label for any button in this pane, so the only
    way to reach one was by position, and two "Regenerate" buttons sit a few
    points above it. Pressing one of those rotates a bearer token and breaks
    every client already configured, which is the failure this button exists to
    end. An identifier is what makes the right control reachable without aiming
    at coordinates.

    An identifier on the wrong control is worse than none, because a script
    written against it presses something else with confidence. So what is
    checked is not that the string exists but that it is on the button that
    writes the configuration, and on nothing else.
    """

    def setUp(self) -> None:
        self.text = SETTINGS.read_text(encoding="utf-8")

    def test_the_identifier_is_on_the_button_that_writes_the_configuration(self) -> None:
        start = self.text.index('Button("Update my client config")')
        control = self.text[start:self.text.index("Spacer()", start)]
        self.assertIn("ClaudeConfigInstaller.update(", control)
        self.assertIn(
            ".accessibilityIdentifier(MCPSettings.updateConfigButtonIdentifier)", control,
            "the update button is no longer reachable by identity, so a script has "
            "nothing to aim at but the coordinates beside the regenerate buttons",
        )

    def test_no_other_control_answers_to_the_same_name(self) -> None:
        """Including, above all, either button that rotates a token.

        Other controls are welcome to have identifiers of their own; what would
        make a press ambiguous is a second one answering to *this* name.
        """
        self.assertEqual(
            self.text.count("MCPSettings.updateConfigButtonIdentifier"), 1,
            "a second control answers to the update button's name, so a press "
            "targeted by it may land somewhere else",
        )
        name = re.search(r'updateConfigButtonIdentifier = "([^"]+)"', self.text)
        self.assertIsNotNone(name, "the identifier is no longer a named constant")
        self.assertEqual(
            self.text.count(f'"{name.group(1)}"'), 1,
            "the identifier is also spelled out as a literal somewhere, which is a "
            "second name for a control that a rename would leave behind",
        )


if __name__ == "__main__":
    unittest.main()
