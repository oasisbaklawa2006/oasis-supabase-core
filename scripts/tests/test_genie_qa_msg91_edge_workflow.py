#!/usr/bin/env python3
"""Fail-closed protected Genie QA commissioning workflow regression suite."""
from pathlib import Path
import hashlib
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/genie-qa-msg91-edge-commission.yml"
CHECK = ROOT / "scripts/genie-qa/verify_msg91_qa_edge_workflow.rb"
BASELINE_SHA = "a4ec8aafc41afa14717c092e583ebb697fe000ef"


class QaMsg91ProtectedWorkflowTests(unittest.TestCase):
    def validate(self, raw: str, repin: bool = False) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            doc = base / "edge.yml"
            doc.write_text(raw, encoding="utf-8")
            guard = CHECK
            if repin:
                current = hashlib.sha256(WORKFLOW.read_bytes()).hexdigest()
                candidate = hashlib.sha256(raw.encode("utf-8")).hexdigest()
                source = CHECK.read_text()
                marker = "workflow_sha256 = '" + current + "'"
                self.assertIn(marker, source)
                guard = base / "verify.rb"
                guard.write_text(
                    source.replace(marker, "workflow_sha256 = '" + candidate + "'"),
                    encoding="utf-8",
                )
            return subprocess.run(
                ["ruby", str(guard), str(doc)],
                capture_output=True, text=True, check=False,
            )

    def test_current_approved_workflow_passes(self):
        result = self.validate(WORKFLOW.read_text())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("GENIE_QA_MSG91_EDGE_WORKFLOW_PASS", result.stdout)

    def test_workflow_digest_is_pinned(self):
        digest = hashlib.sha256(WORKFLOW.read_bytes()).hexdigest()
        self.assertIn("workflow_sha256 = '" + digest + "'", CHECK.read_text())

    def test_byte_pin_rejects_any_mutation(self):
        original = WORKFLOW.read_text()
        mutation = original.replace(
            "      QA_PROJECT_REF: skhpmltfjgqitntkmclb",
            "      QA_PROJECT_REF: another-project", 1,
        )
        self.assertNotEqual(mutation, original)
        result = self.validate(mutation)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("approved QA workflow SHA-256 changed", result.stderr)

    def test_structural_security_guards_enforced_beyond_digest(self):
        original = WORKFLOW.read_text()
        mutations = (
            ("  workflow_dispatch:", "  push:\n    branches: [main]\n  workflow_dispatch:"),
            ("environment: genie-qa-bootstrap", "# environment: genie-qa-bootstrap"),
            ("QA_PROJECT_REF: skhpmltfjgqitntkmclb", "QA_PROJECT_REF: wrong-project"),
            ("if: inputs.mode == 'deploy'", "if: true"),
            ("          ref: " + "$" + "{{ github.sha }}",
             "          ref: " + "$" + "{{ inputs.expected_head_sha }}"),
            ('test "$GITHUB_SHA" = "$EXPECTED_SHA"', '# test "$GITHUB_SHA" = "$EXPECTED_SHA"'),
            ("QA-EDGE-APPROVAL=[A-Za-z0-9._/-]{6,128}",
             "QA-EDGE-APPROVAL=.*"),
            ('      - name: Refuse provider credentials and any pre-existing QA Edge functions',
             '      - name: Refuse provider credentials and any pre-existing QA Edge functions\n        if: false'),
            ('      - name: Verify strict direct QA TLS and commissioned no-egress schema',
             '      - name: Verify strict direct QA TLS and commissioned no-egress schema\n        continue-on-error: true'),
            ('          cmp -s "$RUNNER_TEMP/qa-expected-versions.txt"',
             '          # cmp -s "$RUNNER_TEMP/qa-expected-versions.txt"'),
            ('          cp scripts/genie-qa/inert_msg91_provider_verify.mjs',
             '          # cp scripts/genie-qa/inert_msg91_provider_verify.mjs'),
            ('GENIE_QA_EDGE_JWT_AUTHORITY_UNVERIFIED',
             'GENIE_QA_EDGE_JWT_UNVERIFIED_ALLOWED'),
            ('QA_MIGRATION_SOURCE_SHA: a4ec8aafc41afa14717c092e583ebb697fe000ef',
             'QA_MIGRATION_SOURCE_SHA: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'),
        )
        for original_text, altered in mutations:
            with self.subTest(control=original_text[:45]):
                self.assertIn(original_text, original)
                result = self.validate(original.replace(original_text, altered, 1), repin=True)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertIn("GENIE_QA_MSG91_EDGE_WORKFLOW_DENIED", result.stderr)

    def test_each_remote_source_attestation_uses_a_fresh_download_tree(self):
        source = WORKFLOW.read_text()
        self.assertIn(
            'remote="$(mktemp -d "$RUNNER_TEMP/qa-remote-attest-$slug.XXXXXXXX")"',
            source,
        )
        self.assertIn("GENIE_QA_EDGE_REMOTE_ATTEST_TMP_FAILED", source)
        self.assertNotIn(
            'local remote="$RUNNER_TEMP/qa-remote-attest-$slug"',
            source,
        )
        self.assertEqual(
            source.count('attest_deployed_source msg91-otp'), 2,
        )

    def test_live_bundle_digests_cannot_change_before_success(self):
        source = WORKFLOW.read_text()
        self.assertIn('GENIE_QA_EDGE_BUNDLE_PRE_READ_FAILED', source)
        self.assertIn('GENIE_QA_EDGE_BUNDLE_POST_READ_FAILED', source)
        self.assertIn('GENIE_QA_EDGE_ATTESTED_BUNDLE_CHANGED', source)
        self.assertIn('verify_msg91_bundle_provenance.py', source)
        self.assertEqual(source.count('--mode capture'), 1)
        self.assertEqual(source.count('--mode final'), 2)
        self.assertLess(
            source.index('GENIE_QA_EDGE_ATTESTED_BUNDLE_CHANGED'),
            source.index('supabase functions deploy msg91-session-bridge'),
        )
        self.assertLess(
            source.index('GENIE_QA_EDGE_PROVIDER_SECRET_ADDED'),
            source.index('GENIE_QA_EDGE_LAST_BUNDLE_CHANGED'),
        )
        self.assertLess(
            source.index('GENIE_QA_EDGE_LAST_BUNDLE_CHANGED'),
            source.index('GENIE_QA_MSG91_INERT_DUAL_EDGE_DEPLOY_PASS'),
        )

    def test_bootstrap_migration_set_is_exact_and_immutable(self):
        result = subprocess.run(
            ["git", "ls-tree", "-r", "--name-only", BASELINE_SHA,
             "--", "supabase/migrations"],
            cwd=ROOT, capture_output=True, text=True, check=True,
        )
        versions = []
        for path in result.stdout.splitlines():
            matched = re.fullmatch(r"supabase/migrations/([0-9]{14})_[^/]+\.sql", path)
            self.assertIsNotNone(matched, path)
            versions.append(matched.group(1))
        self.assertEqual(len(versions), 516)
        self.assertEqual(len(set(versions)), 516)

    def test_release_files_have_explicit_human_codeowners(self):
        owners = (ROOT / ".github/CODEOWNERS").read_text()
        paths = (
            ".github/CODEOWNERS",
            ".github/workflows/genie-qa-msg91-edge-commission.yml",
            "scripts/genie-qa/verify_msg91_qa_edge_workflow.rb",
            "scripts/genie-qa/verify_msg91_secret_inventory.py",
            "scripts/genie-qa/inert_msg91_provider_verify.mjs",
            "scripts/tests/test_genie_qa_msg91_edge_workflow.py",
            "scripts/tests/test_genie_qa_secret_inventory.py",
            "scripts/tests/test_genie_qa_msg91_inert.py",
            "scripts/tests/test_genie_qa_remote_source.py",
            "scripts/genie-qa/verify_msg91_bundle_provenance.py",
            "scripts/tests/test_genie_qa_bundle_provenance.py",
        )
        for path in paths:
            with self.subTest(path=path):
                self.assertIn(
                    "/" + path + " @oasisbaklawa2006 @dineshmutrejabackup-cmd",
                    owners,
                )

    def test_downloaded_source_attestation_order_and_fail_closed(self):
        source = WORKFLOW.read_text()
        expected_before_write = source.index(
            '--output "$RUNNER_TEMP/qa-expected-source-$slug.json"'
        )
        first_deploy = source.index('supabase functions deploy msg91-otp')
        first_attest = source.index('attest_deployed_source msg91-otp')
        bridge_deploy = source.index('supabase functions deploy msg91-session-bridge')
        second_attest = source.rindex('attest_deployed_source msg91-otp')
        bridge_attest = source.index('attest_deployed_source msg91-session-bridge')
        published_success = source.index('GENIE_QA_MSG91_INERT_DUAL_EDGE_DEPLOY_PASS')
        self.assertLess(
            expected_before_write, first_deploy
        )
        self.assertLess(first_deploy, first_attest)
        self.assertLess(first_attest, bridge_deploy)
        self.assertLess(bridge_deploy, second_attest)
        self.assertLess(second_attest, bridge_attest)
        self.assertLess(bridge_attest, published_success)
        self.assertIn('supabase functions download "$slug"', source)
        self.assertIn('--project-ref "$QA_PROJECT_REF" --use-api', source)
        self.assertIn('GENIE_QA_EDGE_REMOTE_SOURCE_DOWNLOAD_FAILED', source)
        self.assertIn('GENIE_QA_EDGE_DEPLOYED_SOURCE_MISMATCH', source)
        self.assertIn('cmp -s "$RUNNER_TEMP/qa-expected-source-$slug.json"', source)

    def test_provider_secret_inventory_and_deploy_are_separate(self):
        source = WORKFLOW.read_text()
        self.assertIn("/v1/projects/$QA_PROJECT_REF/secrets", source)
        self.assertIn("inert_msg91_provider_verify.mjs", source)
        self.assertIn("GENIE_QA_EDGE_PROVIDER_SECRET_ADDED", source)
        self.assertIn("GENIE_QA_EDGE_JWT_AUTHORITY_UNVERIFIED", source)
        self.assertIn("GENIE_QA_EDGE_MIGRATION_VERSION_SET_DRIFT", source)
        self.assertEqual(source.count("supabase functions deploy "), 2)
        self.assertNotIn("tcxvcatsqqertcnycuop", source)


if __name__ == "__main__":
    unittest.main()
