"""The matcher's ranking rules.

These pin behaviour an agent depends on: that a near-miss on the name still
finds the prompt, that a weak or tied result is reported as unconfident rather
than returned as an answer, and that the semantic pass can never hand back a
prompt the library does not contain.

Nothing here calls a model. The semantic layer is exercised through a stub, so
the suite stays offline and free.
"""

from __future__ import annotations

import unittest

from promptlib import match as M
from promptlib.enhance import EnhancerError
from promptlib.store import Seed


def seed(seed_id: str, title: str = "", body: str = "", tags=None, category: str = "") -> Seed:
    return Seed(
        id=seed_id,
        body=body or title or seed_id,
        title=title,
        tags=list(tags or []),
        category=category,
    )


LIBRARY = [
    seed("fix-bug-and-test", "Fix this bug and test", "fix this bug and test",
         tags=["coding", "debug"]),
    seed("review-my-diff", "Review my diff", "review my changes before I merge",
         tags=["coding", "review"]),
    seed("explain-this-code", "Explain this code", "explain what this code does",
         tags=["coding"]),
    seed("write-regression-test", "Write a regression test",
         "write a regression test for this", tags=["testing"], category="Coding"),
]


class NormalisationTests(unittest.TestCase):
    def test_hyphens_become_word_boundaries(self):
        # The ask has to reach the same tokens a hyphenated seed id does, or
        # asking "fix bug and test" never finds `fix-bug-and-test`.
        self.assertEqual(M.normalise("fix-bug-and-test"), "fix bug and test")

    def test_punctuation_and_case_fold_away(self):
        self.assertEqual(M.normalise("Review MY diff!"), "review my diff")

    def test_stopwords_are_dropped(self):
        self.assertEqual(M.tokens("the prompt for reviewing a diff"), {"reviewing", "diff"})

    def test_an_ask_of_only_stopwords_keeps_its_words(self):
        # Dropping everything would match every prompt equally, which is the
        # same as matching none of them.
        self.assertTrue(M.tokens("what should I use"))


class RankingTests(unittest.TestCase):
    def test_exact_title_wins(self):
        ranked = M.rank("Review my diff", LIBRARY)
        self.assertEqual(ranked[0].seed.id, "review-my-diff")

    def test_paraphrase_finds_the_right_prompt(self):
        # The words are the body's, not the title's — this is the case a
        # title-only lookup gets wrong.
        ranked = M.rank("review my changes before I merge", LIBRARY)
        self.assertEqual(ranked[0].seed.id, "review-my-diff")

    def test_a_hyphenated_id_is_reachable_by_its_words(self):
        ranked = M.rank("fix bug and test", LIBRARY)
        self.assertEqual(ranked[0].seed.id, "fix-bug-and-test")

    def test_a_tag_can_carry_a_match(self):
        ranked = M.rank("debug", LIBRARY)
        self.assertEqual(ranked[0].seed.id, "fix-bug-and-test")
        self.assertEqual(ranked[0].matched_on, "tags")

    def test_scores_are_bounded(self):
        for m in M.rank("review my diff", LIBRARY):
            self.assertGreaterEqual(m.score, 0.0)
            self.assertLessEqual(m.score, 1.0)

    def test_noise_is_dropped_rather_than_ranked_last(self):
        # A word the library does not contain should return nothing, not a list
        # of everything in weak order — an agent reads the first row.
        self.assertEqual(M.rank("quarterly invoice reconciliation", LIBRARY), [])

    def test_order_is_stable_for_equal_scores(self):
        twins = [seed("b-one", "Same title"), seed("a-one", "Same title")]
        ranked = M.rank("same title", twins)
        self.assertEqual([m.seed.id for m in ranked], ["a-one", "b-one"])

    def test_matched_on_names_the_strongest_field(self):
        ranked = M.rank("Explain this code", LIBRARY)
        self.assertEqual(ranked[0].matched_on, "title")


class ConfidenceTests(unittest.TestCase):
    def test_a_clear_strong_winner_is_confident(self):
        self.assertTrue(M.is_confident(M.rank("Review my diff", LIBRARY)))

    def test_nothing_is_not_confident(self):
        self.assertFalse(M.is_confident([]))

    def test_a_weak_top_hit_is_not_confident(self):
        matches = [M.Match(seed=seed("a"), score=0.2), M.Match(seed=seed("b"), score=0.05)]
        self.assertFalse(M.is_confident(matches))

    def test_a_strong_but_tied_top_hit_is_not_confident(self):
        # This is the case the margin exists for: two high scores mean the
        # lexical pass cannot tell them apart, however good they look.
        matches = [M.Match(seed=seed("a"), score=0.80), M.Match(seed=seed("b"), score=0.75)]
        self.assertFalse(M.is_confident(matches))


class ChoiceParsingTests(unittest.TestCase):
    def test_plain_json(self):
        self.assertEqual(
            M._parse_choice('{"id": "review-my-diff", "reason": "it reviews diffs"}'),
            ("review-my-diff", "it reviews diffs"),
        )

    def test_json_inside_a_fence_or_prose(self):
        raw = 'Sure!\n```json\n{"id": "explain-this-code", "reason": "explains code"}\n```'
        self.assertEqual(M._parse_choice(raw), ("explain-this-code", "explains code"))

    def test_an_explicit_none_is_read_as_no_answer(self):
        self.assertEqual(M._parse_choice('{"id": null, "reason": "nothing fits"}'),
                         (None, "nothing fits"))

    def test_unparseable_output_is_no_answer_rather_than_a_crash(self):
        self.assertEqual(M._parse_choice("I could not decide."), (None, ""))


class SemanticPickTests(unittest.TestCase):
    def setUp(self):
        self.ranked = M.rank("code", LIBRARY)

    def test_an_invented_id_is_refused(self):
        # A model that names a prompt the library does not have has invented
        # one; handing that back would be worse than admitting no match.
        chosen, reason = M.semantic_pick(
            "anything", self.ranked,
            backend=None, config=_StubEnhancer('{"id": "not-a-real-prompt", "reason": "x"}'),
        )
        self.assertIsNone(chosen)
        self.assertEqual(reason, "x")

    def test_a_real_id_is_returned_with_its_reason(self):
        chosen, reason = M.semantic_pick(
            "anything", self.ranked,
            backend=None,
            config=_StubEnhancer('{"id": "explain-this-code", "reason": "it explains code"}'),
        )
        self.assertIsNotNone(chosen)
        self.assertEqual(chosen.seed.id, "explain-this-code")
        self.assertEqual(reason, "it explains code")


class SearchTests(unittest.TestCase):
    def test_a_confident_lexical_hit_never_calls_a_model(self):
        result = M.search("Review my diff", LIBRARY, config=_ExplodingEnhancer())
        self.assertEqual(result.decided_by, "lexical")
        self.assertTrue(result.confident)
        self.assertEqual(result.best.seed.id, "review-my-diff")

    def test_semantic_off_returns_the_lexical_ranking_and_says_so(self):
        result = M.search("code", LIBRARY, semantic=False, config=_ExplodingEnhancer())
        self.assertIn("switched off", result.decided_by)
        self.assertFalse(result.confident)

    def test_an_unreachable_enhancer_degrades_instead_of_failing(self):
        result = M.search("code", LIBRARY, config=_ExplodingEnhancer())
        self.assertTrue(result.decided_by.startswith("lexical"))
        self.assertIn("no semantic pass", result.decided_by)
        self.assertTrue(result.matches)

    def test_the_semantic_choice_is_promoted_and_the_rest_kept(self):
        # "test" is the ambiguous case by construction: two prompts score close
        # together, so the lexical pass hands over and the model's pick — the
        # runner-up here — is promoted over it.
        self.assertEqual([m.seed.id for m in M.rank("test", LIBRARY)],
                         ["write-regression-test", "fix-bug-and-test"])
        result = M.search(
            "test", LIBRARY,
            config=_StubEnhancer('{"id": "fix-bug-and-test", "reason": "it also tests"}'),
        )
        self.assertEqual(result.decided_by, "semantic")
        self.assertEqual(result.best.seed.id, "fix-bug-and-test")
        self.assertEqual(result.best.reason, "it also tests")
        # The alternatives survive, so a caller that disagrees needs no second call.
        self.assertEqual([m.seed.id for m in result.matches],
                         ["fix-bug-and-test", "write-regression-test"])

    def test_a_choice_outside_the_candidate_list_is_refused(self):
        # No such prompt exists, so naming it is the model inventing an answer.
        # The lexical ranking stands and `decided_by` says what happened.
        result = M.search(
            "test", LIBRARY,
            config=_StubEnhancer('{"id": "ship-it-and-hope", "reason": "no"}'),
        )
        self.assertIn("matched none", result.decided_by)
        self.assertEqual(result.best.seed.id, "write-regression-test")

    def test_every_seed_is_a_candidate_for_the_model_even_when_none_scores(self):
        # The candidate list the model sees is the unfloored ranking, so a
        # prompt the lexical pass rated at nearly zero is still choosable.
        ask = "something to check my work before I merge it"
        result = M.search(
            ask, LIBRARY,
            config=_StubEnhancer('{"id": "explain-this-code", "reason": "chosen from the tail"}'),
        )
        self.assertEqual(result.best.seed.id, "explain-this-code")

    def test_no_candidates_at_all(self):
        result = M.search("quarterly invoice reconciliation", LIBRARY,
                          config=_ExplodingEnhancer())
        self.assertEqual(result.matches, [])
        self.assertIsNone(result.best)

    def test_a_hit_below_the_floor_still_reaches_the_semantic_pass(self):
        # Regression. "check my work before I merge it" shares almost no wording
        # with "review my changes before I merge", so every score fell under the
        # floor, `rank` returned nothing, and `search` gave up BEFORE asking the
        # model — discarding the right prompt in exactly the case the semantic
        # layer exists for. Found by calling find_prompt over MCP, not by a test.
        ask = "something to check my work before I merge it"
        self.assertEqual(M.rank(ask, LIBRARY), [], "the floor should still drop these")
        result = M.search(
            ask, LIBRARY,
            config=_StubEnhancer('{"id": "review-my-diff", "reason": "pre-merge review"}'),
        )
        self.assertEqual(result.decided_by, "semantic")
        self.assertEqual(result.best.seed.id, "review-my-diff")

    def test_an_empty_library_says_so(self):
        result = M.search("anything", [], config=_ExplodingEnhancer())
        self.assertIn("empty", result.decided_by)
        self.assertEqual(result.matches, [])


class _StubEnhancer:
    """Stands in for a configured enhancer, returning a canned reply.

    `run_prompt` dispatches on `config.auth`, so the stub declares an auth mode
    the real code path never reaches: `search` is handed this object and the
    monkeypatched `run_prompt` below answers instead.
    """

    def __init__(self, reply: str):
        self.reply = reply
        self.auth = "stub"


class _ExplodingEnhancer(_StubEnhancer):
    def __init__(self):
        super().__init__("")


def _fake_run_prompt(system, message, backend=None, config=None):
    if isinstance(config, _ExplodingEnhancer):
        raise EnhancerError("no enhancer configured")
    if isinstance(config, _StubEnhancer):
        return config.reply
    raise EnhancerError("unexpected call")


def setUpModule():
    global _real_run_prompt
    _real_run_prompt = M.run_prompt
    M.run_prompt = _fake_run_prompt


def tearDownModule():
    M.run_prompt = _real_run_prompt


if __name__ == "__main__":
    unittest.main()
