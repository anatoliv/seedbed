"""Public model suggestions and official documentation discovery, without credentials."""
from __future__ import annotations

import json
import re
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timezone
from html.parser import HTMLParser
from pathlib import Path

CATALOG_URL = "https://models.dev/api.json"
# Only these first-party catalogs are browsed for documentation. Never fetch
# URLs supplied by the public model dataset, or guess model-specific paths.
PROVIDERS = {
    "anthropic": ("claude", "Anthropic", "https://platform.claude.com/docs/en/models/overview",
                  "https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices"),
    "openai": ("openai", "OpenAI", "https://developers.openai.com/api/docs/models",
               "https://developers.openai.com/api/docs/guides/prompt-engineering"),
    "xai": ("grok", "xAI", "https://docs.x.ai/developers/models",
            "https://docs.x.ai/developers/model-capabilities/text/reasoning"),
    "google": ("gemini", "Google", "https://ai.google.dev/gemini-api/docs/models",
               "https://ai.google.dev/gemini-api/docs/prompting-strategies"),
    "deepseek": ("deepseek", "DeepSeek", "https://api-docs.deepseek.com/quick_start/pricing",
                 "https://api-docs.deepseek.com/guides/reasoning_model"),
    "meta": ("meta", "Meta", "https://dev.meta.ai/docs",
             "https://dev.meta.ai/docs"),
    "llama": ("llama", "Meta Llama", "https://www.llama.com/docs/model-cards-and-prompt-formats/",
              "https://www.llama.com/docs/how-to-guides/prompting/"),
    "qwen": ("qwen", "Qwen", "https://qwen.readthedocs.io/en/latest/",
             "https://qwen.readthedocs.io/en/latest/getting_started/concepts.html"),
    "cursor": ("composer", "Cursor", "https://cursor.com/docs/models",
               "https://cursor.com/docs/agent/prompting"),
}
MAX_BYTES = 12 * 1024 * 1024


def read_url(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": "Seedbed/model-discovery"})
    with urllib.request.urlopen(req, timeout=12) as response:
        raw = response.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        raise ValueError("The model source is too large.")
    return raw.decode("utf-8", errors="replace")


def catalog_models(data: dict) -> list[dict]:
    """Recent text models from original providers, sorted by release date."""
    result = []
    today = date.today().isoformat()
    for provider, (family, label, _, _) in PROVIDERS.items():
        entries = data.get(provider, {}).get("models", {})
        if not isinstance(entries, dict):
            continue
        candidates = []
        for model_id, entry in entries.items():
            if not isinstance(entry, dict) or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._-]*", model_id):
                continue
            outputs = entry.get("modalities", {}).get("output", [])
            released = entry.get("release_date", "")
            if "text" not in outputs or entry.get("status") == "deprecated":
                continue
            if not re.fullmatch(r"\d{4}-\d{2}(?:-\d{2})?", released) or released > today:
                continue
            # Moving aliases and dated snapshots obscure the current lineup.
            if model_id.endswith("-latest") or re.search(r"(?:-\d{8}|-\d{4}-\d{2}-\d{2})$", model_id):
                continue
            candidates.append({"id": model_id, "name": str(entry.get("name", model_id)),
                               "family": family, "provider": label, "released": released})
        candidates.sort(key=lambda item: (item["released"], item["id"]), reverse=True)
        result.extend(candidates[:6])
    return sorted(result, key=lambda item: (item["released"], item["name"]), reverse=True)


def suggestions(root: Path, refresh: bool = False) -> dict:
    slot = root / ".cache" / "model-catalog.json"
    cached = None
    try:
        cached = json.loads(slot.read_text())
        if not (isinstance(cached, dict) and isinstance(cached.get("models"), list)
                and isinstance(cached.get("updated"), str) and cached.get("source") == CATALOG_URL):
            cached = None
    except (OSError, ValueError):
        pass
    if cached and not refresh:
        return {**cached, "cached": True, "warning": ""}
    try:
        data = json.loads(read_url(CATALOG_URL))
        models = catalog_models(data)
        if not models:
            raise ValueError("The catalog returned no supported text models.")
        result = {"models": models, "source": CATALOG_URL,
                  "updated": datetime.now(timezone.utc).isoformat(timespec="seconds")}
        slot.parent.mkdir(parents=True, exist_ok=True)
        slot.write_text(json.dumps(result))
        return {**result, "cached": False, "warning": ""}
    except Exception as exc:
        if cached:
            return {**cached, "cached": True,
                    "warning": "Could not refresh; showing the saved catalog. " + str(exc)}
        raise RuntimeError("Could not load model suggestions: " + str(exc)) from None


class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links: list[str] = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            self.links.extend(value for key, value in attrs if key == "href" and value)


def normalized(value: str) -> str:
    value = re.sub(r"(?:-\d{8}|-\d{4}-\d{2}-\d{2})$", "", value.lower())
    return re.sub(r"[^a-z0-9]", "", value)


def provider_for(model_id: str, name: str, family: str) -> str | None:
    text = " ".join((family, model_id, name)).lower()
    aliases = {"anthropic": ("anthropic", "claude"), "openai": ("openai", "gpt", "o1", "o3", "o4"),
               "xai": ("xai", "grok"), "google": ("google", "gemini"),
               "deepseek": ("deepseek",), "meta": ("meta", "muse"), "llama": ("llama",),
               "qwen": ("qwen",), "cursor": ("cursor", "composer")}
    return next((key for key, words in aliases.items()
                 if any(re.search(r"\b" + word + r"\b", text) for word in words)), None)


def documentation(model_id: str, name: str, family: str) -> dict:
    provider = provider_for(model_id, name, family)
    if provider is None:
        return {"sources": [], "provider": "", "warning":
                "No supported vendor matched. Add a documentation URL or local file below."}
    _, label, index, guidance = PROVIDERS[provider]
    terms = [normalized(model_id), normalized(name)]
    terms = [term for term in terms if len(term) >= 5]
    sources: list[dict] = []
    warnings = []
    def inspect(url):
        try:
            html = read_url(url)
            if not html.strip():
                raise ValueError("empty page")
            parser = Links(); parser.feed(html)
            return url, parser.links, None
        except Exception as exc:
            return url, [], str(exc)
    with ThreadPoolExecutor(max_workers=2) as pool:
        for url, links, error in pool.map(inspect, (index, guidance)):
            if error:
                warnings.append(f"Could not check {url}: {error}")
                continue
            for link in links:
                candidate = urllib.parse.urljoin(url, link).split("#")[0]
                parsed = urllib.parse.urlparse(candidate)
                if parsed.scheme != "https" or parsed.hostname != urllib.parse.urlparse(url).hostname:
                    continue
                slug = normalized(parsed.path.rsplit("/", 1)[-1])
                if terms and any(term == slug or slug == "prompting" + term for term in terms):
                    sources.append({"url": candidate, "kind": "Model documentation"})
            # A reachable general guide is useful even without a model-specific match.
            if url == guidance:
                sources.append({"url": url, "kind": "Vendor documentation" if guidance == index
                                else "Vendor prompting guide"})
    unique = {source["url"]: source for source in sources}
    return {"sources": list(unique.values())[:8], "provider": label,
            "warning": "\n".join(warnings) if warnings else
                       ("" if sources else "No documentation links found. Add a source below.")}
