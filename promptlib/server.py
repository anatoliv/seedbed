"""A local web UI: seeds on the left, a model dropdown on the right.

Picking a model copies that model's tailored prompt. Adding a seed renders it
for every target in the background. Refresh re-fetches guidance and rebuilds
whatever went stale.

Localhost only, single user, stdlib only. Bound to 127.0.0.1 — this serves the
contents of your prompt library and has no authentication, so it must never
listen on a routable address.
"""

from __future__ import annotations

import json
import re
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from . import builder
from .enhance import DEFAULT_BACKEND
from .guides import GuideCache, load_registry
from .store import FormatError, Library, Seed
from .usage import Usage

WEB = Path(__file__).resolve().parent / "web"
BRAND = Path(__file__).resolve().parent.parent / "assets" / "brand"
MAX_BODY = 64 * 1024
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")


class State:
    """Everything the handlers share. One per server."""

    def __init__(self, root: Path, enhancer: str = DEFAULT_BACKEND):
        self.root = root
        self.lib = Library(root)
        self.cache = GuideCache(root)
        self.enhancer = enhancer
        self.builder = builder.Builder(self.lib, enhancer)
        self._models_lock = threading.Lock()
        self.reload_models()

    def reload_models(self) -> None:
        """Re-read models.toml so an edit shows up without a restart."""
        with self._models_lock:
            self.models = load_registry(self.root / "models.toml")

    def library_view(self) -> dict:
        """Shared with the CLI and the macOS app, plus this server's job state."""
        view = builder.library_view(self.lib, self.models, self.cache, Usage(self.root))
        job = self.builder.job
        view["job"] = {
            "running": job.running,
            "total": job.total,
            "done": job.done,
            "current": job.current,
            "errors": job.errors,
        }
        return view


class Handler(BaseHTTPRequestHandler):
    state: State  # set on the server class

    server_version = "promptlib"

    def log_message(self, fmt, *args):  # quieter than the default access log
        pass

    # -- helpers ----------------------------------------------------------

    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, payload: dict, code: int = 200) -> None:
        self._send(code, json.dumps(payload).encode(), "application/json; charset=utf-8")

    def _error(self, code: int, message: str) -> None:
        self._json({"error": message}, code)

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_BODY:
            raise ValueError("missing or oversized request body")
        return json.loads(self.rfile.read(length))

    # -- routes -----------------------------------------------------------

    def do_GET(self) -> None:
        url = urlparse(self.path)
        query = parse_qs(url.query)
        if url.path in ("/", "/index.html"):
            page = WEB / "index.html"
            self._send(200, page.read_bytes(), "text/html; charset=utf-8")
        elif url.path == "/favicon.svg":
            self._send(200, (BRAND / "favicon.svg").read_bytes(), "image/svg+xml")
        elif url.path == "/favicon-32.png":
            self._send(200, (BRAND / "favicon-32.png").read_bytes(), "image/png")
        elif url.path == "/apple-touch-icon.png":
            self._send(200, (BRAND / "apple-touch-icon.png").read_bytes(), "image/png")
        elif url.path == "/seedbed-mark.svg":
            self._send(200, (BRAND / "seedbed-mark.svg").read_bytes(), "image/svg+xml")
        elif url.path == "/api/library":
            try:
                self._json(self.state.library_view())
            except FormatError as exc:
                self._error(400, str(exc))
        elif url.path == "/api/render":
            self._render(query)
        else:
            self._error(404, "no such path")

    def _render(self, query: dict) -> None:
        seed_id = (query.get("id") or [""])[0]
        model = (query.get("model") or [""])[0]
        if model not in self.state.models:
            return self._error(400, f"unknown model {model!r}")
        render = self.state.lib.render(seed_id, model)
        if render is None:
            return self._error(
                404, f"no render yet for {seed_id} / {model} — it may still be building"
            )
        self._json({"id": seed_id, "model": model, "body": render.body})

    def do_POST(self) -> None:
        url = urlparse(self.path)
        try:
            payload = self._read_json() if url.path != "/api/refresh" else {}
        except (ValueError, json.JSONDecodeError) as exc:
            return self._error(400, f"bad request body: {exc}")

        if url.path == "/api/seeds":
            self._create_seed(payload)
        elif url.path == "/api/refresh":
            self._refresh()
        elif url.path == "/api/copy":
            self._copy(payload)
        else:
            self._error(404, "no such path")

    def _create_seed(self, payload: dict) -> None:
        """Add a seed, then immediately start rendering it for every target."""
        body = (payload.get("body") or "").strip()
        title = (payload.get("title") or "").strip()
        targets = [t for t in payload.get("targets", []) if t in self.state.models]
        if not body:
            return self._error(400, "the prompt itself cannot be empty")
        seed_id = (payload.get("id") or "").strip() or _slug(title or body)
        if not ID_RE.match(seed_id):
            return self._error(400, f"{seed_id!r} is not a usable id (a-z, 0-9, hyphens)")
        path = self.state.lib.prompts / f"{seed_id}.md"
        if path.exists():
            return self._error(409, f"{seed_id} already exists")
        self.state.lib.prompts.mkdir(parents=True, exist_ok=True)
        Seed(id=seed_id, title=title or seed_id.replace("-", " "), targets=targets, body=body).write(path)

        pairs = builder.pending(self.state.lib, self.state.models, self.state.cache, seed_id=seed_id)
        started = self.state.builder.start(pairs)
        self._json(
            {
                "id": seed_id,
                "queued": len(pairs) if started else 0,
                "busy": not started,
            },
            201,
        )

    def _refresh(self) -> None:
        """Re-fetch guidance, then rebuild everything it made stale."""
        self.state.reload_models()
        try:
            pairs = builder.pending(
                self.state.lib, self.state.models, self.state.cache, refresh_guides=True
            )
        except FormatError as exc:
            return self._error(400, str(exc))
        started = self.state.builder.start(pairs)
        self._json({"queued": len(pairs) if started else 0, "busy": not started})

    def _copy(self, payload: dict) -> None:
        """Server-side clipboard, for when the browser's clipboard API is refused."""
        seed_id = payload.get("id", "")
        model = payload.get("model", "")
        if model not in self.state.models:
            return self._error(400, f"unknown model {model!r}")
        render = self.state.lib.render(seed_id, model)
        if render is None:
            return self._error(404, "no render to copy")
        try:
            subprocess.run(["pbcopy"], input=render.body, text=True, check=True, timeout=10)
        except (OSError, subprocess.SubprocessError) as exc:
            return self._error(500, f"pbcopy failed: {exc}")
        self._json({"copied": True, "words": len(render.body.split())})


def _slug(text: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return slug[:48].strip("-") or "prompt"


def serve(root: Path, port: int = 8765, enhancer: str = DEFAULT_BACKEND) -> None:
    handler = type("BoundHandler", (Handler,), {"state": State(root, enhancer)})
    httpd = ThreadingHTTPServer(("127.0.0.1", port), handler)
    print(f"prompt-library on http://127.0.0.1:{port}  (ctrl-c to stop)")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")
    finally:
        httpd.server_close()
