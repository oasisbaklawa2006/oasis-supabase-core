#!/usr/bin/env python3
"""Negative tests for deployed QA Edge bundle stability certification."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "scripts/genie-qa/verify_msg91_bundle_provenance.py"
ONE = "1" * 64
TWO = "2" * 64


def payload(digest=ONE, slug="msg91-otp", status="ACTIVE"):
    return json.dumps({"slug": slug, "status": status, "ezbr_sha256": digest}).encode()


class BundleStabilityTests(unittest.TestCase):
    def run_gate(self, mode, slug, pin, before=None, after=None, metadata=None):
        cmd = [sys.executable, str(TOOL), "--mode", mode, "--slug", slug, "--pin", str(pin)]
        if before is not None:
            cmd.extend(["--before", str(before)])
        if after is not None:
            cmd.extend(["--after", str(after)])
        if metadata is not None:
            cmd.extend(["--metadata", str(metadata)])
        return subprocess.run(cmd, capture_output=True, text=True, check=False)

    def test_stable_download_recheck_and_final_metadata_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pin, first, last, final = (root / n for n in ("pin", "before.json", "after.json", "final.json"))
            for item in (first, last, final):
                item.write_bytes(payload())
            self.assertEqual(self.run_gate("capture", "msg91-otp", pin, first, last).returncode, 0)
            self.assertEqual(self.run_gate("capture", "msg91-otp", pin, first, last).returncode, 0)
            self.assertEqual(self.run_gate("final", "msg91-otp", pin, metadata=final).returncode, 0)
            self.assertEqual(pin.read_text(), ONE + "\n")

    def test_bundle_drift_during_download_denies(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            before, after, pin = root / "before", root / "after", root / "pin"
            before.write_bytes(payload())
            after.write_bytes(payload(TWO))
            result = self.run_gate("capture", "msg91-otp", pin, before, after)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("GENIE_QA_EDGE_BUNDLE_PROVENANCE_DENIED", result.stderr)
            self.assertFalse(pin.exists())

    def test_bundle_replacement_between_otp_attestations_denies(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pin, before, after = root / "pin", root / "before", root / "after"
            before.write_bytes(payload())
            after.write_bytes(payload())
            self.assertEqual(self.run_gate("capture", "msg91-otp", pin, before, after).returncode, 0)
            before.write_bytes(payload(TWO))
            after.write_bytes(payload(TWO))
            result = self.run_gate("capture", "msg91-otp", pin, before, after)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(pin.read_text(), ONE + "\n")

    def test_final_metadata_replacement_denies(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pin, before, after, final = root / "pin", root / "before", root / "after", root / "final"
            before.write_bytes(payload())
            after.write_bytes(payload())
            self.assertEqual(self.run_gate("capture", "msg91-otp", pin, before, after).returncode, 0)
            final.write_bytes(payload(TWO))
            self.assertNotEqual(self.run_gate("final", "msg91-otp", pin, metadata=final).returncode, 0)

    def test_invalid_metadata_fails_closed_without_leaks(self):
        cases = [
            b"", b"[]", b"{}", b"not-json",
            payload(slug="wrong"), payload(status="FAILED"),
            payload(digest=None), payload(digest="123"),
            b'{"slug":"msg91-otp","slug":"wrong","status":"ACTIVE","ezbr_sha256":"' + ONE.encode() + b'"}',
            b"x" * (1024 * 1024 + 1),
            b'{"slug":"msg91-otp","status":"ACTIVE","ezbr_sha256":"' + ONE.encode() + b'","other":NaN}',
            b'{"slug":"msg91-otp","status":"ACTIVE","ezbr_sha256":"' + ONE.encode() + b'","other":Infinity}',
            b'{"slug":"msg91-otp","status":"ACTIVE","ezbr_sha256":"' + ONE.encode() + b'","other":-Infinity}',
        ]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pin, before, after = root / "pin", root / "before", root / "after"
            after.write_bytes(payload())
            for raw in cases:
                with self.subTest(size=len(raw)):
                    before.write_bytes(raw)
                    result = self.run_gate("capture", "msg91-otp", pin, before, after)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("GENIE_QA_EDGE_BUNDLE_PROVENANCE_DENIED", result.stderr)
                    self.assertNotIn(ONE, result.stderr)


if __name__ == "__main__":
    unittest.main()
