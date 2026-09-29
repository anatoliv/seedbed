"""Exercise the packaged Python core against a library with deliberately old code.

Called by the release gate after Seedbed.app exists. Uses a loopback provider
and a failing Keychain shim, so no account, secret, or paid model is touched.
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


def verify(app: Path) -> None:
    runtime = app / "Contents" / "Resources" / "Python"
    executable = app / "Contents" / "MacOS" / "Seedbed"
    with tempfile.TemporaryDirectory(prefix="seedbed-packaged-runtime-") as directory:
        root = Path(directory)
        library = root / "library"
        (library / "promptlib").mkdir(parents=True)
        (library / "prompts").mkdir()
        (library / "promptlib" / "__init__.py").write_text("")
        (library / "promptlib" / "cli.py").write_text(
            "raise SystemExit('old library package was imported')\n")
        (library / "models.toml").write_text(
            '[models.grok]\nname = "Grok 4.7"\nfamily = "grok"\n'
            'guides = []\nnotes = "No external guidance."\n')
        (library / "prompts" / "sample.md").write_text(
            '+++\ntitle = "Test prompt"\ntargets = ["grok"]\ntags = []\n'
            '+++\nHelp me set this up.\n')

        received: list[dict] = []

        class Provider(BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers["Content-Length"])
                received.append(json.loads(self.rfile.read(length)))
                body = json.dumps({"choices": [{"message": {
                    "content": "built by the packaged runtime"}}]}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        server = HTTPServer(("127.0.0.1", 0), Provider)
        server.timeout = 30
        worker = threading.Thread(target=server.handle_request, daemon=True)
        worker.start()
        try:
            (library / "enhancer.toml").write_text(
                '[enhancer]\nauth = "api_key"\n'
                f'endpoint = "http://127.0.0.1:{server.server_port}/v1/chat/completions"\n'
                'model = "writer"\npreset = "custom"\ntimeout = 5\n')
            test_bin = root / "bin"
            test_bin.mkdir()
            keychain_shim = test_bin / "security"
            keychain_shim.write_text("#!/bin/sh\nexit 1\n")
            keychain_shim.chmod(0o700)
            env = dict(os.environ)
            env["PATH"] = f"{test_bin}:/usr/bin:/bin"
            env["SEEDBED_VERIFY_REBUILD_ROOT"] = str(library)
            result = subprocess.run([str(executable)], cwd=library, env=env,
                                    capture_output=True, text=True, timeout=30)
            if result.returncode:
                raise AssertionError(
                    f"packaged app build failed ({result.returncode}): "
                    f"{result.stderr.strip()[:500]}")
            assert "app rebuilt sample/grok" in result.stdout, result.stdout[:500]
            render = (library / "rendered" / "grok" / "sample.md").read_text()
            assert "built by the packaged runtime" in render, render[:200]
            assert 'enhancer = "api_key"' in render, render[:200]
            assert received and received[0]["model"] == "writer", received
            assert not any(runtime.rglob("__pycache__")), "Python wrote into signed bundle"
        finally:
            server.server_close()
            worker.join(timeout=1)


if __name__ == "__main__":
    import sys

    verify(Path(sys.argv[1]))
    print("packaged app used the saved provider with an older library")
