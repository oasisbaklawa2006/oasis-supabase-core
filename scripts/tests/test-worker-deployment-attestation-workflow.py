#!/usr/bin/env python3
"""Static fail-closed contract for future WhatsApp worker releases.

Does not access Supabase or dispatch deployment workflows.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/whatsapp-packet-ai-worker-production-release.yml"


class DeploymentAttestationWorkflowTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = WORKFLOW.read_text()

    def test_attestation_permissions_are_declared(self):
        self.assertIn("id-token: write", self.workflow)
        self.assertIn("attestations: write", self.workflow)

    def test_signing_is_between_live_metadata_and_source_verification(self):
        steps = [
            "      - name: Verify deployed function metadata",
            "      - name: Build deployment-time source provenance predicate",
            "      - name: Sign and publish deployment-time source attestation",
            "      - name: Verify deployed source closure matches reviewed source",
        ]
        offsets = [self.workflow.index(s) for s in steps]
        self.assertEqual(offsets, sorted(offsets))
        self.assertIn("subject-path: target-source-manifest.json", self.workflow)
        self.assertIn("predicate-path: signing-predicate.json", self.workflow)
        self.assertIn("jq -e '.predicate' deployment-source-predicate.json > signing-predicate.json", self.workflow)

    def test_indeterminate_does_not_pass_release(self):
        self.assertIn('[[ "$source_status" == VERIFIED || "$source_status" == VERIFIED_BY_ATTESTATION ]]', self.workflow)
        self.assertIn("if: github.event_name == 'workflow_dispatch' && inputs.deploy == true && inputs.certify_existing != true", self.workflow)
        self.assertIn("if: github.event_name == 'workflow_dispatch' && inputs.certify_existing == true && inputs.deploy == false", self.workflow)

    def test_existing_release_baseline_is_not_silently_changed(self):
        self.assertIn('EXPECTED_LIVE_VERSION: "18"', self.workflow)
        self.assertIn('CERTIFIED_DEPLOY_VERSION: "19"', self.workflow)


if __name__ == "__main__":
    unittest.main()
