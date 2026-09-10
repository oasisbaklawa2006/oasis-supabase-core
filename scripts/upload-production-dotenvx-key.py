#!/usr/bin/env python3
"""Upload DOTENV_PRIVATE_KEY_PREVIEW to production via Supabase Management API."""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

KEY_NAME = "DOTENV_PRIVATE_KEY_PREVIEW"


def fail(message: str, code: int = 1) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(code)


def resolve_private_key() -> str:
    direct = os.environ.get("PREVIEW_DOTENV_PRIVATE_KEY", "").strip()
    if direct:
        return direct

    keys_path = os.environ.get("DOTENV_KEYS_FILE", "supabase/.env.keys")
    if not os.path.isfile(keys_path):
        fail(f"{keys_path} is missing")

    value = ""
    pattern = re.compile(rf'^{re.escape(KEY_NAME)}="?([^"\n]+)"?\s*$')
    with open(keys_path, encoding="utf-8") as handle:
        for line in handle:
            match = pattern.match(line.strip())
            if match:
                value = match.group(1).strip()
                break
    if not value:
        fail(f"{KEY_NAME} not found in {keys_path}")
    return value


def upload_secret_api(project_ref: str, token: str, value: str) -> str | None:
    payload = json.dumps([{"name": KEY_NAME, "value": value}]).encode("utf-8")
    request = urllib.request.Request(
        f"https://api.supabase.com/v1/projects/{project_ref}/secrets",
        data=payload,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            if response.status not in (200, 201):
                return f"production dotenv key upload failed: HTTP {response.status}"
    except urllib.error.HTTPError as err:
        body = err.read().decode("utf-8", errors="replace").strip()
        snippet = body[:240] if body else err.reason
        return f"production dotenv key upload failed: HTTP {err.code} {snippet}"
    return None


def upload_secret_cli(project_ref: str, keys_path: str) -> str | None:
    result = subprocess.run(
        [
            "supabase",
            "secrets",
            "set",
            "--env-file",
            keys_path,
            "--project-ref",
            project_ref,
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "supabase secrets set failed").strip()
        return f"production dotenv key upload failed via CLI: {detail[:240]}"
    return None


def main() -> None:
    project_ref = os.environ.get("PRODUCTION_PROJECT_REF", "").strip()
    token = os.environ.get("SUPABASE_ACCESS_TOKEN", "").strip()
    keys_path = os.environ.get("DOTENV_KEYS_FILE", "supabase/.env.keys")
    if not project_ref:
        fail("PRODUCTION_PROJECT_REF is required")
    if not token:
        fail("SUPABASE_ACCESS_TOKEN is required")

    private_key = resolve_private_key()
    api_error = upload_secret_api(project_ref, token, private_key)
    if api_error is None:
        print("uploaded_dotenvx_preview_key_to_production")
        return

    if os.path.isfile(keys_path):
        cli_error = upload_secret_cli(project_ref, keys_path)
        if cli_error is None:
            print("uploaded_dotenvx_preview_key_to_production")
            return
        fail(cli_error)

    fail(api_error)


if __name__ == "__main__":
    main()
