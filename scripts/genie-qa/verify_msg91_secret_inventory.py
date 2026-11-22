#!/usr/bin/env python3
"""Fail-closed validator for isolated QA Edge secret-name inventory.

Reads only a local Management API JSON snapshot. Never logs the response,
secret digests, secret values, or individual secret names.
"""
import json
from pathlib import Path
import re
import sys

MAX_INVENTORY_BYTES = 1024 * 1024
SECRET_NAME = re.compile(r"[A-Za-z][A-Za-z0-9_]*", re.ASCII)


class InventoryDenied(ValueError):
    """Invalid or unsafe secret inventory; never include secret contents."""


def _unique_keys(pairs):
    record = {}
    for key, value in pairs:
        if key in record:
            raise InventoryDenied("duplicate JSON object field")
        record[key] = value
    return record


def _reject_non_json_constant(_value):
    raise InventoryDenied("invalid JSON constant")


def validate_inventory(raw: bytes) -> None:
    if not raw or len(raw) > MAX_INVENTORY_BYTES:
        raise InventoryDenied("missing or oversized secret inventory")
    try:
        inventory = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=_unique_keys,
            parse_constant=_reject_non_json_constant,
        )
    except (UnicodeError, json.JSONDecodeError, ValueError, RecursionError) as exc:
        raise InventoryDenied("malformed secret inventory") from exc

    if not isinstance(inventory, list):
        raise InventoryDenied("secret inventory is not a JSON array")
    seen = set()
    for item in inventory:
        if not isinstance(item, dict):
            raise InventoryDenied("unreadable secret inventory entry")
        name = item.get("name")
        if not isinstance(name, str) or not SECRET_NAME.fullmatch(name):
            raise InventoryDenied("invalid or missing secret name")
        if name in seen:
            raise InventoryDenied("duplicate secret inventory name")
        seen.add(name)
        if name.upper() == "MSG91_AUTH_KEY":
            raise InventoryDenied("MSG91 provider key present")

    # Empty [] is legitimate and safe; no header or partial rows are accepted.


def main() -> int:
    if len(sys.argv) != 2:
        print("GENIE_QA_EDGE_SECRET_NAMES_UNPARSABLE", file=sys.stderr)
        return 2
    try:
        with Path(sys.argv[1]).open('rb') as source:
            raw = source.read(MAX_INVENTORY_BYTES + 1)
        validate_inventory(raw)
    except (OSError, InventoryDenied):
        # Never echo malformed response or attacker-controlled secret names.
        print("GENIE_QA_EDGE_SECRET_NAMES_UNPARSABLE_OR_PROVIDER_KEY_PRESENT", file=sys.stderr)
        return 1
    print("GENIE_QA_EDGE_SECRET_INVENTORY_PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
