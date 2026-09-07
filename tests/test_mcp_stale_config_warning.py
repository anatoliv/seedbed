"""A refused MCP client is diagnosed in the app, not left as a bare 401.

The app is the only thing that knows the current port and the current tokens,
and it hands them over through a button somebody has to press. So a regenerated
token or a moved port silently breaks every client already configured, and the
break reaches the person as HTTP 401, which accuses the credential when the
cause may be the address. On 2026-09-07 both halves happened to one client at
once: the tokens had been rotated without the holder being updated, and the port
had moved off 8787 while another local server genuinely answers there, so
Seedbed's token was being presented to a different program that correctly
refused it.

The server already knows the difference. It knows whether a credential arrived
at all, and it knows the same client has been turned away eleven times in a row.
This pins that it says so, and pins the two ways the diagnosis inverts silently:
a probe that reads a refused connection as an occupied port would warn about a
collision that is not there, and an alert that forgot to clear would keep
accusing a client the person has already fixed.

Read as text rather than executed. There is no Swift test target here, and the
config that actually goes stale lives outside the repository on the client
machine, so no test in this suite can exercise the live path. What it can do is
refuse to let the wiring be removed or reversed by accident.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "macos" / "Sources" / "Seedbed"
SERVER = SOURCES / "MCP" / "MCPServer.swift"
SETTINGS = SOURCES / "MCP" / "MCPSettings.swift"


def block(text: str, opener: str) -> str:
    """The source from `opener` to the closing brace at its own indent."""
    start = text.index(opener)
    indent = " " * (len(text[:start].rsplit("\n", 1)[-1]))
    end = text.index(f"\n{indent}}}", start)
    return text[start:end]


class RefusalIsDiagnosed(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.server = SERVER.read_text(encoding="utf-8")
        cls.settings = SETTINGS.read_text(encoding="utf-8")

    def test_the_401_path_records_what_it_saw(self) -> None:
        """Every refusal feeds the diagnosis, or the pane reports nothing."""
        reject = block(self.server, "private func rejectUnauthenticated(")
        self.assertIn("recordAuthAlert(credentialPresented:", reject,
                      "a refusal no longer records anything for the pane to show")
        self.assertIn(
            'rejectUnauthenticated(\n                credentialPresented: '
            'request.headers["authorization"] != nil\n            )',
            self.server,
            "the refusal no longer distinguishes a missing credential from a wrong one",
        )

    def test_a_missing_credential_and_a_wrong_token_read_differently(self) -> None:
        """The two are different mistakes and want different instructions.

        A wrong token is a stale copy or a wrong address. No token at all is a
        malformed entry: no `headers` block, or a `type` that is not `http`, so
        the client never sends one. Telling somebody to re-copy their token
        when the entry has no header for it sends them round the same loop.
        """
        alert = block(self.server, "struct MCPAuthAlert")
        self.assertIn("case wrongToken", alert)
        self.assertIn("case noCredential", alert)
        self.assertIn("headers block", alert,
                      "the no-credential case no longer names the missing block")
        self.assertIn("regenerated one", alert,
                      "the wrong-token case no longer names a stale token")
        record = block(self.server, "private func recordAuthAlert(")
        self.assertIn("credentialPresented ? .wrongToken : .noCredential", record)

    def test_the_alert_carries_no_part_of_the_presented_token(self) -> None:
        """A diagnostic pane is where a secret gets read out loud.

        A token that is wrong here may be right for the server the client meant
        to reach, so echoing it back would leak somebody else's credential into
        a window this repository already documents as un-screenshottable.
        """
        alert = block(self.server, "struct MCPAuthAlert")
        # A declaration with no brace on the line is a stored property; `title`
        # and `detail` open one, so they are computed and hold nothing.
        stored = re.findall(r"^    var (\w+): [^\n{]+$", alert, re.MULTILINE)
        self.assertEqual(stored, ["cause", "attempts", "lastAttempt"],
                         "MCPAuthAlert grew a stored property; it must not hold a credential")
        record = block(self.server, "private func recordAuthAlert(")
        self.assertNotIn("header", record,
                         "the recorder now handles the raw authorization header")

    def test_a_run_of_refusals_is_counted_and_a_success_clears_it(self) -> None:
        """The count is the signal, and a stale count is a false accusation.

        One refusal is somebody opening the URL in a browser. A dozen is a
        configured client looping. And a client that has since been fixed must
        stop being reported, or the warning outlives the problem and the next
        person learns to ignore it.
        """
        record = block(self.server, "private func recordAuthAlert(")
        self.assertIn("authAlert?.cause == cause ? (authAlert?.attempts ?? 0) : 0", record,
                      "consecutive refusals of the same shape are no longer counted")
        self.assertIn("throttle.recordSuccess()\n        clearAuthAlert()", self.server,
                      "an authenticated request no longer clears the diagnosis")
        set_tokens = block(self.server, "func setTokens(")
        self.assertIn("clearAuthAlert()", set_tokens,
                      "a restart no longer clears an alert the new configuration answers")

    def test_only_a_ready_connection_means_the_old_port_is_taken(self) -> None:
        """The probe inverts silently if `.waiting` is read as occupied.

        A refused loopback connect lands in `.waiting`, not `.failed`, because
        Network framework treats "nothing there yet" as something to retry. Read
        that as a listener and the pane warns about a collision on every Mac
        where the port is free, which is most of them.
        """
        probe = block(self.server, "nonisolated static func isSomethingListening(")
        self.assertIn("case .ready: once.resume(true)", probe)
        self.assertIn("case .waiting, .failed, .cancelled: once.resume(false)", probe)
        self.assertIn("once.resume(false) }", probe,
                      "the probe has no deadline, so a silent port would hang the check")

    def test_the_old_port_is_only_a_collision_when_seedbed_is_elsewhere(self) -> None:
        """On 8787 a listener is this app working, not another program."""
        check = block(self.server, "func refreshLegacyPortCheck(")
        self.assertIn("guard currentPort != MCPConstants.legacyDefaultPort", check)
        self.assertIn("legacyPortHeldByAnother = false", check)
        self.assertIn("MCPConstants.legacyDefaultPort", check)

    def test_settings_says_both_things_beside_the_status_line(self) -> None:
        """Where a person already looks to find out whether it is running."""
        self.assertIn("statusRow\n            diagnosticRows", self.settings,
                      "the diagnosis moved away from the status line")
        rows = block(self.settings, "@ViewBuilder private var diagnosticRows")
        self.assertIn("server.authAlert", rows)
        self.assertIn("server.legacyPortHeldByAnother", rows)
        self.assertIn("MCPConstants.legacyDefaultPort", rows,
                      "the port warning hardcodes a number instead of naming the constant")
        self.assertNotIn("8787", rows)
        self.assertIn("await server.refreshLegacyPortCheck(", self.settings,
                      "nothing re-probes the old port when the pane opens")


if __name__ == "__main__":
    unittest.main()
