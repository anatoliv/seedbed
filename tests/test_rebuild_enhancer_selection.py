"""Build entry points must use the library's saved enhancer unless overridden."""

import io
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from promptlib.cli import main
from promptlib.enhancer import EnhancerConfig
from promptlib.server import State
from promptlib.store import Library, Seed


class ConfiguredEnhancerSelection(unittest.TestCase):
    def setUp(self):
        temporary = TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "models.toml").write_text(
            '[models.grok]\nname = "Grok 4.7"\nfamily = "grok"\nguides = []\n',
            encoding="utf-8",
        )
        library = Library(self.root)
        library.prompts.mkdir()
        Seed(id="sample", title="Sample", targets=["grok"], body="Help me")\
            .write(library.prompts / "sample.md")
        EnhancerConfig(auth="api_key", endpoint="http://localhost:11434/v1/chat/completions",
                       model="writer", _root=self.root).save()
        self.library = library

    def test_rebuild_uses_saved_provider_instead_of_claude_cli(self):
        with (mock.patch("promptlib.enhancer.keychain_get", return_value="test-key"),
              mock.patch("promptlib.enhance._via_http", return_value="from saved provider") as http,
              mock.patch("promptlib.enhance._via_claude_cli",
                         side_effect=AssertionError("Claude CLI must not run"))):
            with redirect_stdout(io.StringIO()):
                result = main(["--root", str(self.root), "build", "--force",
                               "--id", "sample", "--model", "grok"])

        self.assertEqual(result, 0)
        self.assertEqual(self.library.render("sample", "grok").body,
                         "from saved provider")
        self.assertEqual(self.library.render("sample", "grok").enhancer, "api_key")
        self.assertEqual(http.call_args.args[1:3],
                         ("http://localhost:11434/v1/chat/completions", "writer"))

    def test_rebuild_uses_saved_azure_provider(self):
        endpoint = "https://example.openai.azure.com/openai/v1/chat/completions"
        EnhancerConfig(auth="azure_api_key", endpoint=endpoint,
                       model="deployment", _root=self.root).save()
        with (mock.patch("promptlib.enhancer.keychain_get", return_value="test-key"),
              mock.patch("promptlib.enhance._via_http", return_value="from Azure") as http,
              mock.patch("promptlib.enhance._via_claude_cli",
                         side_effect=AssertionError("Claude CLI must not run"))):
            with redirect_stdout(io.StringIO()):
                result = main(["--root", str(self.root), "build", "--force",
                               "--id", "sample", "--model", "grok"])

        self.assertEqual(result, 0)
        self.assertEqual(self.library.render("sample", "grok").enhancer,
                         "azure_api_key")
        self.assertEqual(http.call_args.args[1:3], (endpoint, "deployment"))

    def test_explicit_enhancer_still_overrides_saved_provider(self):
        with (mock.patch("promptlib.enhance._via_http",
                         side_effect=AssertionError("Saved provider must not run")),
              mock.patch("promptlib.enhance._via_claude_cli",
                         return_value="from explicit override")):
            with redirect_stdout(io.StringIO()):
                result = main(["--root", str(self.root), "build", "--force",
                               "--id", "sample", "--model", "grok",
                               "--enhancer", "cli"])

        self.assertEqual(result, 0)
        self.assertEqual(self.library.render("sample", "grok").body,
                         "from explicit override")
        self.assertEqual(self.library.render("sample", "grok").enhancer, "cli")

    def test_live_copy_uses_saved_provider(self):
        with (mock.patch("promptlib.enhancer.keychain_get", return_value="test-key"),
              mock.patch("promptlib.enhance._via_http", return_value="from live copy"),
              mock.patch("promptlib.enhance._via_claude_cli",
                         side_effect=AssertionError("Claude CLI must not run")),
              mock.patch("promptlib.cli.subprocess.run") as clipboard):
            with redirect_stdout(io.StringIO()):
                result = main(["--root", str(self.root), "copy", "sample",
                               "--model", "grok", "--live"])

        self.assertEqual(result, 0)
        self.assertEqual(self.library.render("sample", "grok").body, "from live copy")
        clipboard.assert_called_once_with(
            ["pbcopy"], input="from live copy", text=True, check=True)

    def test_web_build_uses_saved_provider(self):
        with (mock.patch("promptlib.enhancer.keychain_get", return_value="test-key"),
              mock.patch("promptlib.enhance._via_http", return_value="from web build"),
              mock.patch("promptlib.enhance._via_claude_cli",
                         side_effect=AssertionError("Claude CLI must not run"))):
            state = State(self.root)
            from promptlib import builder
            pairs = builder.pending(state.lib, state.models, state.cache,
                                    seed_id="sample", model_id="grok")
            state.builder._run(pairs)

        self.assertEqual(self.library.render("sample", "grok").body, "from web build")
        self.assertEqual(state.builder.job.errors, [])


if __name__ == "__main__":
    unittest.main()
