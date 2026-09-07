"""Keep Seedbed's MCP endpoint clear of a sibling app's reserved ports."""

from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "macos" / "Sources" / "Seedbed"
APP = SOURCES / "App.swift"
SERVER = SOURCES / "MCP" / "MCPServer.swift"
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
        self.assertIn("a sibling app", release_notes)


if __name__ == "__main__":
    unittest.main()
