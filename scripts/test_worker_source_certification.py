#!/usr/bin/env python3
"""Regression tests for fail-closed deployed Edge Function source verification."""
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "scripts/edge-function-source-manifest.py"
VERIFY = ROOT / "scripts/verify-deployed-edge-function-source-closure.sh"
TYPE_PATH = "whatsapp-content-interpret/types.ts"

# Resolve bash to a fully-qualified path once, rather than passing the
# literal "bash" (a partial path Bandit's B607 flags). sys.executable is
# already fully-qualified for the interpreter running this test.
BASH = shutil.which("bash") or "/usr/bin/bash"

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
        # Fully-qualified interpreter path, literal script path, fixed flags,
        # and arguments drawn only from this test's own TemporaryDirectory:
        # no shell, no untrusted input, nothing dynamic in the command name.
        subprocess.run(  # noqa: S603 -- shell=False (default); see module docstring
            [sys.executable, str(MANIFEST), str(self.reviewed), "worker",
             "--output", str(self.manifest)],
            cwd=ROOT, check=True,
        )
        for path in ("worker/index.ts", "whatsapp-content-interpret/sanitize.ts"):
            self.put(self.api, path, (self.reviewed / path).read_text())
        self.output = self.base / "live.json"

    @staticmethod
    def put(root, path, value):
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(value)

    def verify(self, provenance=False):
        # Same fixed-command shape as setUp: fully-qualified executable,
        # literal script path, arguments confined to this test's own
        # TemporaryDirectory. No shell, no untrusted input.
        cmd = [BASH, str(VERIFY), str(self.api), "worker",
               str(self.manifest), str(self.output)]
        if provenance:
            cmd.append(str(self.prov))
        return subprocess.run(cmd, cwd=ROOT, text=True, capture_output=True)  # noqa: S603

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
