#!/usr/bin/env python3
"""QA-only MSG91 provider overlay must never make outbound provider calls."""
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
STUB = ROOT / "scripts/genie-qa/inert_msg91_provider_verify.mjs"
WORKFLOW = ROOT / ".github/workflows/genie-qa-msg91-edge-commission.yml"


class InertMsg91QaProviderTests(unittest.TestCase):
    def test_inert_stub_cannot_call_provider_even_if_auth_key_present(self):
        # This tests actual exported JS behavior, not just a source string.
        test = """
import assert from 'node:assert/strict';
import {verifyProviderAccessToken} from './scripts/genie-qa/inert_msg91_provider_verify.mjs';
let attempted = 0;
const result = await verifyProviderAccessToken({
  authKey: 'INJECTED_KEY_SHOULD_NOT_SEND',
  accessToken: 'INJECTED_TOKEN',
  fetchImpl: async () => { attempted += 1; throw new Error('provider attempted'); },
});
assert.equal(result.ok, false);
assert.equal(result.raw.error, 'qa_provider_disabled');
assert.equal(attempted, 0);
"""
        result = subprocess.run(
            ["node", "--input-type=module", "--eval", test],
            cwd=ROOT, capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_overlay_is_scoped_to_qa_workdir(self):
        source = WORKFLOW.read_text()
        self.assertIn(
            'cp scripts/genie-qa/inert_msg91_provider_verify.mjs',
            source,
        )
        self.assertIn(
            '"$workdir/supabase/functions/msg91-otp/provider-verify.mjs"',
            source,
        )
        self.assertIn(
            "GENIE_QA_EDGE_PROVIDER_SECRET_ADDED",
            source,
        )
        stub = STUB.read_text()
        self.assertNotIn("fetch(", stub)
        self.assertNotIn("https://api.msg91.com", stub)


if __name__ == "__main__":
    unittest.main()
