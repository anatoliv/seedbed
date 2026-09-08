"""The published qwen figures must equal the marks they claim to total.

Every number the site states about the qwen run is a hand-typed summary of one
markdown table under the experiment transcripts. Nothing connected the two,
so on 2026-09-05
the totals line went out one short in each column and stayed wrong through three
audits, a copy pass and a release, because reading a total tells you nothing
about whether it adds up. These tests count the marks and compare.

The scoring document is excluded from the public snapshot, so the tests that
need it skip rather than fail when it is absent. The last test needs only the
two site pages and runs everywhere: if the figures on the landing page and the
evidence page ever disagree, one of them was edited alone.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCORING = ROOT / "docs" / "experiments" / "h1b-qwen-seed-vs-render-2026-09-05" / "SCORING.md"
INDEX = ROOT / "site" / "index.html"
EVIDENCE = ROOT / "site" / "evidence" / "index.html"

# The withdrawn task. Its marks were scored against an answer key later measured
# false, so the page also states the totals with it removed.
WITHDRAWN = "t4"


def marks():
    """Per-task check-mark counts for both arms, read from the scoring table.

    Returns {task: (seed, render)}. A cell counts for an arm when it opens with
    a check mark. "partial" and every caveated cross count for nothing, which is
    the rule the per-task verdict in the same document already implies: the seed
    takes t4 on one check mark plus one partial against the render's one.
    """
    rows = [line for line in SCORING.read_text(encoding="utf-8").splitlines()
            if line.startswith("|") and "---" not in line]
    counts, task = {}, None
    for line in rows[1:]:
        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) < 4 or cells[0].lower().startswith("**"):
            continue
        if cells[0]:
            task = cells[0].split()[0]
        if task is None:
            continue
        seed, render = counts.get(task, (0, 0))
        counts[task] = (seed + cells[2].startswith("✓"),
                        render + cells[3].startswith("✓"))
    return counts


def totals(counts, skip=()):
    seed = sum(v[0] for t, v in counts.items() if t not in skip)
    render = sum(v[1] for t, v in counts.items() if t not in skip)
    criteria = 3 * len([t for t in counts if t not in skip])
    return seed, render, criteria


class QwenScoringTotalsTests(unittest.TestCase):
    def setUp(self) -> None:
        if not SCORING.is_file():
            self.skipTest("the experiment scoring is not published in this checkout")
        self.counts = marks()

    def test_the_table_holds_four_tasks_of_three_criteria(self) -> None:
        """A parser that silently reads half the table would pass everything else."""
        self.assertEqual(sorted(self.counts), ["t1", "t2", "t3", "t4"])

    def test_the_scoring_document_states_the_count_it_recorded(self) -> None:
        seed, render, criteria = totals(self.counts)
        self.assertTrue(f"A = {seed}/{criteria} criteria, B = {render}/{criteria}."
                        in SCORING.read_text(encoding="utf-8"),
                        "the Result line no longer adds up its own table")

    def test_both_site_pages_state_the_count(self) -> None:
        seed, render, criteria = totals(self.counts)
        phrase = f"{render} of {criteria} criteria against {seed} of {criteria}"
        for page in (INDEX, EVIDENCE):
            self.assertTrue(phrase in page.read_text(encoding="utf-8"),
                            f"{page.name} does not state {phrase!r}")

    def test_the_totals_row_states_the_count(self) -> None:
        seed, render, criteria = totals(self.counts)
        row = f"<th>{seed} of {criteria}</th><th>{render} of {criteria}</th>"
        self.assertTrue(row in EVIDENCE.read_text(encoding="utf-8"),
                        f"the Total row is not {row!r}, so it disagrees with the "
                        "marks above it")

    def test_the_withdrawn_task_is_removed_by_arithmetic_not_by_hand(self) -> None:
        """The figure without t4 has to come off the marks, not off the total.

        Subtracting the withdrawn task's points from a total that was itself
        wrong is how one arithmetic slip became two.
        """
        seed, render, criteria = totals(self.counts, skip=(WITHDRAWN,))
        phrase = f"{render} of {criteria} criteria against {seed} of {criteria}"
        self.assertTrue(phrase in EVIDENCE.read_text(encoding="utf-8"),
                        f"the figure without {WITHDRAWN} is not {phrase!r}")

    def test_the_record_carries_the_withdrawal_before_its_own_marks(self) -> None:
        """A reader meets the caveat before the figures, not sixty lines after.

        The withdrawal reached the site on 2026-09-08 and reached this file only
        in its closing argument, so anyone opening the source to check the site
        read the whole scoring table and the verdict with no signal that t4 no
        longer counts. Position is the property that failed, so position is what
        this pins.
        """
        text = SCORING.read_text(encoding="utf-8")
        withdrawal = text.find("t4 is withdrawn as evidence")
        self.assertNotEqual(withdrawal, -1, "the record states no withdrawal at all")
        for landmark in ("| Task | Criterion |", "**Winner by task:**"):
            at = text.find(landmark)
            self.assertNotEqual(at, -1, f"{landmark!r} is gone from the record")
            self.assertLess(withdrawal, at,
                            f"the withdrawal is stated after {landmark!r}, so a "
                            "reader meets the figures before the caveat")

    def test_the_record_and_the_site_agree_on_the_disputed_cell(self) -> None:
        """The site was corrected on 2026-09-08 and its source was not.

        The qwen table's t4 cell asserted the answer key's cause as fact. The
        published page now attributes it instead; for a while the document the
        page is counted from still stated it flat, which is the wrong way round
        for a source of truth.
        """
        phrase = "which the key called the bug"
        self.assertTrue(phrase in SCORING.read_text(encoding="utf-8"),
                        f"the record does not say {phrase!r}, so it asserts the "
                        "withdrawn cause as fact again")
        self.assertTrue(phrase in EVIDENCE.read_text(encoding="utf-8"),
                        f"the page does not say {phrase!r}, so it no longer "
                        "matches the record it is counted from")

    def test_the_per_task_verdict_matches_the_marks(self) -> None:
        won = [t for t, (seed, render) in self.counts.items() if render > seed]
        self.assertEqual(len(won), 3, "the render no longer wins three of the four tasks")
        for page in (INDEX, EVIDENCE):
            self.assertTrue(f"{len(won)} of 4" in page.read_text(encoding="utf-8"),
                            f"{page.name} does not state {len(won)} of 4 tasks")


class WithdrawnTaskIsMarkedTests(unittest.TestCase):
    """A published figure must not be readable without its caveat.

    t4 was withdrawn because the task contains no defect for the code it
    supplies, so every headline counting four tasks counts one that is no longer
    evidence. The withdrawal was stated in one run's section and not the other's
    for three days, and neither verdict card mentioned it at all: a reader who
    saw only the number had no signal that a caveat existed. These run without
    the scoring document, so the public snapshot checks them too.
    """

    MARKER = "t4 withdrawn as evidence"
    # The verdict cards, one per model, by the class each page gives them. Keyed
    # on the card rather than on the text, because the section headings restate
    # the figure and the section right below them is what explains it.
    CARD = {"site/index.html": 'class="big"',
            "site/evidence/index.html": 'class="r '}

    def test_every_verdict_card_carries_the_withdrawal(self) -> None:
        for page in (INDEX, EVIDENCE):
            rel = page.relative_to(ROOT).as_posix()
            html = page.read_text(encoding="utf-8")
            cards = html.count(self.CARD[rel])
            self.assertTrue(cards, f"{rel} has no verdict cards to check")
            self.assertEqual(
                cards, html.count(self.MARKER),
                f"{rel} has {cards} verdict cards but "
                f"{html.count(self.MARKER)} withdrawal markers, so a published "
                "figure is readable without its caveat")

    def test_the_landing_page_routes_to_the_explanation(self) -> None:
        """The landing page states the caveat; only the evidence page explains it."""
        html = INDEX.read_text(encoding="utf-8")
        for marker in re.finditer(r"t4 withdrawn as evidence\.(.{0,80})", html):
            self.assertIn('href="/evidence/"', marker.group(1),
                          "a withdrawal marker on the landing page does not link "
                          "to the page that explains it")

    def test_both_runs_say_what_their_headline_is_without_t4(self) -> None:
        """Stating the withdrawal in one run's section and not the other is the
        defect this pair of tests exists to stop recurring."""
        html = EVIDENCE.read_text(encoding="utf-8")
        for phrase in ("none of the three remaining tasks",
                       "3 of the 3 remaining tasks"):
            self.assertIn(phrase, html,
                          f"a run section no longer says {phrase!r}, so one "
                          "headline counts a withdrawn task without saying so")


class SitePagesAgreeTests(unittest.TestCase):
    """Runs without the scoring document, so the public snapshot checks it too."""

    def test_the_two_pages_state_the_same_qwen_figures(self) -> None:
        pattern = re.compile(r"(\d+) of (\d+) criteria against (\d+) of (\d+)")
        found = {page.name: set(pattern.findall(page.read_text(encoding="utf-8")))
                 for page in (INDEX, EVIDENCE)}
        shared = found[INDEX.name] & found[EVIDENCE.name]
        self.assertTrue(shared,
                        f"the pages state no criteria figure in common: {found}")


if __name__ == "__main__":
    unittest.main()
