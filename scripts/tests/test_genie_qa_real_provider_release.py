import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
import tarfile
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/genie-qa"))
from verify_qa_real_provider_secret_inventory import verify
from archive_qa_msg91_closure import archive

class TestRelease(unittest.TestCase):
    def test_inventory(self):
        names = ["QA_MSG91_PROVIDER_AUTH_KEY", "QA_MSG91_TEST_PHONE_ALLOWLIST"]
        def raw(n): return json.dumps([{"name": x} for x in n]).encode()
        verify(raw(names))
        for bad in [names[:1], names + ["QA_MSG91_PROVIDER_ENABLED"],
                    names + ["MSG91_AUTH_KEY"], names + ["OPENAI_API_KEY"],
                    names + [names[0]], names + ["qa_msg91_provider_enabled"]]:
            with self.assertRaises(ValueError): verify(raw(bad))

    def test_archive_closure(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            src = root / "supabase/functions/msg91-otp"
            src.mkdir(parents=True)
            (root / "supabase/config.toml").write_text('project_id = "skhpmltfjgqitntkmclb"\n')
            (src / "index.ts").write_text("export {};")
            (src / "not-in-closure").write_text("never archive")
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps({"files":[{"path":"msg91-otp/index.ts"}]}))
            output = root / "rollback.tgz"
            archive(root,manifest,output)
            with tarfile.open(output) as t:
                self.assertEqual(set(t.getnames()),{"supabase/config.toml","supabase/functions/msg91-otp/index.ts"})
            manifest.write_text(json.dumps({"files":[{"path":"../secret"}]}))
            with self.assertRaises(ValueError): archive(root,manifest,root/"bad.tgz")
            (src/"link.ts").symlink_to(src/"index.ts")
            manifest.write_text(json.dumps({"files":[{"path":"msg91-otp/link.ts"}]}))
            with self.assertRaises(ValueError): archive(root,manifest,root/"link.tgz")

    def test_release_boundary(self):
        workflow=(ROOT/".github/workflows/genie-qa-msg91-real-provider-release.yml").read_text()
        script=(ROOT/"scripts/genie-qa/release_msg91_real_provider.sh").read_text()
        self.assertIn("github.event_name == 'workflow_dispatch'",workflow)
        self.assertIn("github.ref == 'refs/heads/main'",workflow)
        self.assertIn("environment: genie-qa-bootstrap",workflow)
        self.assertIn("GENIE_QA_MSG91_MANAGEMENT_TOKEN",workflow)
        self.assertNotIn("secrets.SUPABASE_ACCESS_TOKEN",workflow)
        self.assertLess(workflow.index("id: rollback"),workflow.index("release_msg91_real_provider.sh deploy"))
        self.assertNotIn("tcxvcatsqqertcnycuop",script)
        self.assertEqual(script.count("supabase functions deploy "),2)
        self.assertIn('QA_REF=skhpmltfjgqitntkmclb',script)
        self.assertIn("default_transaction_read_only=on",script)
        self.assertIn("AUTHORIZE-GENIE-QA-REAL-PROVIDER-BUNDLES",script)
        self.assertIn('attest msg91-otp "$WORK/otp-verified-first"',script)
        self.assertIn('sha256sum -c SHA256SUMS',script)
        self.assertNotIn("supabase secrets set",script)
