#!/usr/bin/env python3
"""Offline forward recovery controls; never connect to a database."""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/genie-qa-canonical-bootstrap.yml"
VALIDATOR = ROOT / "scripts/genie-qa/verify_protected_workflow.rb"


class ForwardRecoveryTests(unittest.TestCase):
    def test_scripts_parse(self):
        for name in ("capture_forward_backup.sh", "forward_preservation.sh", "install_pg17_client.sh"):
            subprocess.run(["bash", "-n", str(ROOT / "scripts/genie-qa" / name)], check=True)

    def test_workflow_protection_rejects_missing_backup(self):
        raw = WORKFLOW.read_text()
        mutations = [
            ("if-no-files-found: error", "if-no-files-found: warn"),
            ("runs-on: ubuntu-24.04", "runs-on: ubuntu-latest"),
            ("env -u GENIE_QA_DATABASE_URL -u GENIE_QA_CA_CERT_PEM bash scripts/genie-qa/install_pg17_client.sh", "true"),
            ("backup.tar.gpg.sha256", "database.dump"),
            ("QA_REVIEWED_BASELINE_CHANGED", "QA_REVIEWED_BASELINE_IGNORED"),
            ("bash scripts/genie-qa/capture_forward_backup.sh", "true"),
            ("permissions:\n", "continue-on-error: true\npermissions:\n"),
            ("  schema:\n", "  schema:\n    continue-on-error: true\n"),
            ("id: forward_backup_upload\n", "id: forward_backup_upload\n        continue-on-error: true\n"),
            ("- name: Capture encrypted QA recovery archive and preservation baseline\n",
             "- name: Capture encrypted QA recovery archive and preservation baseline\n        continue-on-error: true\n"),
            ("- name: Verify recovery archive retention and unchanged protected data\n",
             "- name: Verify recovery archive retention and unchanged protected data\n        continue-on-error: true\n"),
            ("- name: Verify protected data survived forward apply\n",
             "- name: Verify protected data survived forward apply\n        continue-on-error: true\n"),
            ("        id: forward_apply\n", ""),
            ("id: forward_apply\n", "id: renamed_apply\n"),
            (" || steps.forward_apply.outcome == 'cancelled'", ""),
            ("steps.forward_apply.outcome == 'cancelled'", "steps.forward_apply.outcome == 'skipped'"),
            ('test "$actual" = "$GENIE_QA_VERIFIED_STATE_SHA256" ||',
             "true ||"),
            ('actual="$(sha256sum "$RUNNER_TEMP/qa-preservation-before.json" | cut -d \' \' -f1)"',
             'actual="$GENIE_QA_VERIFIED_STATE_SHA256"'),
            ('if [[ "$GENIE_QA_RUN_MODE" == apply-forward ]]; then',
             'if [[ "$GENIE_QA_RUN_MODE" == preflight-forward ]]; then'),
            ('[[ "$QA_ARTIFACT_ID" =~ ^[1-9][0-9]*$ ]] ||', "true ||"),
            ('[[ "$QA_ARTIFACT_DIGEST" =~ ^(sha256:)?[0-9a-f]{64}$ ]] ||', "true ||"),
            ("id: forward_backup_upload", "id: renamed_upload"),
        ]
        with tempfile.TemporaryDirectory() as folder:
            target = pathlib.Path(folder) / "workflow.yml"
            target.write_text(raw)
            accepted = subprocess.run(["ruby", str(VALIDATOR), str(target)], capture_output=True, text=True)
            self.assertEqual(accepted.returncode, 0, accepted.stderr)
            self.assertIn("GENIE_QA_PROTECTED_WORKFLOW_PASS", accepted.stdout)
            for before, after in mutations:
                with self.subTest(before=before):
                    self.assertIn(before, raw)
                    target.write_text(raw.replace(before, after, 1))
                    result = subprocess.run(["ruby", str(VALIDATOR), str(target)], capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("GENIE_QA_WORKFLOW_DENIED", result.stderr)

    def test_forward_preflight_is_direct_only_and_nonmutating(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("qa_target", ROOT / "scripts/genie-qa/verify_qa_target.py")
        guard = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(guard)
        env = {
            "GENIE_QA_PROJECT_REF": guard.QA_PROJECT_REF,
            "GENIE_QA_RUN_MODE": "preflight-forward",
            "GENIE_QA_EXPECTED_SHA": "a" * 40,
            "GENIE_QA_CHANGE_REFERENCE": "Core#495/Buyer#74 forward preflight",
            "GENIE_QA_DATABASE_URL": "postgresql://postgres:synthetic@db." + guard.QA_PROJECT_REF + ".supabase.co:5432/postgres",
            "GENIE_QA_FORWARD_LEDGER_COUNT": "516",
            "GENIE_QA_FORWARD_LEDGER_MAX": "20261119200100",
            "GENIE_QA_FORWARD_TOTAL": "533",
        }
        guard.validate_invocation(env)
        with self.assertRaises(ValueError):
            guard.validate_invocation({**env, "GENIE_QA_FORWARD_LEDGER_COUNT": ""})
        with self.assertRaises(ValueError):
            guard.validate_invocation({**env, "GENIE_QA_RUN_MODE": "apply-forward",
                "GENIE_QA_APPROVAL_PHRASE": guard.FORWARD_APPROVAL_PHRASE})
