"""Finding the prompt someone means, not the one they named.

An agent asking this library for a prompt does not know what it is called. It
asks for "something for reviewing a diff before I merge" when the prompt is
titled "Review my diff", or for "the bug one" when there are two of those. An
exact-name lookup fails both, and a substring search fails the first.

Two layers, cheapest first:

1. **Lexical.** Token overlap plus trigram similarity over id, title, body,
   category and tags. Free, instant, offline, and the right answer when the ask
   is a near-miss on the name. It also reports WHICH field matched, because
   "matched on a tag" and "matched on the body" are different kinds of evidence
   and the caller should be able to see which it got.

2. **Semantic.** When the lexical pass has no clear winner, the ask and the
   candidates go to the configured enhancer, which picks one and says why. The
   default enhancer is the Claude Code CLI, which needs no API key and spends
   nothing beyond a subscription already paid for, so this is on by default. It
   degrades to the lexical answer when no enhancer is reachable rather than
   failing the call: a worse answer beats no answer for something an agent is
   waiting on.

The thresholds that decide "no clear winner" are named constants below rather
than numbers buried in an expression, because they are the part of this that
will need tuning against real asks.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field as dataclass_field

from .enhance import EnhancerError, run_prompt
from .store import Seed

#: A hit this strong is taken on its own.
STRONG_SCORE = 0.55
#: ...but only if it also beats the runner-up by this much. Two prompts scoring
#: 0.6 and 0.58 means the lexical pass cannot tell them apart, however high the
#: numbers look.
CLEAR_MARGIN = 0.12
#: Below this a hit is noise — an ask sharing one common word with a body.
FLOOR_SCORE = 0.08
#: How many candidates the semantic pass is shown. Enough to contain the right
#: answer, few enough to keep the request small.
SEMANTIC_CANDIDATES = 12

#: Weights per field. Someone asking by name is asking about the title or the
#: id; the body is corroboration, not the primary signal.
FIELD_WEIGHTS: dict[str, float] = {
    "title": 3.0,
    "id": 2.5,
    "tags": 2.0,
    "category": 1.5,
    "body": 1.0,
}

#: Dropped before matching. English filler, plus the words an agent wraps every
#: request in — "give me the prompt for X" is a request for X.
STOPWORDS = {
    "a", "about", "an", "and", "any", "anything", "are", "as", "at", "be", "by",
    "can", "do", "find", "for", "from", "get", "give", "have", "help", "i", "in",
    "is", "it", "like", "looking", "me", "my", "need", "of", "on", "one", "or",
    "please", "prompt", "prompts", "seed", "should", "some", "something", "that",
    "the", "then", "there", "this", "to", "use", "using", "want", "was", "what",
    "which", "with", "would", "you", "your",
}

_WORD = re.compile(r"[a-z0-9]+")


def normalise(text: str) -> str:
    """Lowercase, and everything that is not a letter or digit becomes a space.

    Hyphens matter here: seed ids are hyphenated (`fix-bug-and-test`), so an ask
    of "fix bug and test" has to reach the same tokens the id does.
    """
    return " ".join(_WORD.findall(text.lower()))


def tokens(text: str, *, drop_stopwords: bool = True) -> set[str]:
    words = normalise(text).split()
    if not drop_stopwords:
        return set(words)
    kept = {w for w in words if w not in STOPWORDS}
    # An ask made entirely of stopwords ("what should I use") still has to match
    # something rather than everything, so keep the words instead of nothing.
    return kept or set(words)


def trigrams(text: str) -> set[str]:
    """Character trigrams of the normalised text, padded so short strings match.

    Padding is what lets "diff" score against "diffs" and "reviewing" against
    "review"; without it a three-letter difference at a word end reads as a
    different word entirely.
    """
    padded = f"  {normalise(text)}  "
    return {padded[i : i + 3] for i in range(len(padded) - 2)}


def _dice(a: set[str], b: set[str]) -> float:
    if not a or not b:
        return 0.0
    return 2 * len(a & b) / (len(a) + len(b))


def _field_score(ask: str, ask_tokens: set[str], ask_trigrams: set[str],
                 value: str) -> float:
    """How well one field answers the ask, in 0…1.

    Two signals, because each fails where the other works. Token overlap says
    "these are the same words" and is blind to a typo or a plural. Trigram
    similarity survives both and is blind to word order, so on its own it scores
    "test the bug fix" and "fix the bug test" identically.
    """
    if not value.strip():
        return 0.0
    normalised = normalise(value)
    if not normalised:
        return 0.0
    if normalised == normalise(ask):
        return 1.0
    overlap = len(ask_tokens & tokens(value)) / len(ask_tokens) if ask_tokens else 0.0
    similarity = _dice(ask_trigrams, trigrams(value))
    return 0.6 * overlap + 0.4 * similarity


@dataclass
class Match:
    """One candidate, with the evidence for it."""

    seed: Seed
    score: float
    #: Field name → its own 0…1 score, so a caller can say what matched.
    fields: dict[str, float] = dataclass_field(default_factory=dict)
    #: Set only by the semantic pass.
    reason: str = ""

    @property
    def matched_on(self) -> str:
        """The field that contributed most, for a one-line explanation."""
        if not self.fields:
            return ""
        return max(self.fields.items(), key=lambda kv: kv[1])[0]

    def as_dict(self) -> dict:
        return {
            "id": self.seed.id,
            "title": self.seed.title or self.seed.id,
            "body": self.seed.body,
            "category": self.seed.category,
            "tags": list(self.seed.tags),
            "score": round(self.score, 4),
            "matched_on": self.matched_on,
            "fields": {k: round(v, 4) for k, v in self.fields.items()},
            "reason": self.reason,
        }


@dataclass
class Result:
    """What a search decided, and how."""

    matches: list[Match]
    #: "lexical", "semantic", or "lexical" with the reason semantic was skipped.
    decided_by: str
    #: True when the top hit stands clear of the rest on its own.
    confident: bool

    @property
    def best(self) -> Match | None:
        return self.matches[0] if self.matches else None

    def as_dict(self) -> dict:
        return {
            "decided_by": self.decided_by,
            "confident": self.confident,
            "matches": [m.as_dict() for m in self.matches],
        }


def rank(ask: str, seeds: list[Seed], floor: float = FLOOR_SCORE) -> list[Match]:
    """Every seed scored against the ask, best first, noise dropped.

    `floor` is loosened to zero by `search` when it is assembling candidates for
    the semantic pass. The floor exists to stop a weak match being *returned* as
    an answer; it must not stop one being *considered* by the model, because the
    case the whole two-layer design exists for is an ask that shares almost no
    wording with the prompt it means.
    """
    ask_tokens = tokens(ask)
    ask_trigrams = trigrams(ask)
    scored: list[Match] = []
    for seed in seeds:
        values = {
            "title": seed.title,
            "id": seed.id,
            "tags": " ".join(seed.tags),
            "category": seed.category,
            "body": seed.body,
        }
        fields = {
            name: _field_score(ask, ask_tokens, ask_trigrams, value)
            for name, value in values.items()
        }
        total = sum(FIELD_WEIGHTS[name] * value for name, value in fields.items())
        score = total / sum(FIELD_WEIGHTS.values())
        if score >= floor:
            scored.append(Match(seed=seed, score=score, fields=fields))
    # Ties break on id so the order is stable between runs; a matcher that
    # returns a different winner for the same library is untestable.
    scored.sort(key=lambda m: (-m.score, m.seed.id))
    return scored


def is_confident(matches: list[Match]) -> bool:
    """True when the lexical pass has a winner worth returning without asking a model."""
    if not matches:
        return False
    if matches[0].score < STRONG_SCORE:
        return False
    runner_up = matches[1].score if len(matches) > 1 else 0.0
    return matches[0].score - runner_up >= CLEAR_MARGIN


SEMANTIC_SYSTEM = """You match a request to one prompt from a library.

You are given a request and a numbered list of prompts, each with an id, a \
title and the prompt's own text. Choose the ONE prompt that best serves the \
request, judging by what the prompt is for rather than by shared wording.

Answer with JSON only, no prose and no markdown fence:
{"id": "<the chosen prompt's id>", "reason": "<one short sentence>"}

If no prompt in the list serves the request, answer {"id": null, "reason": \
"<why none fit>"}. Choosing nothing is a real answer; never pick the least bad \
option to avoid it."""


def _candidate_block(matches: list[Match]) -> str:
    lines = []
    for index, match in enumerate(matches, 1):
        seed = match.seed
        tag_note = f" [tags: {', '.join(seed.tags)}]" if seed.tags else ""
        category = f" [category: {seed.category}]" if seed.category else ""
        lines.append(
            f"{index}. id: {seed.id}\n"
            f"   title: {seed.title or seed.id}{category}{tag_note}\n"
            f"   prompt: {seed.body}"
        )
    return "\n\n".join(lines)


def _parse_choice(raw: str) -> tuple[str | None, str]:
    """Read the model's answer, tolerating a fence or surrounding prose.

    A model told to answer in JSON mostly does, and occasionally wraps it. The
    difference should not be the reason a lookup fails, so the first JSON object
    in the reply wins.
    """
    text = raw.strip()
    start, end = text.find("{"), text.rfind("}")
    if start == -1 or end <= start:
        return None, ""
    try:
        data = json.loads(text[start : end + 1])
    except (ValueError, TypeError):
        return None, ""
    if not isinstance(data, dict):
        return None, ""
    chosen = data.get("id")
    reason = str(data.get("reason") or "").strip()
    return (str(chosen) if chosen else None), reason


def semantic_pick(ask: str, matches: list[Match], *, config=None,
                  backend: str | None = None) -> tuple[Match | None, str]:
    """Let the enhancer choose among the candidates.

    Returns (chosen, reason). A chosen id the list does not contain is treated
    as no answer: the model has invented one, and returning a prompt nobody
    asked for is worse than saying nothing.
    """
    if not matches:
        return None, ""
    message = f"Request:\n{ask}\n\nPrompts:\n\n{_candidate_block(matches)}"
    raw = run_prompt(SEMANTIC_SYSTEM, message, backend=backend, config=config)
    chosen_id, reason = _parse_choice(raw)
    if not chosen_id:
        return None, reason
    for match in matches:
        if match.seed.id == chosen_id:
            return match, reason
    return None, reason


def search(ask: str, seeds: list[Seed], *, semantic: bool = True, limit: int = 5,
           config=None, backend: str | None = None) -> Result:
    """The whole two-layer search.

    The semantic pass reorders rather than replaces: the lexical ranking still
    comes back underneath the model's pick, so a caller that disagrees has the
    alternatives without a second call.
    """
    # Everything scored, then the answerable subset. Two lists rather than one
    # because they serve different jobs: what may be RETURNED as an answer, and
    # what the model is allowed to CONSIDER. A near-zero lexical score is not
    # evidence of a bad match — it is the absence of evidence, and it was
    # silently discarding the right prompt when the ask shared no wording with
    # it ("check my work before I merge" against "review my changes before I
    # merge" scored 0.067 against a floor of 0.08).
    considered = rank(ask, seeds, floor=0.0)
    ranked = [m for m in considered if m.score >= FLOOR_SCORE]

    confident = is_confident(ranked)
    if confident:
        return Result(matches=ranked[:limit], decided_by="lexical", confident=True)
    if not semantic:
        return Result(
            matches=ranked[:limit],
            decided_by="lexical (semantic pass switched off)",
            confident=False,
        )
    if not considered:
        return Result(matches=[], decided_by="lexical (the library is empty)", confident=False)

    try:
        chosen, reason = semantic_pick(
            ask, considered[:SEMANTIC_CANDIDATES], config=config, backend=backend
        )
    except EnhancerError as exc:
        # The enhancer is optional infrastructure for this call. Say what
        # happened in `decided_by` rather than failing: the caller still gets
        # the lexical ranking, and now knows it is looking at second best.
        return Result(
            matches=ranked[:limit],
            decided_by=f"lexical (no semantic pass: {exc})",
            confident=False,
        )

    if chosen is None:
        return Result(
            matches=ranked[:limit],
            decided_by="lexical (the model matched none of them)",
            confident=False,
        )

    chosen.reason = reason
    rest = [m for m in ranked if m.seed.id != chosen.seed.id]
    return Result(matches=[chosen] + rest[: limit - 1], decided_by="semantic", confident=True)
