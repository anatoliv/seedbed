"""Keep Seedbed's MCP endpoint clear of the ports other local servers take."""

from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "macos" / "Sources" / "Seedbed"
APP = SOURCES / "App.swift"
SERVER = SOURCES / "MCP" / "MCPServer.swift"
PORT_MOVE = SOURCES / "MCP" / "MCPPortMove.swift"
SETTINGS = SOURCES / "MCP" / "MCPSettings.swift"
MANUAL = SOURCES / "Manual.swift"
GUIDE = SOURCES / "Guide.swift"
MACOS_README = ROOT / "macos" / "README.md"
WHATS_NEW = SOURCES / "WhatsNew.swift"


class MCPDefaultPortTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.app = APP.read_text()
        cls.server = SERVER.read_text()

    def test_seedbed_uses_its_own_default_port(self) -> None:
        self.assertIn("static let defaultPort: UInt16 = 8789", self.server)
        self.assertIn(
            "@AppStorage(AppController.mcpPortKey) private var port "
            "= Int(MCPConstants.defaultPort)",
            SETTINGS.read_text(),
        )

    def test_upgrade_moves_only_the_missing_or_legacy_default(self) -> None:
        migration = self.app.split("static func migrateMCPDefaultPortIfNeeded", 1)[1]
        migration = migration.split("\n    }", 1)[0]
        self.assertIn("stored == nil", migration)
        self.assertIn("MCPConstants.legacyDefaultPort", migration)
        self.assertIn("defaults.set(Int(MCPConstants.defaultPort)", migration)
        self.assertNotIn("stored != nil", migration)
        self.assertIn("Self.migrateMCPDefaultPortIfNeeded()", self.app)

    def test_user_facing_examples_name_the_new_port(self) -> None:
        for path in (MANUAL, GUIDE):
            copy = path.read_text()
            self.assertIn("8789", copy, path)
            self.assertNotIn("8787", copy, path)
        readme = MACOS_README.read_text()
        self.assertIn("default port is 8789", readme)
        self.assertIn("former 8787 default", readme)
        release_notes = WHATS_NEW.read_text().split('version: "0.1.8"', 1)[1]
        release_notes = release_notes.split('version: "0.1.7"', 1)[0]
        self.assertIn("defaults to port 8789", release_notes)
        self.assertIn("other local agent servers", release_notes)

    def test_a_taken_port_is_walked_past_rather_than_shared(self) -> None:
        """The listener must refuse to share, and the walk must step over the
        ports other local servers default to, or two programs that both move
        end up a launch order apart from swapping places."""
        self.assertIn("params.allowLocalEndpointReuse = false", self.server)
        self.assertNotIn("allowLocalEndpointReuse = true", self.server)
        scan = PORT_MOVE.read_text()
        self.assertIn("static let scanLimit: UInt16 = 32", scan)
        self.assertIn(
            "static let reservedPorts: Set<UInt16> = Set([8765, 8784] + Array(8787...8802))",
            scan,
        )
        self.assertIn("MCPPortScan.firstFree(requested: port", self.server)
        self.assertIn("defaults.set(Int(candidate), forKey: AppController.mcpPortKey)",
                      self.server, "the moved port no longer reaches the Settings field")

    def test_the_bound_port_is_only_recorded_once_the_listener_is_ready(self) -> None:
        listening = self.server.split("private func beginListening(", 1)[1]
        listening = listening.split("nonisolated static func listenerParameters", 1)[0]
        self.assertIn("case .ready:\n                boundPort = candidate", listening)
        self.assertNotIn("boundPort = port", listening,
                         "boundPort is set before the bind is attempted again")

    def test_user_facing_copy_says_the_port_moves(self) -> None:
        manual = MANUAL.read_text()
        self.assertIn("If the port is already taken", manual)
        self.assertIn("What happens if something else is already using the port?", manual)
        self.assertIn("Port 8789 was taken, so Seedbed is listening on 8803.", manual)
        self.assertIn("moves up to the next free one", GUIDE.read_text())
        self.assertIn("walks up to the next free port", MACOS_README.read_text())


if __name__ == "__main__":
    unittest.main()
