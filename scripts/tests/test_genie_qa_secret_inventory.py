#!/usr/bin/env python3
"""Negative tests for the no-provider QA secret-inventory gate."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CHECK = ROOT / "scripts/genie-qa/verify_msg91_secret_inventory.py"


class GenieQaSecretInventoryTests(unittest.TestCase):
    def check_raw(self, raw: bytes, expected_ok: bool) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "secrets.json"
            path.write_bytes(raw)
            result = subprocess.run(
                [sys.executable, str(CHECK), str(path)],
                capture_output=True,
                text=True,
                check=False,
            )
        if expected_ok:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("GENIE_QA_EDGE_SECRET_INVENTORY_PASS", result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("GENIE_QA_EDGE_SECRET_NAMES_UNPARSABLE_OR_PROVIDER_KEY_PRESENT", result.stderr)
            self.assertNotIn("SENSITIVE_VALUE", result.stderr)
            self.assertNotIn("SENSITIVE_VALUE", result.stdout)

    def test_empty_inventory_and_valid_records_pass(self):
        self.check_raw(b"[]", True)
        self.check_raw(
            json.dumps([
                {"name": "SUPABASE_URL", "value": "SENSITIVE_VALUE"},
                {"name": "SOME_OTHER_KEY", "digest": "SENSITIVE_VALUE"},
            ]).encode("utf-8"),
            True,
        )

    def test_provider_key_and_case_variants_fail_closed(self):
        for name in ("MSG91_AUTH_KEY", "msg91_auth_key", "Msg91_Auth_Key"):
            with self.subTest(name=name):
                self.check_raw(json.dumps([{"name": name}]).encode(), False)

    def test_partial_or_malformed_inventories_fail_closed(self):
        invalid = [
            b"",
            b"NAME | DIGEST",
            b'{"name":"SUPABASE_URL"}',
            b'{"error":"forbidden"}',
            b'[{"name":"SAFE"},',
            b'[null]',
            b'["name | digest"]',
            b'[{"name":"SAFE"}, {"digest":"SENSITIVE_VALUE"}]',
            b'[{"name":"SAFE"}, {"name":3}]',
            b'[{"name":"SAFE"}, {"name":"bad name"}]',
            b'[{"name":"SAFE"}, {"name":"SAFE"}]',
            b'[{"name":"SAFE","name":"MSG91_AUTH_KEY"}]',
            b'[{"name":"SAFE","value":NaN}]',
            b'[{"name":"SAFE"}] garbage',
            b'x' * (1024 * 1024 + 1),
        ]
        for raw in invalid:
            with self.subTest(payload=raw[:60]):
                self.check_raw(raw, False)

    def test_mixed_valid_and_unreadable_provider_entry_fails(self):
        self.check_raw(
            b'[{"name":"SUPABASE_URL"}, {"digest":"SENSITIVE_VALUE"}, {"name":"MSG91_AUTH_KEY"}]',
            False,
        )


if __name__ == "__main__":
    unittest.main()
