#!/usr/bin/env python3
"""Negative contract tests: QA MSG91 Edge deployment cannot bypass review gates."""
from pathlib import Path
import hashlib
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

    def test_workflow_sha256_is_pinned_to_the_guard(self):
        digest = hashlib.sha256(WORKFLOW.read_bytes()).hexdigest()
        self.assertIn("workflow_sha256 = '" + digest + "'", CHECK.read_text())

    def test_qa_release_files_are_explicitly_code_owned(self):
        owners = (ROOT / ".github/CODEOWNERS").read_text()
        required = (
            ".github/CODEOWNERS",
            ".github/workflows/genie-qa-msg91-edge-commission.yml",
            "scripts/genie-qa/verify_msg91_qa_edge_workflow.rb",
            "scripts/genie-qa/verify_msg91_secret_inventory.py",
            "scripts/tests/test_genie_qa_msg91_edge_workflow.py",
            "scripts/tests/test_genie_qa_secret_inventory.py",
        )
        for path in required:
            with self.subTest(path=path):
                self.assertIn(
                    "/" + path + " @oasisbaklawa2006 @dineshmutrejabackup-cmd",
                    owners,
                )

    def test_critical_security_guards_fail_closed(self):
        original = WORKFLOW.read_text()
        mutations = (
            ("  workflow_dispatch:", "  push:\n    branches: [main]\n  workflow_dispatch:"),
            ("environment: genie-qa-bootstrap", "# environment: genie-qa-bootstrap"),
            ("QA_PROJECT_REF: skhpmltfjgqitntkmclb", "QA_PROJECT_REF: wrong-project"),
            ("if: inputs.mode == 'deploy'", "if: inputs.mode == 'deploy' || inputs.mode == 'preflight'"),
            ("PGSSLMODE=verify-full", "PGSSLMODE=require"),
            ('guard.validate_target(os.environ.get("QA_DATABASE_URL", ""), mode="apply")',
             'guard.validate_target(os.environ.get("QA_DATABASE_URL", ""), mode="preflight")'),
            ("516|1|0|1|1|1|0|0|true|false|false",
             "516|1|0|1|1|1|0|1|true|false|false"),
            ("python3 scripts/genie-qa/verify_msg91_secret_inventory.py",
             "python3 scripts/genie-qa/accept_unvalidated_inventory.py"),
            ("GENIE_QA_EDGE_ALREADY_EXISTS_STOP_FOR_RECONCILIATION",
             "GENIE_QA_IGNORE_EXISTING_FUNCTIONS"),
            ('--project-ref "$QA_PROJECT_REF" --no-verify-jwt',
             '--project-ref "wrong-project" --no-verify-jwt'),
            ('test "$current_main" = "$EXPECTED_SHA"', "true"),
            ('test "$current_main" = "$EXPECTED_SHA"',
             '# test "$current_main" = "$EXPECTED_SHA"'),
            ('test "$QA_EDGE_APPROVAL" = \x27AUTHORIZE-GENIE-QA-MSG91-EDGE-DEPLOY\x27',
             '# test "$QA_EDGE_APPROVAL" = \x27AUTHORIZE-GENIE-QA-MSG91-EDGE-DEPLOY\x27'),
            ('      - name: Refuse provider credentials and any pre-existing QA Edge functions',
             '      - name: Refuse provider credentials and any pre-existing QA Edge functions\n        if: false'),
            ('      - name: Verify strict direct QA TLS and commissioned no-egress schema',
             '      - name: Verify strict direct QA TLS and commissioned no-egress schema\n        continue-on-error: true'),
            ('      - name: Refuse provider credentials and any pre-existing QA Edge functions',
             '      - name: Refuse provider credentials and any pre-existing QA Edge functions\n        continue-on-error: true'),
            ("          echo 'GENIE_QA_MSG91_SCHEMA_PARITY_PASS'",
             "          # echo 'GENIE_QA_MSG91_SCHEMA_PARITY_PASS'"),
            ("             || '|' || (SELECT count(*)::int FROM auth.sessions)::text",
             "             || '|' || (SELECT count(*)::int FROM auth.identities)::text"),
        )
        for old, new in mutations:
            with self.subTest(security_control=old):
                self.assertIn(old, original)
                result = self.validate(original.replace(old, new, 1))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("GENIE_QA_MSG91_EDGE_WORKFLOW_DENIED", result.stderr)

    def test_provider_secret_preflight_and_deploy_step_remain_separate(self):
        source = WORKFLOW.read_text()
        self.assertIn("https://api.supabase.com/v1/projects/$QA_PROJECT_REF/secrets", source)
        self.assertIn("verify_msg91_secret_inventory.py", source)
        self.assertIn("GENIE_QA_BRIDGE_DEPLOY_FAILED_PARTIAL_STATE_STOP", source)
        self.assertEqual(source.count("supabase functions deploy "), 2)
        self.assertIn("if: inputs.mode == 'deploy'", source)
        self.assertNotIn("tcxvcatsqqertcnycuop", source)


if __name__ == "__main__":
    unittest.main()
