#!/usr/bin/env python3
"""Synthetic hosted UAT for the Gifting enquiry receiver (Central #677, Core PR #557).

Run only from the manually dispatched workflow .github/workflows/gifting-receiver-hosted-uat.yml, or locally
in --local-test mode against a scratch database. It targets exactly one allow-listed, isolated preview branch,
uses a scoped short-lived consumer/token created and revoked inside this run, and writes evidence only after a
credential-redaction scan passes. It never prints, stores or uploads a credential.

Standard library only; database access goes through the `psql` client with connection details passed in
PG* environment variables (never on the command line).
"""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path

REF_RE = re.compile(r"^[a-z]{20}$")
TOKEN_RE = re.compile(r"oc_(?:preview|staging|production)_[0-9a-f]{16,}")
RECEIVER_MIGRATION = "20261118210000"
UAT_SOURCE = "uat-hosted-synthetic"
TOKEN_TTL_MINUTES = 30
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
    def __init__(self, conn: dict, local: bool) -> None:
        self.env = {**os.environ, "PGHOST": conn["host"], "PGPORT": conn["port"], "PGUSER": conn["user"],
                    "PGDATABASE": conn["dbname"], "PGSSLMODE": "disable" if local else conn["sslmode"],
                    "PGCONNECT_TIMEOUT": "15", "PGOPTIONS": "-c statement_timeout=30000"}
        if conn["password"]:
            self.env["PGPASSWORD"] = conn["password"]

    def run(self, sql: str) -> str:
        proc = subprocess.run(["psql", "-X", "-A", "-t", "-q", "-v", "ON_ERROR_STOP=1", "-c", sql],
                              env=self.env, capture_output=True, text=True, timeout=60)
        if proc.returncode != 0:
            # psql errors can echo query text; never surface it beyond a generic message.
            raise UatAbort("database statement failed")
        return proc.stdout.strip()


def mask(value: str) -> None:
    if os.environ.get("GITHUB_ACTIONS") == "true":
        print(f"::add-mask::{value}")


# ----------------------------------------------------------------------------- HTTP
def post(url: str, token: str | None, key: str | None, body, ctx, content_type: str = "application/json"):
    data = body if isinstance(body, (bytes, bytearray)) else json.dumps(body).encode()
    headers = {"content-type": content_type}
    if token:
        headers["authorization"] = f"Bearer {token}"
    if key is not None:
        headers["idempotency-key"] = key
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=20, context=ctx) as resp:
            return resp.status, json.loads(resp.read() or b"null")
    except urllib.error.HTTPError as err:
        raw = err.read()
        try:
            return err.code, json.loads(raw or b"null")
        except ValueError:
            return err.code, {"_raw": "non-json"}


def payload(message: str = "Synthetic hosted UAT enquiry", kind: str = "corporate") -> dict:
    return {"kind": kind, "email": "uat-synthetic@example.invalid", "phone": "+919999900000",
            "name": "UAT Synthetic", "company": None, "message": message, "source": UAT_SOURCE,
            "consent": {"marketing": False, "timestamp": None}, "attribution": {"utm_source": "uat"}}


# ----------------------------------------------------------------------------- the run
def run(args) -> int:
    local = args.local_test
    if local and (os.environ.get("GIFTING_UAT_LOCAL_TEST") != "1" or os.environ.get("GITHUB_ACTIONS")):
        raise UatAbort("--local-test needs GIFTING_UAT_LOCAL_TEST=1 and is refused inside GitHub Actions")
    if os.environ.get("GITHUB_ACTIONS") and os.environ.get("GITHUB_EVENT_NAME") != "workflow_dispatch":
        raise UatAbort("hosted UAT runs only from a manual workflow_dispatch")

    db_url = os.environ.get("GIFTING_UAT_DB_URL", "")
    conn = parse_db_url(db_url)
    secrets = [conn["password"], db_url]
    if local:
        url = args.function_url
        ref = args.ref or "local-test"
        ctx = ssl.create_default_context(cafile=args.ca_file) if args.ca_file else ssl.create_default_context()
    else:
        entry = validate_target(args.ref, load_targets())
        assert_db_matches_ref(conn, args.ref)
        ref, url, ctx = args.ref, function_url(args.ref), ssl.create_default_context()
    db = Db(conn, local)
    run_id = os.environ.get("GITHUB_RUN_ID", uuid.uuid4().hex[:8])
    started = datetime.now(timezone.utc).isoformat()
    results: list[dict] = []
    consumer_key = f"gifting-uat-hosted-{run_id}"
    tokens: dict[str, str] = {}

    def check(name: str, ok: bool, observed: str) -> None:
        results.append({"scenario": name, "pass": bool(ok), "observed": observed})
        print(f"{'PASS' if ok else 'FAIL'}  {name}  {observed}")

    def rows(lead: str) -> int:
        return int(db.run(f"select count(*) from public.gifting_enquiries where source_lead_id = '{lead}'") or 0)

    # --- preflight: read-only isolation and readiness checks; abort before any write
    migration_expr = ("'true'" if local else
                      f"(exists(select 1 from supabase_migrations.schema_migrations where version = '{RECEIVER_MIGRATION}'))::text")
    consumers_expr = ("'0'" if local else
                      "(select count(*)::text from public.connect_consumers where consumer_key not like 'gifting-uat-%')")
    pre = db.run(
        "select concat_ws('|', "
        f"{migration_expr}, "
        "(to_regclass('public.gifting_enquiries') is not null)::text, "
        "'0', "
        f"{consumers_expr}, "
        "(select count(*)::text from public.gifting_enquiries where source not like 'uat-%'), "
        "has_function_privilege('anon','public.gifting_enquiry_receive_v1(text,uuid,jsonb)','EXECUTE')::text)"
    )
    migrated, table, _unused, foreign_consumers, foreign_rows, anon_exec = pre.split("|")
    # A separate statement: PostgreSQL resolves relations at parse time, even in an untaken CASE branch.
    products = "0"
    if db.run("select (to_regclass('public.products') is not null)::text") == "true":
        products = db.run("select count(*)::text from public.products")
    if migrated != "true" or table != "true":
        raise UatAbort("the receiver migration is not applied on this target")
    if products != "0" or foreign_consumers != "0" or foreign_rows != "0":
        raise UatAbort("target is not an empty, isolated preview (data or foreign consumers present)")
    if anon_exec != "false":
        raise UatAbort("anon can execute the receiver RPC on this target")
    print("preflight: isolated, empty, receiver migration present, anon cannot execute the RPC")

    cleanup_done = False
    try:
        # --- provision a dedicated synthetic consumer and short-lived tokens, inside the database
        ttl = f"now() + interval '{TOKEN_TTL_MINUTES} minutes'"
        out = db.run(
            "with c as (select public.connect_admin_register_consumer_v1("
            f"'{consumer_key}','b2c_website','{'staging' if local else 'preview'}','Hosted synthetic UAT (temporary)') j), "
            "b as (select public.connect_admin_bind_profile_v1((c.j->>'consumer_id')::uuid, "
            "(select id from public.connect_profiles where profile_key='gifting_enquiries_v1'), "
            f"'{'staging' if local else 'preview'}') from c), "
            "t1 as (select 'OK=' || (public.connect_admin_issue_token_v1((c.j->>'consumer_id')::uuid, "
            f"array['enquiries:gifting:write'], '{'staging' if local else 'preview'}', {ttl}, 60)->>'token') from c, b), "
            "t2 as (select 'EXPIRED=' || (public.connect_admin_issue_token_v1((c.j->>'consumer_id')::uuid, "
            f"array['enquiries:gifting:write'], '{'staging' if local else 'preview'}', now() - interval '1 minute', 60)->>'token') from c, b), "
            "t3 as (select 'SCOPE=' || (public.connect_admin_issue_token_v1((c.j->>'consumer_id')::uuid, "
            f"array['catalogue:read'], '{'staging' if local else 'preview'}', {ttl}, 60)->>'token') from c, b), "
            "t4 as (select public.connect_admin_issue_token_v1((c.j->>'consumer_id')::uuid, "
            f"array['enquiries:gifting:write'], '{'staging' if local else 'preview'}', {ttl}, 60) j from c, b), "
            "t4r as (select 'REVOKED=' || (t4.j->>'token') || '|' || (select public.connect_admin_revoke_token_v1((t4.j->>'token_id')::uuid)::text) from t4) "
            "select * from t1 union all select * from t2 union all select * from t3 union all select * from t4r"
        )
        for line in out.splitlines():
            name, _, value = line.partition("=")
            tokens[name] = value.split("|")[0]
            mask(tokens[name])
        secrets.extend(tokens.values())
        if set(tokens) != {"OK", "EXPIRED", "SCOPE", "REVOKED"}:
            raise UatAbort("credential provisioning did not complete")

        lead, lead2, lead3, lead4 = (str(uuid.uuid4()) for _ in range(4))
        body = payload()

        # --- credential negatives: none may write
        for name, tok, want in (("missing token", None, 401), ("invalid token", "x" * 48, 401),
                                ("expired token", tokens["EXPIRED"], 401), ("wrong-scope token", tokens["SCOPE"], 403),
                                ("revoked token", tokens["REVOKED"], 401)):
            status, _ = post(url, tok, lead2, body, ctx)
            check(f"credential: {name} -> HTTP {want}", status == want, f"got {status}")
        check("credential: no row written by any rejected credential", rows(lead2) == 0, f"rows={rows(lead2)}")

        # --- first delivery, replay, conflict
        s1, r1 = post(url, tokens["OK"], lead, body, ctx)
        check("delivery: first delivery -> 201 accepted", s1 == 201 and (r1 or {}).get("status") == "accepted"
              and (r1 or {}).get("queue") == "gifting_enquiries" and (r1 or {}).get("sourceLeadId") == lead, f"got {s1}")
        check("delivery: exactly one enquiry persisted", rows(lead) == 1, f"rows={rows(lead)}")
        s2, r2 = post(url, tokens["OK"], lead, body, ctx)
        check("replay: identical replay -> 200 with the same enquiryId",
              s2 == 200 and (r2 or {}).get("enquiryId") == (r1 or {}).get("enquiryId") and (r2 or {}).get("replayed") is True, f"got {s2}")
        check("replay: still one row", rows(lead) == 1, f"rows={rows(lead)}")
        s3, _ = post(url, tokens["OK"], lead, payload("CHANGED"), ctx)
        stored = db.run(f"select message from public.gifting_enquiries where source_lead_id = '{lead}'")
        check("conflict: different payload for the same lead -> 409", s3 == 409, f"got {s3}")
        check("conflict: stored enquiry not overwritten", stored == "Synthetic hosted UAT enquiry", "unchanged" if stored == body["message"] else "CHANGED")
        s4, r4 = post(url, tokens["OK"], lead, body, ctx)
        check("replay: exact replay still succeeds after a rejected conflict",
              s4 == 200 and (r4 or {}).get("enquiryId") == (r1 or {}).get("enquiryId"), f"got {s4}")

        # --- concurrency: one row, one enquiryId
        with concurrent.futures.ThreadPoolExecutor(max_workers=20) as pool:
            outs = list(pool.map(lambda _: post(url, tokens["OK"], lead3, body, ctx), range(20)))
        ids = {(o[1] or {}).get("enquiryId") for o in outs}
        check("concurrency: 20 simultaneous deliveries all accepted", all(o[0] in (200, 201) for o in outs),
              ",".join(sorted({str(o[0]) for o in outs})))
        check("concurrency: exactly one row and one enquiryId", rows(lead3) == 1 and len(ids) == 1, f"rows={rows(lead3)} ids={len(ids)}")

        # --- marketing-only and malformed
        for kind in ("newsletter", "rewards"):
            st, _ = post(url, tokens["OK"], lead4, payload(kind=kind), ctx)
            check(f"marketing: {kind} -> 422", st == 422, f"got {st}")
        check("marketing: no marketing-only row in the queue", rows(lead4) == 0, f"rows={rows(lead4)}")
        st, _ = post(url, tokens["OK"], "not-a-uuid", body, ctx)
        check("validation: bad idempotency key -> 400", st == 400, f"got {st}")
        st, _ = post(url, tokens["OK"], lead4, b"{not json", ctx)
        check("validation: invalid JSON -> 400", st == 400, f"got {st}")
        st, _ = post(url, tokens["OK"], lead4, body, ctx, content_type="text/plain")
        check("validation: wrong media type -> 415", st == 415, f"got {st}")
        req = urllib.request.Request(url, method="GET")
        try:
            with urllib.request.urlopen(req, timeout=20, context=ctx) as resp:
                st = resp.status
        except urllib.error.HTTPError as err:
            st = err.code
        check("validation: GET -> 405", st == 405, f"got {st}")
    finally:
        # --- cleanup runs even after a failure: revoke every token, suspend the consumer, prove it
        try:
            db.run(f"update public.connect_tokens set revoked_at = coalesce(revoked_at, now()) where consumer_id = "
                   f"(select id from public.connect_consumers where consumer_key = '{consumer_key}')")
            db.run(f"update public.connect_consumers set status = 'suspended' where consumer_key = '{consumer_key}'")
            live = db.run("select count(*) from public.connect_tokens t join public.connect_consumers c on c.id = t.consumer_id "
                          f"where c.consumer_key = '{consumer_key}' and t.revoked_at is null and (t.expires_at is null or t.expires_at > now())")
            cleanup_done = live == "0"
            check("cleanup: no live UAT token remains and the consumer is suspended", cleanup_done, f"live_tokens={live}")
            if tokens.get("OK"):
                st, _ = post(url, tokens["OK"], str(uuid.uuid4()), payload(), ctx)
                check("cleanup: the valid token is rejected after revocation", st == 401, f"got {st}")
        except Exception:  # noqa: BLE001 - cleanup failure is reported, never hidden
            check("cleanup: revocation failed - revoke the UAT consumer manually", False, "see runbook")

    # --- evidence, written only after the redaction scan passes
    evidence = {
        "target": {"ref": ref, "function_url": url if not local else "local-test"},
        "mode": "local-test" if local else "hosted-preview",
        "run": {"id": run_id, "started": started, "finished": datetime.now(timezone.utc).isoformat(),
                "git_sha": os.environ.get("GITHUB_SHA", "local"), "token_ttl_minutes": TOKEN_TTL_MINUTES},
        "results": results,
        "summary": {"passed": sum(r["pass"] for r in results), "failed": sum(not r["pass"] for r in results)},
        "cleanup_verified": cleanup_done,
    }
    lines = [f"# Gifting enquiry receiver — synthetic UAT evidence ({evidence['mode']})", "",
             f"- target ref: `{ref}`", f"- run: `{run_id}` at {started}", f"- git sha: `{evidence['run']['git_sha']}`", "",
             "| Scenario | Result | Observed |", "|---|---|---|"]
    lines += [f"| {r['scenario']} | {'PASS' if r['pass'] else 'FAIL'} | {r['observed']} |" for r in results]
    lines += ["", f"**{evidence['summary']['passed']} passed, {evidence['summary']['failed']} failed; cleanup verified: {cleanup_done}.**",
              "No credential appears in this file; tokens were generated in the database, kept in memory and revoked."]
    blob = json.dumps(evidence, indent=2) + "\n".join(lines)
    if scan_for_secrets(blob, secrets):
        raise UatAbort("redaction scan failed; evidence withheld")
    out_dir = Path(args.evidence_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
    (out_dir / "evidence.md").write_text("\n".join(lines) + "\n")
    print(f"evidence written to {out_dir} ({evidence['summary']['passed']} passed, {evidence['summary']['failed']} failed)")
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
