#!/usr/bin/env python3
"""Negative proofs for the Studio AI-copy inert QA source and protected workflow."""
from __future__ import annotations
from pathlib import Path
import importlib.util
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
OVERLAY = ROOT / "scripts/studio-qa/build_inert_copy.py"
GUARD = ROOT / "scripts/studio-qa/verify_preflight.rb"
WORKFLOW = ROOT / ".github/workflows/studio-ai-copy-qa-preflight.yml"
SOURCE = ROOT / "supabase/functions/catalogue-ai-copy/index.ts"
HELPER = ROOT / "supabase/functions/_shared/catalogueAiCopy.ts"
SECRETS = ROOT / "scripts/studio-qa/verify_secrets.py"

def load(path: Path):
    spec = importlib.util.spec_from_file_location("studio_qa_test", path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module

class StudioQaInertTests(unittest.TestCase):
    def test_authorized_source_renders_provider_inert(self):
        tool = load(OVERLAY)
        actual = SOURCE.read_text()
        content = tool.render_inert(actual)
        self.assertIn("has_ai_studio_permission_v1", content)
        self.assertIn('p_key: "ai_studio.ai.use"', content)
        self.assertIn("https://studio-qa.oasis.invalid", content)
        self.assertIn('return json({ ok: false, error: "AI service is not configured" }, 503, origin);', content)
        self.assertNotIn("fetch(", content)
        self.assertNotIn("OPENAI_API_KEY", content)
        self.assertNotIn("AI_STUDIO_AI_ENABLED", content)
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp) / "functions"
            tool.build(SOURCE, HELPER, dest)
            self.assertEqual((dest / "_shared/catalogueAiCopy.ts").read_bytes(), HELPER.read_bytes())
            self.assertEqual((dest / "catalogue-ai-copy/index.ts").read_text(), content)
            with self.assertRaises(tool.OverlayDenied):
                tool.build(SOURCE, HELPER, dest)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            modified_helper = root / "catalogueAiCopy.ts"
            modified_helper.write_text(HELPER.read_text() + "\\nfetch('https://provider.example');\\n")
            with self.assertRaises(tool.OverlayDenied):
                tool.build(SOURCE, modified_helper, root / "outputs")

    def test_mutated_source_rejected(self):
        tool = load(OVERLAY)
        source = SOURCE.read_text()
        changes = [
            source.replace('p_key: "ai_studio.ai.use"', 'p_key: "ai_studio.app.access"'),
            source.replace('"has_ai_studio_permission_v1"', '"has_wrong_permission"'),
            source.replace(tool.ORIGIN_LINE, 'const configured = "*";'),
            source.replace(tool.PROVIDER_BOUNDARY, "  const apiKey = 'secret';"),
            source.replace('fetch("https://api.openai.com/v1/responses"', 'fetch("https://malicious.example/v1/responses"'),
            source.replace("clearTimeout(timeout)", "void timeout"),
            source.replace("parseCatalogueCopyRequest(await req.json())", "await req.json()"),
            source.replace(tool.PROVIDER_BOUNDARY, '  await fetch("https://api.openai.com/early");\n' + tool.PROVIDER_BOUNDARY),
        ]
        for candidate in changes:
            self.assertNotEqual(candidate, source)
            with self.subTest(case=changes.index(candidate)):
                with self.assertRaises(tool.OverlayDenied):
                    tool.render_inert(candidate)

    def test_nonplatform_secrets_fail_closed(self):
        module = load(SECRETS)
        for good in (b'[]', b'[{"name":"SUPABASE_ANON_KEY"}]',
                     b'[{"name":"SUPABASE_URL"},{"name":"SUPABASE_PUBLISHABLE_KEYS"}]'):
            module.verify(good)
        bad = [b'{}', b'null', b'[{"name":"OPENAI_API_KEY"}]', b'[{"name":"MSG91_AUTH_KEY"}]',
               b'[{"name":"RESEND_API_KEY"}]', b'[{"name":"AI_STUDIO_AI_ENABLED"}]',
               b'[{"name":"SUPABASE_URL"},{"name":"SUPABASE_URL"}]',
               b'[{"name":"SUPABASE_URL","name":"OPENAI_API_KEY"}]',
               b'[{"name":"SUPABASE_OPENAI_API_KEY"}]',
               b'[{"name":"SB_MSG91_AUTH_KEY"}]',
               b'[{"name":"SUPABASE_UNKNOWN_CUSTOM"}]', b'[NaN]', b'']
        for raw in bad:
            with self.subTest(data=raw[:16]):
                with self.assertRaises(module.SecretsDenied):
                    module.verify(raw)

class StudioQaGovernanceTests(unittest.TestCase):
    def check(self, source: str) -> subprocess.CompletedProcess:
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yml", encoding="utf-8") as f:
            f.write(source)
            f.flush()
            return subprocess.run(["ruby", str(GUARD), f.name], text=True,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  timeout=8, check=False)

    def test_clean_workflow_passes(self):
        r = self.check(WORKFLOW.read_text())
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("STUDIO_QA_READONLY_WORKFLOW_PASS", r.stdout)

    def test_unsafe_workflow_mutations_fail(self):
        origin = WORKFLOW.read_text()
        cases = [
            ("open to PR", "on:\n  workflow_dispatch:", "on:\n  push:\n  workflow_dispatch:"),
            ("production ref", "QA_PROJECT_REF: skhpmltfjgqitntkmclb", "QA_PROJECT_REF: tcxvcatsqqertcnycuop"),
            ("optional main guard", "github.ref == 'refs/heads/main'", "github.ref != 'refs/heads/main'"),
            ("nonfatal", "    timeout-minutes: 25", "    timeout-minutes: 25\n    continue-on-error: true"),
            ("extra function", "type == \"array\" and length == 0", "type == \"array\" and length >= 0"),
            ("unauthorized checkout", "ref: ${{ github.sha }}", "ref: ${{ inputs.expected_head_sha }}"),
            ("disable verifier", "scripts/studio-qa/verify_secrets.py", "scripts/studio-qa/always_allow.py"),
            ("JWT disabled", "verify_jwt = true", "verify_jwt = false"),
            ("unsafe deploy", "echo STUDIO_QA_INERT_SOURCE_ONLY_PASS", "supabase functions deploy catalogue-ai-copy"),
            ("skip step", "      - name: Check QA-only provider-secret absence", "      - name: Check QA-only provider-secret absence\n        if: false"),
            ("SQL DELETE", "SELECT (SELECT count(*) FROM supabase_migrations.schema_migrations)::text", "DELETE FROM auth.users; SELECT (SELECT count(*) FROM supabase_migrations.schema_migrations)::text"),
            ("SQL INSERT", "SELECT (SELECT count(*) FROM supabase_migrations.schema_migrations)::text", "INSERT INTO auth.users VALUES (NULL); SELECT (SELECT count(*) FROM supabase_migrations.schema_migrations)::text"),
            ("readwrite SQL session", 'PGOPTIONS: "-c default_transaction_read_only=on"', 'PGOPTIONS: "-c default_transaction_read_only=off"'),
            ("curl implicit write", "curl --fail --silent --show-error --max-time 30", 'curl --data "{}" --fail --silent --show-error --max-time 30'),
            ("full helper scan removed", "! grep -Erq", "! grep -Eq"),
        ]
        for name, old, new in cases:
            self.assertIn(old, origin, name)
            with self.subTest(name=name):
                r = self.check(origin.replace(old, new, 1))
                self.assertNotEqual(r.returncode, 0, name)

if __name__ == "__main__":
    unittest.main()
