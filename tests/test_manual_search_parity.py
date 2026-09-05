"""The Swift manual search must keep scoring the way `promptlib.match` does.

`macos/Sources/Seedbed/ManualSearch.swift` is a second implementation of the
lexical pass in `promptlib/match.py`. It exists because the manual is compiled
into the app, is searched on every keystroke, and has to keep working when no
usable Python interpreter can be found, which is a state this app really reaches
(an app launched from Finder inherits a minimal PATH, and on a Mac with Xcode
installed that resolves `python3` to a 3.9 without `tomllib`). Help is exactly
where someone goes when that happens, so Help's search cannot depend on it.

Duplication is the cost of that choice, and an unguarded duplicate silently
diverges. This is the guard: it reads both files and fails when the constants or
the scoring blend stop agreeing. It does not import Swift or run the app, so it
costs nothing and runs in the ordinary suite.

If you are here because this test failed, the fix is to change BOTH files, not
to relax the test. If the two are meant to diverge, delete the assertion and say
why in the docstring, so the next reader knows it was a decision.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

from promptlib import match as M

REPO = Path(__file__).resolve().parent.parent
SWIFT = REPO / "macos" / "Sources" / "Seedbed" / "ManualSearch.swift"


class ManualSearchParity(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = SWIFT.read_text(encoding="utf-8")

    def test_the_swift_port_is_where_it_says_it_is(self):
        """A moved or renamed file must fail loudly rather than skip the checks."""
        self.assertTrue(SWIFT.exists(), f"{SWIFT} is missing; update this test or the path")

    def test_floor_score_agrees(self):
        found = re.search(r"static let FLOOR_SCORE = ([0-9.]+)", self.source)
        self.assertIsNotNone(found, "FLOOR_SCORE not found in ManualSearch.swift")
        self.assertAlmostEqual(float(found.group(1)), M.FLOOR_SCORE, places=6)

    def test_field_weights_agree(self):
        """The three fields a manual topic has must weigh what a seed's do.

        A topic's term is scored as a title, its section as a category, and its
        prose plus worked example as a body. Those three weights have to match,
        or the same words rank differently depending on which surface you typed
        them into.
        """
        block = re.search(
            r"static let FIELD_WEIGHTS: \[String: Double\] = \[(.*?)\]",
            self.source, re.S)
        self.assertIsNotNone(block, "FIELD_WEIGHTS not found in ManualSearch.swift")
        pairs = dict(
            (name, float(value))
            for name, value in re.findall(r'"([a-z]+)":\s*([0-9.]+)', block.group(1))
        )
        self.assertEqual(set(pairs), {"title", "category", "body"})
        for name, weight in pairs.items():
            self.assertAlmostEqual(
                weight, M.FIELD_WEIGHTS[name], places=6,
                msg=f"{name} weighs {weight} in Swift and {M.FIELD_WEIGHTS[name]} in Python")

    def test_stopwords_agree(self):
        block = re.search(
            r"static let STOPWORDS: Set<String> = \[(.*?)\n    \]", self.source, re.S)
        self.assertIsNotNone(block, "STOPWORDS not found in ManualSearch.swift")
        swift_words = set(re.findall(r'"([a-z]+)"', block.group(1)))
        self.assertEqual(
            swift_words, M.STOPWORDS,
            msg="stopword lists differ: "
                f"only in Swift {sorted(swift_words - M.STOPWORDS)}, "
                f"only in Python {sorted(M.STOPWORDS - swift_words)}")

    def test_the_two_signals_are_blended_the_same_way(self):
        """0.6 token overlap plus 0.4 trigram similarity, in both files.

        Pinned by reading the source rather than by calling it, because the whole
        point is that one of the two implementations is not importable from here.
        The Python side is checked by calling it, so a change there fails this
        test from the other direction.
        """
        self.assertIn("0.6 * overlap + 0.4 * dice(askTrigrams, trigrams(value))",
                      self.source,
                      "the Swift blend changed; match.py still uses 0.6/0.4")
        python_source = (REPO / "promptlib" / "match.py").read_text(encoding="utf-8")
        self.assertIn("0.6 * overlap + 0.4 * similarity", python_source,
                      "the Python blend changed; ManualSearch.swift still uses 0.6/0.4")

    def test_an_exact_match_still_scores_one_in_both(self):
        """The short-circuit that makes a typed-out title win outright."""
        self.assertIn("if normalised == normalise(ask) { return 1 }", self.source)
        self.assertEqual(
            M._field_score("Review my diff", M.tokens("Review my diff"),
                           M.trigrams("Review my diff"), "review my diff"),
            1.0)

    def test_trigrams_are_padded_the_same(self):
        """Two spaces either side, which is what lets "diff" score against "diffs"."""
        self.assertIn('let padded = Array("  \\(normalise(text))  ")', self.source)
        self.assertIn('padded = f"  {normalise(text)}  "',
                      (REPO / "promptlib" / "match.py").read_text(encoding="utf-8"))

    def test_the_relative_cutoff_is_documented_as_swift_only(self):
        """RELATIVE_CUTOFF has no Python counterpart, on purpose.

        The matcher's caller is an agent that wants the alternatives; a person
        reading a result list wants the answer. If someone later adds one to
        match.py, this test should be revisited rather than deleted.
        """
        self.assertIn("static let RELATIVE_CUTOFF", self.source)
        self.assertFalse(hasattr(M, "RELATIVE_CUTOFF"),
                         "match.py grew a RELATIVE_CUTOFF; decide whether the two should agree")


if __name__ == "__main__":
    unittest.main()
