"""The bundled core must write to --root outside its own package directory."""

import io
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from tempfile import TemporaryDirectory

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from promptlib.cli import main


class ExplicitRoot(unittest.TestCase):
    def test_new_prompt_reports_a_path_inside_the_selected_library(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "models.toml").write_text("[models]\n")
            output = io.StringIO()
            with redirect_stdout(output):
                result = main(["--root", str(root), "new", "test-prompt"])
            self.assertEqual(result, 0)
            self.assertIn("created prompts/test-prompt.md", output.getvalue())
            self.assertTrue((root / "prompts" / "test-prompt.md").is_file())


if __name__ == "__main__":
    unittest.main()
