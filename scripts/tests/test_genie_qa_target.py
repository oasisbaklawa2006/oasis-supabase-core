#!/usr/bin/env python3
"""Offline negative proof for Genie QA target and release authorization."""
import importlib.util
import pathlib
import unittest

script = pathlib.Path(__file__).resolve().parents[1] / "genie-qa" / "verify_qa_target.py"
spec = importlib.util.spec_from_file_location("genie_qa_guard", script)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

SAFE_URL = "postgresql://postgres:synthetic-password@db.skhpmltfjgqitntkmclb.supabase.co:5432/postgres"
POOLER_URL = (
    "postgresql://postgres.skhpmltfjgqitntkmclb:synthetic-password"
    "@aws-0-ap-south-1.pooler.supabase.com:5432/postgres"
)

VALID = {
    "GENIE_QA_PROJECT_REF": guard.QA_PROJECT_REF,
    "GENIE_QA_RUN_MODE": "preflight",
    "GENIE_QA_EXPECTED_SHA": "a" * 40,
    "GENIE_QA_CHANGE_REFERENCE": "Core#495/Buyer#74 QA bootstrap",
    "GENIE_QA_DATABASE_URL": SAFE_URL,
}

class GuardTests(unittest.TestCase):
    def test_valid_preflight(self):
        guard.validate_invocation(VALID)

    def test_apply_requires_specific_approval(self):
        with self.assertRaises(ValueError):
            guard.validate_invocation({**VALID, "GENIE_QA_RUN_MODE": "apply"})
        guard.validate_invocation({
            **VALID, "GENIE_QA_RUN_MODE": "apply",
            "GENIE_QA_APPROVAL_PHRASE": guard.APPROVAL_PHRASE,
        })

    def test_pooler_accepted_only_for_read_only_preflight(self):
        guard.validate_invocation({**VALID, "GENIE_QA_DATABASE_URL": POOLER_URL})
        with self.assertRaises(ValueError):
            guard.validate_invocation({
                **VALID,
                "GENIE_QA_DATABASE_URL": POOLER_URL,
                "GENIE_QA_RUN_MODE": "apply",
                "GENIE_QA_APPROVAL_PHRASE": guard.APPROVAL_PHRASE,
            })

    def test_pooler_rejects_other_projects_and_unsafe_endpoints(self):
        for bad in [
            POOLER_URL.replace(guard.QA_PROJECT_REF, guard.PRODUCTION_PROJECT_REF),
            POOLER_URL.replace(guard.QA_PROJECT_REF, "cojllopluhzcsfmxwjbj"),
            POOLER_URL.replace("postgres." + guard.QA_PROJECT_REF, "postgres"),
            POOLER_URL.replace("aws-0-ap-south-1", "aws-0-us-east-1"),
            POOLER_URL.replace("aws-0-ap-south-1", "aws-x-ap-south-1"),
            POOLER_URL.replace("pooler.supabase.com", "pooler.supabase.com.evil.test"),
            POOLER_URL.replace(":5432", ":6543"),
            POOLER_URL.replace("/postgres", "/wrong"),
            POOLER_URL + "?sslmode=disable",
            POOLER_URL + "?sslmode=require",
            POOLER_URL.replace("synthetic-password", ""),
            POOLER_URL + "\nother",
        ]:
            with self.subTest(bad=bad.replace("synthetic-password", "[redacted]")):
                with self.assertRaises(ValueError):
                    guard.validate_invocation({**VALID, "GENIE_QA_DATABASE_URL": bad})

    def test_target_is_pinned_to_new_standalone_project(self):
        for bad in [
            SAFE_URL.replace(guard.QA_PROJECT_REF, guard.PRODUCTION_PROJECT_REF),
            SAFE_URL.replace(guard.QA_PROJECT_REF, "cojllopluhzcsfmxwjbj"),
            SAFE_URL.replace(":5432", ":6543"),
            SAFE_URL.replace("/postgres", "/other"),
            SAFE_URL.replace("db.skhpmltfjgqitntkmclb.supabase.co", "db.skhpmltfjgqitntkmclb.supabase.co.evil.test"),
            SAFE_URL.replace("postgres:synthetic-password", "other:synthetic-password"),
            SAFE_URL.replace("postgres:synthetic-password", "postgres:"),
            SAFE_URL + "?sslmode=disable",
            SAFE_URL + "\nanything",
            "https://example.com",
            "",
        ]:
            with self.subTest(bad=bad.replace("synthetic-password", "[redacted]")):
                with self.assertRaises(ValueError):
                    guard.validate_invocation({**VALID, "GENIE_QA_DATABASE_URL": bad})

    def test_rejects_unauthorized_mode_and_unpinned_commit(self):
        for change in [
            {"GENIE_QA_RUN_MODE": "production"},
            {"GENIE_QA_EXPECTED_SHA": "main"},
            {"GENIE_QA_EXPECTED_SHA": ""},
            {"GENIE_QA_PROJECT_REF": guard.PRODUCTION_PROJECT_REF},
            {"GENIE_QA_CHANGE_REFERENCE": "unknown"},
        ]:
            with self.assertRaises(ValueError):
                guard.validate_invocation({**VALID, **change})

    def test_malformed_authority_does_not_expose_credentials(self):
        import os
        import subprocess
        import sys
        secret = "GENIE_QA_CANARY_DO_NOT_LOG"
        # Unicode fullwidth colon causes urlsplit() to fail before .port.
        malformed = (
            "postgresql://postgres:" + secret +
            "@db.skhpmltfjgqitntkmclb.supabase.co：5432/postgres"
        )
        with self.assertRaisesRegex(ValueError, "Malformed QA database authority") as caught:
            guard.validate_target(malformed)
        self.assertNotIn(secret, str(caught.exception))
        proc = subprocess.run(
            [sys.executable, str(script)],
            env={**os.environ, **VALID, "GENIE_QA_DATABASE_URL": malformed},
            capture_output=True, text=True, check=False,
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Malformed QA database authority", proc.stderr)
        self.assertNotIn(secret, proc.stdout + proc.stderr)
        self.assertNotIn("Traceback", proc.stderr)

    def test_local_gate_drops_only_remote_environment_overrides(self):
        workflow = (
            pathlib.Path(__file__).resolve().parents[2]
            / ".github/workflows/genie-qa-canonical-bootstrap.yml"
        ).read_text()
        self.assertIn(
            "env -u SUPABASE_WORKDIR -u PGSSLMODE -u PGSSLROOTCERT",
            workflow,
        )
        self.assertIn("PGSSLMODE=verify-full", workflow)
        self.assertIn('cd "$SUPABASE_WORKDIR"', workflow)

    def test_apply_forward_requires_its_own_phrase_and_exact_counts(self):
        forward = {
            **VALID, "GENIE_QA_RUN_MODE": "apply-forward",
            "GENIE_QA_APPROVAL_PHRASE": guard.FORWARD_APPROVAL_PHRASE,
            "GENIE_QA_FORWARD_LEDGER_COUNT": "516",
            "GENIE_QA_FORWARD_LEDGER_MAX": "20261119200100",
            "GENIE_QA_FORWARD_TOTAL": "528",
            "GENIE_QA_RECOVERY_REFERENCE": "Core#495:RECOVERY-VERIFIED:12345",
            "GENIE_QA_VERIFIED_STATE_SHA256": "b" * 64,
        }
        guard.validate_invocation(forward)
        for change in [
            {"GENIE_QA_APPROVAL_PHRASE": guard.APPROVAL_PHRASE},  # bootstrap phrase must not authorize forward
            {"GENIE_QA_APPROVAL_PHRASE": ""},
            {"GENIE_QA_FORWARD_LEDGER_COUNT": ""},
            {"GENIE_QA_FORWARD_LEDGER_COUNT": "51x"},
            {"GENIE_QA_FORWARD_TOTAL": "0528"},
            {"GENIE_QA_FORWARD_LEDGER_MAX": "2026111920010"},
            {"GENIE_QA_FORWARD_LEDGER_MAX": ""},
            {"GENIE_QA_RECOVERY_REFERENCE": ""},
            {"GENIE_QA_VERIFIED_STATE_SHA256": ""},
            {"GENIE_QA_FORWARD_LEDGER_COUNT": "528"},  # nothing pending
            {"GENIE_QA_FORWARD_LEDGER_COUNT": "529"},  # ledger ahead of source
            {"GENIE_QA_DATABASE_URL": POOLER_URL},  # pooler is read-only preflight only
            {"GENIE_QA_DATABASE_URL": SAFE_URL.replace(guard.QA_PROJECT_REF, guard.PRODUCTION_PROJECT_REF)},
        ]:
            with self.subTest(change=sorted(change)):
                with self.assertRaises(ValueError):
                    guard.validate_invocation({**forward, **change})

    def test_bootstrap_phrase_does_not_authorize_apply_and_forward_phrase_does_not_authorize_bootstrap(self):
        with self.assertRaises(ValueError):
            guard.validate_invocation({
                **VALID, "GENIE_QA_RUN_MODE": "apply",
                "GENIE_QA_APPROVAL_PHRASE": guard.FORWARD_APPROVAL_PHRASE,
            })

if __name__ == "__main__":
    unittest.main()
