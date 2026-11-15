#!/usr/bin/env python3
"""Fail-closed, read-only database readiness gate for isolated Buyer #64 Preview UAT.

Requires psql and a restricted, preview-only connection string. Never prints credentials.
This is a separate database gate: Edge function deployment status alone is insufficient.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote, urlparse

PRODUCTION_REF = "tcxvcatsqqertcnycuop"
REQUIRED_RELATIONS = (
    "auth.users",
    "public.carton_configurations",
    "public.product_packing_profiles",
    "supabase_migrations.schema_migrations",
)
SQL = """
SELECT
  (SELECT count(*) FROM supabase_migrations.schema_migrations)::text
  || '|' || (to_regclass('auth.users') IS NOT NULL)::text
  || '|' || (to_regclass('public.carton_configurations') IS NOT NULL)::text
  || '|' || (to_regclass('public.product_packing_profiles') IS NOT NULL)::text
  || '|' || (to_regclass('supabase_migrations.schema_migrations') IS NOT NULL)::text;
"""


def validate_target(project_ref: str, database_url: str) -> None:
    if not re.fullmatch(r"[a-z0-9]{20}", project_ref) or project_ref == PRODUCTION_REF:
        raise ValueError("PREVIEW_PROJECT_REF must be a non-production 20-character project ref")
    parsed = urlparse(database_url)
    host = (parsed.hostname or "").lower()
    if parsed.scheme not in {"postgres", "postgresql"} or not host:
        raise ValueError("PREVIEW_DATABASE_URL must be a PostgreSQL URL")
    # A substring match admits db.<ref>.supabase.co.evil and other misleading
    # hosts. This gate intentionally accepts only the dedicated direct DB host,
    # never a pooler/production host or an arbitrary URL containing the ref.
    if host != f"db.{project_ref}.supabase.co":
        raise ValueError("Database hostname must match exact Preview direct DB host")
    if parsed.port not in (None, 5432):
        raise ValueError("Preview direct DB port must be 5432")
    if parsed.path != "/postgres" or not parsed.username or not parsed.password:
        raise ValueError("Preview URL requires explicit postgres DB and credentials")


def check(project_ref: str, database_url: str) -> None:
    validate_target(project_ref, database_url)
    # Never put the credential-bearing URI in the psql command line where it
    # can be exposed to process inspection, CI command tracing or job logs.
    # Strip inherited PG* overrides so the validated target remains authoritative.
    parsed = urlparse(database_url)
    # Do not downgrade to encrypted-but-unauthenticated "require". Supabase
    # documents verify-full plus its project root CA for verified PSQL.
    ca_location = os.environ.get("PREVIEW_CA_CERT_FILE", "")
    try:
        trusted_ca = Path(ca_location)
        if (
            not trusted_ca.is_absolute()
            or not trusted_ca.is_file()
            or trusted_ca.stat().st_size <= 0
            or trusted_ca.stat().st_mode & 0o002
        ):
            raise ValueError("untrusted CA path")
        ca_path = str(trusted_ca.resolve(strict=True))
    except (OSError, ValueError):
        raise RuntimeError("Preview root CA file missing or invalid") from None
    # Do not copy the CI runner environment into psql: it may contain
    # unrelated API tokens or provider credentials. The database password is
    # supplied explicitly as PGPASSWORD; no other secrets are forwarded.
    env = {
        "PATH": os.environ.get("PATH", os.defpath),
        "LC_ALL": "C",
    }
    env.update(
        PGHOST=parsed.hostname or "",
        PGPORT=str(parsed.port or 5432),
        PGUSER=unquote(parsed.username or ""),
        PGPASSWORD=unquote(parsed.password or ""),
        PGDATABASE="postgres",
        PGSSLMODE="verify-full",
        PGSSLROOTCERT=ca_path,
    )
    result = subprocess.run(
        ["psql", "-X", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-c", SQL],
        capture_output=True,
        text=True,
        timeout=30,
        env=env,
        check=False,
    )
    if result.returncode:
        raise RuntimeError("Preview database query failed; inspect restricted runner logs")
    parts = result.stdout.strip().split("|")
    if len(parts) != 5 or not parts[0].isdigit():
        raise RuntimeError("Unexpected Preview database response")
    count = int(parts[0])
    if count == 0 or any(value != "true" for value in parts[1:]):
        raise RuntimeError("PREVIEW_SCHEMA_NOT_READY: missing migrations or required relations")
    print(f"PREVIEW_SCHEMA_READY: {count} migrations; required relations present; target {project_ref}")


def main() -> None:
    project_ref = os.environ.get("PREVIEW_PROJECT_REF", "")
    database_url = os.environ.get("PREVIEW_DATABASE_URL", "")
    if not project_ref or not database_url:
        raise ValueError("PREVIEW_PROJECT_REF and PREVIEW_DATABASE_URL required")
    check(project_ref, database_url)


def cli() -> int:
    try:
        main()
    except (ValueError, RuntimeError, subprocess.TimeoutExpired):
        # Parsing an attacker-supplied URI may raise ValueError containing the
        # entire authority (and password). Never print raw exceptions or input.
        print("PREVIEW_SCHEMA_NOT_READY: target or schema validation failed (details redacted)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(cli())
