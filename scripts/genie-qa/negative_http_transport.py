"""Protected, no-deploy Genie QA negative HTTP probes. Never print credentials or response bodies."""
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import time
import ssl
import tempfile
import urllib.error
import urllib.request

from verify_qa_target import validate_target

REF = "skhpmltfjgqitntkmclb"
BASE = "https://" + REF + ".supabase.co"
MGMT = "https://api.supabase.com/v1/projects/" + REF + "/"
GITHUB_MAIN = "https://api.github.com/repos/oasisbaklawa2006/oasis-supabase-core/git/ref/heads/main"
ROOT = Path(__file__).resolve().parents[2]
BASELINE = "5a0094bb85895a2f1f510b9adbc99fa152ccf0cb887f5e46790ddff194c662f5"
CAS_HASH = "81991606ba607a1e41553988e288c32e56112859c9127d2e9bcdf9463d5b1d25"
BUNDLES = {
    "msg91-otp": (19, "47b2b980f89ec5a813dc72e5c4de29128dfb1b4a457ee56d57a3eed3cd5c034f"),
    "buyer-login-gateway": (11, "ebb2a2615f9045e2a71b9a9a0c9e1cba7e503523da1812643e7791e1b3dc0398"),
    "msg91-session-bridge": (17, "47c64fb7996548e59301cff7bfe2886a9e06a3bb41b0ff168676abfd8c0d5ee3"),
}
FIXTURES = ("910000000001", "910000000002")

class Denied(Exception):
    pass

def require(ok, label):
    if not ok:
        raise Denied(label)

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

def http(url, headers=None, data=None, *, method=None, raw=None, timeout=25):
    require(url.startswith(BASE + "/") or url.startswith(MGMT) or url == GITHUB_MAIN, "HTTP_TARGET_DENIED")
    require(raw is None or data is None, "HTTP_BODY_AMBIGUOUS")
    req = urllib.request.Request(url, method=method, data=raw if raw is not None else (None if data is None else json.dumps(data).encode()),
        headers={"Accept": "application/json", "Content-Type": "application/json", **(headers or {})})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect(),
        urllib.request.HTTPSHandler(context=ssl.create_default_context()))
    try:
        with opener.open(req, timeout=timeout) as res:
            status, raw = res.status, res.read(2_000_001)
    except urllib.error.HTTPError as exc:
        status, raw = exc.code, exc.read(2_000_001)
    except Exception:
        raise Denied("HTTP_TRANSPORT_FAILED") from None
    require(len(raw) <= 2_000_000, "HTTP_RESPONSE_TOO_LARGE")
    try:
        body = json.loads(raw)
    except (ValueError, UnicodeError):
        body = None
    return status, body

def management(path):
    status, body = http(MGMT + path, {"Authorization": "Bearer " + os.environ["SUPABASE_ACCESS_TOKEN"]})
    require(status == 200, "MANAGEMENT_READ_FAILED")
    return body

def inventory():
    secrets = management("secrets")
    require(isinstance(secrets, list) and all(isinstance(s, dict) and isinstance(s.get("name"), str) for s in secrets), "SECRET_INVENTORY_INVALID")
    names = {s["name"] for s in secrets}
    require(not names.intersection({"QA_MSG91_PROVIDER_ENABLED", "MSG91_AUTH_KEY", "OPENAI_API_KEY"}), "ACTIVATION_OR_PROHIBITED_SECRET_PRESENT")
    for slug, (version, digest) in BUNDLES.items():
        meta = management("functions/" + slug)
        # Report only code-owned slug/field labels; never log returned values.
        # Version advances are never auto-accepted, even with matching content.
        require(isinstance(meta, dict) and meta.get("slug") == slug,
                "QA_BUNDLE_DRIFT:" + slug + ":identity")
        require(type(meta.get("version")) is int and meta["version"] == version,
                "QA_BUNDLE_DRIFT:" + slug + ":version")
        require(meta.get("status") == "ACTIVE", "QA_BUNDLE_DRIFT:" + slug + ":status")
        require(meta.get("ezbr_sha256") == digest, "QA_BUNDLE_DRIFT:" + slug + ":hash")
        require(meta.get("verify_jwt") is False, "QA_BUNDLE_DRIFT:" + slug + ":jwt")

def public_key():
    key = os.environ.get("QA_PUBLISHABLE_KEY", "")
    if not key:
        keys = management("api-keys?reveal=false")
        require(isinstance(keys, list), "PUBLISHABLE_KEY_UNAVAILABLE")
        candidates = [k.get("api_key") for k in keys if isinstance(k, dict)
                      and k.get("type") == "publishable" and not k.get("disabled")
                      and isinstance(k.get("api_key"), str)]
        require(len(candidates) == 1, "PUBLISHABLE_KEY_UNAVAILABLE")
        key = candidates[0]
    require(re.fullmatch(r"sb_publishable_[A-Za-z0-9_-]+", key) is not None, "PUBLISHABLE_KEY_REQUIRED")
    return key

def db(sql, env):
    # Only repository-owned SELECT statements reach this driver. No request
    # inputs are interpolated into SQL. Explicit libpq TLS and read-only
    # transactions replace process execution; credentials never enter argv.
    validate_target(env["PGDATABASE"], mode="apply")
    require(not any(k.startswith("PG") for k in os.environ), "AMBIENT_LIBPQ_ENV_DENIED")
    import psycopg2
    from psycopg2.extensions import register_type, new_type
    conn = None
    try:
        conn = psycopg2.connect(env["PGDATABASE"], sslmode="verify-full",
                                sslrootcert=env["PGSSLROOTCERT"], connect_timeout=10,
                                client_encoding="UTF8",
                                options="-c default_transaction_read_only=on -c statement_timeout=15000")
        conn.set_session(readonly=True, autocommit=False)
        # Preserve PostgreSQL's exact JSON/JSONB text, not re-serialized Python
        # objects: the original protected fingerprint includes one final LF.
        register_type(new_type((114, 3802), "QA_JSON_TEXT", lambda value, cursor: value), conn)
        with conn.cursor() as cur:
            cur.execute("SHOW transaction_read_only")
            require(cur.fetchone() == ("on",), "QA_DATABASE_NOT_READ_ONLY")
            cur.execute(sql)
            require(cur.description is not None and len(cur.description) == 1, "QA_DATABASE_RESULT_INVALID")
            rows = cur.fetchall()
            require(all(len(row) == 1 and isinstance(row[0], str) for row in rows), "QA_DATABASE_RESULT_INVALID")
            return "".join(row[0] + "\n" for row in rows).encode("utf-8")
    except Denied:
        raise
    except Exception:
        raise Denied("QA_DATABASE_READ_FAILED") from None
    finally:
        if conn is not None:
            try:
                conn.rollback()
            finally:
                conn.close()

def census_select():
    # Preserve the canonical census SELECT byte-for-byte. Strip only its
    # fixed transaction envelope because the driver owns the transaction.
    source = (ROOT / "scripts/genie-qa/forward_preservation.sql").read_text()
    prefix = "-- Read-only protected-state census; never return raw records or credentials.\nBEGIN READ ONLY;\n"
    suffix = "\nCOMMIT;\n"
    require(source.startswith(prefix) and source.endswith(suffix), "QA_CENSUS_ENVELOPE_CHANGED")
    return source[len(prefix):-len(suffix)]

def snapshot(env):
    raw = db(census_select(), env)
    try:
        obj = json.loads(raw)
    except ValueError:
        raise Denied("QA_CENSUS_INVALID") from None
    require(len(obj) == 17 and all(isinstance(v, dict) and isinstance(v.get("count"), int)
            and re.fullmatch(r"[0-9a-f]{64}", v.get("sha256", "")) for v in obj.values()), "QA_CENSUS_INVALID")
    return hashlib.sha256(raw).hexdigest()

def scope(env):
    files = sorted(x.name.split("_", 1)[0] for x in (ROOT / "supabase/migrations").glob("*.sql"))
    ledger = db("SELECT version FROM supabase_migrations.schema_migrations ORDER BY version", env).decode().splitlines()
    require(len(files) == 533 and files == ledger, "QA_LEDGER_DRIFT")
    sql = """SELECT jsonb_build_object(
        'cas_sha',encode(sha256(convert_to(pg_get_functiondef('public.update_customer_order_draft_line_genie_if_quantity_v1(uuid,uuid,numeric,numeric)'::regprocedure),'UTF8')),'hex'),
        'unsafe',(SELECT count(*) FROM pg_extension WHERE extname IN ('pg_cron','pg_net','http','dblink')),
        'cron',to_regclass('cron.job') IS NOT NULL,
        'orders',(SELECT count(*) FROM public.orders),
        'auth_users',(SELECT count(*) FROM auth.users),
        'sessions',(SELECT count(*) FROM auth.sessions),
        'lines',(SELECT count(*) FROM public.customer_order_draft_lines),
        'drafts',(SELECT count(*) FROM public.customer_order_drafts WHERE status='active' AND readiness_status='ready'),
        'rejected',(SELECT count(*) FROM public.b2b_applications WHERE id='a6221000-0000-4000-8000-000000000001' AND business_name='GENIE-QA-REJECTED' AND status='rejected' AND user_id IS NULL AND resolved_company_id IS NULL AND contact_phone='0000000001'),
        'staff',(SELECT count(*) FROM public.users WHERE id='a6221000-0000-4000-8000-000000000002' AND name='GENIE-QA-STAFF' AND role='staff' AND company_id IS NULL AND phone='0000000002'),
        'fixture_auth',(SELECT count(*) FROM auth.users WHERE id IN ('a6221000-0000-4000-8000-000000000001','a6221000-0000-4000-8000-000000000002')),
        'a_total',(SELECT sum(quantity*unit_price_snapshot*(CASE WHEN tax_inclusive_snapshot THEN 1 ELSE 1+gst_rate_snapshot/100 END)) FROM public.customer_order_draft_lines WHERE sku_snapshot IN ('GENIE-QA-CAT-01','GENIE-QA-CAT-03')),
        'b_total',(SELECT sum(quantity*unit_price_snapshot*(CASE WHEN tax_inclusive_snapshot THEN 1 ELSE 1+gst_rate_snapshot/100 END)) FROM public.customer_order_draft_lines WHERE sku_snapshot='GENIE-QA-CAT-04')
    )"""
    state = json.loads(db(sql, env))
    require(state == {"cas_sha": CAS_HASH, "unsafe": 0, "cron": False, "orders": 0, "auth_users": 3,
                      "sessions": 1, "lines": 3, "drafts": 2, "rejected": 1, "staff": 1,
                      "fixture_auth": 0, "a_total": 3906, "b_total": 525}, "QA_SCOPE_DRIFT")

def classify_denial(body):
    return isinstance(body, dict) and body.get("ok") is True and body.get("allowOtp") is False and body.get("state") == "ambiguous"

def cas_payload(row):
    require(row.get("quantity") == 18 and row.get("product_id") == "a6182000-0000-4000-8000-000000000003", "QA_CAS_TARGET_DRIFT")
    require(re.fullmatch(r"[0-9a-f-]{36}", row.get("line_id", "")) is not None, "QA_CAS_LINE_INVALID")
    # Exercise the same pinned PT409 branch through a stale product assertion.
    # CAT-04 deliberately differs from this CAT-03 line. Governed Cart writers
    # never change an existing line's product_id; removal makes its ID absent.
    # Thus even if another writer reaches expected quantity 19, the product
    # mismatch still rejects before the delegated update. No positive write path.
    return {"p_line_id": row["line_id"], "p_product_id": "a6182000-0000-4000-8000-000000000004",
            "p_expected_quantity": 19, "p_quantity": 18}


# One ephemeral, TTL-bound scratch function; never update an existing slug.
def pinned_source(relative, blob):
    data = (ROOT / relative).read_bytes()
    require(hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data, usedforsecurity=False).hexdigest() == blob,
            "CANONICAL_PROBE_SOURCE_DRIFT")
    return data.decode("utf-8")

def stage_probe(run_id, proof, expiry):
    require(re.fullmatch(r"[0-9a-f]{24}", run_id) is not None and
            re.fullmatch(r"[0-9a-f]{64}", proof) is not None and type(expiry) is int, "PROBE_LITERAL_INVALID")
    snapshot_source = pinned_source("scripts/genie-qa/central-buyer-login-gateway.snapshot.txt",
                                    "2f1ff3124137910716d790977ba8fc7e88dba85d")
    verifier = pinned_source("supabase/functions/msg91-otp/provider-verify.mjs",
                             "fa37809f6eb9a4413cb9c398fb7adf10ef20490c")
    # Reuse exact mobile classifier, including precedence and phone matching.
    # Exclude canonical request handler, email lookup and rate limiter.
    parts = (("const BUYER_ROLES =", "// Best-effort hot-worker limiter."),
             ("function normalizePhone(", "async function classifyEmail("),
             ("async function classifyMobile(", "serve(async (req)"))
    blocks = []
    for start, end in parts:
        require(snapshot_source.count(start) == 1 and snapshot_source.count(end) == 1, "CLASSIFIER_MARKER_DRIFT")
        first, last = snapshot_source.index(start), snapshot_source.index(end)
        require(first < last, "CLASSIFIER_MARKER_DRIFT")
        blocks.append(snapshot_source[first:last])
    classifier = "\n".join(blocks)
    old = 'console.error("[buyer-login-gateway] mobile lookup failed", lookupError.message);'
    require(classifier.count(old) == 1, "CLASSIFIER_LOG_DRIFT")
    classifier = classifier.replace(old, 'console.error("QA_CLASSIFIER_LOOKUP_FAILED");')
    template = (ROOT / "scripts/genie-qa/negative_http_probe_template.ts").read_text()
    for marker, value in (("__PROOF_SHA__", hashlib.sha256(proof.encode()).hexdigest()),
                          ("__RUN_ID__", run_id), ("__EXPIRES_MS__", str(expiry)),
                          ("// __CANONICAL_CLASSIFIER__", classifier)):
        require(template.count(marker) == 1, "PROBE_TEMPLATE_DRIFT")
        template = template.replace(marker, value)
    require(proof not in template and "__CANONICAL_CLASSIFIER__" not in template, "PROBE_STAGE_INVALID")
    return {"index.ts": template, "provider-verify.mjs": verifier}

def function_inventory():
    rows = management("functions")
    require(isinstance(rows, list) and all(isinstance(row, dict) and isinstance(row.get("slug"), str) for row in rows),
            "FUNCTION_INVENTORY_INVALID")
    require(len({row["slug"] for row in rows}) == len(rows), "FUNCTION_INVENTORY_INVALID")
    return {row["slug"]: row for row in rows}

def exact_function_set():
    require(set(function_inventory()) == set(BUNDLES), "UNEXPECTED_QA_FUNCTION")

def management_mutation(method, path, raw=None, content_type="application/json"):
    # Only this scratch function deployment/deletion lane has write authority.
    require((method == "POST" and re.fullmatch(r"functions/deploy\?slug=genie-qa-negative-[0-9a-f]{24}(?:&bundleOnly=true)?", path))
            or (method == "DELETE" and re.fullmatch(r"functions/genie-qa-negative-[0-9a-f]{24}", path)),
            "MANAGEMENT_MUTATION_DENIED")
    return http(MGMT + path, {"Authorization": "Bearer " + os.environ["SUPABASE_ACCESS_TOKEN"],
                              "Content-Type": content_type}, method=method, raw=raw, timeout=120)

def multipart(slug, files):
    require(re.fullmatch(r"genie-qa-negative-[0-9a-f]{24}", slug) is not None and
            set(files) == {"index.ts", "provider-verify.mjs"}, "PROBE_MULTIPART_SCOPE")
    boundary = "genie-qa-" + secrets.token_hex(20)
    parts = []
    metadata = json.dumps({"name": slug, "entrypoint_path": "index.ts", "verify_jwt": False})
    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="metadata"\r\nContent-Type: application/json\r\n\r\n{metadata}\r\n')
    for name in ("index.ts", "provider-verify.mjs"):
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{name}"\r\nContent-Type: application/octet-stream\r\n\r\n{files[name]}\r\n')
    parts.append(f"--{boundary}--\r\n")
    return "".join(parts).encode(), "multipart/form-data; boundary=" + boundary

def scratch_meta(meta, slug, digest=None):
    require(isinstance(meta, dict) and meta.get("slug") == slug and meta.get("verify_jwt") is False
            and isinstance(meta.get("id"), str) and re.fullmatch(r"[0-9a-f]{64}", meta.get("ezbr_sha256") or "") is not None,
            "SCRATCH_METADATA_INVALID")
    if digest is not None:
        require(meta["ezbr_sha256"] == digest and meta.get("status") == "ACTIVE" and meta.get("version") == 1,
                "SCRATCH_BUNDLE_DRIFT")
    return meta["ezbr_sha256"]

def recover_fixture(env, call, run_id):
    # Read only; exact run marker, not a broad account deletion or audit cleanup.
    rows = json.loads(db("""SELECT coalesce(jsonb_agg(jsonb_build_object('id',id,'email',email,'run',
        raw_app_meta_data->>'genie_qa_transport_run')),'[]'::jsonb)
        FROM auth.users WHERE email LIKE 'genie-qa-transport-%@example.invalid'""", env))
    require(isinstance(rows, list) and len(rows) <= 1, "SCRATCH_IDENTITY_AMBIGUOUS")
    if rows:
        row = rows[0]
        require(row.get("email") == "genie-qa-transport-" + run_id + "@example.invalid" and
                row.get("run") == run_id and re.fullmatch(r"[0-9a-f-]{36}", row.get("id") or "") is not None,
                "SCRATCH_IDENTITY_SCOPE_DENIED")
        status, body = call({"action":"cleanup", "uid":row["id"]})
        require(status == 200 and body == {"ok":True,"cleanup_complete":True}, "SCRATCH_IDENTITY_CLEANUP_FAILED")

def full_probes(env, key):
    # Assert original immutable state before any temporary principal exists.
    scope(env)
    require(snapshot(env) == BASELINE, "QA_BASELINE_CHANGED_BEFORE_SCRATCH")
    inventory()
    exact_function_set()
    run_id, proof = secrets.token_hex(12), secrets.token_hex(32)
    slug = "genie-qa-negative-" + run_id
    files = stage_probe(run_id, proof, int(time.time() * 1000) + 12 * 60 * 1000)
    raw, content_type = multipart(slug, files)
    digest = None
    deployment_attempted = False
    def call(body):
        return http(BASE + "/functions/v1/" + slug, {"apikey":key, "x-genie-qa-proof":proof},
                    body, timeout=150)
    try:
        require(slug not in function_inventory(), "SCRATCH_SLUG_COLLISION")
        deployment_attempted = True
        status, compiled = management_mutation("POST", "functions/deploy?slug=" + slug + "&bundleOnly=true", raw, content_type)
        require(status == 201, "SCRATCH_BUNDLE_PREFLIGHT_FAILED")
        digest = scratch_meta(compiled, slug)
        require(slug not in function_inventory(), "SCRATCH_SLUG_COLLISION")
        assert_exact_main()
        inventory()
        require(snapshot(env) == BASELINE, "QA_BASELINE_CHANGED_BEFORE_DEPLOY")
        status, deployed = management_mutation("POST", "functions/deploy?slug=" + slug, raw, content_type)
        require(status == 201, "SCRATCH_DEPLOY_FAILED")
        scratch_meta(deployed, slug, digest)
        scratch_meta(management("functions/" + slug), slug, digest)
        # Anonymous call with no capability must never enter the handler.
        status, body = http(BASE + "/functions/v1/" + slug, {"apikey":key}, {"action":"pt409"})
        require(status == 403 and body == {"ok":False,"error":"scope_denied"}, "SCRATCH_CAPABILITY_DENIAL_FAILED")
        for action, expected in (("rejected","rejected"),("staff","employee")):
            status, body = call({"action":action})
            require(status == 200 and body == {"ok":True,"state":expected,"allowOtp":False}, "FIXTURE_CLASSIFICATION_FAILED:" + action)
            print(action + "_fixture_classification: HTTP 200 PASS", flush=True)
        status, body = call({"action":"provider"})
        require(status in (401,403) and isinstance(body, dict) and body.get("ok") is False
                and body.get("error") == "provider_verification_failed" and body.get("provider_reached") is True
                and body.get("provider_invalid_token") is True and body.get("upstream_status") in (200,400,401,403),
                "REAL_PROVIDER_DENIAL_NOT_PROVEN")
        print("real_provider_invalid_token: HTTP " + str(status) + " PASS", flush=True)
        require(snapshot(env) == BASELINE, "QA_BASELINE_CHANGED_BEFORE_CAS")
        inventory()
        status, body = call({"action":"pt409"})
        require(status == 409 and body == {"ok":False,"code":"PT409","upstream_status":409,
                "synthetic_session":True,"cleanup_complete":True}, "REAL_PT409_NOT_PROVEN")
        print("stale_cart_pt409: HTTP 409 / PT409 PASS", flush=True)
    finally:
        if deployment_attempted:
            # Recover only the matching temporary principal, never delete audit
            # rows or alter the two existing users. Attempt deletion even if recovery fails.
            try:
                recover_fixture(env, call, run_id)
            finally:
                current = function_inventory().get(slug)
                if current is not None:
                    # A failed compile/deploy can leave an inactive new function.
                    # Only our previously absent, random slug and first version may be removed.
                    require(current.get("slug") == slug and current.get("version") == 1
                            and current.get("verify_jwt") is False, "SCRATCH_CLEANUP_SCOPE_DENIED")
                    if digest is not None:
                        require(current.get("ezbr_sha256") == digest, "SCRATCH_CLEANUP_HASH_DRIFT")
                    status, _ = management_mutation("DELETE", "functions/" + slug)
                    require(status in (200,204), "SCRATCH_DELETE_FAILED")
                require(slug not in function_inventory(), "SCRATCH_FUNCTION_REMAINS")
        exact_function_set()

def probes(env, key):
    headers = {"apikey": key}
    checks = {}
    def expect(name, path, status_expected, predicate=lambda body: True, data=None, extra=None):
        status, body = http(BASE + path, {**headers, **(extra or {})}, data)
        checks[name] = status == status_expected and predicate(body)
        print(name + ": HTTP " + str(status) + (" PASS" if checks[name] else " FAIL"), flush=True)
    expect("missing_jwt", "/auth/v1/user", 401)
    # Observed GoTrue contract (2026-11-28): malformed JWT yields 403 bad_jwt;
    # PostgREST separately must return 401. Do not accept arbitrary 4xx.
    expect("invalid_jwt", "/auth/v1/user", 403,
           lambda b: isinstance(b, dict) and b.get("error_code") == "bad_jwt" and "id" not in b,
           extra={"Authorization": "Bearer invalid.qa.token"})
    expect("invalid_jwt_cart_rpc", "/rest/v1/rpc/get_customer_order_draft_v1", 401,
           data={}, extra={"Authorization": "Bearer invalid.qa.token"})
    # This verifies malformed provider proof denial, not a real MSG91 challenge.
    # Non-string accessToken cannot reach provider even if someone toggles activation.
    inventory()
    expect("malformed_provider_proof_disabled", "/functions/v1/msg91-otp", 401,
           lambda b: isinstance(b, dict) and b.get("error") == "provider_verification_failed",
           {"mode": "verify_widget", "accessToken": {"invalid": True}})
    for label, sentinel in zip(("rejected_fixture", "staff_fixture"), FIXTURES):
        expect(label + "_disabled_gateway_denial", "/functions/v1/buyer-login-gateway", 200,
               classify_denial, {"mode": "preflight", "channel": "mobile", "identifier": sentinel})
    require(all(checks.values()), "HTTP_ASSERTION_FAILED")
    full_probes(env, key)
    print("ALL_TEN_NEGATIVE_HTTP_ASSERTIONS_PASSED", flush=True)

def assert_exact_main():
    # actions/checkout with an explicit commit SHA leaves HEAD detached.
    # Reject symbolic refs rather than resolving any caller-supplied path.
    head = (ROOT / ".git/HEAD").read_text().strip()
    require(re.fullmatch(r"[0-9a-f]{40}", head) is not None
            and head == os.environ.get("EXPECTED_SHA"), "CHECKOUT_MISMATCH")
    status, body = http(GITHUB_MAIN, {"Authorization": "Bearer " + os.environ["GH_TOKEN"],
                                     "X-GitHub-Api-Version": "2022-11-28"})
    require(status == 200 and isinstance(body, dict) and body.get("ref") == "refs/heads/main"
            and isinstance(body.get("object"), dict) and body["object"].get("sha") == head, "MAIN_MOVED")

def main():
    require(os.environ.get("GITHUB_REPOSITORY") == "oasisbaklawa2006/oasis-supabase-core"
            and os.environ.get("GITHUB_REF") == "refs/heads/main"
            and os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
            and re.fullmatch(r"[0-9a-f]{40}", os.environ.get("EXPECTED_SHA", "")) is not None
            and os.environ.get("GITHUB_SHA") == os.environ.get("EXPECTED_SHA")
            and os.environ.get("QA_AUTHORIZATION") == "AUTHORIZE-GENIE-QA-DISPOSABLE-NEGATIVE-HTTP",
            "WORKFLOW_SCOPE_DENIED")
    assert_exact_main()
    try:
        validate_target(os.environ.get("QA_DATABASE_URL", ""), mode="apply")
    except ValueError:
        raise Denied("QA_DATABASE_TARGET_DENIED") from None
    with tempfile.TemporaryDirectory(prefix="qa-negative-http-") as tmp:
        ca = Path(tmp) / "ca.pem"
        ca.write_text(os.environ.get("QA_CA_CERT_PEM", ""))
        ca.chmod(0o600)
        require(ca.stat().st_size > 0, "QA_CA_MISSING")
        env = {"PGDATABASE": os.environ["QA_DATABASE_URL"], "PGSSLROOTCERT": str(ca)}
        scope(env)
        require(snapshot(env) == BASELINE, "QA_BASELINE_CHANGED")
        inventory()
        try:
            key = public_key()
            probes(env, key)
        finally:
            # Check secret/function inventory even if preservation fails.
            try:
                try:
                    scope(env)
                finally:
                    require(snapshot(env) == BASELINE, "QA_PROTECTED_STATE_CHANGED")
            finally:
                inventory()
                exact_function_set()
        print("QA_NEGATIVE_HTTP_PRESERVATION_PASS; 17 protected table fingerprints unchanged")
        print("FULL_NEGATIVE_GATE_PASS")

if __name__ == "__main__":
    try:
        main()
    except Denied as exc:
        print("QA_NEGATIVE_HTTP_STOP: " + str(exc))
        raise SystemExit(1)
    except Exception:
        print("QA_NEGATIVE_HTTP_STOP: UNEXPECTED_FAILURE")
        raise SystemExit(1)
