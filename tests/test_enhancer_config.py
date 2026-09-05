"""Tests for the enhancer configuration.

This decides what gets called, with what credentials, over what transport — so
the endpoint rule and the "keys are never in the file" property both matter more
than anything else in this project.
"""

import re
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from promptlib.enhancer import EnhancerConfig, endpoint_is_acceptable, preset


class EndpointRule(unittest.TestCase):
    def test_https_is_always_fine(self):
        self.assertTrue(endpoint_is_acceptable("https://api.openai.com/v1/chat"))

    def test_plain_http_to_a_public_host_is_refused(self):
        # This is the case that would put an API key on the wire in clear.
        self.assertFalse(endpoint_is_acceptable("http://api.openai.com/v1/chat"))
        self.assertFalse(endpoint_is_acceptable("http://8.8.8.8/v1"))

    def test_http_to_this_machine_is_fine(self):
        for url in ["http://localhost:11434/v1", "http://127.0.0.1:1234/v1"]:
            self.assertTrue(endpoint_is_acceptable(url), url)

    def test_http_to_the_lan_is_fine(self):
        for url in ["http://192.168.4.21:11434/v1", "http://10.0.0.5/v1",
                    "http://mediabox.local:8080/v1"]:
            self.assertTrue(endpoint_is_acceptable(url), url)

    def test_other_schemes_are_refused(self):
        self.assertFalse(endpoint_is_acceptable("ftp://example.com"))
        self.assertFalse(endpoint_is_acceptable("not a url"))


class ConfigFile(unittest.TestCase):
    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def test_defaults_to_the_cli_backend_needing_no_key(self):
        config = EnhancerConfig.load(self.root)
        self.assertEqual(config.auth, "cli")
        self.assertEqual(config.problems(), [])

    def test_round_trips(self):
        EnhancerConfig(auth="api_key", endpoint="https://x/v1", model="m",
                       timeout=120, _root=self.root).save()
        back = EnhancerConfig.load(self.root)
        self.assertEqual((back.auth, back.endpoint, back.model, back.timeout),
                         ("api_key", "https://x/v1", "m", 120))

    def test_the_saved_file_declares_no_key_field(self):
        # Asserting on field NAMES, not a substring: auth = "api_key" is a value
        # and contains "key" perfectly legitimately.
        EnhancerConfig(auth="api_key", endpoint="https://x/v1", model="m",
                       _root=self.root).save()
        text = (self.root / "enhancer.toml").read_text()
        body = text.split("[enhancer]")[1]
        fields = re.findall(r"^(\w+)\s*=", body, re.M)
        self.assertEqual([f for f in fields if "key" in f.lower()], [])
        self.assertIn("Keychain", text)

    def test_a_corrupt_config_falls_back_to_defaults(self):
        (self.root / "enhancer.toml").write_text("{{ not toml", encoding="utf-8")
        self.assertEqual(EnhancerConfig.load(self.root).auth, "cli")

    def test_problems_name_a_bad_endpoint(self):
        config = EnhancerConfig(auth="api_key", endpoint="http://api.openai.com/v1",
                                model="m", _root=self.root)
        self.assertTrue(any("not an acceptable endpoint" in p for p in config.problems()))

    def test_problems_name_a_missing_endpoint_and_model(self):
        config = EnhancerConfig(auth="api_key", endpoint="", model="", _root=self.root)
        self.assertIn("no endpoint set", config.problems())
        self.assertIn("no model set", config.problems())

    def test_chatgpt_oauth_reports_whether_you_are_signed_in(self):
        """This used to assert "not implemented". It is implemented now
        so the problem line has to report the state that actually
        blocks a build: whether there is a token."""
        from unittest import mock
        from promptlib import codex_oauth

        config = EnhancerConfig(auth="chatgpt_oauth", endpoint="https://x", model="m",
                                _root=self.root)

        with mock.patch.object(codex_oauth, "load_tokens", return_value=None):
            problems = config.problems()
        self.assertTrue(any("not signed in" in p for p in problems), problems)
        self.assertTrue(any("enhancer login" in p for p in problems),
                        "the problem should say what to run")

        signed_in = codex_oauth.Tokens("access", "refresh", "", 9e9)
        with mock.patch.object(codex_oauth, "load_tokens", return_value=signed_in):
            self.assertEqual(config.problems(), [])

    def test_a_keychain_that_cannot_be_read_reports_not_signed_in(self):
        """Failing closed. A broken Keychain must not crash a config read."""
        from unittest import mock
        from promptlib import codex_oauth

        config = EnhancerConfig(auth="chatgpt_oauth", endpoint="https://x", model="m",
                                _root=self.root)
        with mock.patch.object(codex_oauth, "load_tokens",
                               side_effect=OSError("no keychain here")):
            problems = config.problems()
        self.assertTrue(any("not signed in" in p for p in problems), problems)

    def test_a_local_server_needs_no_key(self):
        config = EnhancerConfig(auth="api_key", endpoint="http://localhost:11434/v1",
                                model="llama3.2:3b", _root=self.root)
        self.assertEqual(config.problems(), [])

    def test_fallback_counts_only_when_both_parts_are_set(self):
        self.assertFalse(EnhancerConfig(fallback_endpoint="https://x", _root=self.root).has_fallback)
        self.assertTrue(EnhancerConfig(fallback_endpoint="https://x", fallback_model="m",
                                       _root=self.root).has_fallback)


class Presets(unittest.TestCase):
    def test_every_http_preset_has_an_acceptable_endpoint(self):
        from promptlib.enhancer import PRESETS
        for p in PRESETS:
            if p.endpoint and p.auth != "azure_api_key":
                self.assertTrue(endpoint_is_acceptable(p.endpoint), f"{p.id}: {p.endpoint}")

    def test_unknown_preset_is_none(self):
        self.assertIsNone(preset("nope"))
