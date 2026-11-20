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

if __name__ == "__main__":
    unittest.main()
