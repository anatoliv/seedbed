"""Sign in with ChatGPT, so a ChatGPT subscription can build prompts.

Mirrors the first-party Codex CLI's login flow (`openai/codex`,
`codex-rs/login`). It lives here in Python rather than in Swift because prompt
building runs in this package, and the app is a front end over it.

**Every constant below mirrors a literal in the open-source Codex CLI**, and the
redirect URI in particular is allow-listed server-side: change the port and the
authorize call is rejected with `invalid_redirect_uri`. The endpoint is
undocumented and not promised to be stable. If the CLI changes a constant,
follow it here.

## The security-relevant parts, and why each is the way it is

- **PKCE S256.** The `client_id` is public (it is the first-party CLI's), so
  possession of the code alone must not be enough. The verifier proves the
  exchange comes from whoever started the flow.
- **`state`**, 32 random bytes, echoed back and compared. Without it a callback
  can be forged by anything that can reach the loopback port while a login is in
  flight.
- **The listener binds 127.0.0.1 only**, serves exactly one request, and is
  killed by a timeout whether or not it gets one. A loopback listener left
  running is a way in, and one that lives past the flow has no reason to exist.
- **Tokens live in the login Keychain**, never in `enhancer.toml`. That file is
  committed on purpose because it carries the choice, not the secret.
- **Nothing here logs a token.** Errors carry status codes and bodies truncated
  to 200 characters, which is enough to diagnose and not enough to leak.
"""

from __future__ import annotations

import base64
import hashlib
import http.server
import json
import secrets
import socket
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass

#: The first-party Codex CLI client. OpenAI's authorization server accepts this
#: id from any client because PKCE proves possession; the allow-listed redirect
#: URI is the second check.
CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"

AUTHORIZE_URL = "https://auth.openai.com/oauth/authorize"
TOKEN_URL = "https://auth.openai.com/oauth/token"

#: Allow-listed server-side. A different port fails with `invalid_redirect_uri`,
#: which is why this is not configurable.
CALLBACK_PORT = 1455
REDIRECT_URI = f"http://localhost:{CALLBACK_PORT}/auth/callback"
CALLBACK_PATH = "/auth/callback"

#: `offline_access` is what yields a refresh token; the `api.connectors.*` pair
#: is what makes the backend-api route accept the bearer.
SCOPES = ("openid profile email offline_access "
          "api.connectors.read api.connectors.invoke")

#: Branded originator, so traffic from this tool is attributable to it.
ORIGINATOR = "seedbed_macos"

#: The Responses surface the OAuth bearer is accepted on. Part of the auth
#: contract rather than a user setting.
RESPONSES_URL = "https://chatgpt.com/backend-api/codex/responses"

#: Where the token bundle is kept.
KEYCHAIN_SERVICE = "promptlib-codex-oauth"

#: How long to wait for the person to finish consenting in the browser.
LOGIN_TIMEOUT = 300

#: Refresh this far ahead of expiry. Narrow, so back-to-back calls collapse onto
#: one refresh rather than each doing their own.
REFRESH_SLACK = 60


class CodexAuthError(RuntimeError):
    """Sign-in or token refresh failed."""


def _b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def _b64url_decode(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


# MARK: - PKCE


@dataclass(frozen=True)
class PKCE:
    verifier: str
    challenge: str

    @classmethod
    def generate(cls) -> "PKCE":
        """64 random bytes as the verifier; the challenge is its SHA-256.

        Both URL-safe base64 without padding, which is what S256 requires and
        what the CLI produces.
        """
        verifier = _b64url(secrets.token_bytes(64))
        challenge = _b64url(hashlib.sha256(verifier.encode("ascii")).digest())
        return cls(verifier=verifier, challenge=challenge)


def generate_state() -> str:
    """CSRF guard. Embedded in the authorize URL and compared on the callback."""
    return _b64url(secrets.token_bytes(32))


def authorize_url(pkce: PKCE, state: str) -> str:
    """The URL the person opens to consent.

    The two non-standard parameters are the CLI's and are required for the
    simplified flow; dropping them changes what comes back.
    """
    query = urllib.parse.urlencode({
        "response_type": "code",
        "client_id": CLIENT_ID,
        "redirect_uri": REDIRECT_URI,
        "scope": SCOPES,
        "code_challenge": pkce.challenge,
        "code_challenge_method": "S256",
        "id_token_add_organizations": "true",
        "codex_cli_simplified_flow": "true",
        "state": state,
        "originator": ORIGINATOR,
    })
    return f"{AUTHORIZE_URL}?{query}"


# MARK: - Tokens


@dataclass
class Tokens:
    access_token: str
    refresh_token: str
    id_token: str
    #: Unix seconds, computed from `expires_in` at issuance.
    expires_at: float

    @property
    def needs_refresh(self) -> bool:
        return self.expires_at - time.time() < REFRESH_SLACK

    def as_dict(self) -> dict:
        return {
            "access_token": self.access_token,
            "refresh_token": self.refresh_token,
            "id_token": self.id_token,
            "expires_at": self.expires_at,
        }

    @classmethod
    def from_dict(cls, data: dict) -> "Tokens":
        return cls(
            access_token=data.get("access_token", ""),
            refresh_token=data.get("refresh_token", ""),
            id_token=data.get("id_token", ""),
            expires_at=float(data.get("expires_at", 0)),
        )


@dataclass
class Claims:
    """What the id_token says, for display and for the account header.

    Decoded without verifying the signature: it arrived over TLS from
    auth.openai.com moments ago, and it is used for a header and a status line,
    never to authorise anything.
    """
    email: str = ""
    plan: str = ""
    account_id: str = ""


def parse_id_token(jwt: str) -> Claims:
    parts = jwt.split(".")
    if len(parts) != 3:
        raise CodexAuthError("id_token is not a JWT")
    try:
        payload = json.loads(_b64url_decode(parts[1]))
    except (ValueError, TypeError) as exc:
        raise CodexAuthError(f"id_token payload is not JSON: {exc}") from None
    auth = payload.get("https://api.openai.com/auth") or {}
    profile = payload.get("https://api.openai.com/profile") or {}
    return Claims(
        email=payload.get("email") or profile.get("email") or "",
        plan=auth.get("chatgpt_plan_type") or "",
        account_id=auth.get("chatgpt_account_id") or "",
    )


def _post_token_request(fields: dict) -> Tokens:
    body = urllib.parse.urlencode(fields).encode()
    request = urllib.request.Request(
        TOKEN_URL, data=body, method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded",
                 "Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as exc:
        # Truncated deliberately: enough to diagnose, not enough to leak.
        detail = exc.read().decode("utf-8", "replace")[:200]
        raise CodexAuthError(f"the OAuth server returned {exc.code}: {detail}") from None
    except (urllib.error.URLError, TimeoutError) as exc:
        raise CodexAuthError(f"could not reach {TOKEN_URL}: {exc}") from None

    if "access_token" not in payload or "expires_in" not in payload:
        raise CodexAuthError("the OAuth server's response was missing expected fields")
    return Tokens(
        access_token=payload["access_token"],
        # A refresh call omits `refresh_token` when the existing one is still
        # good, so the caller keeps what it had.
        refresh_token=payload.get("refresh_token") or "",
        id_token=payload.get("id_token") or "",
        expires_at=time.time() + float(payload["expires_in"]),
    )


def exchange_code(code: str, verifier: str) -> Tokens:
    return _post_token_request({
        "grant_type": "authorization_code",
        "code": code,
        "redirect_uri": REDIRECT_URI,
        "client_id": CLIENT_ID,
        "code_verifier": verifier,
    })


def refresh_tokens(refresh_token: str) -> Tokens:
    """`offline_access` was in the original grant, or this returns 400."""
    fresh = _post_token_request({
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "client_id": CLIENT_ID,
        "scope": SCOPES,
    })
    if not fresh.refresh_token:
        fresh.refresh_token = refresh_token
    return fresh


# MARK: - Keychain


def load_tokens() -> Tokens | None:
    try:
        out = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
            capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0 or not out.stdout.strip():
        return None
    try:
        return Tokens.from_dict(json.loads(out.stdout.strip()))
    except (ValueError, TypeError):
        return None


def store_tokens(tokens: Tokens | None) -> None:
    if tokens is None:
        subprocess.run(["security", "delete-generic-password", "-s", KEYCHAIN_SERVICE],
                       capture_output=True, text=True)
        return
    subprocess.run(
        ["security", "add-generic-password", "-U", "-s", KEYCHAIN_SERVICE,
         "-a", "promptlib", "-w", json.dumps(tokens.as_dict())],
        capture_output=True, text=True, check=False)


# MARK: - The one-shot loopback listener


_DONE_PAGE = b"""<!doctype html><meta charset="utf-8">
<title>Signed in</title>
<body style="font:15px -apple-system,sans-serif;padding:3rem;max-width:32rem">
<h1 style="font-size:1.2rem">Signed in to ChatGPT</h1>
<p>Seedbed has the token it needs. You can close this tab and go back to the
terminal.</p>"""

_FAIL_PAGE = b"""<!doctype html><meta charset="utf-8">
<title>Sign-in failed</title>
<body style="font:15px -apple-system,sans-serif;padding:3rem;max-width:32rem">
<h1 style="font-size:1.2rem">Sign-in did not complete</h1>
<p>Go back to the terminal for the reason.</p>"""


class _CallbackHandler(http.server.BaseHTTPRequestHandler):
    """Serves exactly one redirect and records what it carried."""

    # Set by the server before it starts.
    expected_state: str = ""
    result: dict = {}

    def do_GET(self):  # noqa: N802 - the stdlib's spelling
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != CALLBACK_PATH:
            self.send_error(404, "not the callback path")
            return
        params = urllib.parse.parse_qs(parsed.query)
        state = (params.get("state") or [""])[0]
        code = (params.get("code") or [""])[0]
        error = (params.get("error") or [""])[0]

        # Compared in constant time and BEFORE the code is looked at, so a
        # forged callback cannot get its code as far as the token endpoint.
        if not secrets.compare_digest(state, type(self).expected_state):
            type(self).result = {"error": "state did not match; possible forged callback"}
            self._reply(400, _FAIL_PAGE)
            return
        if error:
            type(self).result = {"error": f"the authorization server said: {error}"}
            self._reply(400, _FAIL_PAGE)
            return
        if not code:
            type(self).result = {"error": "the callback carried no authorization code"}
            self._reply(400, _FAIL_PAGE)
            return
        type(self).result = {"code": code}
        self._reply(200, _DONE_PAGE)

    def _reply(self, status: int, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        """Silence. The default handler prints the full request line, which
        here contains the authorization code."""


def wait_for_callback(state: str, timeout: int = LOGIN_TIMEOUT) -> str:
    """Run the listener until it gets one callback, then stop it.

    Binds 127.0.0.1 explicitly rather than 0.0.0.0: nothing off this machine has
    any business completing a sign-in started here.
    """
    _CallbackHandler.expected_state = state
    _CallbackHandler.result = {}
    try:
        server = http.server.HTTPServer(("127.0.0.1", CALLBACK_PORT), _CallbackHandler)
    except OSError as exc:
        raise CodexAuthError(
            f"could not listen on 127.0.0.1:{CALLBACK_PORT} ({exc}). That exact "
            "port is allow-listed by the authorization server, so it cannot be "
            "changed; close whatever is using it and try again."
        ) from None
    server.timeout = 1

    deadline = time.time() + timeout
    try:
        while not _CallbackHandler.result and time.time() < deadline:
            server.handle_request()
    finally:
        server.server_close()

    result = _CallbackHandler.result
    _CallbackHandler.expected_state = ""
    _CallbackHandler.result = {}
    if not result:
        raise CodexAuthError(f"no callback arrived within {timeout}s")
    if "error" in result:
        raise CodexAuthError(result["error"])
    return result["code"]


def port_is_free() -> bool:
    """Whether the allow-listed callback port can be bound right now."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            probe.bind(("127.0.0.1", CALLBACK_PORT))
        except OSError:
            return False
    return True


# MARK: - The flows


def login(open_browser=None, timeout: int = LOGIN_TIMEOUT) -> Claims:
    """Run the whole sign-in and store the result. Returns who signed in."""
    pkce = PKCE.generate()
    state = generate_state()
    url = authorize_url(pkce, state)

    opener = open_browser
    if opener is None:
        def opener(target: str) -> None:
            subprocess.run(["open", target], check=False)

    holder: dict = {}

    def run_listener():
        try:
            holder["code"] = wait_for_callback(state, timeout=timeout)
        except CodexAuthError as exc:
            holder["error"] = exc

    # The listener starts first: opening the browser can complete faster than
    # a listener started afterwards would be ready for.
    thread = threading.Thread(target=run_listener, daemon=True)
    thread.start()
    time.sleep(0.2)
    opener(url)
    thread.join(timeout + 5)

    if "error" in holder:
        raise holder["error"]
    if "code" not in holder:
        raise CodexAuthError("sign-in did not complete")

    tokens = exchange_code(holder["code"], pkce.verifier)
    store_tokens(tokens)
    return parse_id_token(tokens.id_token) if tokens.id_token else Claims()


def logout() -> None:
    store_tokens(None)


def current_tokens(refresh_if_needed: bool = True) -> Tokens:
    """The stored tokens, refreshed if they are about to expire.

    Raises rather than returning None: every caller needs a usable token, and
    an explanation of why there isn't one is more useful than a null.
    """
    tokens = load_tokens()
    if tokens is None or not tokens.access_token:
        raise CodexAuthError(
            "not signed in to ChatGPT. Run: python3 -m promptlib enhancer login")
    if refresh_if_needed and tokens.needs_refresh:
        if not tokens.refresh_token:
            raise CodexAuthError(
                "the ChatGPT session expired and there is no refresh token. "
                "Run: python3 -m promptlib enhancer login")
        tokens = refresh_tokens(tokens.refresh_token)
        store_tokens(tokens)
    return tokens


def status() -> dict:
    """Signed-in state for a status line, with no secret in it."""
    tokens = load_tokens()
    if tokens is None or not tokens.access_token:
        return {"signed_in": False}
    claims = parse_id_token(tokens.id_token) if tokens.id_token else Claims()
    return {
        "signed_in": True,
        "email": claims.email,
        "plan": claims.plan,
        "expires_in": max(0, int(tokens.expires_at - time.time())),
        "needs_refresh": tokens.needs_refresh,
    }


def complete(system: str, message: str, model: str, timeout: int = 300) -> str:
    """One non-streaming call to the Codex Responses endpoint.

    `instructions` must be non-empty and `store` must be false; this endpoint
    returns 400 otherwise. It speaks Responses, not Chat Completions, so the
    shape differs from every other backend in `enhance.py`.

    A 401 is retried exactly once after a forced refresh, because the common
    cause is a token that expired between the check and the call.
    """
    tokens = current_tokens()
    claims = parse_id_token(tokens.id_token) if tokens.id_token else Claims()

    def send(access_token: str) -> str:
        body = json.dumps({
            "model": model,
            "input": [{"role": "user", "content": message}],
            "stream": False,
            "instructions": system or "You are a helpful assistant.",
            "store": False,
        }).encode()
        headers = {
            "Authorization": f"Bearer {access_token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "originator": ORIGINATOR,
        }
        if claims.account_id:
            headers["ChatGPT-Account-Id"] = claims.account_id
        request = urllib.request.Request(RESPONSES_URL, data=body, method="POST",
                                         headers=headers)
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return _extract_text(json.load(response))

    try:
        return send(tokens.access_token)
    except urllib.error.HTTPError as exc:
        if exc.code != 401:
            detail = exc.read().decode("utf-8", "replace")[:200]
            raise CodexAuthError(f"Codex returned {exc.code}: {detail}") from None
    except (urllib.error.URLError, TimeoutError) as exc:
        raise CodexAuthError(f"could not reach the Codex endpoint: {exc}") from None

    if not tokens.refresh_token:
        raise CodexAuthError(
            "ChatGPT rejected the token and there is no refresh token. "
            "Run: python3 -m promptlib enhancer login")
    refreshed = refresh_tokens(tokens.refresh_token)
    store_tokens(refreshed)
    try:
        return send(refreshed.access_token)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:200]
        raise CodexAuthError(
            f"Codex still returned {exc.code} after refreshing: {detail}") from None
    except (urllib.error.URLError, TimeoutError) as exc:
        raise CodexAuthError(f"could not reach the Codex endpoint: {exc}") from None


def _extract_text(payload: dict) -> str:
    """Pull the assistant text out of a Responses reply.

    The shape is `output: [{content: [{type: "output_text", text: ...}]}]`, but
    `output_text` is offered as a convenience field by some versions. Try the
    documented path first and fall back rather than failing on a shape change.
    """
    if isinstance(payload.get("output_text"), str) and payload["output_text"].strip():
        return payload["output_text"].strip()
    chunks: list[str] = []
    for item in payload.get("output") or []:
        for part in (item or {}).get("content") or []:
            text = (part or {}).get("text")
            if isinstance(text, str):
                chunks.append(text)
    if not chunks:
        raise CodexAuthError("the Codex response contained no text")
    return "\n".join(chunks).strip()
