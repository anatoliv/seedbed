"""The public site at seedbed.dev: what it links, what it claims, what it must not carry.

The site lives in site/ and is deployed by Scripts/publish-site.sh onto a host
whose Content-Security-Policy has no script-src and no font-src. These tests pin
the things a local preview cannot show: a script tag that the host would block,
a version link that has drifted from the cask, a brand export that no longer
matches its master, a claim the measurements contradict, and a hostname buried
in a raw model output.
"""

import re
import struct
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / "site"
INDEX = SITE / "index.html"
EVIDENCE = SITE / "evidence" / "index.html"
PRIVACY = SITE / "privacy.html"
PAGES = (INDEX, EVIDENCE, PRIVACY)
CASK = ROOT / "Casks" / "seedbed.rb"

# The design notes behind the site list what it must not claim, each because a
# measurement contradicts it. Phrases, lower-cased, that would be one of those.
FORBIDDEN_CLAIMS = (
    "saves you time",
    "save you time",
    "used by developers",
    "better prompts for any model",
    "better prompts for every model",
    "works with any model",
    "loved by",
)
# Assembled from pieces so this file does not itself spell a hostname; the
# public mirror's secrets guard scans tests too, and it should.
INTERNAL = re.compile(r"192\.168\.|(?:ai|web)-0\d\b|amnesia|TBX-\d", re.IGNORECASE)


def text_of(page: Path) -> str:
    return page.read_text(encoding="utf-8")


class SiteAssets(unittest.TestCase):
    def test_brand_exports_are_byte_identical_to_the_masters(self) -> None:
        for name in ("seedbed-mark.svg", "seedbed-app-icon.svg", "favicon.svg",
                     "favicon-32.png", "apple-touch-icon.png"):
            with self.subTest(name=name):
                self.assertEqual(
                    (SITE / name).read_bytes(), (ROOT / "assets" / "brand" / name).read_bytes(),
                    f"site/{name} drifted from assets/brand/{name}; copy it, do not edit it",
                )

    def test_every_icon_url_is_versioned(self) -> None:
        # The host serves svg and png as `immutable` for 7 days and a CDN sits in
        # front, so an icon replaced at a stable path keeps being served from the
        # edge. On 2026-09-07 the site showed the pre-refresh mark for two days
        # after the new one was deployed, and the origin was correct the whole
        # time. Versioned URLs are a different cache key, so the swap is visible
        # at once; bump the version whenever an icon changes.
        for page in PAGES:
            html = text_of(page)
            for ref in re.findall(r'(?:href|src|content)="((?:https://seedbed\.dev)?/[^"]+\.(?:svg|png))"', html):
                if ref.endswith(".dmg"):
                    continue
                with self.subTest(page=page.name, ref=ref):
                    self.assertRegex(ref, r"\?v=\d{8}$", f"{ref} carries no version query")

    def test_og_image_is_the_social_card_size(self) -> None:
        head = (SITE / "og.png").read_bytes()[:24]
        self.assertEqual(head[:8], b"\x89PNG\r\n\x1a\n")
        width, height = struct.unpack(">II", head[16:24])
        self.assertEqual((width, height), (1200, 630))

    def test_og_image_is_generated_from_the_app_icon_master(self) -> None:
        # site/og.png is built by Scripts/make-og-image.sh, which rasterizes
        # assets/brand/seedbed-app-icon.svg and places it. Hand-copying the
        # master's paths into a new drawing is what the brand README forbids,
        # and it is how a social card silently stops matching the app icon.
        script = ROOT / "Scripts" / "make-og-image.sh"
        self.assertTrue(script.is_file())
        body = script.read_text()
        self.assertIn("assets/brand/seedbed-app-icon.svg", body)
        self.assertIn("site/og.png", body)

    def test_pages_reference_only_assets_that_exist(self) -> None:
        for page in PAGES:
            for ref in re.findall(r'(?:href|src)="(/[^"#?]+)', text_of(page)):
                if ref.endswith(".dmg") or ref == "/appcast.xml":
                    continue  # owned by macos/Scripts/publish.sh, not in site/
                target = SITE / ref.lstrip("/")
                if ref.endswith("/"):
                    target = target / "index.html"
                with self.subTest(page=page.name, ref=ref):
                    self.assertTrue(target.is_file(), f"{page.name} links {ref}, which is not in site/")


class SiteContent(unittest.TestCase):
    def test_no_script_and_no_external_stylesheet(self) -> None:
        for page in PAGES:
            html = text_of(page)
            with self.subTest(page=page.name):
                self.assertNotIn("<script", html.lower(), "the host's CSP has no script-src")
                self.assertIsNone(
                    re.search(
                        r'<link[^>]*rel="(stylesheet|preload|preconnect)"[^>]*href="https?://'
                        r'|<link[^>]*href="https?://[^"]*"[^>]*rel="(stylesheet|preload|preconnect)"',
                        html, re.IGNORECASE,
                    ),
                    "the host's CSP has no font-src and style-src is 'self'",
                )

    def test_no_dashes_in_published_copy(self) -> None:
        # The house rule for anything a user reads: no em or en dashes. The
        # 2026-09-06 sweep found forty-six in shipped copy; this keeps the site at zero.
        for page in PAGES:
            html = text_of(page)
            for glyph, name in (("—", "em dash"), ("–", "en dash")):
                with self.subTest(page=page.name, glyph=name):
                    self.assertNotIn(glyph, html, f"{name} in {page.name}")

    def test_no_claim_the_measurements_contradict(self) -> None:
        for page in PAGES:
            lower = text_of(page).lower()
            for phrase in FORBIDDEN_CLAIMS:
                with self.subTest(page=page.name, phrase=phrase):
                    self.assertNotIn(phrase, lower)

    def test_the_negative_result_is_published_beside_the_positive(self) -> None:
        # Publishing the Opus result that did not support the tool is what makes
        # the qwen result worth believing. The two pages that make the claim
        # carry both results; the privacy page makes no claim about either.
        for page in (INDEX, EVIDENCE):
            html = text_of(page)
            with self.subTest(page=page.name):
                self.assertIn("claude-opus-5", html)
                self.assertIn("qwen3-vl-30b", html)
                self.assertIn("0 of 4", html)
                self.assertIn("3 of 4", html)

    def test_nothing_internal_anywhere_in_site(self) -> None:
        for path in sorted(SITE.rglob("*")):
            if not path.is_file() or path.suffix in {".png"}:
                continue
            hit = INTERNAL.search(path.read_text(encoding="utf-8", errors="replace"))
            with self.subTest(path=str(path.relative_to(ROOT))):
                self.assertIsNone(hit, f"{path.relative_to(ROOT)} names something internal: {hit and hit.group(0)}")


class SiteVersion(unittest.TestCase):
    def pinned_versions(self) -> set[str]:
        html = text_of(INDEX)
        found = re.findall(r"Seedbed_(\d+\.\d+\.\d+)_universal\.dmg", html)
        found += re.findall(r'data-version="(\d+\.\d+\.\d+)"', html)
        found += re.findall(r"data-version-label>(\d+\.\d+\.\d+)<", html)
        self.assertGreaterEqual(len(found), 3, "the page carries too few version markers to sync")
        return set(found)

    def test_every_version_marker_on_the_page_agrees(self) -> None:
        self.assertEqual(len(self.pinned_versions()), 1, self.pinned_versions())

    def test_site_pins_the_same_release_as_the_cask(self) -> None:
        # Both are version-pinned surfaces rewritten by release.sh (sync-cask.sh,
        # sync-site.sh) and committed together. Two different numbers means one
        # of them was hand-edited, and one of the two install paths is wrong.
        cask = re.search(r'^  version "(\d+\.\d+\.\d+),\d+"', text_of(CASK), re.MULTILINE)
        self.assertIsNotNone(cask)
        self.assertEqual(self.pinned_versions(), {cask.group(1)})


class SitePublishing(unittest.TestCase):
    def test_publish_site_is_kept_out_of_the_public_mirror(self) -> None:
        # It names the deploy host's document root, the same line publish.sh
        # draws. The script is optional in a public checkout (see
        # test_publish_guards.py for why), so skip rather than fail without it.
        script = ROOT / "Scripts" / "publish-repo.sh"
        if not script.is_file():
            self.skipTest("Scripts/publish-repo.sh is not in this checkout")
        text = text_of(script)
        self.assertIn("--exclude='Scripts/publish-site.sh'", text)
        self.assertIn("Scripts/publish-site.sh", text.split("rm -rf", 1)[1])

    def test_release_syncs_the_site_and_the_gate_checks_it(self) -> None:
        release = text_of(ROOT / "macos" / "Scripts" / "release.sh")
        gate = text_of(ROOT / "macos" / "Scripts" / "check-release.sh")
        self.assertIn("Scripts/sync-site.sh", release)
        self.assertIn("Scripts/sync-site.sh --check", gate)


if __name__ == "__main__":
    unittest.main()
