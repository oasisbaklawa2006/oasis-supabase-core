#!/usr/bin/env python3
"""Fail-closed, deployment-job-scoped worker provenance contract."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/whatsapp-packet-ai-worker-production-release.yml"


class DeploymentAttestationWorkflowTest(unittest.TestCase):
    """Verify signing permissions, step ordering and truthful release evidence."""

    @classmethod
    def setUpClass(cls):
        """Read the actual release workflow under test."""
        cls.workflow = WORKFLOW.read_text()
        cls.deploy = cls.workflow.split("\n  deploy:\n", 1)[1].split("\n  certify-existing:\n", 1)[0]

    def test_attestation_permissions_are_job_scoped(self):
        """Do not grant OIDC signing privileges to preflight or certification."""
        global_permissions = self.workflow.split("\npermissions:\n", 1)[1].split("\n\n", 1)[0]
        self.assertNotIn("id-token: write", global_permissions)
        self.assertNotIn("attestations: write", global_permissions)
        self.assertIn("id-token: write", self.deploy)
        self.assertIn("attestations: write", self.deploy)

    def test_deploy_signs_before_source_verification(self):
        """Require real deploy steps in order, not strings elsewhere in YAML."""
        names = [
            "Verify deployed function metadata",
            "Build deployment-time source provenance predicate",
            "Sign and publish deployment-time source attestation",
            "Verify deployed source closure matches reviewed source",
        ]
        offsets = [self.deploy.index("      - name: " + name) for name in names]
        self.assertEqual(offsets, sorted(offsets))
        self.assertIn("subject-path: target-source-manifest.json", self.deploy)
        self.assertIn("predicate-path: signing-predicate.json", self.deploy)
        self.assertIn("jq -e '.predicate' deployment-source-predicate.json > signing-predicate.json", self.deploy)

    def test_fail_closed_and_truthful_evidence(self):
        """Never upgrade attestation-only evidence to recovered-source VERIFIED."""
        self.assertIn('[[ "$source_status" == VERIFIED || "$source_status" == VERIFIED_BY_ATTESTATION ]]', self.deploy)
        self.assertIn("status: $source_status", self.deploy)
        self.assertIn('deployedSourceClosureSha256: (if $live_closure == "" then null else $live_closure end)', self.deploy)
        self.assertIn('if [[ "$source_status" == VERIFIED ]]; then', self.deploy)

    def test_release_separation_and_baseline(self):
        """Keep the existing release guard and separate certification path."""
        self.assertIn("inputs.deploy == true && inputs.certify_existing != true", self.workflow)
        self.assertIn("inputs.certify_existing == true && inputs.deploy == false", self.workflow)
        self.assertIn('EXPECTED_LIVE_VERSION: "18"', self.workflow)
        self.assertIn('CERTIFIED_DEPLOY_VERSION: "19"', self.workflow)


if __name__ == "__main__":
    unittest.main()
