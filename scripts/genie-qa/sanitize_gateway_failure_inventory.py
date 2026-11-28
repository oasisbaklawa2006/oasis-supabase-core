#!/usr/bin/env python3
"""Emit only typed, allowlisted QA function metadata for recovery evidence."""
import json
import re
import sys
from pathlib import Path

SLUGS = {"buyer-login-gateway", "msg91-otp", "msg91-session-bridge"}
STATUSES = {"ACTIVE", "INACTIVE", "REMOVED", "THROTTLED"}
DIGEST = re.compile(r"[0-9a-f]{64}")
UUID = re.compile(r"[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}")

def sanitize(rows):
    if not isinstance(rows, list):
        raise ValueError("invalid inventory")
    seen = set()
    clean = []
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError("invalid row")
        slug = row.get("slug")
        if not isinstance(slug, str) or slug not in SLUGS or slug in seen:
            raise ValueError("unexpected function")
        seen.add(slug)
        version = row.get("version")
        status = row.get("status")
        verify = row.get("verify_jwt")
        digest = row.get("ezbr_sha256")
        ident = row.get("id")
        if (type(version) is not int or version < 1 or
                not isinstance(status, str) or status not in STATUSES or
                type(verify) is not bool or not isinstance(digest, str) or
                not DIGEST.fullmatch(digest)):
            raise ValueError("invalid metadata")
        item = {"slug": slug, "version": version, "status": status,
                "verify_jwt": verify, "ezbr_sha256": digest}
        if isinstance(ident, str) and UUID.fullmatch(ident):
            item["id"] = ident
        clean.append(item)
    return sorted(clean, key=lambda item: item["slug"])

def main():
    try:
        with Path(sys.argv[1]).open("rb") as stream:
            data = stream.read(1024 * 1024 + 1)
        if len(data) > 1024 * 1024:
            raise ValueError("oversized inventory")
        result = sanitize(json.loads(data))
        Path(sys.argv[2]).write_text(json.dumps(result, sort_keys=True) + "\n")
    except (OSError, ValueError, TypeError, IndexError):
        print("QA_GATEWAY_FAILURE_INVENTORY_UNAVAILABLE", file=sys.stderr)
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(main())
