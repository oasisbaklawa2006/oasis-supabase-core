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
from urllib.parse import urlparse

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
    if project_ref not in host:
        raise ValueError("Database hostname must contain the exact Preview project ref")
    if PRODUCTION_REF in host:
        raise ValueError("Production database target forbidden")


def check(project_ref: str, database_url: str) -> None:
    validate_target(project_ref, database_url)
    env = dict(os.environ)
    env.pop("PGPASSWORD", None)
    result = subprocess.run(
        ["psql", database_url, "-X", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-c", SQL],
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


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, subprocess.TimeoutExpired) as exc:
        print(f"Preview schema gate failed: {exc}", file=sys.stderr)
        sys.exit(1)
