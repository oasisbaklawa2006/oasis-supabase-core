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
import tempfile
from pathlib import Path
from urllib.parse import unquote, urlparse

PRODUCTION_REF = "tcxvcatsqqertcnycuop"
# Canonical Core baseline as verified in the production ledger 16 Nov 2026.
# A branch with only the three recent Buyer migrations is not adequate for UAT.
MINIMUM_CANONICAL_MIGRATIONS = 481
# Reconciled non-PII baseline fingerprint from production Core on 2026-11-16.
# Historical versions through this cutoff must match the approved authority.
# Any canonical-baseline provenance change requires a separately reviewed update.
CANONICAL_BASELINE_CUTOFF = "20261114110000"
CANONICAL_BASELINE_FINGERPRINT = "296a236ac9335c49628d8a1f794eafd2"
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
  || '|' || (to_regclass('supabase_migrations.schema_migrations') IS NOT NULL)::text
  || '|' || (EXISTS (SELECT 1 FROM supabase_migrations.schema_migrations WHERE version = '20261113124200'))::text
  || '|' || (EXISTS (SELECT 1 FROM supabase_migrations.schema_migrations WHERE version = '20261113130000'))::text
  || '|' || (EXISTS (SELECT 1 FROM supabase_migrations.schema_migrations WHERE version = '20261113130100'))::text
  || '|' || (SELECT md5(string_agg(version, E'\\n' ORDER BY version))
            FROM supabase_migrations.schema_migrations
            WHERE version <= '20261114110000');
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
    if any(char in unquote(parsed.username) + unquote(parsed.password) for char in "\r\n\x00"):
        raise ValueError("Invalid Preview credentials")


def pgpass_escape(value: str) -> str:
    """Escape PostgreSQL passfile delimiters in credential fields."""
    return value.replace("\\", "\\\\").replace(":", "\\:")


def trusted_psql_path() -> str:
    """Use only the root-owned system psql installation, never inherited PATH."""
    candidate = Path("/usr/bin/psql")
    try:
        resolved = candidate.resolve(strict=True)
        if not resolved.is_file():
            raise ValueError("not a regular executable")
        # Debian/Ubuntu may use a root-owned /usr/bin/psql symlink to pg_wrapper.
        # Validate every resolved path component, not only the final binary.
        for path in (resolved, *resolved.parents):
            stat = path.stat()
            if stat.st_uid != 0 or stat.st_mode & 0o022:
                raise ValueError("untrusted executable location")
        if not os.access(resolved, os.X_OK):
            raise ValueError("not executable")
    except (OSError, ValueError, RuntimeError):
        raise RuntimeError("Trusted system psql executable unavailable") from None
    # Keep the psql entry-point basename: Debian pg_wrapper dispatches on argv[0].
    # The resolved target was checked above; never search inherited PATH.
    return str(candidate)


def trusted_ca_path(location: str) -> str:
    """Reject replaceable CA files and directory ancestors before TLS verification."""
    try:
        candidate = Path(location)
        if not candidate.is_absolute():
            raise ValueError("CA path must be absolute")
        resolved = candidate.resolve(strict=True)
        if not resolved.is_file():
            raise ValueError("CA must be a regular file")
        allowed_owners = {0, os.geteuid()}
        for index, entry in enumerate((resolved, *resolved.parents)):
            stat = entry.stat()
            if stat.st_uid not in allowed_owners:
                raise ValueError("untrusted CA owner")
            if stat.st_mode & 0o022:
                # Shared /tmp is safe only with root ownership and sticky bit:
                # other users cannot rename a privately owned child directory.
                sticky_root_directory = (
                    index > 0 and stat.st_uid == 0
                    and bool(stat.st_mode & 0o1000)
                    and entry.is_dir()
                )
                if not sticky_root_directory:
                    raise ValueError("writable CA or ancestor")
        if resolved.stat().st_size <= 0:
            raise ValueError("empty CA")
        return str(resolved)
    except (OSError, ValueError, RuntimeError):
        raise RuntimeError("Preview root CA file missing or invalid") from None


def check(project_ref: str, database_url: str) -> None:
    validate_target(project_ref, database_url)
    # Never put the credential-bearing URI in the psql command line where it
    # can be exposed to process inspection, CI command tracing or job logs.
    # Strip inherited PG* overrides so the validated target remains authoritative.
    parsed = urlparse(database_url)
    # Do not downgrade to encrypted-but-unauthenticated "require". Supabase
    # documents verify-full plus its project root CA for verified PSQL.
    ca_path = trusted_ca_path(os.environ.get("PREVIEW_CA_CERT_FILE", ""))
    psql_executable = trusted_psql_path()
    # Pass an explicit allowlist to psql, excluding all CI/provider secrets.
    env = {
        "LC_ALL": "C",
        "PGHOST": parsed.hostname or "",
        "PGPORT": str(parsed.port or 5432),
        "PGUSER": unquote(parsed.username or ""),
        "PGDATABASE": "postgres",
        "PGSSLMODE": "verify-full",
        "PGSSLROOTCERT": ca_path,
    }
    # Keep the database password out of argv and child-process environment.
    # TemporaryDirectory is private (0700); O_EXCL creates a 0600 file.
    with tempfile.TemporaryDirectory(prefix="buyer-preview-pgpass-") as root:
        passfile = Path(root) / "credentials"
        fd = os.open(passfile, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(":".join(pgpass_escape(value) for value in (
                env["PGHOST"], env["PGPORT"], env["PGDATABASE"], env["PGUSER"],
                unquote(parsed.password or ""),
            )) + "\n")
        env["PGPASSFILE"] = str(passfile)
        result = subprocess.run(
            [psql_executable, "-X", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-c", SQL],
            capture_output=True,
            text=True,
            timeout=30,
            env=env,
            check=False,
        )
    if result.returncode:
        raise RuntimeError("Preview database query failed; inspect restricted runner logs")
    parts = result.stdout.strip().split("|")
    if len(parts) != 9 or not parts[0].isdigit():
        raise RuntimeError("Unexpected Preview database response")
    count = int(parts[0])
    if (count < MINIMUM_CANONICAL_MIGRATIONS
            or any(value != "true" for value in parts[1:8])
            or parts[8] != CANONICAL_BASELINE_FINGERPRINT):
        raise RuntimeError("PREVIEW_SCHEMA_NOT_READY: baseline provenance, required versions or relations differ")
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
