"""Protected, no-deploy Genie QA negative HTTP probes. Never print credentials or response bodies."""
import hashlib
import json
import os
from pathlib import Path
import re
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

def http(url, headers=None, data=None):
    require(url.startswith(BASE + "/") or url.startswith(MGMT) or url == GITHUB_MAIN, "HTTP_TARGET_DENIED")
    req = urllib.request.Request(url, data=None if data is None else json.dumps(data).encode(),
        headers={"Accept": "application/json", "Content-Type": "application/json", **(headers or {})})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect(),
        urllib.request.HTTPSHandler(context=ssl.create_default_context()))
    try:
        with opener.open(req, timeout=25) as res:
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
    token = os.environ.get("QA_BUYER_JWT", "")
    if token:
        row = json.loads(db("""SELECT jsonb_build_object('line_id',l.id,'product_id',l.product_id,'quantity',l.quantity,'uid',d.created_by)
          FROM public.customer_order_draft_lines l JOIN public.customer_order_drafts d ON d.id=l.draft_id
          JOIN auth.sessions s ON s.user_id=d.created_by
          WHERE l.sku_snapshot='GENIE-QA-CAT-03' AND d.status='active' AND d.readiness_status='ready'""", env))
        bearer = {"Authorization": "Bearer " + token}
        status, user = http(BASE + "/auth/v1/user", {**headers, **bearer})
        require(status == 200 and isinstance(user, dict) and user.get("id") == row.get("uid"), "QA_BUYER_JWT_SCOPE_DENIED")
        require(snapshot(env) == BASELINE, "QA_BASELINE_CHANGED_BEFORE_CAS")
        expect("stale_cart_pt409", "/rest/v1/rpc/update_customer_order_draft_line_genie_if_quantity_v1", 409,
               lambda b: isinstance(b, dict) and b.get("code") == "PT409", cas_payload(row), bearer)
    else:
        print("stale_cart_pt409: BLOCKED (existing QA Buyer A session JWT not supplied)")
    print("real_provider_invalid_token: BLOCKED (provider remains disabled)")
    print("rejected_staff_classification: BLOCKED (disabled guard intentionally prevents classification)")
    require(all(checks.values()), "HTTP_ASSERTION_FAILED")
    print("SCOPED_TRANSPORT_ASSERTIONS_PASSED; FULL_NEGATIVE_GATE_NOT_CERTIFIED")
    # The complete gate cannot be marked green for disabled-path evidence.
    raise Denied("FULL_NEGATIVE_GATE_INCOMPLETE")

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
            and os.environ.get("QA_AUTHORIZATION") == "AUTHORIZE-GENIE-QA-NEGATIVE-HTTP",
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
        key = public_key()
        try:
            probes(env, key)
        finally:
            require(snapshot(env) == BASELINE, "QA_PROTECTED_STATE_CHANGED")
            scope(env)
            inventory()
            print("QA_NEGATIVE_HTTP_PRESERVATION_PASS; 17 protected table fingerprints unchanged")

if __name__ == "__main__":
    try:
        main()
    except Denied as exc:
        print("QA_NEGATIVE_HTTP_STOP: " + str(exc))
        raise SystemExit(1)
    except Exception:
        print("QA_NEGATIVE_HTTP_STOP: UNEXPECTED_FAILURE")
        raise SystemExit(1)
