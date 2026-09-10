#!/usr/bin/env python3
import json
import sys

TRUSTED_APP_ID = 330661
TRUSTED_APP_SLUG = "supabase"

payload = json.load(sys.stdin)
for check in payload.get("check_runs", []):
    if check.get("name") != "Supabase Preview":
        continue
    app = check.get("app") or {}
    if app.get("id") != TRUSTED_APP_ID or app.get("slug") != TRUSTED_APP_SLUG:
        continue
    if check.get("status") == "completed":
        sys.exit(0 if check.get("conclusion") == "success" else 1)
sys.exit(2)
