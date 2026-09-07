"""Writing a client's MCP configuration changes one block and nothing else.

Seedbed is the only thing that knows the current port and the current tokens,
and it used to hand them over through a snippet somebody had to copy by hand.
Every token rotation and every port change silently broke every client already
configured, and the break surfaced as HTTP 401, which accuses the credential
when the cause may be the address. The decision was an explicit button rather
than an automatic write.

**The file being written is `~/.claude.json`, which lives outside this
repository and holds the whole of somebody's Claude Code configuration,
including every other MCP server they have set up.** So the binding requirement
is not "the seedbed entry is right", it is "the seedbed entry is right and every
other byte is untouched". A decode-then-encode round trip would satisfy the
first and violate the second, reformatting a file nobody asked to have
reformatted.

**Nothing here goes near a real `~/.claude.json`.** That is the point of the
seam: the edit is a pure function from string to string, so the byte-identical
guarantee is checkable on fixtures held in this file. The tests compile
`ClaudeConfigWriter.swift` on its own with a small harness and run it, rather
than reading the source as text, because a grep cannot tell you that the bytes
came back the same. The filesystem half (`ClaudeConfigInstaller`: the backup,
the write, the report) is deliberately thin for the same reason, and only its
two invariants that can be read off the source are checked here.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WRITER = ROOT / "macos" / "Sources" / "Seedbed" / "MCP" / "ClaudeConfigWriter.swift"
SETTINGS = ROOT / "macos" / "Sources" / "Seedbed" / "MCP" / "MCPSettings.swift"

URL = "http://127.0.0.1:9410"
TOKEN = "read-only-token-for-this-test"

#: Reads a request off stdin, calls the one function under test, writes the
#: answer back as JSON. It exists so the assertions below are about bytes the
#: shipped code actually produced.
HARNESS = r"""
import Foundation

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let request = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
      let text = request["text"] as? String,
      let url = request["url"] as? String,
      let token = request["token"] as? String
else {
    FileHandle.standardError.write(Data("harness could not read its request".utf8))
    exit(2)
}

var response: [String: Any]
do {
    let rewrite = try ClaudeConfig.rewriting(text, url: url, token: token)
    response = [
        "ok": true,
        "change": rewrite.change == .replaced ? "replaced" : "created",
        "text": rewrite.text,
    ]
} catch let failure as ClaudeConfig.Failure {
    response = ["ok": false, "failure": failure == .malformed ? "malformed" : "unexpectedShape"]
} catch {
    response = ["ok": false, "failure": "unknown"]
}
FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: response))
"""


def entry(indent: str, url: str = URL, token: str = TOKEN) -> str:
    """The block the writer renders, laid out against its own key's column."""
    return (
        "{\n"
        f'{indent}  "type": "http",\n'
        f'{indent}  "url": "{url}",\n'
        f'{indent}  "headers": {{\n'
        f'{indent}    "Authorization": "Bearer {token}"\n'
        f"{indent}  }}\n"
        f"{indent}}}"
    )


class ClaudeConfigWriterTests(unittest.TestCase):
    """Every case runs the compiled writer over a fixture string."""

    binary: Path
    workdir: str

    @classmethod
    def setUpClass(cls) -> None:
        if shutil.which("swiftc") is None:            # pragma: no cover
            raise unittest.SkipTest("swiftc is not on this machine")
        cls.workdir = tempfile.mkdtemp(prefix="seedbed-config-writer-")
        main = Path(cls.workdir) / "main.swift"
        main.write_text(HARNESS, encoding="utf-8")
        cls.binary = Path(cls.workdir) / "harness"
        build = subprocess.run(
            ["swiftc", "-o", str(cls.binary), str(main), str(WRITER)],
            capture_output=True, text=True,
        )
        if build.returncode != 0:                     # pragma: no cover
            raise AssertionError("the writer did not compile:\n" + build.stderr)

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.workdir, ignore_errors=True)

    def run_writer(self, text: str, url: str = URL, token: str = TOKEN) -> dict:
        request = json.dumps({"text": text, "url": url, "token": token})
        done = subprocess.run(
            [str(self.binary)], input=request, capture_output=True, text=True,
        )
        self.assertEqual(done.returncode, 0, done.stderr)
        return json.loads(done.stdout)

    # -- the replace case -------------------------------------------------

    def test_an_existing_seedbed_entry_is_replaced_in_place(self) -> None:
        """The stale url and token go, and the surrounding file does not move.

        This is the case that happens every time: the entry is already there and
        is pointing at a port or a token that has since changed.
        """
        before = (
            "{\n"
            '  "mcpServers": {\n'
            '    "seedbed": {\n'
            '      "type": "http",\n'
            '      "url": "http://127.0.0.1:8787",\n'
            '      "headers": {\n'
            '        "Authorization": "Bearer a-token-that-was-rotated"\n'
            "      }\n"
            "    }\n"
            "  }\n"
            "}\n"
        )
        after = (
            "{\n"
            '  "mcpServers": {\n'
            f'    "seedbed": {entry("    ")}\n'
            "  }\n"
            "}\n"
        )
        result = self.run_writer(before)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["change"], "replaced")
        self.assertEqual(result["text"], after)

    def test_other_servers_and_other_settings_survive_byte_for_byte(self) -> None:
        """A real file has other servers in it, and none of them are ours.

        Checked two ways, because they fail differently: the exact expected
        bytes catch a reformat, and the prefix/suffix comparison names *where*
        the file moved when it does. The fixture deliberately carries a brace
        inside a string value, which is what a naive brace-counting scan gets
        wrong, and trailing keys after the block so a length mistake shows up.
        """
        before = (
            "{\n"
            '  "numStartups": 41,\n'
            '  "mcpServers": {\n'
            '    "notes": {\n'
            '      "type": "stdio",\n'
            "      \"command\": \"sh -c '{ notes --serve }'\"\n"
            "    },\n"
            '    "seedbed": {\n'
            '      "type": "http",\n'
            '      "url": "http://127.0.0.1:8787",\n'
            '      "headers": {\n'
            '        "Authorization": "Bearer stale"\n'
            "      }\n"
            "    },\n"
            '    "weather": {\n'
            '      "type": "http",\n'
            '      "url": "http://127.0.0.1:5150"\n'
            "    }\n"
            "  },\n"
            '  "tipsHistory": {\n'
            '    "ide-hotkey": 3\n'
            "  }\n"
            "}\n"
        )
        after = before.replace(
            '      "url": "http://127.0.0.1:8787",\n'
            '      "headers": {\n'
            '        "Authorization": "Bearer stale"\n',
            f'      "url": "{URL}",\n'
            '      "headers": {\n'
            f'        "Authorization": "Bearer {TOKEN}"\n',
        )
        result = self.run_writer(before)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["change"], "replaced")
        self.assertEqual(result["text"], after)

        # And say where it moved, when it moves.
        produced = result["text"]
        shared_head = 0
        while (shared_head < min(len(before), len(produced))
               and before[shared_head] == produced[shared_head]):
            shared_head += 1
        shared_tail = 0
        while (shared_tail < min(len(before), len(produced)) - shared_head
               and before[-1 - shared_tail] == produced[-1 - shared_tail]):
            shared_tail += 1
        self.assertIn("notes", before[:shared_head],
                      "the other servers before ours were rewritten")
        self.assertIn("weather", before[len(before) - shared_tail:],
                      "the other servers after ours were rewritten")
        self.assertIn("tipsHistory", before[len(before) - shared_tail:],
                      "settings that are nothing to do with MCP were rewritten")

    # -- the create cases -------------------------------------------------

    def test_a_file_with_other_servers_but_no_seedbed_gains_one(self) -> None:
        """Adding ours must not disturb the entry it is added beside."""
        before = (
            "{\n"
            '  "mcpServers": {\n'
            '    "notes": {\n'
            '      "type": "stdio"\n'
            "    }\n"
            "  }\n"
            "}\n"
        )
        after = (
            "{\n"
            '  "mcpServers": {\n'
            f'    "seedbed": {entry("    ")},\n'
            '    "notes": {\n'
            '      "type": "stdio"\n'
            "    }\n"
            "  }\n"
            "}\n"
        )
        result = self.run_writer(before)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["change"], "created")
        self.assertEqual(result["text"], after)

    def test_a_file_with_no_mcp_servers_key_gains_the_whole_section(self) -> None:
        """Somebody who has never configured an MCP server has no such key."""
        before = (
            "{\n"
            '  "numStartups": 3,\n'
            '  "theme": "dark"\n'
            "}\n"
        )
        after = (
            "{\n"
            '  "mcpServers": {\n'
            f'    "seedbed": {entry("    ")}\n'
            "  },\n"
            '  "numStartups": 3,\n'
            '  "theme": "dark"\n'
            "}\n"
        )
        result = self.run_writer(before)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["change"], "created")
        self.assertEqual(result["text"], after)

    def test_an_empty_object_is_filled_rather_than_left_with_a_stray_comma(self) -> None:
        """`{}` has no member to insert in front of, so it is its own case."""
        result = self.run_writer("{}\n")
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["change"], "created")
        self.assertEqual(
            result["text"],
            "{\n"
            '  "mcpServers": {\n'
            f'    "seedbed": {entry("    ")}\n'
            "  }\n"
            "}\n",
        )

    def test_an_empty_mcp_servers_object_is_filled_the_same_way(self) -> None:
        before = '{\n  "mcpServers": {}\n}\n'
        result = self.run_writer(before)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["change"], "created")
        self.assertEqual(
            result["text"],
            "{\n"
            '  "mcpServers": {\n'
            f'    "seedbed": {entry("    ")}\n'
            "  }\n"
            "}\n",
        )

    # -- refusals ---------------------------------------------------------

    def test_malformed_json_is_refused_rather_than_overwritten(self) -> None:
        """A file we cannot parse is a file we must not write.

        The alternative is destroying a configuration that is almost certainly
        recoverable by hand, in order to fix one entry in it.
        """
        for broken in (
            '{\n  "mcpServers": {\n    "seedbed": {\n',        # truncated
            '{ "mcpServers": { "seedbed": {} },, }',           # doubled comma
            "not json at all",
            "",
            "[1, 2, 3]",                                       # valid JSON, wrong shape
        ):
            with self.subTest(broken=broken[:24]):
                result = self.run_writer(broken)
                self.assertFalse(result["ok"], f"a broken file was edited: {broken!r}")
                self.assertEqual(result["failure"], "malformed")

    def test_an_mcp_servers_key_that_is_not_an_object_is_refused(self) -> None:
        """Valid JSON, but there is no safe place to put the entry."""
        result = self.run_writer('{\n  "mcpServers": null\n}\n')
        self.assertFalse(result["ok"], result)
        self.assertEqual(result["failure"], "unexpectedShape")

    # -- the values that go in --------------------------------------------

    def test_the_result_parses_and_carries_the_url_token_and_transport(self) -> None:
        """The bytes are the hard part, but the entry still has to be right.

        `type` is checked because leaving it out is the specific mistake that
        makes a client dial the URL without the headers, which arrives
        unauthenticated and reports as a bad token.
        """
        before = '{\n  "numStartups": 9\n}\n'
        result = self.run_writer(before)
        parsed = json.loads(result["text"])
        self.assertEqual(parsed["numStartups"], 9, "an unrelated setting changed value")
        seedbed = parsed["mcpServers"]["seedbed"]
        self.assertEqual(seedbed["type"], "http")
        self.assertEqual(seedbed["url"], URL)
        self.assertEqual(seedbed["headers"]["Authorization"], f"Bearer {TOKEN}")

    def test_a_url_is_written_unescaped_and_a_quote_cannot_break_out(self) -> None:
        """Escaping is the writer's own, so both halves need pinning.

        `JSONSerialization` would escape the slashes in a URL and produce a
        correct document that reads as mangled, so the writer quotes strings
        itself. A hand-rolled quoter is also where an injection gets in, so the
        awkward value is checked too.
        """
        result = self.run_writer('{"a": 1}', token='he said "hi" \\ then left')
        self.assertIn(f'"url": "{URL}"', result["text"],
                      "the URL came back with escaped slashes")
        parsed = json.loads(result["text"])
        self.assertEqual(
            parsed["mcpServers"]["seedbed"]["headers"]["Authorization"],
            'Bearer he said "hi" \\ then left',
        )


class TheButtonHandsOverTheReadOnlyToken(unittest.TestCase):
    """Two properties of the caller that can be read straight off the source.

    Neither is reachable from the pure function, and both are the kind of thing
    that inverts silently: passing the wrong token still works, and a token in
    an error string still shows the error.
    """

    def test_the_pane_passes_the_read_only_token_and_not_the_full_one(self) -> None:
        """A client configured by a button press was never asked about.

        It gets the token that can search and read but cannot rebuild a prompt,
        so it can never spend an LLM call.
        """
        text = SETTINGS.read_text(encoding="utf-8")
        self.assertIn("ClaudeConfigInstaller.update(url: url, token: readOnlyToken)", text,
                      "the update button no longer hands over the read-only token")

    def test_no_message_in_the_installer_can_carry_a_token(self) -> None:
        """A failure path is exactly where a secret leaks into a transcript."""
        text = WRITER.read_text(encoding="utf-8")
        installer = text[text.index("enum ClaudeConfigInstaller"):]
        for line_number, line in enumerate(installer.splitlines(), 1):
            if line.lstrip().startswith("//"):
                continue
            self.assertNotIn(
                "\\(token)", line,
                f"the token is interpolated into a string at installer line {line_number}",
            )
        for banned in ("print(", "NSLog(", "os_log("):
            self.assertNotIn(banned, installer,
                             f"{banned} in the installer, which can put a token in a log")


if __name__ == "__main__":                            # pragma: no cover
    unittest.main()
