"""Measure Seedbed's Reference palette against the surfaces it actually draws."""

from __future__ import annotations

import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
THEME = REPO / "macos" / "Sources" / "Seedbed" / "Theme.swift"
NON_TEXT_BAR = 3.0


def rgb(hex_value: int) -> tuple[int, int, int]:
    return ((hex_value >> 16) & 255, (hex_value >> 8) & 255, hex_value & 255)


def linear(channel: int) -> float:
    value = channel / 255
    return value / 12.92 if value <= 0.03928 else ((value + 0.055) / 1.055) ** 2.4


def luminance(value: tuple[int, int, int]) -> float:
    r, g, b = (linear(channel) for channel in value)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a: tuple[int, int, int], b: tuple[int, int, int]) -> float:
    high, low = sorted((luminance(a), luminance(b)), reverse=True)
    return (high + 0.05) / (low + 0.05)


def enum_block(source: str, name: str) -> str:
    start = source.index(f"enum {name} {{")
    brace = source.index("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"unterminated enum {name}")


def dynamic_values(block: str) -> dict[str, dict[str, tuple[int, int, int]]]:
    found = {}
    pattern = r"static let (\w+) = (?:Surface\.)?dynamic\(light: 0x([0-9A-Fa-f_]+), dark: 0x([0-9A-Fa-f_]+)\)"
    for name, light, dark in re.findall(pattern, block):
        found[name] = {
            "light": rgb(int(light.replace("_", ""), 16)),
            "dark": rgb(int(dark.replace("_", ""), 16)),
        }
    return found


def fixed_values(source: str) -> dict[str, tuple[int, int, int]]:
    found = {}
    pattern = (r"static let (\w+) = Color\(red: ([0-9.]+), "
               r"green: ([0-9.]+), blue: ([0-9.]+)\)")
    for name, red, green, blue in re.findall(pattern, source):
        found[name] = tuple(round(float(v) * 255) for v in (red, green, blue))
    return found


class PaletteContrast(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = THEME.read_text()
        cls.fixed = fixed_values(enum_block(cls.source, "Tokens"))
        cls.dynamic = dynamic_values(enum_block(cls.source, "Tokens"))
        cls.surfaces = dynamic_values(enum_block(cls.source, "Surface"))

    def value(self, name: str, appearance: str) -> tuple[int, int, int]:
        if name in self.fixed:
            return self.fixed[name]
        return self.dynamic[name][appearance]

    def test_expected_palette_and_surfaces_were_parsed(self) -> None:
        self.assertTrue({"accent", "brandAccent", "positive"} <= set(self.fixed))
        self.assertTrue({"secondaryAccent", "aiAccent", "warning", "danger"} <= set(self.dynamic))
        self.assertEqual(
            set(self.surfaces),
            {"canvas", "card", "raised", "sunken", "rowAlternate", "chrome", "hairline"},
        )

    def test_visible_signal_colors_clear_the_component_bar(self) -> None:
        visible = ("accent", "secondaryAccent", "aiAccent", "positive", "warning", "danger")
        for appearance in ("light", "dark"):
            canvas = self.surfaces["canvas"][appearance]
            for name in visible:
                with self.subTest(appearance=appearance, token=name):
                    ratio = contrast(self.value(name, appearance), canvas)
                    self.assertGreaterEqual(ratio, NON_TEXT_BAR, f"{name}: {ratio:.2f}:1")

    def test_brand_accent_remains_a_fill_not_an_indicator(self) -> None:
        ratio = contrast(self.fixed["brandAccent"], self.surfaces["canvas"]["light"])
        self.assertLess(ratio, NON_TEXT_BAR)

    def test_surface_ramp_is_ordered_and_distinct(self) -> None:
        for appearance in ("light", "dark"):
            order = ("sunken", "chrome", "canvas", "card", "raised") \
                if appearance == "light" else ("sunken", "canvas", "chrome", "card", "raised")
            values = [self.surfaces[name][appearance] for name in order]
            levels = [luminance(value) for value in values]
            self.assertEqual(levels, sorted(levels))
            self.assertEqual(len(values), len(set(values)))
            self.assertGreaterEqual(
                contrast(self.surfaces["card"][appearance], self.surfaces["canvas"][appearance]),
                1.02,
            )

    def test_hairline_is_visible_on_canvas_and_card(self) -> None:
        for appearance in ("light", "dark"):
            hairline = self.surfaces["hairline"][appearance]
            for ground in ("canvas", "card"):
                self.assertGreaterEqual(contrast(hairline, self.surfaces[ground][appearance]), 1.10)


if __name__ == "__main__":
    unittest.main()
