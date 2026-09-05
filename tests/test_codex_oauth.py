"""The ChatGPT sign-in flow, tested offline.

Nothing here touches the network, the Keychain or a browser. What is worth
testing about an OAuth client is not the happy path — that needs a real server —
but the checks that stop a forged or replayed callback being trusted, and the
constants that the authorization server matches exactly.

The three failure modes this pins:

1. **A forged callback.** Anything on this machine can reach a loopback port
   while a login is in flight. `state` is the only thing standing between that
   and a token exchange, so its comparison is tested directly.
2. **A drifted constant.** The redirect URI and client id are allow-listed
   server-side; a typo fails with `invalid_redirect_uri` and no other clue.
3. **A leaked secret.** Errors carry truncated bodies, the request logger is
   silenced (the default one prints the query string, which holds the
   authorization code), and no token is ever formatted into a message.
"""

from __future__ import annotations

import base64
import hashlib
import json
import sys
import time
import unittest
from pathlib import Path
from unittest import mock
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from promptlib import codex_oauth as oauth


class PKCEIsCorrect(unittest.TestCase):
    """S256 is only worth anything if the challenge really is the hash."""

    def test_the_challenge_is_the_sha256_of_the_verifier(self):
        pkce = oauth.PKCE.generate()
        expected = base64.urlsafe_b64encode(
            hashlib.sha256(pkce.verifier.encode("ascii")).digest()
        ).decode().rstrip("=")
        self.assertEqual(pkce.challenge, expected)

    def test_both_halves_are_url_safe_and_unpadded(self):
        pkce = oauth.PKCE.generate()
        for value in (pkce.verifier, pkce.challenge):
            self.assertNotIn("=", value)
            self.assertNotIn("+", value)
            self.assertNotIn("/", value)

    def test_the_verifier_is_within_the_length_the_rfc_allows(self):
        """RFC 7636 requires 43-128 characters."""
        verifier = oauth.PKCE.generate().verifier
        self.assertGreaterEqual(len(verifier), 43)
        self.assertLessEqual(len(verifier), 128)

    def test_every_flow_gets_its_own_verifier(self):
        self.assertNotEqual(oauth.PKCE.generate().verifier,
                            oauth.PKCE.generate().verifier)

    def test_state_is_unpredictable_and_distinct_per_flow(self):
        self.assertNotEqual(oauth.generate_state(), oauth.generate_state())
        self.assertGreaterEqual(len(oauth.generate_state()), 40)


class AuthorizeURL(unittest.TestCase):
    def setUp(self):
        self.pkce = oauth.PKCE.generate()
        self.state = oauth.generate_state()
        self.query = parse_qs(urlparse(oauth.authorize_url(self.pkce, self.state)).query)

    def test_it_carries_the_challenge_and_never_the_verifier(self):
        """The verifier is the secret. Putting it in a URL would defeat PKCE."""
        self.assertEqual(self.query["code_challenge"], [self.pkce.challenge])
        self.assertEqual(self.query["code_challenge_method"], ["S256"])
        flat = json.dumps(self.query)
        self.assertNotIn(self.pkce.verifier, flat)

    def test_it_carries_the_state(self):
        self.assertEqual(self.query["state"], [self.state])

    def test_the_scope_asks_for_a_refresh_token(self):
        """Without `offline_access` there is no refresh token and every
        session dies at the first expiry."""
        self.assertIn("offline_access", self.query["scope"][0])

    def test_the_connector_scopes_are_present(self):
        """The backend-api route rejects a bearer without these."""
        scope = self.query["scope"][0]
        self.assertIn("api.connectors.read", scope)
        self.assertIn("api.connectors.invoke", scope)

    def test_the_simplified_flow_flags_the_cli_sends_are_present(self):
        self.assertEqual(self.query["id_token_add_organizations"], ["true"])
        self.assertEqual(self.query["codex_cli_simplified_flow"], ["true"])


class AllowListedConstants(unittest.TestCase):
    """These are matched exactly server-side. Drift fails with no useful error."""

    def test_the_redirect_uri_is_the_allow_listed_one(self):
        self.assertEqual(oauth.REDIRECT_URI, "http://localhost:1455/auth/callback")
        self.assertEqual(oauth.CALLBACK_PORT, 1455)

    def test_the_redirect_uri_and_the_port_cannot_drift_apart(self):
        self.assertIn(f":{oauth.CALLBACK_PORT}/", oauth.REDIRECT_URI)
        self.assertTrue(oauth.REDIRECT_URI.endswith(oauth.CALLBACK_PATH))

    def test_the_redirect_target_is_loopback(self):
        host = urlparse(oauth.REDIRECT_URI).hostname
        self.assertIn(host, {"localhost", "127.0.0.1"})

    def test_the_endpoints_are_https(self):
        for url in (oauth.AUTHORIZE_URL, oauth.TOKEN_URL, oauth.RESPONSES_URL):
            self.assertTrue(url.startswith("https://"), url)


class CallbackGuards(unittest.TestCase):
    """The forged-callback path, exercised without a socket."""

    def _handle(self, path: str, expected_state: str):
        handler = oauth._CallbackHandler.__new__(oauth._CallbackHandler)
        handler.path = path
        oauth._CallbackHandler.expected_state = expected_state
        oauth._CallbackHandler.result = {}
        sent = {}
        handler._reply = lambda status, body: sent.update(status=status)
        handler.send_error = lambda status, msg="": sent.update(status=status)
        handler.do_GET()
        return oauth._CallbackHandler.result, sent

    def test_a_mismatched_state_is_refused_and_the_code_is_not_kept(self):
        result, sent = self._handle(
            "/auth/callback?code=stolen&state=wrong", expected_state="right")
        self.assertIn("error", result)
        self.assertIn("forged", result["error"])
        self.assertNotIn("code", result)
        self.assertEqual(sent["status"], 400)

    def test_a_matching_state_yields_the_code(self):
        result, sent = self._handle(
            "/auth/callback?code=good&state=right", expected_state="right")
        self.assertEqual(result, {"code": "good"})
        self.assertEqual(sent["status"], 200)

    def test_an_error_from_the_authorization_server_is_reported(self):
        result, _ = self._handle(
            "/auth/callback?error=access_denied&state=right", expected_state="right")
        self.assertIn("access_denied", result["error"])

    def test_a_callback_with_no_code_is_refused(self):
        result, _ = self._handle("/auth/callback?state=right", expected_state="right")
        self.assertIn("no authorization code", result["error"])

    def test_another_path_is_not_treated_as_the_callback(self):
        result, sent = self._handle("/?code=x&state=right", expected_state="right")
        self.assertEqual(result, {})
        self.assertEqual(sent["status"], 404)

    def test_the_request_logger_is_silenced(self):
        """The stdlib default prints the request line, which holds the code."""
        handler = oauth._CallbackHandler.__new__(oauth._CallbackHandler)
        self.assertIsNone(handler.log_message("%s", "anything"))


class TokenHandling(unittest.TestCase):
    def test_a_token_near_expiry_wants_refreshing(self):
        soon = oauth.Tokens("a", "r", "", time.time() + 5)
        later = oauth.Tokens("a", "r", "", time.time() + 3600)
        self.assertTrue(soon.needs_refresh)
        self.assertFalse(later.needs_refresh)

    def test_a_refresh_that_omits_the_refresh_token_keeps_the_old_one(self):
        """The server omits it when the existing one is still good. Dropping it
        would silently end the session at the next expiry."""
        fresh = oauth.Tokens("new-access", "", "", time.time() + 3600)
        with mock.patch.object(oauth, "_post_token_request", return_value=fresh):
            out = oauth.refresh_tokens("original-refresh")
        self.assertEqual(out.refresh_token, "original-refresh")
        self.assertEqual(out.access_token, "new-access")

    def test_a_refresh_that_returns_a_new_refresh_token_uses_it(self):
        fresh = oauth.Tokens("new-access", "rotated", "", time.time() + 3600)
        with mock.patch.object(oauth, "_post_token_request", return_value=fresh):
            out = oauth.refresh_tokens("original-refresh")
        self.assertEqual(out.refresh_token, "rotated")

    def test_round_trips_through_the_stored_shape(self):
        original = oauth.Tokens("a", "r", "i", 1234.5)
        self.assertEqual(oauth.Tokens.from_dict(original.as_dict()), original)

    def test_not_signed_in_says_what_to_run(self):
        with mock.patch.object(oauth, "load_tokens", return_value=None):
            with self.assertRaises(oauth.CodexAuthError) as caught:
                oauth.current_tokens()
        self.assertIn("enhancer login", str(caught.exception))

    def test_an_expired_token_with_no_refresh_token_says_to_sign_in_again(self):
        stale = oauth.Tokens("a", "", "", time.time() - 1)
        with mock.patch.object(oauth, "load_tokens", return_value=stale):
            with self.assertRaises(oauth.CodexAuthError) as caught:
                oauth.current_tokens()
        self.assertIn("expired", str(caught.exception))


class IDTokenClaims(unittest.TestCase):
    @staticmethod
    def _jwt(payload: dict) -> str:
        encode = lambda data: base64.urlsafe_b64encode(
            json.dumps(data).encode()).decode().rstrip("=")
        return f"{encode({'alg': 'none'})}.{encode(payload)}.signature"

    def test_it_reads_the_account_id_used_for_the_request_header(self):
        jwt = self._jwt({
            "email": "a@example.com",
            "https://api.openai.com/auth": {
                "chatgpt_plan_type": "pro", "chatgpt_account_id": "acct_1"},
        })
        claims = oauth.parse_id_token(jwt)
        self.assertEqual(claims.email, "a@example.com")
        self.assertEqual(claims.plan, "pro")
        self.assertEqual(claims.account_id, "acct_1")

    def test_it_falls_back_to_the_profile_email(self):
        jwt = self._jwt({"https://api.openai.com/profile": {"email": "b@example.com"}})
        self.assertEqual(oauth.parse_id_token(jwt).email, "b@example.com")

    def test_a_token_with_no_claims_gives_empty_strings_not_an_error(self):
        claims = oauth.parse_id_token(self._jwt({}))
        self.assertEqual((claims.email, claims.plan, claims.account_id), ("", "", ""))

    def test_something_that_is_not_a_jwt_is_refused(self):
        with self.assertRaises(oauth.CodexAuthError):
            oauth.parse_id_token("not-a-jwt")


class ResponsesShape(unittest.TestCase):
    """This endpoint speaks Responses, not Chat Completions, and rejects the
    wrong shape with a bare 400."""

    def test_it_reads_the_documented_output_path(self):
        payload = {"output": [{"content": [{"type": "output_text", "text": "hello"}]}]}
        self.assertEqual(oauth._extract_text(payload), "hello")

    def test_it_accepts_the_convenience_field(self):
        self.assertEqual(oauth._extract_text({"output_text": "hi"}), "hi")

    def test_a_reply_with_no_text_is_an_error_not_an_empty_prompt(self):
        """Returning "" here would write an empty render to disk."""
        with self.assertRaises(oauth.CodexAuthError):
            oauth._extract_text({"output": []})


class WiredIntoTheEnhancer(unittest.TestCase):
    def test_the_auth_mode_no_longer_refuses(self):
        """It used to raise 'not implemented yet' before reaching any code."""
        from promptlib import enhance
        with mock.patch.object(oauth, "complete", return_value="built") as called:
            out = enhance.run_prompt("sys", "msg", backend="chatgpt_oauth")
        self.assertEqual(out, "built")
        self.assertTrue(called.called)

    def test_an_auth_failure_surfaces_as_an_enhancer_error(self):
        """So the CLI and the app report it the same way as every other backend."""
        from promptlib import enhance
        with mock.patch.object(oauth, "complete",
                               side_effect=oauth.CodexAuthError("not signed in")):
            with self.assertRaises(enhance.EnhancerError) as caught:
                enhance.run_prompt("sys", "msg", backend="chatgpt_oauth")
        self.assertIn("not signed in", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
