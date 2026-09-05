"""Every palette token must still clear the WCAG bar it is used against.

This exists because the palette was inherited rather than measured. Seedbed took
Reference's colour *values* but not its *canvas*: a sibling app measured them against
warm paper and Seedbed draws them on the system ground, which is nearer white.
The ratios did not transfer, and recomputing them found `warning` at 2.86:1 for a
non-text component that needs 3:1, on the Accessibility warning triangle. The
icon whose whole job is to catch your eye was the one below the bar.

A number measured once and never again drifts back. So the ratios are computed
here, from the values actually declared in `Theme.swift`, on every test run.

If you are here because this failed: the fix is to change the colour, not the
bar. If a token is genuinely exempt, add it to `DECORATIVE` with the reason,
because an exemption that is written down is a decision and one that is not is
an accident.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
THEME = REPO / "macos" / "Sources" / "Seedbed" / "Theme.swift"

#: The window ground each appearance draws on. Light is white, which is what
#: makes this stricter than that app's warm paper; dark is macOS's dark window
#: background, near enough for a contrast bar.
WHITE = (255, 255, 255)
DARK = (30, 30, 30)

#: What the What's New badges fill their background at.
TINT_ALPHA = 0.14

#: WCAG 2.1: 3:1 for a non-text component (an icon, a dot, a stroke), 4.5:1 for
#: body text. The badge labels are 9pt, so the large-text exception does not
#: apply to them.
NON_TEXT_BAR = 3.0
TEXT_BAR = 4.5

#: Tokens exempt from the non-text bar, with the reason. `brandAccent` and
#: `brandWarning` are large fills only and their doc comments say so; a fill is
#: not a component boundary and has no contrast requirement of its own.
DECORATIVE = {
    "brandAccent": "large fills and brand moments only, never a stroke or text",
    "brandWarning": "the undarkened amber, fills only; `warning` is the readable one",
}


def _linear(channel: float) -> float:
    c = channel / 255
    return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4


def luminance(rgb: tuple[int, int, int]) -> float:
    r, g, b = (_linear(c) for c in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a: tuple[int, int, int], b: tuple[int, int, int]) -> float:
    high, low = sorted((luminance(a), luminance(b)), reverse=True)
    return (high + 0.05) / (low + 0.05)


def composite(fg, bg, alpha: float):
    """`fg` at `alpha` over `bg`, which is what `.opacity()` draws."""
    return tuple(round(fg[i] * alpha + bg[i] * (1 - alpha)) for i in range(3))


_COLOR = re.compile(
    r"Color\(red:\s*([0-9.]+),\s*green:\s*([0-9.]+),\s*blue:\s*([0-9.]+)\)")


def parse_theme() -> dict[str, tuple[int, int, int]]:
    """`name -> rgb` for every `static let <name> = Color(red:...)` in Theme.swift.

    Deliberately reads the source rather than taking values passed in, so the
    test measures what the app actually draws.
    """
    source = THEME.read_text(encoding="utf-8")
    found = {}
    for name, body in re.findall(
            r"static let (\w+)\s*=\s*(Color\(red:[^)]*\))", source):
        match = _COLOR.search(body)
        if match:
            found[name] = tuple(round(float(v) * 255) for v in match.groups())
    return found


def parse_on_tint() -> dict[str, dict[str, tuple[int, int, int] | str]]:
    """The `OnTint` rung: `name -> {light, dark}`, where dark may be a reference."""
    source = THEME.read_text(encoding="utf-8")
    block = re.search(r"enum OnTint \{(.*?)\n    \}", source, re.S)
    assert block, "OnTint block not found in Theme.swift"
    result = {}
    # The trailing newline is added because the last declaration in the block
    # does not have one: the block regex consumed it. Without this the last
    # badge is silently missing, which `test_all_three_badges_are_covered`
    # exists to catch and did.
    for name, body in re.findall(
            r"static let (\w+) = adaptive\((.*?)\)\n", block.group(1) + "\n", re.S):
        light = _COLOR.search(body[:body.find("dark:")])
        dark = _COLOR.search(body[body.find("dark:"):])
        entry: dict = {}
        if light:
            entry["light"] = tuple(round(float(v) * 255) for v in light.groups())
        if dark:
            entry["dark"] = tuple(round(float(v) * 255) for v in dark.groups())
        else:
            # `dark: brandWarning` and friends: resolve the reference.
            reference = re.search(r"dark:\s*(\w+)\)?\s*$", body.strip())
            if reference:
                entry["dark"] = reference.group(1)
        result[name] = entry
    return result


class PaletteContrast(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.tokens = parse_theme()
        cls.on_tint = parse_on_tint()

    def test_the_palette_was_actually_read(self):
        """A parse that silently found nothing would pass every other test here."""
        for expected in ("accent", "brandAccent", "positive", "warning", "brandWarning"):
            self.assertIn(expected, self.tokens,
                          f"{expected} not parsed out of Theme.swift; the declaration "
                          "shape changed and this test is now blind")

    def test_every_visible_token_clears_the_non_text_bar_on_white(self):
        """3:1 against the light ground, for anything drawn as an icon or a stroke."""
        for name, rgb in sorted(self.tokens.items()):
            if name in DECORATIVE:
                continue
            with self.subTest(token=name):
                ratio = contrast(rgb, WHITE)
                self.assertGreaterEqual(
                    ratio, NON_TEXT_BAR,
                    f"{name} is {ratio:.2f}:1 against white, below the {NON_TEXT_BAR}:1 "
                    "bar for a non-text component")

    def test_warning_is_the_specific_regression_this_file_exists_for(self):
        """It was 2.86:1 on the Accessibility triangle. Never again silently."""
        ratio = contrast(self.tokens["warning"], WHITE)
        self.assertGreaterEqual(ratio, NON_TEXT_BAR)
        self.assertGreater(
            ratio, contrast(self.tokens["brandWarning"], WHITE),
            "`warning` must be the darker of the pair; it is the one drawn as an icon")

    def test_every_visible_token_clears_the_non_text_bar_on_dark(self):
        """The other appearance, which is the half a light-mode check misses."""
        for name, rgb in sorted(self.tokens.items()):
            if name in DECORATIVE:
                continue
            with self.subTest(token=name):
                ratio = contrast(rgb, DARK)
                self.assertGreaterEqual(
                    ratio, NON_TEXT_BAR,
                    f"{name} is {ratio:.2f}:1 against the dark ground")

    def test_badge_labels_clear_the_text_bar_on_their_own_tint(self):
        """The failure that made this card: token ink on a 14% tint of itself.

        The badge fill is the base token; the label is the `OnTint` rung. Both
        appearances are checked, because a single value cannot serve both and
        `accent` and `positive` were failing in dark mode too.
        """
        fills = {
            "accent": "accent",
            "positive": "positive",
            # The badge fills with the undarkened amber, so that is the tint the
            # label has to be readable on.
            "warning": "brandWarning",
        }
        for name, entry in sorted(self.on_tint.items()):
            base = self.tokens[fills[name]]
            for appearance, ground in (("light", WHITE), ("dark", DARK)):
                ink = entry[appearance]
                if isinstance(ink, str):
                    ink = self.tokens[ink]
                with self.subTest(badge=name, appearance=appearance):
                    tint = composite(base, ground, TINT_ALPHA)
                    ratio = contrast(ink, tint)
                    self.assertGreaterEqual(
                        ratio, TEXT_BAR,
                        f"{name} label is {ratio:.2f}:1 on its own {int(TINT_ALPHA * 100)}% "
                        f"tint in {appearance} mode, below the {TEXT_BAR}:1 text bar "
                        "(the labels are 9pt, so the large-text exception does not apply)")

    def test_all_three_badges_are_covered(self):
        self.assertEqual(set(self.on_tint), {"accent", "positive", "warning"})


if __name__ == "__main__":
    unittest.main()
