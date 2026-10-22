#!/usr/bin/env python3
"""Execute the certify-existing source-evidence step against fixtures.

The certify-existing job is never run by pull-request CI, so this test lifts
the literal bash of its "Verify source deploy run and preflight rollback
evidence" step out of the workflow and runs it with GitHub's API stubbed. The
fixtures mirror what the pinned source deployment run's jobs produce.
"""
import json
import os
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/whatsapp-packet-ai-worker-production-release.yml"
STEP_NAME = "Verify source deploy run and preflight rollback evidence"
REPO = "oasisbaklawa2006/oasis-supabase-core"

FAKE_CURL = r"""#!/usr/bin/env bash
# Serve fixture files for the GitHub API URLs the step requests.
set -euo pipefail
out=""; url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -H) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
key="$(printf '%s' "$url" | sed -E 's#^https://api.github.com/repos/[^/]+/[^/]+/##; s#[^A-Za-z0-9]+#_#g')"
src="$FIXTURE_DIR/$key"
[[ -f "$src" ]] || { echo "fake curl: no fixture for $url ($key)" >&2; exit 22; }
cp "$src" "$out"
"""


def _fixture_key(path):
    """Mirror the fake curl's URL-to-filename mapping."""
    import re
    return re.sub(r"[^A-Za-z0-9]+", "_", path)


class CertifyExistingSourceEvidenceTest(unittest.TestCase):
    """Run the real step text against valid and adversarial evidence."""

    @classmethod
    def setUpClass(cls):
        """Extract the step script and the env it runs with."""
        workflow = yaml.safe_load(WORKFLOW.read_text())
        job = workflow["jobs"]["certify-existing"]
        steps = [s for s in job["steps"] if s.get("name") == STEP_NAME]
        assert len(steps) == 1, f"expected exactly one step named {STEP_NAME!r}"
        cls.script = steps[0]["run"]
        env = {k: str(v) for k, v in workflow["env"].items()}
        env.update({k: str(v) for k, v in job["env"].items() if not str(v).startswith("${{")})
        cls.job_env = env
        cls.release_sha = env["CERTIFICATION_RELEASE_SHA"]
        cls.run_id = env["CERTIFICATION_SOURCE_DEPLOY_RUN_ID"]
        cls.version = env["CERTIFICATION_DEPLOY_VERSION"]
        cls.bundle = env["CERTIFICATION_DEPLOY_BUNDLE_SHA"]
        cls.project = env["SUPABASE_PROJECT_REF"]
        cls.function = env["FUNCTION_NAME"]

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.work = self.tmp / "work"
        self.fixtures = self.tmp / "fixtures"
        self.bin = self.tmp / "bin"
        for d in (self.work, self.fixtures, self.bin):
            d.mkdir()
        (self.bin / "curl").write_text(FAKE_CURL)
        (self.bin / "curl").chmod(0o755)

        closure = "a220be24c6f233c92f1e5e16d21fe593071fe58d3d071e169c733d5564ab1b82"
        self.manifest_bytes = json.dumps(
            {"function": self.function, "fileCount": 6, "closureSha256": closure},
            indent=2).encode() + b"\n"
        # Rebuilt locally by the preceding "Bind certification" step.
        (self.work / "target-source-manifest.json").write_bytes(self.manifest_bytes)

        self.run = {
            "event": "workflow_dispatch",
            "name": "WhatsApp Packet AI Worker Production Release",
            "status": "completed", "conclusion": "success",
            "run_attempt": 1, "head_sha": self.release_sha,
        }
        self.preflight = {
            "target-source-manifest.json": self.manifest_bytes,
            "whatsapp-packet-ai-worker-preflight-attestation.json": {
                "status": "PREFLIGHT_VERIFIED", "runId": self.run_id, "runAttempt": "1",
                "releaseSha": self.release_sha, "projectRef": self.project,
                "function": self.function, "reviewedSourceClosureSha256": closure,
                "previousVersion": 19, "verifyJwt": True,
            },
        }
        self.deployment = {
            "target-source-manifest.json": self.manifest_bytes,
            "live-function-after.json": {
                "slug": self.function, "status": "ACTIVE",
                "version": int(self.version), "ezbr_sha256": self.bundle, "verify_jwt": True,
            },
            "whatsapp-packet-ai-worker-release-attestation.json": {
                "status": "VERIFIED_BY_ATTESTATION", "runId": self.run_id, "runAttempt": "1",
                "releaseSha": self.release_sha, "projectRef": self.project,
                "function": self.function, "previousVersion": 19,
                "deployedVersion": int(self.version), "deployedBundleSha256": self.bundle,
                "reviewedSourceClosureSha256": closure,
            },
            "whatsapp-packet-ai-worker-runtime-certification.txt": b"RUNTIME_CERTIFIED\n",
        }
        self.extra_artifacts = []

    # -- fixture assembly -------------------------------------------------

    @staticmethod
    def _zip(path, files):
        with zipfile.ZipFile(path, "w") as zf:
            for name, content in files.items():
                if isinstance(content, (dict, list)):
                    content = json.dumps(content).encode()
                zf.writestr(name, content)

    def _write_fixtures(self):
        runs = f"actions/runs/{self.run_id}"
        (self.fixtures / _fixture_key(runs)).write_text(json.dumps(self.run))
        artifacts = []
        for artifact_id, kind, files in ((101, "preflight", self.preflight),
                                         (202, "deployment", self.deployment)):
            if files is None:
                continue
            artifacts.append({
                "id": artifact_id, "expired": False,
                "name": f"whatsapp-packet-ai-worker-production-{kind}-{self.release_sha}-1",
            })
            self._zip(self.fixtures / _fixture_key(f"actions/artifacts/{artifact_id}/zip"), files)
        artifacts.extend(self.extra_artifacts)
        (self.fixtures / _fixture_key(f"{runs}/artifacts?per_page=100")).write_text(
            json.dumps({"artifacts": artifacts}))

    def _run_step(self):
        self._write_fixtures()
        env = dict(os.environ)
        env.update(self.job_env)
        env.update({
            "PATH": f"{self.bin}:{env['PATH']}",
            "FIXTURE_DIR": str(self.fixtures),
            "GITHUB_REPOSITORY": REPO,
            "GH_TOKEN": "fixture-token",
        })
        return subprocess.run(
            ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", self.script],
            cwd=self.work, env=env, capture_output=True, text=True, timeout=60)

    def assertAccepted(self):
        result = self._run_step()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assertRejected(self, marker=None):
        result = self._run_step()
        self.assertNotEqual(result.returncode, 0, "step accepted invalid evidence")
        if marker:
            self.assertIn(marker, result.stdout + result.stderr)

    # -- cases --------------------------------------------------------------

    def test_valid_pinned_evidence_is_accepted(self):
        self.assertAccepted()

    def test_failed_source_run_is_rejected(self):
        self.run["conclusion"] = "failure"
        self.assertRejected()

    def test_rerun_attempt_is_rejected(self):
        self.run["run_attempt"] = 2
        self.assertRejected()

    def test_wrong_release_commit_is_rejected(self):
        self.run["head_sha"] = "0" * 40
        self.assertRejected()

    def test_missing_deployment_artifact_is_rejected(self):
        self.deployment = None
        self.assertRejected()

    def test_duplicate_artifact_name_is_rejected(self):
        self.extra_artifacts.append({
            "id": 303, "expired": False,
            "name": f"whatsapp-packet-ai-worker-production-deployment-{self.release_sha}-1",
        })
        self.assertRejected()

    def test_path_traversal_entry_is_rejected_before_extraction(self):
        self.deployment["../escaped.txt"] = b"x"
        self.assertRejected("SOURCE_EVIDENCE_UNSAFE_ENTRY")
        self.assertFalse((self.work / "source-evidence" / "escaped.txt").exists())
        self.assertFalse((self.work / "escaped.txt").exists())

    def test_nested_entry_is_rejected(self):
        self.preflight["nested/target-source-manifest.json"] = self.manifest_bytes
        self.assertRejected("SOURCE_EVIDENCE_UNSAFE_ENTRY")

    def test_hidden_entry_is_rejected(self):
        self.preflight[".hidden"] = b"x"
        self.assertRejected("SOURCE_EVIDENCE_UNSAFE_ENTRY")

    def test_empty_required_file_is_rejected(self):
        self.deployment["whatsapp-packet-ai-worker-runtime-certification.txt"] = b""
        self.assertRejected()

    def test_preflight_from_other_run_is_rejected(self):
        self.preflight["whatsapp-packet-ai-worker-preflight-attestation.json"]["runId"] = "11111111111"
        self.assertRejected()

    def test_unverified_preflight_status_is_rejected(self):
        self.preflight["whatsapp-packet-ai-worker-preflight-attestation.json"]["status"] = "PREFLIGHT_FAILED"
        self.assertRejected()

    def test_release_attestation_rerun_attempt_is_rejected(self):
        self.deployment["whatsapp-packet-ai-worker-release-attestation.json"]["runAttempt"] = "2"
        self.assertRejected()

    def test_deployed_manifest_mismatch_is_rejected(self):
        self.deployment["target-source-manifest.json"] = self.manifest_bytes.replace(b"6", b"7", 1)
        self.assertRejected()

    def test_preflight_manifest_mismatch_is_rejected(self):
        self.preflight["target-source-manifest.json"] = self.manifest_bytes + b" "
        self.assertRejected()

    def test_live_metadata_wrong_version_is_rejected(self):
        self.deployment["live-function-after.json"]["version"] = 19
        self.assertRejected()

    def test_live_metadata_wrong_bundle_is_rejected(self):
        self.deployment["live-function-after.json"]["ezbr_sha256"] = "1" * 64
        self.assertRejected()

    def test_failed_release_attestation_status_is_rejected(self):
        self.deployment["whatsapp-packet-ai-worker-release-attestation.json"]["status"] = "FAILED"
        self.assertRejected()

    def test_release_attestation_wrong_deployed_version_is_rejected(self):
        self.deployment["whatsapp-packet-ai-worker-release-attestation.json"]["deployedVersion"] = 19
        self.assertRejected()

    def test_release_attestation_wrong_bundle_is_rejected(self):
        self.deployment["whatsapp-packet-ai-worker-release-attestation.json"]["deployedBundleSha256"] = "2" * 64
        self.assertRejected()

    def test_release_attestation_wrong_closure_is_rejected(self):
        att = self.deployment["whatsapp-packet-ai-worker-release-attestation.json"]
        att["reviewedSourceClosureSha256"] = "3" * 64
        self.assertRejected()


if __name__ == "__main__":
    unittest.main()
