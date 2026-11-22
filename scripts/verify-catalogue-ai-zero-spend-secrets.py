#!/usr/bin/env python3
"""Conservative Production AI-copy no-spend evidence. Never print secret names/values."""
from __future__ import annotations
import json
import sys
from pathlib import Path

def verify(payload: object) -> None:
    if not isinstance(payload, list):
        raise ValueError("Management API secret inventory is unavailable or malformed")
    names: dict[str, dict] = {}
    for row in payload:
        if not isinstance(row, dict) or not isinstance(row.get("name"), str):
            raise ValueError("Management API secret record cannot be verified")
        name = row["name"]
        if name in names:
            raise ValueError("Duplicate secret name; cannot verify release configuration")
        names[name] = row
    # Regardless of flag state, a missing provider credential ensures zero
    # OpenAI requests from this function. Never remove credentials automatically.
    if "OPENAI_API_KEY" in names:
        raise ValueError("Provider credential present: no-spend release blocked")
    flag = names.get("AI_STUDIO_AI_ENABLED")
    if flag is not None and flag.get("value") != "false":
        raise ValueError("AI enabled/unknown/redacted: cannot certify disabled state")

def self_test() -> None:
    verify([])
    verify([{"name": "AI_STUDIO_AI_ENABLED", "value": "false"}])
    for test in (
        [{"name": "OPENAI_API_KEY", "value": "REDACTED"}],
        [{"name": "AI_STUDIO_AI_ENABLED", "value": "true"}],
        [{"name": "AI_STUDIO_AI_ENABLED", "value": "***"}],
        [{"name": "AI_STUDIO_AI_ENABLED"}],
        {"secrets": []},
        [{"name": "A"}, {"name": "A"}],
    ):
        try:
            verify(test)
        except ValueError:
            continue
        raise AssertionError("Unsafe secrets inventory was accepted")
    print("Zero-spend Production secret-inventory checks passed.")

if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        self_test()
    elif len(sys.argv) == 2:
        try:
            verify(json.loads(Path(sys.argv[1]).read_text(encoding="utf-8")))
        except (ValueError, OSError, json.JSONDecodeError) as exc:
            # The message cannot include secret contents.
            print(f"AI_COPY_ZERO_SPEND_BLOCKED: {exc.__class__.__name__}", file=sys.stderr)
            sys.exit(1)
        print("AI_COPY_ZERO_SPEND_VERIFIED: provider credential absent; feature disabled.")
    else:
        print("Usage: verify-catalogue-ai-zero-spend-secrets.py INVENTORY_JSON|--self-test", file=sys.stderr)
        sys.exit(2)
