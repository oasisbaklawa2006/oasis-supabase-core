#!/usr/bin/env python3
"""Validate only the QA secret inventory's names, with activation absent."""
import sys
import json
from pathlib import Path
from verify_msg91_secret_inventory import validate_inventory
REQUIRED = {"QA_MSG91_PROVIDER_AUTH_KEY", "QA_MSG91_TEST_PHONE_ALLOWLIST"}
FORBIDDEN = {"MSG91_AUTH_KEY", "QA_MSG91_PROVIDER_ENABLED", "OPENAI_API_KEY"}
def verify(raw: bytes) -> None:
    validate_inventory(raw)
    rows = json.loads(raw)
    names = {item["name"] for item in rows}
    if not REQUIRED.issubset(names) or {n.upper() for n in names} & FORBIDDEN:
        raise ValueError("QA provider secret inventory denied")
if __name__ == "__main__":
    try:
        with Path(sys.argv[1]).open("rb") as stream:
            verify(stream.read(1024*1024+1))
    except (OSError, ValueError, IndexError):
        print("QA_REAL_PROVIDER_SECRET_INVENTORY_DENIED", file=sys.stderr)
        sys.exit(1)
    print("QA_REAL_PROVIDER_SECRET_INVENTORY_PASS")
