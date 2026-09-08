"""The override that let the "Update my client config" button finally be pressed.

Pressing that button writes a real file, the MCP client configuration in the
home folder of whoever is running the app, and that is why it had gone unpressed
in the UI for as long as it did: a test that presses it rewrites the tester's own
configuration, along with saving a backup beside it. `ClaudeConfigInstaller`
already took a path; the pane did not, so there was no way to aim a press
anywhere harmless.

`MCPSettings.clientConfigPath` is that way. What it must not become is a second
route into the write. The resolution itself is checked as a value by
`macos/Tests/SeedbedTests/MCPClientConfigPathTests.swift`, which runs the
shipped function. What that cannot reach is where the pane calls it, and whether
the override stayed a path and nothing more. Both are read off the source here.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SETTINGS = ROOT / "macos" / "Sources" / "Seedbed" / "MCP" / "MCPSettings.swift"
WRITER = ROOT / "macos" / "Sources" / "Seedbed" / "MCP" / "ClaudeConfigWriter.swift"

#: The variable's name, written once here so a rename shows up as a failure in
#: this file rather than as a harness that silently stops redirecting.
VARIABLE = "SEEDBED_CLIENT_CONFIG_PATH"


def flattened(text: str) -> str:
    """The source with every run of whitespace collapsed to one space.

    The call being pinned spans several lines and its wrapping is the
    formatter's business, not this test's.
    """
    return " ".join(text.split())


class TheButtonWritesWhereTheOverrideSays(unittest.TestCase):
    def setUp(self) -> None:
        self.text = SETTINGS.read_text(encoding="utf-8")
        self.flat = flattened(self.text)

    def test_the_press_resolves_its_path_instead_of_taking_the_default(self) -> None:
        """The seam itself.

        Without `at:` here the installer falls back to its own `defaultPath`,
        the variable is inert, and pressing the button in a test writes the
        tester's real configuration file.
        """
        self.assertIn(
            "ClaudeConfigInstaller.update( url: url, token: readOnlyToken, "
            "at: MCPSettings.clientConfigPath() )",
            self.flat,
            "the update button no longer resolves its path through the override",
        )

    def test_the_pane_still_hands_over_the_read_only_token(self) -> None:
        """The override redirects a path. It does not relax anything else.

        A client configured by a button press was never asked about, so it gets
        the token that cannot spend an LLM call. That property and this one live
        in the same expression, and this is the half a path change could break.
        """
        self.assertIn("token: readOnlyToken,", self.flat)
        self.assertNotIn("ClaudeConfigInstaller.update( url: url, token: token", self.flat)

    def test_the_variable_is_named_once_and_read_through_the_constant(self) -> None:
        """A literal at the call site is how a rename half-lands.

        The declaration names the string; everything else refers to the
        constant, so a rename is one edit and a harness pointing at the old name
        cannot quietly keep passing while writing the real file.
        """
        self.assertEqual(
            self.text.count(f'"{VARIABLE}"'), 1,
            f"{VARIABLE} should be written as a literal exactly once, at its declaration",
        )
        self.assertIn(
            f'static let clientConfigPathVariable = "{VARIABLE}"', self.text,
            "the variable's name moved out of its documented declaration",
        )

    def test_an_empty_override_cannot_aim_the_write(self) -> None:
        """An exported-but-blank variable resolves to the real file, not to "".

        Read off the source as well as run as a value, because the guard is one
        `isEmpty` and losing it is a one-character edit that no absent-variable
        test would notice.
        """
        resolver = self.flat[self.flat.index("static func clientConfigPath("):]
        resolver = resolver[:resolver.index("private var url")]
        self.assertIn("override.isEmpty ? ClaudeConfigInstaller.defaultPath : override", resolver)

    def test_the_declaration_says_why_the_override_exists(self) -> None:
        """The next person has to be told that pressing this writes a real file.

        Without that, the variable reads as configuration somebody might set for
        convenience, which is the one use it must not have.
        """
        declaration = self.text[:self.text.index("static let clientConfigPathVariable")]
        comment = declaration[declaration.rindex("/// The environment variable"):]
        preamble = flattened(comment.replace("///", " "))
        self.assertIn("writes a real file", preamble)
        self.assertIn("UI test that presses the button", preamble)


class TheOverrideStopsAtThePane(unittest.TestCase):
    """The installer must stay unredirectable from anywhere but its caller.

    The whole safety argument for this override is that it changes one argument
    at one call site. An environment read inside the writer would move the
    decision somewhere no caller can see, and would apply to every future caller
    including ones that have a good reason to write the real file.
    """

    def test_the_writer_reads_no_environment_of_its_own(self) -> None:
        text = WRITER.read_text(encoding="utf-8")
        self.assertNotIn("ProcessInfo", text)
        self.assertNotIn(VARIABLE, text)

    def test_the_installers_default_path_is_still_the_real_file(self) -> None:
        """The override must not have been implemented by moving the default."""
        text = WRITER.read_text(encoding="utf-8")
        self.assertIn(
            'static var defaultPath: String { (NSHomeDirectory() as NSString)'
            '.appendingPathComponent(".claude.json") }',
            flattened(text),
        )


if __name__ == "__main__":
    unittest.main()
