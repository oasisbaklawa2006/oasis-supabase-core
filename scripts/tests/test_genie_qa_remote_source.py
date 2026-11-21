#!/usr/bin/env python3
"""Offline regression: only the exact QA overlaid source closure may pass."""
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
manifest_path = ROOT / "scripts/edge-function-source-manifest.py"
spec = importlib.util.spec_from_file_location("edge_function_manifest", manifest_path)
manifest_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest_module)

FUNCTIONS = ROOT / "supabase/functions"
STUB = ROOT / "scripts/genie-qa/inert_msg91_provider_verify.mjs"


def stage_function_tree(dest: Path) -> None:
    for directory in ("msg91-otp", "msg91-session-bridge", "_shared"):
        shutil.copytree(FUNCTIONS / directory, dest / directory)
    shutil.copy2(STUB, dest / "msg91-otp/provider-verify.mjs")


class QaRemoteClosureAttestationTests(unittest.TestCase):
    def test_actual_overlaid_closures_match_exact_downloaded_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            staged = Path(tmp) / "staged"
            remote = Path(tmp) / "remote"
            stage_function_tree(staged)
            shutil.copytree(staged, remote)
            for slug in ("msg91-otp", "msg91-session-bridge"):
                with self.subTest(slug=slug):
                    approved = manifest_module.build_manifest(staged, slug)
                    downloaded = manifest_module.build_manifest(remote, slug)
                    self.assertEqual(approved, downloaded)
                    self.assertIn(
                        "msg91-otp/provider-verify.mjs",
                        {f["path"] for f in approved["files"]},
                    )

    def test_provider_verifier_mismatch_denies_both_functions(self):
        with tempfile.TemporaryDirectory() as tmp:
            staged = Path(tmp) / "staged"
            remote = Path(tmp) / "remote"
            stage_function_tree(staged)
            shutil.copytree(staged, remote)
            path = remote / "msg91-otp/provider-verify.mjs"
            path.write_bytes(path.read_bytes() + b"\n// tampered after deploy\n")
            for slug in ("msg91-otp", "msg91-session-bridge"):
                with self.subTest(slug=slug):
                    self.assertNotEqual(
                        manifest_module.build_manifest(staged, slug),
                        manifest_module.build_manifest(remote, slug),
                    )

    def test_missing_provider_verifier_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            staged = Path(tmp) / "staged"
            stage_function_tree(staged)
            (staged / "msg91-otp/provider-verify.mjs").unlink()
            for slug in ("msg91-otp", "msg91-session-bridge"):
                with self.subTest(slug=slug):
                    with self.assertRaises(SystemExit):
                        manifest_module.build_manifest(staged, slug)


if __name__ == "__main__":
    unittest.main()
