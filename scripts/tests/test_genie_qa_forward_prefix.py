#!/usr/bin/env python3
"""Behavioural proof of the apply-forward ledger prefix gate, run against a stub psql (no database, no network)."""
import os
import pathlib
import stat
import subprocess
import tempfile
import unittest

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/genie-qa-canonical-bootstrap.yml"
STEP = "Prove QA ledger is an exact prefix of the reviewed sequence (forward mode only)"


def step_script() -> str:
    doc = yaml.safe_load(WORKFLOW.read_text())
    return next(s["run"] for s in doc["jobs"]["schema"]["steps"] if s["name"] == STEP)


class ForwardPrefixGateTests(unittest.TestCase):
    SOURCE = [f"2026010100{n:04d}" for n in range(1, 121)]  # 120 reviewed source versions (gate requires 3-4 digit counts)

    def run_gate(self, recorded, *, count="100", maximum=None, total="120", source=None):
        source = self.SOURCE if source is None else source
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            migrations = tmp / "overlay" / "supabase" / "migrations"
            migrations.mkdir(parents=True)
            for version in source:
                (migrations / f"{version}_m.sql").write_text("select 1;\n")
            bindir = tmp / "bin"
            bindir.mkdir()
            ledger = tmp / "ledger.txt"
            ledger.write_text("".join(f"{v}\n" for v in recorded))
            stub = bindir / "psql"
            stub.write_text(f"#!/bin/bash\ncat {ledger}\n")
            stub.chmod(stub.stat().st_mode | stat.S_IEXEC)
            env = {
                **os.environ,
                "PATH": f"{bindir}:{os.environ['PATH']}",
                "SUPABASE_WORKDIR": str(tmp / "overlay"),
                "RUNNER_TEMP": str(tmp),
                "GENIE_QA_DATABASE_URL": "postgresql://stub",
                "GENIE_QA_FORWARD_LEDGER_COUNT": count,
                "GENIE_QA_FORWARD_LEDGER_MAX": maximum or (self.SOURCE[int(count) - 1] if count.isdigit() and 0 < int(count) <= len(self.SOURCE) else "20260101009999"),
                "GENIE_QA_FORWARD_TOTAL": total,
            }
            return subprocess.run(["bash", "-c", step_script()], env=env, capture_output=True, text=True)

    def test_exact_prefix_passes(self):
        result = self.run_gate(self.SOURCE[:100])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("GENIE_QA_FORWARD_LEDGER_PREFIX_PROVEN", result.stdout)

    def test_gap_in_ledger_is_not_a_prefix(self):
        recorded = self.SOURCE[:50] + self.SOURCE[51:101]  # same length, one version missing and one extra
        result = self.run_gate(recorded)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("GENIE_QA_FORWARD_LEDGER_NOT_A_PREFIX", result.stderr + result.stdout)

    def test_ledger_with_unknown_version_fails(self):
        recorded = self.SOURCE[:99] + ["20260101999999"]
        result = self.run_gate(recorded)
        self.assertNotEqual(result.returncode, 0)

    def test_declared_max_must_match(self):
        result = self.run_gate(self.SOURCE[:100], maximum=self.SOURCE[98])
        self.assertNotEqual(result.returncode, 0)

    def test_total_must_match_source(self):
        result = self.run_gate(self.SOURCE[:100], total="121")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("GENIE_QA_FORWARD_SOURCE_COUNT_MISMATCH", result.stderr + result.stdout)

    def test_nothing_to_apply_fails(self):
        result = self.run_gate(self.SOURCE, count="120", total="120")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("GENIE_QA_FORWARD_NOTHING_TO_APPLY", result.stderr + result.stdout)

    def test_malformed_inputs_fail(self):
        for count in ("", "10x", "0100"):
            with self.subTest(count=count):
                self.assertNotEqual(self.run_gate(self.SOURCE[:100], count=count).returncode, 0)

    def test_duplicate_source_version_fails(self):
        duplicated = self.SOURCE[:119] + [self.SOURCE[118]]
        # Two files may share a version prefix with different names; the gate must treat that as a hard failure.
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            migrations = tmp / "overlay" / "supabase" / "migrations"
            migrations.mkdir(parents=True)
            for index, version in enumerate(duplicated):
                (migrations / f"{version}_m{index}.sql").write_text("select 1;\n")
            bindir = tmp / "bin"
            bindir.mkdir()
            stub = bindir / "psql"
            stub.write_text("#!/bin/bash\ntrue\n")
            stub.chmod(stub.stat().st_mode | stat.S_IEXEC)
            env = {**os.environ, "PATH": f"{bindir}:{os.environ['PATH']}", "SUPABASE_WORKDIR": str(tmp / "overlay"),
                   "RUNNER_TEMP": str(tmp), "GENIE_QA_DATABASE_URL": "postgresql://stub",
                   "GENIE_QA_FORWARD_LEDGER_COUNT": "100", "GENIE_QA_FORWARD_LEDGER_MAX": self.SOURCE[99],
                   "GENIE_QA_FORWARD_TOTAL": "120"}
            result = subprocess.run(["bash", "-c", step_script()], env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("GENIE_QA_FORWARD_SOURCE_VERSION_DUPLICATE", result.stderr + result.stdout)


if __name__ == "__main__":
    unittest.main()
