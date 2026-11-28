#!/usr/bin/env python3
"""Offline forward recovery controls; never connect to a database."""
import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/genie-qa-canonical-bootstrap.yml"
VALIDATOR = ROOT / "scripts/genie-qa/verify_protected_workflow.rb"


class ForwardRecoveryTests(unittest.TestCase):
    def test_scripts_parse(self):
        for name in ("capture_forward_backup.sh", "forward_preservation.sh"):
            subprocess.run(["bash", "-n", str(ROOT / "scripts/genie-qa" / name)], check=True)

    def test_workflow_protection_rejects_missing_backup(self):
        import tempfile
        raw = WORKFLOW.read_text()
        mutations = [
            ("if-no-files-found: error", "if-no-files-found: warn"),
            ("backup.tar.gpg.sha256", "database.dump"),
            ("QA_REVIEWED_BASELINE_CHANGED", "QA_REVIEWED_BASELINE_IGNORED"),
            ("bash scripts/genie-qa/capture_forward_backup.sh", "true"),
        ]
        with tempfile.TemporaryDirectory() as folder:
            target = pathlib.Path(folder) / "workflow.yml"
            for before, after in mutations:
                with self.subTest(before=before):
                    self.assertIn(before, raw)
                    target.write_text(raw.replace(before, after, 1))
                    result = subprocess.run(["ruby", str(VALIDATOR), str(target)], capture_output=True)
                    self.assertNotEqual(result.returncode, 0)

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
