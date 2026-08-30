#!/usr/bin/env python3
"""Fetch GEMINI_API_KEY value from production Supabase secrets store (stdout only)."""
import json
import os
import sys
import urllib.error
import urllib.request

ref = os.environ.get("PRODUCTION_PROJECT_REF", "")
token = os.environ.get("SUPABASE_ACCESS_TOKEN", "")
if not ref or not token:
    sys.exit(1)

req = urllib.request.Request(
    f"https://api.supabase.com/v1/projects/{ref}/secrets",
    headers={"Authorization": f"Bearer {token}"},
)
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        payload = json.load(resp)
except urllib.error.HTTPError as err:
    sys.stderr.write(f"production secrets fetch failed: HTTP {err.code}\n")
    sys.exit(1)

for item in payload:
    if item.get("name") == "GEMINI_API_KEY" and item.get("value"):
        print(item["value"])
        sys.exit(0)

sys.exit(1)
