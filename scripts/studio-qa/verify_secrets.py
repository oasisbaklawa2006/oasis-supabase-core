#!/usr/bin/env python3
"""Read-only fail-closed QA Management API inventory check. Never expose keys."""
from __future__ import annotations
import json
from pathlib import Path
import re
import sys

NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z", re.ASCII)
MAX_BYTES = 1024 * 1024
# Exact host-managed platform secrets only. Prefixes are NOT sufficient:
# SUPABASE_OPENAI_API_KEY and SB_MSG91_AUTH_KEY are attacker-controlled names.
PLATFORM_SECRET_NAMES = frozenset({
    "SUPABASE_URL",
    "SUPABASE_ANON_KEY",
    "SUPABASE_SERVICE_ROLE_KEY",
    "SUPABASE_DB_URL",
    "SUPABASE_PUBLISHABLE_KEYS",
    "SUPABASE_SECRET_KEYS",
    "SUPABASE_JWT_SECRET",
    "SUPABASE_PUBLISHABLE_KEY",
})


class SecretsDenied(ValueError):
    pass


def _unique(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise SecretsDenied("duplicate JSON field")
        value[key] = item
    return value


def _invalid_number(_value):
    raise SecretsDenied("invalid number")


def verify(raw: bytes) -> None:
    if not raw or len(raw) > MAX_BYTES:
        raise SecretsDenied("unavailable or oversized inventory")
    try:
        data = json.loads(raw.decode("utf-8"), object_pairs_hook=_unique,
                          parse_constant=_invalid_number)
    except (ValueError, UnicodeError, RecursionError) as exc:
        raise SecretsDenied("malformed inventory") from exc
    if not isinstance(data, list):
        raise SecretsDenied("not an inventory list")
    seen = set()
    for row in data:
        if not isinstance(row, dict):
            raise SecretsDenied("unreadable inventory row")
        name = row.get("name")
        if not isinstance(name, str) or not NAME.fullmatch(name) or name in seen:
            raise SecretsDenied("unreadable or duplicate inventory name")
        seen.add(name)
        # Non-Supabase custom secrets are not necessary for the inert Studio
        # QA bundle. Reject anything that could enable external providers,
        # including unfamiliar credentials, rather than rely on a blocklist.
        if name not in PLATFORM_SECRET_NAMES:
            raise SecretsDenied("non-platform secret present")
    # [] is allowed: an isolated project need not expose default secrets in
    # the Management API listing for this source-only preflight.


def main() -> int:
    if len(sys.argv) != 2:
        return 2
    try:
        with Path(sys.argv[1]).open("rb") as stream:
            verify(stream.read(MAX_BYTES + 1))
    except (OSError, SecretsDenied):
        print("STUDIO_QA_PROVIDER_INVENTORY_DENIED", file=sys.stderr)
        return 1
    print("STUDIO_QA_PROVIDER_SECRET_ABSENCE_PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
