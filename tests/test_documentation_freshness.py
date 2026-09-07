"""Guard user and design documentation against implemented behavior."""

from __future__ import annotations

import tomllib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def _read(*parts: str) -> str:
    """Contents, or "" when the file is not in this checkout.

    Read at import time and unconditionally, this module raised on the public
    snapshot, which excludes the design plan — and an ImportError in one test
    module fails the whole suite, which is the snapshot's build gate. So a
    missing file yields "" here and the tests that need it skip with a reason,
    the same way the publish-guard tests already handle a script that is absent
    from a public checkout by design.
    """
    path = ROOT.joinpath(*parts)
    return path.read_text(encoding="utf-8") if path.is_file() else ""


README = _read("README.md")
MACOS_README = _read("macos", "README.md")
PLAN = _read("docs", "design", "PLAN.md")
GUIDE = _read("macos", "Sources", "Seedbed", "Guide.swift")
MANUAL = _read("macos", "Sources", "Seedbed", "Manual.swift")
SERVER = _read("macos", "Sources", "Seedbed", "MCP", "MCPServer.swift")
ENHANCER = _read("promptlib", "enhancer.py")


class DocumentationFreshnessTests(unittest.TestCase):
    def test_chatgpt_sign_in_is_documented_as_implemented(self) -> None:
        if not PLAN:
            self.skipTest("the design plan is not published in this checkout")
        for copy in (README, MACOS_README, PLAN):
            self.assertIn("ChatGPT", copy)
        self.assertNotIn("Not implemented: ChatGPT", MACOS_README)
        self.assertIn("promptlib enhancer login", MACOS_README)
        self.assertIn("five auth modes", ENHANCER)

    def test_update_docs_distinguish_development_and_installed_copies(self) -> None:
        for copy in (README, MACOS_README, GUIDE):
            self.assertIn("Sparkle", copy)
            self.assertIn("git", copy)
        self.assertNotIn("There is no Sparkle feed", MACOS_README)

    def test_design_plan_names_the_current_target_count(self) -> None:
        if not PLAN:
            self.skipTest("the design plan is not published in this checkout")
        models = tomllib.loads((ROOT / "models.toml").read_text())["models"]
        number = {5: "Five"}.get(len(models), str(len(models)))
        self.assertIn(f"{number} ship", PLAN)

    def test_mcp_compatibility_path_matches_the_server(self) -> None:
        self.assertIn('allowedPaths: Set<String> = ["/", "/mcp"]', SERVER)
        self.assertIn("http://127.0.0.1:8789/mcp      answered", MANUAL)
        self.assertNotIn("/mcp      not found", MANUAL)
        self.assertIn("require the conventional `/mcp` path", MACOS_README)
        self.assertNotIn("URL with a path on the end", MANUAL)

    def test_current_docs_use_the_modal_term(self) -> None:
        # The other half of this check — that no document names another project
        # — moved to tests/test_no_sibling_projects.py, which sweeps every
        # tracked file rather than these four and does not have to spell the
        # name it forbids.
        self.assertNotIn("opens a small sheet", GUIDE)
        self.assertIn("opens a compact modal", GUIDE)


if __name__ == "__main__":
    unittest.main()
