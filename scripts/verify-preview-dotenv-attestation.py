#!/usr/bin/env python3
"""Verify a narrow, historical executor attestation for supabase/.env.preview.

This is NOT a general bypass. It exists only for ciphertext whose independent
private key is no longer held anywhere, and it passes only when ALL of these are
independently proven through the GitHub API (never the Supabase secrets API):

  1. The current supabase/.env.preview blob SHA appears in the committed
     attestation list (supabase/.env.preview.attestations.json).
  2. The attested check-run was published by the trusted Supabase GitHub App
     (id 330661, slug "supabase"), is named "Supabase Preview", completed with
     conclusion "success", and ran on the attested commit.
  3. supabase/.env.preview at that exact commit has exactly the attested blob.
  4. supabase/config.toml at that commit declares both env() Edge Runtime
     secrets, so a successful hosted preview there actually exercised the
     decryption of this ciphertext (a preview that never referenced the
     secrets proves nothing about the key).

An attestation proves only that the hosted executor once decrypted this exact
blob. It never replaces the mandatory hosted Supabase Preview / Edge Runtime
readiness gates, which still must pass at the PR head. Any other ciphertext
change fails closed and requires an independently held key.

Only codes and short identifiers are printed; no secret material is read.
"""
from __future__ import annotations

import base64
import binascii
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

EXPECTED_REPOSITORY = "oasisbaklawa2006/oasis-supabase-core"
TRUSTED_APP_ID = 330661
TRUSTED_APP_SLUG = "supabase"
CHECK_NAME = "Supabase Preview"
PREVIEW_FILE = "supabase/.env.preview"
CONFIG_FILE = "supabase/config.toml"
REQUIRED_SECRET_DECLARATIONS = (
    re.compile(r'(?m)^GEMINI_API_KEY\s*=\s*"env\(GEMINI_API_KEY\)"\s*$'),
    re.compile(r'(?m)^WA_STAGE1B_CERT_SECRET\s*=\s*"env\(WA_STAGE1B_CERT_SECRET\)"\s*$'),
)
DEFAULT_ATTESTATIONS = "supabase/.env.preview.attestations.json"
MAX_ENTRIES = 8
ENTRY_KEYS = {"blob", "commit", "check_run_id"}
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
LOCAL_HOSTS = {"127.0.0.1", "localhost"}


def fail(code: str, detail: str = "") -> None:
    suffix = f" {detail}" if detail else ""
    print(f"PREVIEW_DOTENV_ATTESTATION_FAILED: {code}{suffix}", file=sys.stderr)
    sys.exit(1)


def api_base() -> str:
    base = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
    parsed = urllib.parse.urlparse(base)
    if parsed.scheme == "https":
        return base
    if parsed.scheme == "http" and parsed.hostname in LOCAL_HOSTS:
        return base
    fail("API_BASE_NOT_TRUSTED")
    return base  # unreachable


def api_get(path: str, token: str) -> dict:
    request = urllib.request.Request(  # nosec B310 - scheme/host validated in api_base()
        f"{api_base()}{path}",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:  # nosec B310
            payload = json.load(response)
    except (urllib.error.URLError, ValueError, TimeoutError):
        fail("GITHUB_API_UNAVAILABLE", path.split("?", 1)[0])
        return {}
    if not isinstance(payload, dict):
        fail("GITHUB_API_UNEXPECTED_RESPONSE")
    return payload


def current_blob() -> str:
    if not os.path.isfile(PREVIEW_FILE):
        fail("ENV_PREVIEW_MISSING")
    result = subprocess.run(
        ["git", "hash-object", PREVIEW_FILE],
        capture_output=True,
        text=True,
        check=False,
    )
    blob = result.stdout.strip()
    if result.returncode != 0 or not SHA_RE.match(blob):
        fail("BLOB_HASH_UNAVAILABLE")
    return blob


def load_entries(path: str) -> list[dict]:
    if not os.path.isfile(path):
        return []
    try:
        with open(path, encoding="utf-8") as handle:
            document = json.load(handle)
    except (OSError, ValueError):
        fail("ATTESTATIONS_UNREADABLE")
    if not isinstance(document, dict) or set(document) != {"version", "attestations"}:
        fail("ATTESTATIONS_SCHEMA")
    if document["version"] != 1 or not isinstance(document["attestations"], list):
        fail("ATTESTATIONS_SCHEMA")
    entries = document["attestations"]
    if len(entries) > MAX_ENTRIES:
        fail("ATTESTATIONS_TOO_MANY")
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != ENTRY_KEYS:
            fail("ATTESTATION_ENTRY_SCHEMA")
        if not (isinstance(entry["blob"], str) and SHA_RE.match(entry["blob"])):
            fail("ATTESTATION_ENTRY_SCHEMA")
        if not (isinstance(entry["commit"], str) and SHA_RE.match(entry["commit"])):
            fail("ATTESTATION_ENTRY_SCHEMA")
        run_id = entry["check_run_id"]
        if isinstance(run_id, bool) or not isinstance(run_id, int) or run_id <= 0:
            fail("ATTESTATION_ENTRY_SCHEMA")
    return entries


def main() -> None:
    repository = os.environ.get("GITHUB_REPOSITORY", "").strip()
    if repository != EXPECTED_REPOSITORY:
        fail("REPOSITORY_NOT_PINNED")
    token = (os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or "").strip()
    if not token:
        fail("GITHUB_TOKEN_REQUIRED")

    blob = current_blob()
    entries = load_entries(
        os.environ.get("PREVIEW_DOTENV_ATTESTATIONS_FILE", DEFAULT_ATTESTATIONS)
    )
    matches = [entry for entry in entries if entry["blob"] == blob]
    if not matches:
        fail("NO_ATTESTATION_FOR_CURRENT_BLOB")
    entry = matches[0]

    run = api_get(f"/repos/{repository}/check-runs/{entry['check_run_id']}", token)
    app = run.get("app") if isinstance(run.get("app"), dict) else {}
    if app.get("id") != TRUSTED_APP_ID or app.get("slug") != TRUSTED_APP_SLUG:
        fail("CHECK_RUN_PUBLISHER_UNTRUSTED")
    if run.get("name") != CHECK_NAME:
        fail("CHECK_RUN_NAME_MISMATCH")
    if run.get("status") != "completed" or run.get("conclusion") != "success":
        fail("CHECK_RUN_NOT_SUCCESSFUL")
    if run.get("head_sha") != entry["commit"]:
        fail("CHECK_RUN_COMMIT_MISMATCH")

    contents = api_get(
        f"/repos/{repository}/contents/{PREVIEW_FILE}?ref={entry['commit']}", token
    )
    if contents.get("sha") != blob:
        fail("ATTESTED_COMMIT_BLOB_MISMATCH")

    config = api_get(
        f"/repos/{repository}/contents/{CONFIG_FILE}?ref={entry['commit']}", token
    )
    try:
        config_text = base64.b64decode(config.get("content", ""), validate=False).decode("utf-8")
    except (binascii.Error, UnicodeDecodeError, AttributeError):
        fail("ATTESTED_CONFIG_UNREADABLE")
    if config.get("encoding") != "base64" or "[edge_runtime.secrets]" not in config_text:
        fail("ATTESTED_CONFIG_SECRETS_NOT_DECLARED")
    if not all(pattern.search(config_text) for pattern in REQUIRED_SECRET_DECLARATIONS):
        fail("ATTESTED_CONFIG_SECRETS_NOT_DECLARED")

    print(
        "PREVIEW_DOTENV_ATTESTATION_VERIFIED "
        f"blob={blob[:8]} commit={entry['commit'][:8]} check_run={entry['check_run_id']}"
    )


if __name__ == "__main__":
    main()
