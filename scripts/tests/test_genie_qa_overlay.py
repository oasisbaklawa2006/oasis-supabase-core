#!/usr/bin/env python3
"""Offline negative tests for the exact-fingerprint QA-only migration overlay."""
import importlib.util
from pathlib import Path
import sys
import unittest

source = Path(__file__).resolve().parents[1] / "genie-qa" / "build_no_egress_overlay.py"
sys.path.insert(0, str(source.parent))
spec = importlib.util.spec_from_file_location("genie_qa_overlay", source)
overlay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(overlay)

BASE = (
    b'CREATE SCHEMA public;\n' +
    overlay.EGRESS_INSTALLS[0] + b'\n' +
    overlay.EGRESS_INSTALLS[1] + b'\n' +
    b'CREATE TABLE public.checkpoint(id int);\n'
)

class OverlaySafetyTests(unittest.TestCase):
    def test_qa_scratch_config_is_pinned_without_changing_other_settings(self):
        original = overlay.PRODUCTION_CONFIG_HEADER + b"\n[api]\nenabled = true\n"
        expected = overlay.QA_CONFIG_HEADER + b"\n[api]\nenabled = true\n"
        self.assertEqual(overlay.pin_qa_config(original), expected)
        self.assertNotIn(overlay.PRODUCTION_CONFIG_HEADER, overlay.pin_qa_config(original))

    def test_rejects_unknown_or_ambiguous_project_config(self):
        valid = overlay.PRODUCTION_CONFIG_HEADER + b"\n[api]\nenabled = true\n"
        for bad in (
            valid.replace(overlay.PRODUCTION_CONFIG_HEADER, overlay.QA_CONFIG_HEADER),
            valid.replace(overlay.PRODUCTION_CONFIG_HEADER, b'project_id = "foreign"'),
            valid + overlay.PRODUCTION_CONFIG_HEADER + b"\n",
            b"\n" + valid,
        ):
            with self.subTest(raw=bad[:70]):
                with self.assertRaisesRegex(ValueError, "config|binding"):
                    overlay.pin_qa_config(bad)

    def test_strips_exactly_two_extensions_from_known_source(self):
        cleaned = overlay.remove_baseline_egress(
            BASE, expected_blob=overlay.blob_hash(BASE)
        )
        self.assertNotIn(b"CREATE EXTENSION", cleaned)
        self.assertEqual(cleaned.count(b"-- QA-ONLY NO-EGRESS"), 2)
        self.assertIn(b"CREATE TABLE public.checkpoint", cleaned)

    def test_refuses_modified_canonical_baseline(self):
        with self.assertRaisesRegex(ValueError, "fingerprint mismatch"):
            overlay.remove_baseline_egress(BASE + b"-- altered")

    def test_refuses_removed_or_duplicate_install(self):
        for bad in (
            BASE.replace(overlay.EGRESS_INSTALLS[0], b""),
            BASE + overlay.EGRESS_INSTALLS[0],
            BASE.replace(overlay.EGRESS_INSTALLS[1], b""),
        ):
            with self.subTest(length=len(bad)):
                with self.assertRaisesRegex(ValueError, "exactly one"):
                    overlay.remove_baseline_egress(
                        bad, expected_blob=overlay.blob_hash(bad)
                    )

    def test_does_not_erase_unrecognized_outbound_install(self):
        extra = BASE + b'CREATE EXTENSION IF NOT EXISTS "http";\n'
        cleaned = overlay.remove_baseline_egress(
            extra, expected_blob=overlay.blob_hash(extra)
        )
        self.assertIn(b'CREATE EXTENSION IF NOT EXISTS "http"', cleaned)

    def test_does_not_change_other_sql(self):
        cleaned = overlay.remove_baseline_egress(
            BASE, expected_blob=overlay.blob_hash(BASE)
        )
        self.assertTrue(cleaned.startswith(b"CREATE SCHEMA public;"))
        self.assertTrue(cleaned.endswith(b"CREATE TABLE public.checkpoint(id int);\n"))

if __name__ == "__main__":
    unittest.main()
