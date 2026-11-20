#!/usr/bin/env python3
"""Fail-closed, offline target/authorization validator for Genie QA schema release.

This module never connects to a database, fetches secrets, or modifies production.
"""
from __future__ import annotations

import os
import re
import sys
from urllib.parse import urlsplit

QA_PROJECT_REF = "skhpmltfjgqitntkmclb"
QA_HOST = f"db.{QA_PROJECT_REF}.supabase.co"
# Supabase shared Session Pooler uses IPv4. Match its known regional
# hostname shape and pin the tenant in the PostgreSQL username.
POOLER_HOST_PATTERN = re.compile(r"^aws-[0-9]+-ap-south-1\.pooler\.supabase\.com$")
PRODUCTION_PROJECT_REF = "tcxvcatsqqertcnycuop"
APPROVAL_PHRASE = "AUTHORIZE-GENIE-QA-CANONICAL-BOOTSTRAP"
SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")


def validate_target(dsn: str, mode: str = "preflight") -> None:
    """Pin the isolated project and restrict IPv4 pooler access to preflight.

    A Session Pooler can be used for read-only connectivity checks but is not
    approved for canonical migration apply. No credentials are ever logged.
    """
    if not isinstance(dsn, str) or not dsn or dsn != dsn.strip() or any(
        ord(c) < 32 or ord(c) == 127 for c in dsn
    ):
        raise ValueError("GENIE_QA_DATABASE_URL is missing or malformed")
    try:
        # urlsplit itself can raise on malformed Unicode host/port separators.
        # Keep all parser exceptions out of release logs: DSNs contain secrets.
        p = urlsplit(dsn)
        port = p.port
        user = p.username
        password = p.password
        host = p.hostname
    except ValueError:
        raise ValueError("Malformed QA database authority") from None
    if p.scheme not in ("postgres", "postgresql"):
        raise ValueError("Only PostgreSQL DSNs are permitted")
    if port != 5432 or p.path != "/postgres" or p.query or p.fragment:
        raise ValueError("Unexpected QA database URL port, path or parameters")
    if not password:
        raise ValueError("Missing QA database authentication")
    if PRODUCTION_PROJECT_REF in dsn:
        raise ValueError("Production reference is forbidden")

    if host == QA_HOST and user == "postgres":
        return
    if (
        mode == "preflight"
        and host is not None
        and POOLER_HOST_PATTERN.fullmatch(host)
        and user == f"postgres.{QA_PROJECT_REF}"
    ):
        return
    raise ValueError("Not the approved QA endpoint for this run mode")


def validate_invocation(env: dict[str, str]) -> None:
    if env.get("GENIE_QA_PROJECT_REF") != QA_PROJECT_REF:
        raise ValueError("QA project reference mismatch")
    mode = env.get("GENIE_QA_RUN_MODE")
    if mode not in ("preflight", "apply"):
        raise ValueError("Only preflight or apply modes permitted")
    if not SHA_PATTERN.fullmatch(env.get("GENIE_QA_EXPECTED_SHA", "")):
        raise ValueError("Missing exact current Core commit SHA")
    if not env.get("GENIE_QA_CHANGE_REFERENCE", "").startswith("Core#495/Buyer#74"):
        raise ValueError("Canonical issue/change reference required")
    if mode == "apply" and env.get("GENIE_QA_APPROVAL_PHRASE") != APPROVAL_PHRASE:
        raise ValueError("Explicit owner approved QA-only schema apply phrase missing")
    validate_target(env.get("GENIE_QA_DATABASE_URL", ""), mode=mode)


if __name__ == "__main__":
    try:
        validate_invocation(dict(os.environ))
    except ValueError as exc:
        # No DSN, token or certificate contents are printed.
        print(f"GENIE_QA_BOOTSTRAP_DENIED: {exc}", file=sys.stderr)
        raise SystemExit(1)
    print("GENIE_QA_BOOTSTRAP_TARGET_VALIDATED")
