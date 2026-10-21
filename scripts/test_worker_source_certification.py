#!/usr/bin/env python3
"""Regression tests for fail-closed deployed Edge Function source verification."""
import json
import os
import runpy
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "scripts/edge-function-source-manifest.py"
VERIFY = ROOT / "scripts/verify-deployed-edge-function-source-closure.sh"
TYPE_PATH = "whatsapp-content-interpret/types.ts"

class SourceVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.reviewed = self.base / "reviewed"
        self.api = self.base / "api"
        self.prov = self.base / "provenance"
        for root in (self.reviewed, self.api, self.prov):
            (root / "worker").mkdir(parents=True)
            (root / "whatsapp-content-interpret").mkdir()
        self.put(self.reviewed, "worker/index.ts",
                 'import { run } from "../whatsapp-content-interpret/sanitize.ts";\nrun();\n')
        self.put(self.reviewed, "whatsapp-content-interpret/sanitize.ts",
                 'import type { SourceKind } from "./types.ts";\nexport function run(): void {}\n')
        self.put(self.reviewed, TYPE_PATH, 'export type SourceKind = "text";\n')
        self.manifest = self.base / "target.json"
        old_argv = __import__("sys").argv
        try:
            __import__("sys").argv = [str(MANIFEST), str(self.reviewed), "worker",
                                      "--output", str(self.manifest)]
            runpy.run_path(str(MANIFEST), run_name="__main__")
        finally:
            __import__("sys").argv = old_argv
        for path in ("worker/index.ts", "whatsapp-content-interpret/sanitize.ts"):
            self.put(self.api, path, (self.reviewed / path).read_text())
        self.output = self.base / "live.json"

    @staticmethod
    def put(root, path, value):
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(value)

    def verify(self, provenance=False):
        # Test-only, fixed command shape: no shell interpolation or untrusted arguments.
        args = [str(self.api), "worker", str(self.manifest), str(self.output)]
        if provenance:
            args.append(str(self.prov))
        return subprocess.run(("/usr/bin/bash", str(VERIFY), *args), cwd=ROOT,
                              text=True, capture_output=True, check=False,
                              env={"PATH": os.defpath, "HOME": str(self.base)})

    def test_erased_type_only_is_indeterminate(self):
        result = self.verify()
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertIn("TYPE_ONLY_SOURCE_OMISSION", result.stderr)
        self.assertNotIn("DEPLOYED_SOURCE_CLOSURE_VERIFIED", result.stdout)

    def test_wrong_live_runtime_bytes_fail(self):
        self.put(self.api, "whatsapp-content-interpret/sanitize.ts",
                 "export function run(): void { throw Error('changed'); }\n")
        result = self.verify()
        self.assertEqual(result.returncode, 1)
        self.assertIn("DEPLOYED_SOURCE_MISMATCH", result.stderr)

    def test_independent_provenance_can_complete_full_closure(self):
        self.put(self.prov, "worker/index.ts", (self.reviewed / "worker/index.ts").read_text())
        self.put(self.prov, TYPE_PATH, (self.reviewed / TYPE_PATH).read_text())
        result = self.verify(provenance=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("DEPLOYED_SOURCE_CLOSURE_VERIFIED", result.stdout)
        self.assertEqual(json.loads(self.output.read_text())["closureSha256"],
                         json.loads(self.manifest.read_text())["closureSha256"])

    def test_wrong_independent_type_bytes_fail(self):
        self.put(self.prov, "worker/index.ts", (self.reviewed / "worker/index.ts").read_text())
        self.put(self.prov, TYPE_PATH, 'export type SourceKind = "tampered";\n')
        result = self.verify(provenance=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("DEPLOYED_SOURCE_MISMATCH", result.stderr)

if __name__ == "__main__":
    unittest.main()
