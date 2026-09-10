#!/usr/bin/env python3
import json
import sys

payload = json.load(sys.stdin)
for check in payload.get("check_runs", []):
    if check.get("name") == "Supabase Preview" and check.get("status") == "completed":
        sys.exit(0 if check.get("conclusion") == "success" else 1)
sys.exit(2)
