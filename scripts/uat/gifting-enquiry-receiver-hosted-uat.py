#!/usr/bin/env python3
"""Synthetic hosted UAT for the Gifting enquiry receiver (Central #677, Core PR #557).

Run only from the manually dispatched workflow .github/workflows/gifting-receiver-hosted-uat.yml, or locally
in --local-test mode against a scratch database. It targets exactly one allow-listed, isolated preview branch,
uses a scoped short-lived consumer/token created and revoked inside this run, and writes evidence only after a
credential-redaction scan passes. It never prints, stores or uploads a credential.

Standard library only. Database access goes through the `psql` client: connection details travel in PG*
environment variables (never on the command line) and every value in SQL is passed as a psql variable and
quoted by psql itself (`:'name'`), never interpolated into the statement text.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import http.client
import json
import os
import re
import shutil
import ssl
import subprocess  # nosec B404 - only used to run the psql client with a fixed argument list, never a shell
import sys
import urllib.parse
import uuid
from datetime import datetime, timezone
from pathlib import Path

REF_RE = re.compile(r"^[a-z]{20}$")
TOKEN_RE = re.compile(r"oc_(?:preview|staging|production)_[0-9a-f]{16,}")
RECEIVER_MIGRATION = "20261119020000"
UAT_SOURCE = "uat-hosted-synthetic"
TOKEN_TTL_MINUTES = 30
PROFILE_KEY = "gifting_enquiries_v1"
TARGETS_FILE = Path(__file__).resolve().parents[2] / "docs" / "programme" / "gifting-uat-targets.json"


class UatAbort(Exception):
    """A safety condition failed; nothing further is attempted."""


# ----------------------------------------------------------------------------- guards (unit-tested)
def load_targets(path: Path = TARGETS_FILE) -> dict:
    return json.loads(path.read_text())


def validate_target(ref: str, targets: dict) -> dict:
    """The ref must be well formed, allow-listed, non-persistent, data-free and never forbidden."""
    if not REF_RE.match(ref or ""):
        raise UatAbort("preview ref must be 20 lowercase letters")
    if ref in targets.get("forbidden_refs", []):
        raise UatAbort("refusing a forbidden (production) project ref")
    for entry in targets.get("targets", []):
        if entry.get("ref") == ref:
            if entry.get("persistent") is not False or entry.get("with_data") is not False:
                raise UatAbort("allow-list entry must describe a non-persistent, data-free preview")
            return entry
    raise UatAbort("ref is not in the reviewed UAT target allow-list")


def parse_db_url(url: str) -> dict:
    parsed = urllib.parse.urlparse(url or "")
    if parsed.scheme not in ("postgres", "postgresql") or not parsed.hostname:
        raise UatAbort("GIFTING_UAT_DB_URL is not a postgres URL")
    return {
        "host": parsed.hostname,
        "port": str(parsed.port or 5432),
        "user": urllib.parse.unquote(parsed.username or ""),
        "password": urllib.parse.unquote(parsed.password or ""),
        "dbname": (parsed.path or "/postgres").lstrip("/") or "postgres",
        "sslmode": urllib.parse.parse_qs(parsed.query).get("sslmode", ["require"])[0],
    }


def assert_db_matches_ref(conn: dict, ref: str) -> None:
    """The database credential must belong to the allow-listed ref (direct host or pooler user)."""
    if f"db.{ref}.supabase.co" == conn["host"] or conn["user"].endswith(f".{ref}"):
        return
    raise UatAbort("database URL does not belong to the allow-listed preview ref")


def function_url(ref: str) -> str:
    return f"https://{ref}.supabase.co/functions/v1/gifting-enquiries"


def scan_for_secrets(text: str, secrets: list[str]) -> list[str]:
    hits = []
    if TOKEN_RE.search(text):
        hits.append("token-pattern")
    for secret in secrets:
        if secret and len(secret) >= 8 and secret in text:
            hits.append("known-secret")
    return hits


# ----------------------------------------------------------------------------- database access
class Db:
    """psql wrapper: values are passed as psql variables and quoted by psql (:'name'), never formatted into SQL."""

    def __init__(self, conn: dict, local: bool) -> None:
        psql = shutil.which("psql")
        if not psql:
            raise UatAbort("the psql client is required")
        self.psql = psql
        self.env = {**os.environ, "PGHOST": conn["host"], "PGPORT": conn["port"], "PGUSER": conn["user"],
                    "PGDATABASE": conn["dbname"], "PGSSLMODE": "disable" if local else conn["sslmode"],
                    "PGCONNECT_TIMEOUT": "15", "PGOPTIONS": "-c statement_timeout=30000"}
        if conn["password"]:
            self.env["PGPASSWORD"] = conn["password"]

    def run(self, sql: str, **variables: str) -> str:
        args = [self.psql, "-X", "-A", "-t", "-q", "-v", "ON_ERROR_STOP=1"]
        for name, value in variables.items():
            args += ["-v", f"{name}={value}"]
        args += ["-f", "-"]
        # Reviewed exception: argv[0] is the resolved psql binary, flags are literals, there is no shell, and every
        # caller-supplied value travels as a psql variable that psql itself quotes (:'name'), never as SQL text.
        proc = subprocess.run(  # nosec B603  # nosemgrep
            args, input=sql, env=self.env, capture_output=True, text=True, timeout=60, check=False)
        if proc.returncode != 0:
            # psql errors can echo query text; never surface it beyond a generic message.
            raise UatAbort("database statement failed")
        return proc.stdout.strip()


def mask(value: str) -> None:
    if os.environ.get("GITHUB_ACTIONS") == "true":
        print(f"::add-mask::{value}")


# ----------------------------------------------------------------------------- HTTP
def request(url: str, method: str, token: str | None, key: str | None, body, ctx: ssl.SSLContext,
            content_type: str = "application/json") -> tuple[int, dict | None]:
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or not parsed.hostname:
        raise UatAbort("function URL must be https")
    headers = {"content-type": content_type}
    if token:
        headers["authorization"] = f"Bearer {token}"
    if key is not None:
        headers["idempotency-key"] = key
    data = None
    if method == "POST":
        data = body if isinstance(body, (bytes, bytearray)) else json.dumps(body).encode()
    conn = http.client.HTTPSConnection(parsed.hostname, parsed.port or 443, timeout=20, context=ctx)
    try:
        conn.request(method, parsed.path or "/", body=data, headers=headers)
        response = conn.getresponse()
        raw = response.read()
    finally:
        conn.close()
    try:
        return response.status, json.loads(raw or b"null")
    except ValueError:
        return response.status, {"_raw": "non-json"}


def payload(message: str = "Synthetic hosted UAT enquiry", kind: str = "corporate") -> dict:
    return {"kind": kind, "email": "uat-synthetic@example.invalid", "phone": "+919999900000",
            "name": "UAT Synthetic", "company": None, "message": message, "source": UAT_SOURCE,
            "consent": {"marketing": False, "timestamp": None}, "attribution": {"utm_source": "uat"}}


# ----------------------------------------------------------------------------- the run
class Uat:
    def __init__(self, db: Db, url: str, ctx: ssl.SSLContext, local: bool, run_id: str) -> None:
        self.db, self.url, self.ctx, self.local = db, url, ctx, local
        self.env_name = "staging" if local else "preview"
        self.consumer_key = f"gifting-uat-hosted-{run_id}"
        self.tokens: dict[str, str] = {}
        self.results: list[dict] = []

    def check(self, name: str, ok: bool, observed: str) -> None:
        self.results.append({"scenario": name, "pass": bool(ok), "observed": observed})
        print(f"{'PASS' if ok else 'FAIL'}  {name}  {observed}")

    def post(self, token, key, body, **kw):
        return request(self.url, "POST", token, key, body, self.ctx, **kw)

    def rows(self, lead: str) -> int:
        return int(self.db.run("select count(*) from public.gifting_enquiries where source_lead_id = :'lead'", lead=lead) or 0)

    # -- preflight: read-only; abort before any write
    def preflight(self) -> None:
        migrated = "true" if self.local else self.db.run(
            "select (exists(select 1 from supabase_migrations.schema_migrations where version = :'version'))::text",
            version=RECEIVER_MIGRATION)
        table = self.db.run("select (to_regclass('public.gifting_enquiries') is not null)::text")
        has_products = self.db.run("select (to_regclass('public.products') is not null)::text") == "true"
        products = self.db.run("select count(*)::text from public.products") if has_products else "0"
        foreign_consumers = "0" if self.local else self.db.run(
            "select count(*)::text from public.connect_consumers where consumer_key not like 'gifting-uat-%'")
        foreign_rows = self.db.run("select count(*)::text from public.gifting_enquiries where source not like 'uat-%'")
        anon_exec = self.db.run(
            "select has_function_privilege('anon','public.gifting_enquiry_receive_v1(text,uuid,jsonb)','EXECUTE')::text")
        if migrated != "true" or table != "true":
            raise UatAbort("the receiver migration is not applied on this target")
        if products != "0" or foreign_consumers != "0" or foreign_rows != "0":
            raise UatAbort("target is not an empty, isolated preview (data or foreign consumers present)")
        if anon_exec != "false":
            raise UatAbort("anon can execute the receiver RPC on this target")
        print("preflight: isolated, empty, receiver migration present, anon cannot execute the RPC")

    # -- provisioning: dedicated synthetic consumer and short-lived tokens, created inside the database
    def provision(self) -> list[str]:
        sql = """
with c as (select public.connect_admin_register_consumer_v1(:'consumer_key', 'b2c_website', :'env', 'Hosted synthetic UAT (temporary)') j),
b as (select public.connect_admin_bind_profile_v1((c.j->>'consumer_id')::uuid,
        (select id from public.connect_profiles where profile_key = :'profile'), :'env') from c),
t1 as (select 'OK=' || (public.connect_admin_issue_token_v1((c.j->>'consumer_id')::uuid, array['enquiries:gifting:write'], :'env',
        now() + make_interval(mins => :'ttl'::int), 60)->>'token') from c, b),
t2 as (select 'EXPIRED=' || (public.connect_admin_issue_token_v1((c.j->>'consumer_id')::uuid, array['enquiries:gifting:write'], :'env',
        now() - interval '1 minute', 60)->>'token') from c, b),
t3 as (select 'SCOPE=' || (public.connect_admin_issue_token_v1((c.j->>'consumer_id')::uuid, array['catalogue:read'], :'env',
        now() + make_interval(mins => :'ttl'::int), 60)->>'token') from c, b),
t4 as (select public.connect_admin_issue_token_v1((c.j->>'consumer_id')::uuid, array['enquiries:gifting:write'], :'env',
        now() + make_interval(mins => :'ttl'::int), 60) j from c, b),
t4r as (select 'REVOKED=' || (t4.j->>'token') || '|'
        || (select public.connect_admin_revoke_token_v1((t4.j->>'token_id')::uuid)::text) from t4)
select * from t1 union all select * from t2 union all select * from t3 union all select * from t4r
"""
        out = self.db.run(sql, consumer_key=self.consumer_key, env=self.env_name, profile=PROFILE_KEY, ttl=str(TOKEN_TTL_MINUTES))
        for line in out.splitlines():
            name, _, value = line.partition("=")
            self.tokens[name] = value.split("|")[0]
            mask(self.tokens[name])
        if set(self.tokens) != {"OK", "EXPIRED", "SCOPE", "REVOKED"}:
            raise UatAbort("credential provisioning did not complete")
        return list(self.tokens.values())

    # -- scenarios
    def credentials(self, lead: str, body: dict) -> None:
        cases = (("missing token", None, 401), ("invalid token", "x" * 48, 401), ("expired token", self.tokens["EXPIRED"], 401),
                 ("wrong-scope token", self.tokens["SCOPE"], 403), ("revoked token", self.tokens["REVOKED"], 401))
        for name, token, want in cases:
            status, _ = self.post(token, lead, body)
            self.check(f"credential: {name} -> HTTP {want}", status == want, f"got {status}")
        self.check("credential: no row written by any rejected credential", self.rows(lead) == 0, f"rows={self.rows(lead)}")

    def delivery(self, lead: str, body: dict) -> None:
        ok = self.tokens["OK"]
        s1, r1 = self.post(ok, lead, body)
        r1 = r1 or {}
        self.check("delivery: first delivery -> 201 accepted",
                   s1 == 201 and r1.get("status") == "accepted" and r1.get("queue") == "gifting_enquiries"
                   and r1.get("sourceLeadId") == lead, f"got {s1}")
        self.check("delivery: exactly one enquiry persisted", self.rows(lead) == 1, f"rows={self.rows(lead)}")
        s2, r2 = self.post(ok, lead, body)
        r2 = r2 or {}
        self.check("replay: identical replay -> 200 with the same enquiryId",
                   s2 == 200 and r2.get("enquiryId") == r1.get("enquiryId") and r2.get("replayed") is True, f"got {s2}")
        self.check("replay: still one row", self.rows(lead) == 1, f"rows={self.rows(lead)}")
        s3, _ = self.post(ok, lead, payload("CHANGED"))
        stored = self.db.run("select message from public.gifting_enquiries where source_lead_id = :'lead'", lead=lead)
        self.check("conflict: different payload for the same lead -> 409", s3 == 409, f"got {s3}")
        unchanged = stored == body["message"]
        self.check("conflict: stored enquiry not overwritten", unchanged, "unchanged" if unchanged else "CHANGED")
        s4, r4 = self.post(ok, lead, body)
        self.check("replay: exact replay still succeeds after a rejected conflict",
                   s4 == 200 and (r4 or {}).get("enquiryId") == r1.get("enquiryId"), f"got {s4}")

    def concurrency(self, lead: str, body: dict) -> None:
        with concurrent.futures.ThreadPoolExecutor(max_workers=20) as pool:
            outs = list(pool.map(lambda _: self.post(self.tokens["OK"], lead, body), range(20)))
        ids = {(o[1] or {}).get("enquiryId") for o in outs}
        self.check("concurrency: 20 simultaneous deliveries all accepted", all(o[0] in (200, 201) for o in outs),
                   ",".join(sorted({str(o[0]) for o in outs})))
        self.check("concurrency: exactly one row and one enquiryId", self.rows(lead) == 1 and len(ids) == 1,
                   f"rows={self.rows(lead)} ids={len(ids)}")

    def marketing_and_validation(self, lead: str, body: dict) -> None:
        ok = self.tokens["OK"]
        for kind in ("newsletter", "rewards"):
            status, _ = self.post(ok, lead, payload(kind=kind))
            self.check(f"marketing: {kind} -> 422", status == 422, f"got {status}")
        self.check("marketing: no marketing-only row in the queue", self.rows(lead) == 0, f"rows={self.rows(lead)}")
        status, _ = self.post(ok, "not-a-uuid", body)
        self.check("validation: bad idempotency key -> 400", status == 400, f"got {status}")
        status, _ = self.post(ok, lead, b"{not json")
        self.check("validation: invalid JSON -> 400", status == 400, f"got {status}")
        status, _ = self.post(ok, lead, body, content_type="text/plain")
        self.check("validation: wrong media type -> 415", status == 415, f"got {status}")
        status, _ = request(self.url, "GET", None, None, None, self.ctx)
        self.check("validation: GET -> 405", status == 405, f"got {status}")

    # -- cleanup: runs even after a failure; revokes every token, suspends the consumer, proves it
    def cleanup(self) -> bool:
        try:
            self.db.run("update public.connect_tokens set revoked_at = coalesce(revoked_at, now()) "
                        "where consumer_id = (select id from public.connect_consumers where consumer_key = :'consumer_key')",
                        consumer_key=self.consumer_key)
            self.db.run("update public.connect_consumers set status = 'suspended' where consumer_key = :'consumer_key'",
                        consumer_key=self.consumer_key)
            live = self.db.run(
                "select count(*) from public.connect_tokens t join public.connect_consumers c on c.id = t.consumer_id "
                "where c.consumer_key = :'consumer_key' and t.revoked_at is null and (t.expires_at is null or t.expires_at > now())",
                consumer_key=self.consumer_key)
            done = live == "0"
            self.check("cleanup: no live UAT token remains and the consumer is suspended", done, f"live_tokens={live}")
            if self.tokens.get("OK"):
                status, _ = self.post(self.tokens["OK"], str(uuid.uuid4()), payload())
                self.check("cleanup: the valid token is rejected after revocation", status == 401, f"got {status}")
            return done
        except (UatAbort, OSError, subprocess.SubprocessError, http.client.HTTPException) as err:
            self.check("cleanup: revocation failed - revoke the UAT consumer manually", False, type(err).__name__)
            return False


def build_context(args: argparse.Namespace) -> tuple[dict, str, str, ssl.SSLContext, bool]:
    local = args.local_test
    if local and (os.environ.get("GIFTING_UAT_LOCAL_TEST") != "1" or os.environ.get("GITHUB_ACTIONS")):
        raise UatAbort("--local-test needs GIFTING_UAT_LOCAL_TEST=1 and is refused inside GitHub Actions")
    if os.environ.get("GITHUB_ACTIONS") and os.environ.get("GITHUB_EVENT_NAME") != "workflow_dispatch":
        raise UatAbort("hosted UAT runs only from a manual workflow_dispatch")
    conn = parse_db_url(os.environ.get("GIFTING_UAT_DB_URL", ""))
    if local:
        ctx = ssl.create_default_context(cafile=args.ca_file) if args.ca_file else ssl.create_default_context()
        return conn, args.ref or "local-test", args.function_url or "", ctx, True
    validate_target(args.ref, load_targets())
    assert_db_matches_ref(conn, args.ref)
    return conn, args.ref, function_url(args.ref), ssl.create_default_context(), False


def write_evidence(uat: Uat, ref: str, local: bool, started: str, run_id: str, cleanup_done: bool, secrets: list[str],
                   out_dir: Path) -> dict:
    summary = {"passed": sum(r["pass"] for r in uat.results), "failed": sum(not r["pass"] for r in uat.results)}
    mode = "local-test" if local else "hosted-preview"
    evidence = {
        "target": {"ref": ref, "function_url": "local-test" if local else uat.url},
        "mode": mode,
        "run": {"id": run_id, "started": started, "finished": datetime.now(timezone.utc).isoformat(),
                "git_sha": os.environ.get("GITHUB_SHA", "local"), "token_ttl_minutes": TOKEN_TTL_MINUTES},
        "results": uat.results,
        "summary": summary,
        "cleanup_verified": cleanup_done,
    }
    lines = [f"# Gifting enquiry receiver — synthetic UAT evidence ({mode})", "",
             f"- target ref: `{ref}`", f"- run: `{run_id}` at {started}", f"- git sha: `{evidence['run']['git_sha']}`", "",
             "| Scenario | Result | Observed |", "|---|---|---|"]
    lines += [f"| {r['scenario']} | {'PASS' if r['pass'] else 'FAIL'} | {r['observed']} |" for r in uat.results]
    lines += ["", f"**{summary['passed']} passed, {summary['failed']} failed; cleanup verified: {cleanup_done}.**",
              "No credential appears in this file; tokens were generated in the database, kept in memory and revoked."]
    blob = json.dumps(evidence, indent=2) + "\n".join(lines)
    if scan_for_secrets(blob, secrets):
        raise UatAbort("redaction scan failed; evidence withheld")
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
    (out_dir / "evidence.md").write_text("\n".join(lines) + "\n")
    return evidence


def run(args: argparse.Namespace) -> int:
    conn, ref, url, ctx, local = build_context(args)
    secrets = [conn["password"], os.environ.get("GIFTING_UAT_DB_URL", "")]
    run_id = os.environ.get("GITHUB_RUN_ID", uuid.uuid4().hex[:8])
    started = datetime.now(timezone.utc).isoformat()
    uat = Uat(Db(conn, local), url, ctx, local, run_id)
    uat.preflight()  # read-only; aborts before any write
    cleanup_done = False
    try:
        secrets.extend(uat.provision())
        lead, lead_credentials, lead_concurrent, lead_marketing = (str(uuid.uuid4()) for _ in range(4))
        body = payload()
        uat.credentials(lead_credentials, body)
        uat.delivery(lead, body)
        uat.concurrency(lead_concurrent, body)
        uat.marketing_and_validation(lead_marketing, body)
    finally:
        cleanup_done = uat.cleanup()
    evidence = write_evidence(uat, ref, local, started, run_id, cleanup_done, secrets, Path(args.evidence_dir))
    totals = evidence["summary"]
    print(f"evidence written to {args.evidence_dir} ({totals['passed']} passed, {totals['failed']} failed)")
    return 0 if evidence["summary"]["failed"] == 0 and cleanup_done else 1


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--ref", help="allow-listed Supabase preview branch ref")
    parser.add_argument("--evidence-dir", default="uat-evidence")
    parser.add_argument("--local-test", action="store_true", help="scratch database mode (never in GitHub Actions)")
    parser.add_argument("--function-url", help="--local-test only")
    parser.add_argument("--ca-file", help="--local-test only")
    args = parser.parse_args(argv)
    try:
        return run(args)
    except UatAbort as err:
        print(f"UAT ABORTED: {err}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
