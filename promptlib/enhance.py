"""The enhancer: the model that rewrites a seed into a tailored prompt.

Distinct from the target, which is the model the prompt is written FOR. The
default backend shells out to the Claude Code CLI already on this machine, so
the tool needs no API key and no extra spend.
"""

from __future__ import annotations

import os
import shutil
import subprocess

DEFAULT_BACKEND = "claude-cli"
CLI_MODEL = "opus"
API_MODEL = "claude-opus-5"  # per the claude-api skill: exact ID, no date suffix
TIMEOUT = 300

# HTTP statuses worth trying the fallback for: the request was fine, the other
# end was not. A 400/401/404 means the configuration is wrong and a second
# endpoint with the same body would fail the same way.
RETRYABLE = {408, 409, 425, 429, 500, 502, 503, 504}

from .store import CONTEXTS, DEFAULT_CONTEXT

SYSTEM = """You rewrite short prompts into precise, effective prompts for a \
specific target model.

You are given: the target model, prompting guidance for that model, and a short \
seed prompt written by a developer.

Produce ONE prompt, ready to paste into that model. Requirements:
- Preserve the seed's intent exactly. Do not add goals it does not state.
- Apply the guidance to THIS target. Different models want different amounts of \
direction; follow the guidance rather than a house style.
- Keep {{PLACEHOLDER}} tokens verbatim if the seed contains any.
- If the seed refers to material the person will supply ("this code", "my \
diff", "this bug"), the prompt MUST end with a labelled place to put it: a \
`<code>` block, a final line reading `Code:`, or the equivalent for whatever \
the input is. A prompt with nowhere for its input cannot be pasted and used, \
which is a defect the reader only discovers after copying it.
- **Write for the stated usage context, and it changes the prompt materially.** \
For an agent with the repository open, instructing it to reproduce a failure, \
read surrounding code and run the suite is correct. For a chat window holding \
one snippet, those instructions are actively harmful: the model searches for \
code that is not there and declines to answer. In that context, tell it to work \
from the supplied text alone, to say what it cannot determine from that text, \
and never to ask for files or command output it cannot obtain.
- State what "done" looks like, and any verification the task implies.
- No preamble, no explanation, no surrounding markdown fence. Output the prompt \
itself and nothing else."""


class EnhancerError(RuntimeError):
    """The enhancer could not produce a render."""


def _user_message(seed_body: str, model_name: str, guidance: str,
                  context: str = DEFAULT_CONTEXT) -> str:
    return (
        f"Target model: {model_name}\n\n"
        f"Where this prompt will be used: {CONTEXTS[context]}\n\n"
        f"Prompting guidance for this model:\n<guidance>\n{guidance}\n</guidance>\n\n"
        f"Seed prompt to rewrite:\n<seed>\n{seed_body}\n</seed>"
    )


#: Where the `claude` CLI installs itself, in the order worth trying.
#:
#: `shutil.which` alone is not enough and the reason is the same one the
#: interpreter probe exists for: an app launched from Finder inherits a minimal
#: PATH — roughly /usr/bin:/bin:/usr/sbin:/sbin — so a binary in ~/.local/bin or
#: /opt/homebrew/bin is invisible to it while working perfectly in a terminal.
#: The failure looks like "not installed" to someone who has it installed.
CLAUDE_CANDIDATES = [
    "~/.local/bin/claude",          # the official installer
    "~/.claude/local/claude",       # the older local install
    "/opt/homebrew/bin/claude",     # Homebrew on Apple silicon
    "/usr/local/bin/claude",        # Homebrew on Intel
    "/usr/bin/claude",
]


def find_claude_cli() -> str | None:
    """The `claude` binary, or None. `SEEDBED_CLAUDE_BIN` overrides everything."""
    override = os.environ.get("SEEDBED_CLAUDE_BIN", "").strip()
    if override:
        return override if os.access(os.path.expanduser(override), os.X_OK) else None
    found = shutil.which("claude")
    if found:
        return found
    for candidate in CLAUDE_CANDIDATES:
        path = os.path.expanduser(candidate)
        if os.access(path, os.X_OK):
            return path
    return None


def _via_claude_cli(prompt: str) -> str:
    binary = find_claude_cli()
    if not binary:
        looked = ", ".join(CLAUDE_CANDIDATES)
        raise EnhancerError(
            "the `claude` CLI was not found. Looked on PATH and in: " + looked + ". "
            "Install Claude Code, set SEEDBED_CLAUDE_BIN to its path, or pick "
            "another backend with --enhancer anthropic|openai."
        )
    try:
        done = subprocess.run(
            [binary, "-p", prompt, "--model", CLI_MODEL],
            capture_output=True,
            text=True,
            timeout=TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        raise EnhancerError(f"claude CLI did not answer within {TIMEOUT}s") from None
    if done.returncode != 0:
        raise EnhancerError(f"claude CLI failed ({done.returncode}): {done.stderr.strip()[:400]}")
    out = done.stdout.strip()
    if not out:
        raise EnhancerError("claude CLI returned nothing")
    return out


def _via_anthropic(prompt: str, system: str = SYSTEM) -> str:
    try:
        import anthropic
    except ModuleNotFoundError:
        raise EnhancerError("the anthropic SDK is not installed: pip install anthropic") from None
    try:
        client = anthropic.Anthropic()
        response = client.messages.create(
            model=API_MODEL,
            max_tokens=16000,
            system=system,
            messages=[{"role": "user", "content": prompt}],
        )
    except anthropic.APIStatusError as exc:
        raise EnhancerError(f"Anthropic API error {exc.status_code}: {exc}") from None
    except anthropic.APIConnectionError as exc:
        raise EnhancerError(f"could not reach the Anthropic API: {exc}") from None
    parts = [b.text for b in response.content if b.type == "text"]
    if not parts:
        raise EnhancerError("the API returned no text content")
    return "\n".join(parts).strip()


class RetryableError(EnhancerError):
    """The other end failed in a way a second endpoint might not."""


def _via_http(prompt: str, endpoint: str, model: str, key: str,
              auth: str, timeout: int, system: str = SYSTEM) -> str:
    """Any OpenAI-compatible endpoint, including Azure and local servers.

    Raw HTTP on purpose: this reaches local and self-hosted endpoints, and the
    tool should not need a vendor SDK to talk to one.
    """
    import json
    import urllib.error
    import urllib.request

    if not endpoint or not model:
        raise EnhancerError("the enhancer has no endpoint or model set")

    payload = json.dumps(
        {
            "model": model,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": prompt},
            ],
        }
    ).encode()
    headers = {"Content-Type": "application/json"}
    if key:
        # Azure wants its key in its own header; everyone else takes a Bearer.
        headers["api-key" if auth == "azure_api_key" else "Authorization"] = (
            key if auth == "azure_api_key" else f"Bearer {key}")

    req = urllib.request.Request(endpoint, data=payload, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        detail = exc.read()[:200].decode("utf-8", "replace")
        message = f"{endpoint} returned {exc.code}: {detail}"
        raise (RetryableError if exc.code in RETRYABLE else EnhancerError)(message) from None
    except (urllib.error.URLError, TimeoutError) as exc:
        raise RetryableError(f"could not reach {endpoint}: {exc}") from None
    try:
        return body["choices"][0]["message"]["content"].strip()
    except (KeyError, IndexError, TypeError):
        raise EnhancerError(f"unexpected response shape from {endpoint}") from None


def enhance(seed_body: str, model_name: str, guidance: str,
            backend: str | None = None, config=None,
            context: str = DEFAULT_CONTEXT) -> str:
    """Build one prompt with the configured enhancer.

    `backend` overrides the configuration for a single call, which is what the
    CLI's --enhancer flag does. `context` says where the finished prompt will be
    pasted, which changes what a good prompt looks like.
    """
    return run_prompt(SYSTEM,
                      _user_message(seed_body, model_name, guidance, context),
                      backend=backend, config=config)


def run_prompt(system: str, message: str, backend: str | None = None, config=None) -> str:
    """Send one system+user pair to the configured enhancer.

    Shared by prompt building and by the comparison summary, so both inherit the
    same auth modes, endpoint rule and fallback.
    """
    auth = backend or (config.auth if config else DEFAULT_BACKEND)
    if auth in {"claude-cli", "cli"}:
        return _via_claude_cli(f"{system}\n\n---\n\n{message}")
    if auth in {"anthropic", "sdk"}:
        return _via_anthropic(message, system=system)
    if auth == "chatgpt_oauth":
        # Imported here rather than at module scope so the rest of the enhancer
        # keeps working on a machine where the Keychain is unavailable.
        from . import codex_oauth
        model = (config.model if config and config.model else "gpt-5.4-mini")
        timeout = config.timeout if config else 300
        try:
            return codex_oauth.complete(system, message, model, timeout=timeout)
        except codex_oauth.CodexAuthError as exc:
            raise EnhancerError(str(exc)) from None
    if auth not in {"api_key", "azure_api_key", "openai"}:
        raise EnhancerError(f"unknown enhancer {auth!r}")

    if config is None:
        raise EnhancerError("this enhancer needs configuration. Run: promptlib enhancer set")

    try:
        return _via_http(message, config.endpoint, config.model, config.api_key,
                         config.auth, config.timeout, system=system)
    except RetryableError as primary:
        if not config.has_fallback:
            raise
        # One attempt, not a loop: a fallback that also fails is a configuration
        # problem, and retrying it burns time before any output.
        try:
            return _via_http(message, config.fallback_endpoint, config.fallback_model,
                             config.fallback_api_key, "api_key", config.timeout,
                             system=system)
        except EnhancerError as secondary:
            raise EnhancerError(f"primary failed ({primary}); fallback failed ({secondary})") from None
