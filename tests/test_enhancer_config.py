"""Tests for the enhancer configuration.

This decides what gets called, with what credentials, over what transport — so
the endpoint rule and the "keys are never in the file" property both matter more
than anything else in this project.
"""

import io
import json
import re
import subprocess
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from promptlib.enhance import _via_http
from promptlib.enhancer import (EnhancerConfig, azure_legacy_deployment_url,
                                endpoint_is_acceptable, keychain_set, preset)


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

    def test_choosing_azure_preset_replaces_previous_provider_model(self):
        from promptlib.cli import cmd_enhancer

        EnhancerConfig(auth="cli", model="opus", _root=self.root).save()
        args = SimpleNamespace(root=self.root, action="set", preset="azure", auth=None,
                               endpoint=None, model=None, timeout=None,
                               fallback_endpoint=None, fallback_model=None,
                               key=None, fallback_key=None)
        with mock.patch("promptlib.enhancer.keychain_get", return_value="test-key"):
            with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                self.assertEqual(cmd_enhancer(args, None, {}, None), 0)
        config = EnhancerConfig.load(self.root)
        self.assertEqual(config.model, "YOUR-DEPLOYMENT")
        self.assertEqual(config.auth, "azure_api_key")

    def test_legacy_azure_endpoint_does_not_need_separate_model(self):
        config = EnhancerConfig(
            auth="azure_api_key",
            endpoint="https://gateway.example.com/genai/v1/openai/deployments/dev/chat/"
                     "completions?api-version=2024-10-21",
            model="", _root=self.root)
        with mock.patch("promptlib.enhancer.keychain_get", return_value="test-key"):
            self.assertEqual(config.problems(), [])

    def test_failed_keychain_write_does_not_claim_azure_was_saved(self):
        from promptlib.cli import cmd_enhancer

        original = EnhancerConfig(auth="cli", model="opus", _root=self.root)
        original.save()
        args = SimpleNamespace(root=self.root, action="set", preset="azure", auth=None,
                               endpoint=None, model=None, timeout=None,
                               fallback_endpoint=None, fallback_model=None,
                               key="test-key", fallback_key=None)
        with mock.patch("promptlib.cli.keychain_set", return_value=False):
            with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()) as errors:
                self.assertEqual(cmd_enhancer(args, None, {}, None), 1)
        self.assertIn("could not save the enhancer API key", errors.getvalue())
        self.assertEqual(EnhancerConfig.load(self.root).auth, "cli")

    def test_failed_security_command_is_reported(self):
        with mock.patch("promptlib.enhancer.subprocess.run",
                        return_value=subprocess.CompletedProcess([], 1, "", "denied")):
            self.assertFalse(keychain_set("test-service", "test-key"))


class Presets(unittest.TestCase):
    def test_every_http_preset_has_an_acceptable_endpoint(self):
        from promptlib.enhancer import PRESETS
        for p in PRESETS:
            if p.endpoint and p.auth != "azure_api_key":
                self.assertTrue(endpoint_is_acceptable(p.endpoint), f"{p.id}: {p.endpoint}")

    def test_unknown_preset_is_none(self):
        self.assertIsNone(preset("nope"))

    def test_azure_preset_uses_v1_route_and_requires_deployment(self):
        azure = preset("azure")
        self.assertEqual(azure.endpoint,
                         "https://YOUR-RESOURCE.openai.azure.com/openai/v1/chat/completions")
        self.assertEqual(azure.model, "YOUR-DEPLOYMENT")
        self.assertEqual(azure.auth, "azure_api_key")

        config = EnhancerConfig(auth=azure.auth, endpoint=azure.endpoint,
                                model=azure.model)
        with mock.patch("promptlib.enhancer.keychain_get", return_value="test-key"):
            self.assertTrue(any("YOUR-RESOURCE" in p for p in config.problems()))
            self.assertTrue(any("YOUR-DEPLOYMENT" in p for p in config.problems()))

    def test_one_preset_is_not_a_provider(self):
        """Someone must be able to find "point this at my own server" in the menu.

        Every other entry is a brand, and a list of brands reads as the complete
        set of options. On 2026-09-07 a reader wanting a model on their own
        machine went down that list, found no entry for it, and concluded it was
        unsupported. It was supported the whole time: the endpoint is editable
        and a private address passes `endpoint_is_acceptable`. The defect was
        that nothing said so.

        So this pins the entry rather than its wording, which is free to change.
        """
        custom = preset("custom")
        self.assertIsNotNone(custom, "the non-provider preset is gone, and with it the "
                                     "only hint in the menu that your own server is an option")
        self.assertEqual(custom.auth, "api_key")
        self.assertTrue(endpoint_is_acceptable(custom.endpoint),
                        "its placeholder must satisfy the rule it is demonstrating")
        self.assertFalse(custom.model,
                         "the model depends on what the user runs, so it stays blank "
                         "rather than suggesting one they do not have")


class AzureHTTP(unittest.TestCase):
    @staticmethod
    def _response():
        response = mock.MagicMock()
        response.__enter__.return_value.read.return_value = json.dumps(
            {"choices": [{"message": {"content": "ok"}}]}).encode()
        return response

    def test_v1_sends_deployment_as_model_with_api_key_header(self):
        endpoint = "https://resource.openai.azure.com/openai/v1/chat/completions"
        with mock.patch("urllib.request.urlopen", return_value=self._response()) as send:
            self.assertEqual(_via_http("hello", endpoint, "my-deployment", "test-key",
                                       "azure_api_key", 10), "ok")
        request = send.call_args.args[0]
        self.assertEqual(json.loads(request.data)["model"], "my-deployment")
        self.assertEqual(request.get_header("Api-key"), "test-key")
        self.assertIsNone(request.get_header("Authorization"))

    def test_legacy_route_uses_deployment_in_path_without_model_body(self):
        endpoint = ("https://gateway.example.com/genai/v1/openai/deployments/"
                    "my-deployment/chat/completions?api-version=2024-10-21")
        self.assertTrue(azure_legacy_deployment_url(endpoint))
        with mock.patch("urllib.request.urlopen", return_value=self._response()) as send:
            self.assertEqual(_via_http("hello", endpoint, "", "test-key",
                                       "azure_api_key", 10), "ok")
        self.assertNotIn("model", json.loads(send.call_args.args[0].data))
