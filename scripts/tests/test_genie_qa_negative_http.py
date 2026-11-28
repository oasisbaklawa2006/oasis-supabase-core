import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/genie-qa"))
import negative_http_transport as t

class TransportTests(unittest.TestCase):
    def test_reject_wrong_host(self):
        for url in ("https://tcxvcatsqqertcnycuop.supabase.co/auth/v1/user",
                    "https://skhpmltfjgqitntkmclb.supabase.co.evil.test/auth/v1/user",
                    "https://api.supabase.com/v1/projects/tcxvcatsqqertcnycuop/secrets"):
            with self.assertRaisesRegex(t.Denied, "HTTP_TARGET_DENIED"):
                t.http(url)

    def test_redirect_denied(self):
        self.assertIsNone(t.NoRedirect().redirect_request(None, None, 302, "", {}, "https://evil.test"))

    def test_activation_and_openai_secret_denied(self):
        for name in ("QA_MSG91_PROVIDER_ENABLED", "MSG91_AUTH_KEY", "OPENAI_API_KEY"):
            with patch.object(t, "management", return_value=[{"name": name}]):
                with self.assertRaisesRegex(t.Denied, "ACTIVATION_OR_PROHIBITED_SECRET_PRESENT"):
                    t.inventory()

    def test_fixture_denial_not_classification(self):
        self.assertTrue(t.classify_denial({"ok": True, "state": "ambiguous", "allowOtp": False}))
        for body in ({"ok": True, "state": "approved", "allowOtp": True},
                     {"ok": True, "state": "rejected", "allowOtp": False},
                     {"ok": False, "state": "ambiguous", "allowOtp": False}):
            self.assertFalse(t.classify_denial(body))

    def test_stale_only(self):
        row = {"line_id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
               "product_id": "a6182000-0000-4000-8000-000000000003", "quantity": 18}
        payload = t.cas_payload(row)
        self.assertEqual(payload["p_expected_quantity"], 19)
        self.assertEqual(payload["p_quantity"], 18)
        self.assertEqual(payload["p_product_id"], "a6182000-0000-4000-8000-000000000004")
        # Mirrors the pinned CAS condition: even if a concurrent writer makes
        # the quantity equal to the supplied expectation, product mismatch holds.
        for quantity in (18, 19, 24):
            self.assertTrue(row["product_id"] != payload["p_product_id"]
                            or quantity != payload["p_expected_quantity"])
        with self.assertRaisesRegex(t.Denied, "QA_CAS_TARGET_DRIFT"):
            t.cas_payload(dict(row, quantity=19))

    def test_publishable_only(self):
        with patch.dict(os.environ, {"QA_PUBLISHABLE_KEY": "sb_secret_bad"}):
            with self.assertRaisesRegex(t.Denied, "PUBLISHABLE_KEY_REQUIRED"):
                t.public_key()

    def test_missing_jwt_never_claims_full_gate(self):
        calls = []
        def fake_http(url, headers, data=None):
            calls.append((url, headers, data))
            if url.endswith("buyer-login-gateway"):
                return 200, {"ok": True, "state": "ambiguous", "allowOtp": False}
            if url.endswith("msg91-otp"):
                self.assertIsInstance(data["accessToken"], dict)
                return 401, {"error": "provider_verification_failed"}
            return 401, {}
        with patch.dict(os.environ, {"QA_BUYER_JWT": ""}), patch.object(t, "http", side_effect=fake_http), patch.object(t, "inventory"):
            with self.assertRaisesRegex(t.Denied, "FULL_NEGATIVE_GATE_INCOMPLETE"):
                t.probes({}, "sb_publishable_test")
        self.assertEqual(len(calls), 6)
        self.assertTrue(all(c[0].startswith(t.BASE + "/") for c in calls))
        self.assertFalse(any("update_customer_order_draft" in c[0] for c in calls))

    def test_workflows_are_separate_and_live_lock_shared(self):
        workflows = ROOT / ".github/workflows"
        offline = (workflows / "genie-qa-negative-http-ci.yml").read_text()
        live = (workflows / "genie-qa-negative-http.yml").read_text()
        self.assertIn("  pull_request:", offline)
        self.assertNotIn("environment:", offline)
        self.assertNotIn("secrets.", offline)
        self.assertNotIn("workflow_dispatch:", offline)
        self.assertIn("  workflow_dispatch:", live)
        self.assertNotIn("pull_request:", live)
        self.assertIn("environment: genie-qa-bootstrap", live)
        self.assertIn("group: genie-qa-msg91-edge-commission", live)
        self.assertIn("cancel-in-progress: false", live)

    def test_live_gate_not_available_on_pr(self):
        with patch.dict(os.environ, {"GITHUB_EVENT_NAME": "pull_request"}):
            with self.assertRaisesRegex(t.Denied, "WORKFLOW_SCOPE_DENIED"):
                t.main()

if __name__ == "__main__":
    unittest.main()
