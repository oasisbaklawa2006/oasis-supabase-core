#!/usr/bin/env python3
"""Regression tests: QA migration workflow security must be active YAML."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/genie-qa-canonical-bootstrap.yml"
CHECK = ROOT / "scripts/genie-qa/verify_protected_workflow.rb"


class WorkflowProtectionTests(unittest.TestCase):
    def validate(self, raw: str) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "release.yml"
            path.write_text(raw)
            return subprocess.run(
                ["ruby", str(CHECK), str(path)],
                check=False, capture_output=True, text=True,
            )

    def test_unmodified_protected_workflow_passes(self):
        result = self.validate(WORKFLOW.read_text())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("GENIE_QA_PROTECTED_WORKFLOW_PASS", result.stdout)

    def test_comment_and_expanded_apply_predicate_both_fail(self):
        original = WORKFLOW.read_text()
        for old, replacement in (
            ("environment: genie-qa-bootstrap",
             "# environment: genie-qa-bootstrap"),
            ("if: inputs.mode == 'apply'",
             "if: inputs.mode == 'apply' || inputs.mode == 'preflight'"),
            ("PGSSLMODE=verify-full", "PGSSLMODE=require"),
            ("GENIE_QA_PROJECT_REF: skhpmltfjgqitntkmclb",
             "GENIE_QA_PROJECT_REF: tcxvcatsqqertcnycuop"),
            ("env -u SUPABASE_WORKDIR -u PGSSLMODE -u PGSSLROOTCERT",
             "env -u SUPABASE_WORKDIR"),
            ("if: github.repository == 'oasisbaklawa2006/oasis-supabase-core' && github.ref == 'refs/heads/main'",
             "if: github.repository == 'oasisbaklawa2006/oasis-supabase-core'"),
        ):
            with self.subTest(old=old):
                self.assertIn(old, original)
                result = self.validate(original.replace(old, replacement, 1))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("GENIE_QA_WORKFLOW_DENIED", result.stderr)

    def test_nonmanual_trigger_rejected(self):
        original = WORKFLOW.read_text()
        self.assertIn("  workflow_dispatch:", original)
        changed = original.replace(
            "  workflow_dispatch:",
            "  push:\n    branches: [main]\n  workflow_dispatch:", 1,
        )
        result = self.validate(changed)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
