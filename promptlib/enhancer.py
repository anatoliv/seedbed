"""Which model does the building, and how it authenticates.

Mirrors Reference's Settings → AI: provider presets, three auth modes,
endpoint + model, a Keychain-held key, and a fallback tried once when the
primary fails retryably.

Two things stay deliberately different from a chat client. There is no
streaming (a build is one request and the result goes to a file), and the local
`claude` CLI is a first-class backend, because it uses a subscription that is
already paid for and needs no key at all.
"""

from __future__ import annotations

import subprocess
import tomllib
from dataclasses import dataclass, field
from ipaddress import ip_address
from pathlib import Path
from urllib.parse import urlparse

CONFIG_FILE = "enhancer.toml"
KEYCHAIN_SERVICE = "promptlib-enhancer"
FALLBACK_KEYCHAIN_SERVICE = "promptlib-enhancer-fallback"


@dataclass
class Preset:
    id: str
    name: str
    endpoint: str
    model: str
    auth: str = "api_key"


#: Provider presets, matching Reference's `AIProviderPreset.all`. Cost-first:
#: OpenAI is here because most people start there, the rest are ways to spend
#: less, and the two local ones cost nothing at all.
PRESETS: list[Preset] = [
    Preset("claude-cli", "Claude Code CLI (no key, uses your subscription)", "", "opus", "cli"),
    Preset("anthropic-sdk", "Anthropic SDK (ANTHROPIC_API_KEY or ant login)", "", "claude-opus-5", "sdk"),
    Preset("openai-chatgpt", "ChatGPT Plus/Pro (sign in, no API key)",
           "https://chatgpt.com/backend-api/codex/responses", "gpt-5.4-mini", "chatgpt_oauth"),
    Preset("openai", "OpenAI (paid)",
           "https://api.openai.com/v1/chat/completions", "gpt-4o-mini"),
    Preset("openrouter", "OpenRouter (many models, paid)",
           "https://openrouter.ai/api/v1/chat/completions", "openrouter/auto"),
    Preset("anthropic", "Anthropic Claude API (paid)",
           "https://api.anthropic.com/v1/chat/completions", "claude-haiku-4-5"),
    Preset("azure", "Azure OpenAI (paid, api-key header)",
           "https://YOUR-RESOURCE.openai.azure.com/openai/deployments/YOUR-DEPLOYMENT"
           "/chat/completions?api-version=2024-10-21", "", "azure_api_key"),
    Preset("github", "GitHub Models (free personal tier)",
           "https://models.inference.ai.azure.com/chat/completions", "gpt-4o-mini"),
    Preset("groq", "Groq (very cheap, fast llama variants)",
           "https://api.groq.com/openai/v1/chat/completions", "llama-3.3-70b-versatile"),
    Preset("together", "Together AI (cheap open-weight models)",
           "https://api.together.xyz/v1/chat/completions", "meta-llama/Llama-3.3-70B-Instruct-Turbo"),
    Preset("fireworks", "Fireworks AI (cheap open-weight models)",
           "https://api.fireworks.ai/inference/v1/chat/completions",
           "accounts/fireworks/models/llama-v3p3-70b-instruct"),
    Preset("ollama", "Ollama (local, free)",
           "http://localhost:11434/v1/chat/completions", "llama3.2:3b"),
    Preset("lmstudio", "LM Studio (local, free)",
           "http://localhost:1234/v1/chat/completions", ""),
    Preset("llamacpp", "llama.cpp (local, free)",
           "http://localhost:8080/v1/chat/completions", ""),
]

AUTH_MODES = ["cli", "sdk", "api_key", "azure_api_key", "chatgpt_oauth"]


def keychain_get(service: str) -> str:
    """Read a secret. A missing item is normal, not an error."""
    try:
        out = subprocess.run(["security", "find-generic-password", "-s", service, "-w"],
                             capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return ""
    return out.stdout.strip() if out.returncode == 0 else ""


def keychain_set(service: str, value: str) -> None:
    """Store or clear a secret. Never written to the config file."""
    if not value:
        subprocess.run(["security", "delete-generic-password", "-s", service],
                       capture_output=True, text=True)
        return
    subprocess.run(["security", "add-generic-password", "-U", "-s", service,
                    "-a", "promptlib", "-w", value],
                   capture_output=True, text=True, check=False)


def endpoint_is_acceptable(url: str) -> bool:
    """https anywhere; plain http only to this machine or the LAN.

    Same rule as Reference. An API key sent over http to a public host is
    readable by anything between here and there, and a local model server has
    no certificate — so the rule is about where, not about the scheme alone.
    """
    parsed = urlparse(url)
    if parsed.scheme == "https":
        return True
    if parsed.scheme != "http":
        return False
    host = (parsed.hostname or "").lower()
    if host in {"localhost", "127.0.0.1", "::1"} or host.endswith(".local"):
        return True
    try:
        return ip_address(host).is_private
    except ValueError:
        return False


@dataclass
class EnhancerConfig:
    """What builds a prompt. Keys are never in this object's file form."""

    auth: str = "cli"
    endpoint: str = ""
    model: str = "opus"
    preset: str = "claude-cli"
    timeout: int = 300
    fallback_endpoint: str = ""
    fallback_model: str = ""
    _root: Path = field(default=Path("."), repr=False)

    @property
    def api_key(self) -> str:
        return keychain_get(KEYCHAIN_SERVICE)

    @property
    def fallback_api_key(self) -> str:
        return keychain_get(FALLBACK_KEYCHAIN_SERVICE)

    @property
    def has_fallback(self) -> bool:
        return bool(self.fallback_endpoint and self.fallback_model)

    @classmethod
    def load(cls, root: Path) -> "EnhancerConfig":
        path = root / CONFIG_FILE
        if not path.is_file():
            return cls(_root=root)
        try:
            data = tomllib.loads(path.read_text(encoding="utf-8"))
        except (tomllib.TOMLDecodeError, OSError):
            return cls(_root=root)     # a broken config must not block a build
        spec = data.get("enhancer", {})
        return cls(
            auth=spec.get("auth", "cli"),
            endpoint=spec.get("endpoint", ""),
            model=spec.get("model", "opus"),
            preset=spec.get("preset", ""),
            timeout=int(spec.get("timeout", 300)),
            fallback_endpoint=spec.get("fallback_endpoint", ""),
            fallback_model=spec.get("fallback_model", ""),
            _root=root,
        )

    def save(self) -> None:
        """Written in full, with a header explaining why no key is here."""
        lines = [
            "# Which model builds your prompts, and how it authenticates.",
            "#",
            "# API keys are NOT here. They live in the login Keychain under",
            f"#   {KEYCHAIN_SERVICE} / {FALLBACK_KEYCHAIN_SERVICE}",
            "# so this file is safe to commit and to sync between machines.",
            "",
            "[enhancer]",
            f'auth     = "{self.auth}"',
            f'endpoint = "{self.endpoint}"',
            f'model    = "{self.model}"',
            f'preset   = "{self.preset}"',
            f"timeout  = {self.timeout}",
        ]
        if self.fallback_endpoint or self.fallback_model:
            lines += [
                "",
                "# Tried once when the primary fails retryably (rate limit, 5xx, network).",
                f'fallback_endpoint = "{self.fallback_endpoint}"',
                f'fallback_model    = "{self.fallback_model}"',
            ]
        (self._root / CONFIG_FILE).write_text("\n".join(lines) + "\n", encoding="utf-8")

    def problems(self) -> list[str]:
        """Everything wrong with this configuration, in one pass."""
        issues = []
        if self.auth not in AUTH_MODES:
            issues.append(f"unknown auth mode {self.auth!r}")
        if self.auth in {"api_key", "azure_api_key", "chatgpt_oauth"}:
            if not self.endpoint:
                issues.append("no endpoint set")
            elif not endpoint_is_acceptable(self.endpoint):
                issues.append(
                    f"{self.endpoint} is not an acceptable endpoint: https, or http "
                    "only to localhost or a private address")
            if not self.model:
                issues.append("no model set")
        if self.auth == "api_key" and not self.api_key and not self._is_local():
            issues.append("no API key in the Keychain (fine for a local server, not for a paid one)")
        if self.auth == "azure_api_key" and not self.api_key:
            issues.append("Azure needs an api-key in the Keychain")
        if self.auth == "chatgpt_oauth" and not self._codex_signed_in():
            issues.append("not signed in to ChatGPT. Run: "
                          "python3 -m promptlib enhancer login")
        if self.has_fallback and not endpoint_is_acceptable(self.fallback_endpoint):
            issues.append(f"fallback endpoint {self.fallback_endpoint} is not acceptable")
        return issues

    @staticmethod
    def _codex_signed_in() -> bool:
        """Whether a usable ChatGPT token is stored.

        Imported lazily and failing closed: a machine where the Keychain cannot
        be reached should report "not signed in", which is true and actionable,
        rather than crashing the whole config read.
        """
        try:
            from . import codex_oauth
            tokens = codex_oauth.load_tokens()
        except Exception:
            return False
        return bool(tokens and tokens.access_token)

    def _is_local(self) -> bool:
        host = (urlparse(self.endpoint).hostname or "").lower()
        return host in {"localhost", "127.0.0.1", "::1"} or host.endswith(".local")

    def describe(self) -> str:
        if self.auth == "cli":
            return f"Claude Code CLI (model {self.model or 'opus'}) needs no key"
        if self.auth == "sdk":
            return f"Anthropic SDK ({self.model})"
        where = self.endpoint or "no endpoint"
        key = "key set" if self.api_key else "no key"
        return f"{self.model or 'no model'} at {where} ({self.auth}, {key})"


def preset(preset_id: str) -> Preset | None:
    return next((p for p in PRESETS if p.id == preset_id), None)
