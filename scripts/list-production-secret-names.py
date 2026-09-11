#!/usr/bin/env python3
"""List production Supabase secret names via Management API (names only)."""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request


def main() -> None:
    project_ref = os.environ.get("PRODUCTION_PROJECT_REF", "").strip()
    token = os.environ.get("SUPABASE_ACCESS_TOKEN", "").strip()
    if not project_ref or not token:
        sys.exit(1)

    request = urllib.request.Request(
        f"https://api.supabase.com/v1/projects/{project_ref}/secrets",
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as err:
        print(
            f"production secrets list failed: HTTP {err.code}",
            file=sys.stderr,
        )
        sys.exit(1)

    for item in payload:
        name = item.get("name")
        if isinstance(name, str) and name:
            print(name)


if __name__ == "__main__":
    main()
