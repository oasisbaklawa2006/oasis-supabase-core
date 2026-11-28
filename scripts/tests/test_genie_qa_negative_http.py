import os
import sys
import unittest
import hashlib
import tempfile
import types
from pathlib import Path
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/genie-qa"))
import negative_http_transport as t

class TransportTests(unittest.TestCase):
    def test_reject_wrong_host(self):
        for url in ("https://tcxvcatsqqertcnycuop.supabase.co/auth/v1/user",
                    "https://skhpmltfjgqitntkmclb.supabase.co.evil.test/auth/v1/user",
                    "https://api.supabase.com/v1/projects/tcxvcatsqqertcnycuop/secrets"):
            with self.assertRaisesRegex(t.Denied, "HTTP_TARGET_DENIED"):
                t.http(url)

    def test_redirect_denied(self):
        self.assertIsNone(t.NoRedirect().redirect_request(None, None, 302, "", {}, "https://evil.test"))

    def test_activation_and_openai_secret_denied(self):
        for name in ("QA_MSG91_PROVIDER_ENABLED", "MSG91_AUTH_KEY", "OPENAI_API_KEY"):
            with patch.object(t, "management", return_value=[{"name": name}]):
                with self.assertRaisesRegex(t.Denied, "ACTIVATION_OR_PROHIBITED_SECRET_PRESENT"):
                    t.inventory()

    def test_inventory_exact_repin_and_field_denials(self):
        expected = {"msg91-otp": (19, "47b2b980f89ec5a813dc72e5c4de29128dfb1b4a457ee56d57a3eed3cd5c034f"),
                    "buyer-login-gateway": (11, "ebb2a2615f9045e2a71b9a9a0c9e1cba7e503523da1812643e7791e1b3dc0398"),
                    "msg91-session-bridge": (17, "47c64fb7996548e59301cff7bfe2886a9e06a3bb41b0ff168676abfd8c0d5ee3")}
        self.assertEqual(t.BUNDLES, expected)
        metadata = {slug: {"slug": slug, "version": version, "ezbr_sha256": digest,
                          "status": "ACTIVE", "verify_jwt": False}
                    for slug, (version, digest) in expected.items()}
        def read(path):
            return [] if path == "secrets" else metadata[path.split("/", 1)[1]]
        with patch.object(t, "management", side_effect=read):
            t.inventory()
            for slug, (version, digest) in expected.items():
                for field, wrong, label in (("version", version - 1, "version"),
                                             ("version", version + 1, "version"),
                                             ("version", float(version), "version"),
                                             ("ezbr_sha256", "0" * 64, "hash"),
                                             ("status", "INACTIVE", "status"),
                                             ("verify_jwt", True, "jwt"),
                                             ("slug", "wrong", "identity")):
                    with self.subTest(slug=slug, field=field, wrong=wrong):
                        original = metadata[slug][field]
                        metadata[slug][field] = wrong
                        try:
                            with self.assertRaisesRegex(t.Denied, "QA_BUNDLE_DRIFT:" + slug + ":" + label):
                                t.inventory()
                        finally:
                            metadata[slug][field] = original
            t.inventory()

    def test_fixture_denial_not_classification(self):
        self.assertTrue(t.classify_denial({"ok": True, "state": "ambiguous", "allowOtp": False}))
        for body in ({"ok": True, "state": "approved", "allowOtp": True},
                     {"ok": True, "state": "rejected", "allowOtp": False},
                     {"ok": False, "state": "ambiguous", "allowOtp": False}):
            self.assertFalse(t.classify_denial(body))

    def test_stale_only(self):
        row = {"line_id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
               "product_id": "a6182000-0000-4000-8000-000000000003", "quantity": 18}
        payload = t.cas_payload(row)
        self.assertEqual(payload["p_expected_quantity"], 19)
        self.assertEqual(payload["p_quantity"], 18)
        self.assertEqual(payload["p_product_id"], "a6182000-0000-4000-8000-000000000004")
        # Mirrors the pinned CAS condition: even if a concurrent writer makes
        # the quantity equal to the supplied expectation, product mismatch holds.
        for quantity in (18, 19, 24):
            self.assertTrue(row["product_id"] != payload["p_product_id"]
                            or quantity != payload["p_expected_quantity"])
        with self.assertRaisesRegex(t.Denied, "QA_CAS_TARGET_DRIFT"):
            t.cas_payload(dict(row, quantity=19))

    def test_publishable_only(self):
        with patch.dict(os.environ, {"QA_PUBLISHABLE_KEY": "sb_secret_bad"}):
            with self.assertRaisesRegex(t.Denied, "PUBLISHABLE_KEY_REQUIRED"):
                t.public_key()

    def test_all_six_base_checks_precede_scratch_lane(self):
        calls = []
        def fake_http(url, headers, data=None):
            calls.append((url, headers, data))
            if url.endswith("buyer-login-gateway"):
                return 200, {"ok": True, "state": "ambiguous", "allowOtp": False}
            if url.endswith("msg91-otp"):
                self.assertIsInstance(data["accessToken"], dict)
                return 401, {"error": "provider_verification_failed"}
            if url.endswith("/auth/v1/user") and headers.get("Authorization") == "Bearer invalid.qa.token":
                return 403, {"code": 403, "error_code": "bad_jwt"}
            return 401, {}
        with patch.object(t, "http", side_effect=fake_http), patch.object(t, "inventory"), patch.object(t, "full_probes", side_effect=lambda *_: self.assertEqual(len(calls), 6)) as full:
            t.probes({}, "sb_publishable_test")
            full.assert_called_once_with({}, "sb_publishable_test")
        self.assertEqual(len(calls), 6)
        self.assertTrue(all(c[0].startswith(t.BASE + "/") for c in calls))
        self.assertFalse(any("update_customer_order_draft" in c[0] for c in calls))

    def test_invalid_jwt_denial_contract_is_exact(self):
        cases = [(403, {"code": 403, "error_code": "bad_jwt"}, None),
                 (403, {}, "HTTP_ASSERTION_FAILED"),
                 (403, {"error_code": "not_admin"}, "HTTP_ASSERTION_FAILED"),
                 (403, {"error_code": "bad_jwt", "id": "unexpected-user"}, "HTTP_ASSERTION_FAILED"),
                 (401, {"error_code": "bad_jwt"}, "HTTP_ASSERTION_FAILED"),
                 (200, {"error_code": "bad_jwt"}, "HTTP_ASSERTION_FAILED"),
                 (429, {"error_code": "bad_jwt"}, "HTTP_ASSERTION_FAILED"),
                 (500, {"error_code": "bad_jwt"}, "HTTP_ASSERTION_FAILED")]
        for status, body, stop in cases:
            with self.subTest(status=status, body=body):
                def fake_http(url, headers, data=None):
                    if url.endswith("/auth/v1/user") and headers.get("Authorization"):
                        return status, body
                    if url.endswith("buyer-login-gateway"):
                        return 200, {"ok": True, "state": "ambiguous", "allowOtp": False}
                    if url.endswith("msg91-otp"):
                        return 401, {"error": "provider_verification_failed"}
                    return 401, {}
                with patch.object(t, "http", side_effect=fake_http), patch.object(t, "inventory"), patch.object(t, "full_probes") as full:
                    if stop:
                        with self.assertRaisesRegex(t.Denied, "^" + stop + "$"):
                            t.probes({}, "sb_publishable_test")
                        full.assert_not_called()
                    else:
                        t.probes({}, "sb_publishable_test")
                        full.assert_called_once()

    def test_workflows_are_separate_and_live_lock_shared(self):
        workflows = ROOT / ".github/workflows"
        offline = (workflows / "genie-qa-negative-http-ci.yml").read_text()
        live = (workflows / "genie-qa-negative-http.yml").read_text()
        self.assertIn("  pull_request:", offline)
        self.assertNotIn("environment:", offline)
        self.assertNotIn("secrets.", offline)
        self.assertNotIn("workflow_dispatch:", offline)
        self.assertIn("  workflow_dispatch:", live)
        self.assertNotIn("pull_request:", live)
        self.assertIn("environment: genie-qa-bootstrap", live)
        self.assertIn("group: genie-qa-msg91-edge-commission", live)
        self.assertIn("cancel-in-progress: false", live)

    def test_exact_main_no_process(self):
        head = "a" * 40
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".git").mkdir()
            (root / ".git/HEAD").write_text(head + "\n")
            with patch.object(t, "ROOT", root), patch.dict(os.environ, {"EXPECTED_SHA": head, "GH_TOKEN": "test"}), patch.object(t, "http", return_value=(200, {"ref": "refs/heads/main", "object": {"sha": head}})) as request:
                t.assert_exact_main()
                self.assertEqual(request.call_args.args[0], t.GITHUB_MAIN)
                request.return_value = (200, {"ref": "refs/heads/main", "object": {"sha": "b" * 40}})
                with self.assertRaisesRegex(t.Denied, "MAIN_MOVED"):
                    t.assert_exact_main()
                (root / ".git/HEAD").write_text("ref: refs/heads/main\n")
                with self.assertRaisesRegex(t.Denied, "CHECKOUT_MISMATCH"):
                    t.assert_exact_main()

    def test_census_exact_envelope(self):
        source = (ROOT / "scripts/genie-qa/forward_preservation.sql").read_text()
        self.assertEqual(t.census_select(), source.split("BEGIN READ ONLY;\n", 1)[1].rsplit("\nCOMMIT;\n", 1)[0])
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "scripts/genie-qa").mkdir(parents=True)
            (root / "scripts/genie-qa/forward_preservation.sql").write_text(source.replace("BEGIN READ ONLY;", "BEGIN;"))
            with patch.object(t, "ROOT", root), self.assertRaisesRegex(t.Denied, "QA_CENSUS_ENVELOPE_CHANGED"):
                t.census_select()

    def test_database_driver_read_only_and_exact_text(self):
        conn = MagicMock()
        cursor = conn.cursor.return_value.__enter__.return_value
        cursor.fetchone.return_value = ("on",)
        cursor.description = [("value",)]
        cursor.fetchall.return_value = [('{"x": 1}',)]
        driver = types.ModuleType("psycopg2")
        driver.connect = MagicMock(return_value=conn)
        extensions = types.ModuleType("psycopg2.extensions")
        extensions.new_type = MagicMock()
        extensions.register_type = MagicMock()
        env = {"PGDATABASE": "postgresql://postgres:dummy@db.skhpmltfjgqitntkmclb.supabase.co:5432/postgres",
               "PGSSLROOTCERT": "/tmp/qa-ca.pem"}
        with patch.dict(sys.modules, {"psycopg2": driver, "psycopg2.extensions": extensions}), patch.dict(os.environ, {}, clear=True):
            result = t.db("SELECT 1", env)
            self.assertEqual(result, b'{"x": 1}\n')
            self.assertEqual(hashlib.sha256(result).hexdigest(), hashlib.sha256(b'{"x": 1}\n').hexdigest())
            driver.connect.assert_called_once_with(env["PGDATABASE"], sslmode="verify-full", sslrootcert=env["PGSSLROOTCERT"], connect_timeout=10, client_encoding="UTF8", options="-c default_transaction_read_only=on -c statement_timeout=15000")
            conn.set_session.assert_called_once_with(readonly=True, autocommit=False)
            cursor.execute.assert_any_call("SHOW transaction_read_only")
            conn.rollback.assert_called_once()
            conn.close.assert_called_once()
            cursor.fetchone.return_value = ("off",)
            with self.assertRaisesRegex(t.Denied, "QA_DATABASE_NOT_READ_ONLY"):
                t.db("SELECT 1", env)
            with patch.dict(os.environ, {"PGHOST": "untrusted"}):
                with self.assertRaisesRegex(t.Denied, "AMBIENT_LIBPQ_ENV_DENIED"):
                    t.db("SELECT 1", env)


    def test_stage_pinned_source_and_expiring_capability(self):
        proof = "a" * 64
        run_id = "b" * 24
        files = t.stage_probe(run_id, proof, 123456789)
        src = files["index.ts"]
        self.assertNotIn(proof, src)
        self.assertIn(hashlib.sha256(proof.encode()).hexdigest(), src)
        self.assertIn("const RUN = \"" + run_id + "\"", src)
        self.assertIn("const EXPIRY = 123456789", src)
        self.assertIn("async function classifyMobile(", src)
        self.assertNotIn("async function classifyEmail(", src)
        self.assertNotIn('lookupError.message', src)
        self.assertIn("auth.admin.createUser", src)
        self.assertIn("auth.signInWithPassword", src)
        self.assertIn("auth.admin.deleteUser", src)
        self.assertIn("body?.code === \"PT409\"", src)
        self.assertIn("Deno.env.get(\"QA_MSG91_PROVIDER_ENABLED\") === undefined", src)
        self.assertNotIn('sendOtp', src)
        self.assertNotIn('signInWithOtp', src)
        self.assertNotIn('get_customer_order_draft_v1"', src)
        self.assertNotIn("auth.audit_log_entries", src)
        with self.assertRaisesRegex(t.Denied, "PROBE_LITERAL_INVALID"):
            t.stage_probe("../bad", proof, 123)

    def test_management_writes_only_unique_scratch_paths(self):
        for method, path in (("DELETE","functions/msg91-otp"), ("POST","secrets"),
                            ("PATCH","functions/genie-qa-negative-"+"b"*24),
                            ("POST","functions/deploy?slug=buyer-login-gateway")):
            with patch.object(t,"http") as request:
                with self.assertRaisesRegex(t.Denied,"MANAGEMENT_MUTATION_DENIED"):
                    t.management_mutation(method,path)
                request.assert_not_called()

    def test_scratch_cleanup_is_run_scoped(self):
        run_id = "a"*24
        fixture = {"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","email":"genie-qa-transport-"+run_id+"@example.invalid","run":run_id}
        call = MagicMock(return_value=(200,{"ok":True,"cleanup_complete":True}))
        with patch.object(t,"db",side_effect=[__import__("json").dumps([fixture]).encode(), b"[]"]):
            t.recover_fixture({},call,run_id)
            call.assert_called_once_with({"action":"cleanup","uid":fixture["id"]})
        call.reset_mock()
        with patch.object(t,"db",return_value=__import__("json").dumps([dict(fixture,run="wrong")]).encode()):
            with self.assertRaisesRegex(t.Denied,"SCRATCH_IDENTITY_SCOPE_DENIED"):
                t.recover_fixture({},call,run_id)
            call.assert_not_called()

    def test_scratch_success_and_fail_closed_cleanup(self):
        slug = "genie-qa-negative-" + "b"*24
        base = {k:{} for k in t.BUNDLES}
        meta = {"slug":slug,"name":slug,"id":"synthetic-id","verify_jwt":False,"version":1,"status":"ACTIVE","ezbr_sha256":"c"*64}
        for failure in ("none", "provider", "cleanup", "digest", "lost_pt409", "pt409_500", "pt409_bad_body"):
            deployed = False
            deleted = False
            attempted = []
            def mutate(method,path,raw=None,content_type=None):
                nonlocal deployed, deleted
                attempted.append((method,path))
                if method=="DELETE":
                    deleted=True
                    deployed=False
                    return 200, {}
                if "bundleOnly=true" not in path:
                    deployed=True
                return 201,dict(meta,ezbr_sha256="d"*64) if failure == "digest" and "bundleOnly=true" in path else meta
            def inv():
                return dict(base,**({slug:meta} if deployed else {}))
            def request(url,headers,data=None,**kwargs):
                if "x-genie-qa-proof" not in headers:
                    return 403,{"ok":False,"error":"scope_denied"}
                action=data["action"]
                if action=="rejected":
                    return 200,{"ok":True,"state":"rejected","allowOtp":False}
                if action=="staff":
                    return 200,{"ok":True,"state":"employee","allowOtp":False}
                if action=="provider":
                    return (500, {}) if failure == "provider" else (401,{"ok":False,"error":"provider_verification_failed","provider_reached":True,"provider_invalid_token":True,"upstream_status":200})
                if action=="pt409":
                    if failure == "lost_pt409":
                        raise t.Denied("HTTP_TRANSPORT_FAILED")
                    if failure == "pt409_500":
                        return 500, {"ok":False,"error":"probe_failed"}
                    if failure == "pt409_bad_body":
                        return 409, {"ok":False,"code":"PT409","upstream_status":409,"synthetic_session":True,"cleanup_complete":False}
                    return 409,{"ok":False,"code":"PT409","upstream_status":409,"synthetic_session":True,"cleanup_complete":True}
                self.fail("unexpected action")
            with patch.object(t,"scope"), patch.object(t,"snapshot",return_value=t.BASELINE), patch.object(t,"inventory"), patch.object(t,"assert_exact_main"), patch.object(t,"function_inventory",side_effect=inv), patch.object(t,"management",return_value=meta), patch.object(t,"management_mutation",side_effect=mutate), patch.object(t,"recover_fixture", side_effect=t.Denied("SCRATCH_IDENTITY_CLEANUP_FAILED") if failure == "cleanup" else None) as recover, patch.object(t,"fixture_rows",return_value=[]) as absence, patch.object(t,"http",side_effect=request), patch.object(t.secrets,"token_hex",side_effect=lambda n: "b"*24 if n==12 else "a"*(n*2)):
                if failure == "none":
                    t.full_probes({}, "sb_publishable_test")
                else:
                    reason = {"provider":"REAL_PROVIDER_DENIAL_NOT_PROVEN",
                              "cleanup":"SCRATCH_IDENTITY_CLEANUP_FAILED",
                              "digest":"SCRATCH_BUNDLE_DRIFT",
                              "lost_pt409":"SCRATCH_REQUEST_OUTCOME_UNKNOWN",
                              "pt409_500":"SCRATCH_REQUEST_OUTCOME_UNKNOWN",
                              "pt409_bad_body":"SCRATCH_REQUEST_OUTCOME_UNKNOWN"}[failure]
                    with self.assertRaisesRegex(t.Denied, reason):
                        t.full_probes({}, "sb_publishable_test")
                recover.assert_called_once()
                if failure in ("cleanup","lost_pt409","pt409_500","pt409_bad_body"):
                    self.assertFalse(deleted)
                    self.assertTrue(deployed)
                    absence.assert_not_called()
                else:
                    absence.assert_called_once()
                    self.assertTrue(deleted)
                    self.assertFalse(deployed)
                    self.assertEqual(attempted[-1],("DELETE","functions/"+slug))

    def test_cleanup_retries_until_database_absence(self):
        run_id = "a"*24
        fixture = {"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","email":"genie-qa-transport-"+run_id+"@example.invalid","run":run_id}
        call = MagicMock(side_effect=[t.Denied("HTTP_TRANSPORT_FAILED"), (200,{"ok":True,"cleanup_complete":True})])
        with patch.object(t,"fixture_rows",side_effect=[[fixture],[fixture],[fixture],[]]), patch.object(t.time,"sleep"):
            t.recover_fixture({},call,run_id)
        self.assertEqual(call.call_count,2)
        call = MagicMock(return_value=(200,{"ok":True,"cleanup_complete":True}))
        with patch.object(t,"fixture_rows",return_value=[fixture]), patch.object(t.time,"sleep"):
            with self.assertRaisesRegex(t.Denied,"SCRATCH_IDENTITY_CLEANUP_FAILED"):
                t.recover_fixture({},call,run_id)
        self.assertEqual(call.call_count,3)

    def test_compile_metadata_optional_but_live_readback_strict(self):
        slug = "genie-qa-negative-"+"a"*24
        base = {"slug":slug,"name":slug,"id":"scratch-id","status":"ACTIVE","version":1}
        live = dict(base, verify_jwt=False, ezbr_sha256="a"*64)
        self.assertIsNone(t.scratch_meta(base,slug))
        self.assertEqual(t.verify_scratch_readback(base,base,live,slug),"a"*64)
        for bad in (dict(base,verify_jwt=True),dict(base,ezbr_sha256="bad"),dict(base,slug="wrong")):
            with self.assertRaises(t.Denied):
                t.scratch_meta(bad,slug)
        for bad in (base,dict(live,verify_jwt=True),dict(live,id="other"),dict(live,version=2)):
            with self.assertRaises(t.Denied):
                t.verify_scratch_readback(base,base,bad,slug)
        with self.assertRaisesRegex(t.Denied,"SCRATCH_BUNDLE_DRIFT"):
            t.verify_scratch_readback(dict(base,ezbr_sha256="b"*64),base,live,slug)

    def test_expiry_guards_and_recovery_only_window(self):
        src = t.stage_probe("b"*24,"a"*64,123456789)["index.ts"]
        self.assertIn("const CLEANUP_EXPIRY = EXPIRY + 8 * 60 * 1000",src)
        self.assertIn("Date.now() >= CLEANUP_EXPIRY",src)
        self.assertLess(src.index('if (action === "cleanup")'),src.index('if (!isolated() || Date.now() >= EXPIRY)'))
        for call in ("const created = await admin!.auth.admin.createUser","const profile = await admin!.from(\"profiles\").insert","const signed = await client.auth.signInWithPassword"):
            self.assertIn("check(isolated() && Date.now() < EXPIRY);\n    "+call,src)

    def test_source_pin_uses_sha256_and_rejects_changed_bytes(self):
        original = b"exact canonical source\n"
        with tempfile.TemporaryDirectory() as tmp:
            file = Path(tmp) / "source"
            file.write_bytes(original)
            with patch.object(t, "ROOT", Path(tmp)):
                self.assertEqual(t.pinned_source("source", hashlib.sha256(original).hexdigest()), original.decode())
                file.write_bytes(original + b"x")
                with self.assertRaisesRegex(t.Denied, "CANONICAL_PROBE_SOURCE_DRIFT"):
                    t.pinned_source("source", hashlib.sha256(original).hexdigest())

    def test_scratch_outbound_destinations_are_pinned(self):
        src = t.stage_probe("b"*24,"a"*64,123456789)["index.ts"]
        self.assertIn('if (input instanceof Request) throw Error("QA_HTTP_REQUEST_DENIED")', src)
        self.assertIn("candidate.origin !== QA_URL", src)
        self.assertIn("candidate.username || candidate.password || candidate.hash", src)
        self.assertIn("!fixedPaths.has(path) && !adminUser", src)
        self.assertIn("const target = new URL(QA_URL)", src)
        self.assertIn("target.pathname = path", src)
        self.assertIn("target.search = candidate.search", src)
        self.assertIn("const suffix = target.pathname + target.search", src)
        self.assertIn('fetch("https://skhpmltfjgqitntkmclb.supabase.co" + suffix, {', src)
        self.assertNotIn("fetch(target,", src)
        self.assertIn('...init, redirect: "error", signal: AbortSignal.timeout(10000)', src)
        self.assertIn('fetch("https://api.msg91.com/api/v5/widget/verifyAccessToken", {', src)
        self.assertNotIn("fetch(input,", src)
        self.assertNotIn("boundedFetch(url, init)", src)

    def test_live_gate_not_available_on_pr(self):
        with patch.dict(os.environ, {"GITHUB_EVENT_NAME": "pull_request"}):
            with self.assertRaisesRegex(t.Denied, "WORKFLOW_SCOPE_DENIED"):
                t.main()

if __name__ == "__main__":
    unittest.main()
