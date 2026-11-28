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

    def test_canonical_deno_runtime_precedes_local_readiness(self):
        """Prevent a future preflight from skipping mandatory Point23 probes."""
        workflow = WORKFLOW.read_text()
        canonical_ci = (ROOT / ".github/workflows/migration-ci.yml").read_text()
        deno_action = (
            "uses: denoland/setup-deno@"
            "ff4860f9d7236f320afa0f82b7e6457384805d05"
        )
        local_gate = (
            "- name: Prove exact Git baseline + full local clean migration "
            "replay and contracts"
        )
        self.assertIn(deno_action, canonical_ci)
        self.assertIn(deno_action, workflow)
        self.assertIn("deno-version: v2.x", workflow)
        self.assertLess(workflow.index("name: Set up pinned Supabase CLI"),
                        workflow.index(deno_action))
        self.assertLess(workflow.index(deno_action), workflow.index(local_gate))
        self.assertEqual(workflow.count(deno_action), 1)

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

    def test_apply_forward_guards_are_active_yaml(self):
        original = WORKFLOW.read_text()
        for old, replacement in (
            ("if: inputs.mode == 'apply-forward'\n        shell: bash\n        run: |\n          set -euo pipefail\n          test \"$GENIE_QA_APPROVAL_PHRASE\" = 'AUTHORIZE-GENIE-QA-FORWARD-APPLY'",
             "if: inputs.mode == 'apply-forward' || inputs.mode == 'preflight'\n        shell: bash\n        run: |\n          set -euo pipefail\n          test \"$GENIE_QA_APPROVAL_PHRASE\" = 'AUTHORIZE-GENIE-QA-FORWARD-APPLY'"),
            ("if: inputs.mode == 'preflight' || inputs.mode == 'apply'", "if: inputs.mode == 'preflight'"),
            ("test \"$GENIE_QA_APPROVAL_PHRASE\" = 'AUTHORIZE-GENIE-QA-FORWARD-APPLY'",
             "test \"$GENIE_QA_APPROVAL_PHRASE\" = 'AUTHORIZE-GENIE-QA-CANONICAL-BOOTSTRAP'"),
            ("GENIE_QA_FORWARD_LEDGER_NOT_A_PREFIX", "GENIE_QA_FORWARD_LEDGER_IGNORED"),
            ("GENIE_QA_FORWARD_LEDGER_COUNT: ${{ inputs.qa_ledger_count }}",
             "GENIE_QA_FORWARD_LEDGER_COUNT: \"516\""),
            ("options: [preflight, apply, preflight-forward, apply-forward]", "options: [preflight, apply, preflight-forward, apply-forward, production]"),
        ):
            with self.subTest(old=old[:60]):
                self.assertIn(old, original)
                result = self.validate(original.replace(old, replacement, 1))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("GENIE_QA_WORKFLOW_DENIED", result.stderr)

    def test_extra_schema_write_step_rejected(self):
        original = WORKFLOW.read_text()
        extra = (
            "\n      - name: Unreviewed schema write\n        shell: bash\n"
            "        run: supabase db " + "push --db-url \"$GENIE_QA_DATABASE_URL\" --yes\n"
        )
        result = self.validate(original.rstrip("\n") + extra)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected schema-write step", result.stderr)


if __name__ == "__main__":
    unittest.main()
