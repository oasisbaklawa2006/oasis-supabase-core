#!/usr/bin/env python3
"""Negative contract tests: QA MSG91 Edge deployment cannot bypass review gates."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/genie-qa-msg91-edge-commission.yml"
CHECK = ROOT / "scripts/genie-qa/verify_msg91_qa_edge_workflow.rb"


class QaMsg91ProtectedWorkflowTests(unittest.TestCase):
    def validate(self, raw: str) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as tmp:
            doc = Path(tmp) / "edge.yml"
            doc.write_text(raw, encoding="utf-8")
            return subprocess.run(
                ["ruby", str(CHECK), str(doc)],
                capture_output=True, text=True, check=False,
            )

    def test_exact_qa_release_workflow_passes(self):
        result = self.validate(WORKFLOW.read_text())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("GENIE_QA_MSG91_EDGE_WORKFLOW_PASS", result.stdout)

    def test_critical_security_guards_fail_closed(self):
        original = WORKFLOW.read_text()
        mutations = (
            ("  workflow_dispatch:", "  push:\n    branches: [main]\n  workflow_dispatch:"),
            ("environment: genie-qa-bootstrap", "# environment: genie-qa-bootstrap"),
            ("QA_PROJECT_REF: skhpmltfjgqitntkmclb",
             "QA_PROJECT_REF: tcxvcatsqqertcnycuop"),
            ("if: inputs.mode == 'deploy'",
             "if: inputs.mode == 'deploy' || inputs.mode == 'preflight'"),
            ("PGSSLMODE=verify-full", "PGSSLMODE=require"),
            ('guard.validate_target(os.environ.get("QA_DATABASE_URL", ""), mode="apply")',
             'guard.validate_target(os.environ.get("QA_DATABASE_URL", ""), mode="preflight")'),
            ("test \"$state\" = '516|1|0|1|true|false|false'",
             "test \"$state\" = '516|1|0|1|true|true|false'"),
            ("grep -Fxq 'MSG91_AUTH_KEY'", "grep -Fxq 'NONEXISTENT_QA_KEY'"),
            ("GENIE_QA_EDGE_ALREADY_EXISTS_STOP_FOR_RECONCILIATION",
             "GENIE_QA_IGNORE_EXISTING_FUNCTIONS"),
            ("--project-ref \"$QA_PROJECT_REF\" --no-verify-jwt",
             "--project-ref \"tcxvcatsqqertcnycuop\" --no-verify-jwt"),
            ("test \"$current_main\" = \"$EXPECTED_SHA\"", "true"),
            ("test \"$QA_EDGE_APPROVAL\" = 'AUTHORIZE-GENIE-QA-MSG91-EDGE-DEPLOY'",
             "true"),
        )
        for old, new in mutations:
            with self.subTest(security_control=old):
                self.assertIn(old, original)
                broken = original.replace(old, new, 1)
                result = self.validate(broken)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("GENIE_QA_MSG91_EDGE_WORKFLOW_DENIED", result.stderr)

    def test_provider_secret_preflight_and_deploy_step_must_remain_separate(self):
        source = WORKFLOW.read_text()
        self.assertIn("supabase secrets list --project-ref \"$QA_PROJECT_REF\"", source)
        self.assertIn("GENIE_QA_EDGE_PROVIDER_KEY_PRESENT_BLOCKS_INERT_DEPLOY", source)
        self.assertIn("GENIE_QA_BRIDGE_DEPLOY_FAILED_PARTIAL_STATE_STOP", source)
        self.assertEqual(source.count("supabase functions deploy "), 2)
        self.assertIn("if: inputs.mode == 'deploy'", source)
        self.assertNotIn("tcxvcatsqqertcnycuop", source)


if __name__ == "__main__":
    unittest.main()
