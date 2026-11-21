#!/usr/bin/env python3
"""Fail-closed QA Edge source bundle provenance across download and final checks.

Captures only a redacted bundle SHA-256. Never prints metadata, token contents,
user details, or source. Must not be used to certify production deployments.
"""
import argparse
import json
import os
from pathlib import Path
import re
import sys

DIGEST = re.compile(r"[0-9a-f]{64}", re.ASCII)
MAX_METADATA_BYTES = 1024 * 1024
ALLOWED = frozenset({"msg91-otp", "msg91-session-bridge"})


class ProvenanceDenied(ValueError):
    pass


def unique_keys(pairs):
    obj = {}
    for key, val in pairs:
        if key in obj:
            raise ProvenanceDenied("duplicate field")
        obj[key] = val
    return obj


def reject_non_json_constant(_value):
    raise ProvenanceDenied("non-JSON constant")


def load_bundle(path: Path, slug: str) -> str:
    with path.open("rb") as handle:
        raw = handle.read(MAX_METADATA_BYTES + 1)
    if not raw or len(raw) > MAX_METADATA_BYTES:
        raise ProvenanceDenied("invalid metadata length")
    try:
        item = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=unique_keys,
            parse_constant=reject_non_json_constant,
        )
    except (ValueError, UnicodeError, RecursionError) as exc:
        raise ProvenanceDenied("invalid metadata") from exc
    if not isinstance(item, dict) or item.get("slug") != slug or item.get("status") != "ACTIVE":
        raise ProvenanceDenied("wrong function identity/status")
    digest = item.get("ezbr_sha256")
    if not isinstance(digest, str) or not DIGEST.fullmatch(digest):
        raise ProvenanceDenied("missing or invalid bundle digest")
    return digest


def load_pin(path: Path) -> str:
    with path.open("rb") as handle:
        raw = handle.read(67)
    if not raw.endswith(b"\n") or len(raw) != 65:
        raise ProvenanceDenied("malformed pinned bundle")
    value = raw[:-1].decode("ascii")
    if not DIGEST.fullmatch(value):
        raise ProvenanceDenied("invalid pinned bundle")
    return value


def verify_capture(slug: str, before: Path, after: Path, pin: Path) -> None:
    first = load_bundle(before, slug)
    second = load_bundle(after, slug)
    if first != second:
        raise ProvenanceDenied("bundle replaced during source download")
    if pin.exists():
        if load_pin(pin) != first:
            raise ProvenanceDenied("bundle replaced since prior attestation")
    else:
        # Exclusive creation prevents a repeated check silently rewriting the
        # original attested fingerprint inside the same protected job.
        with pin.open("x", encoding="ascii") as handle:
            os.chmod(pin, 0o600)
            handle.write(first + "\n")


def verify_final(slug: str, metadata: Path, pin: Path) -> None:
    if load_bundle(metadata, slug) != load_pin(pin):
        raise ProvenanceDenied("final function bundle differs from attestation")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("capture", "final"), required=True)
    parser.add_argument("--slug", choices=sorted(ALLOWED), required=True)
    parser.add_argument("--pin", type=Path, required=True)
    parser.add_argument("--before", type=Path)
    parser.add_argument("--after", type=Path)
    parser.add_argument("--metadata", type=Path)
    args = parser.parse_args()
    try:
        if args.mode == "capture":
            if not args.before or not args.after or args.metadata:
                raise ProvenanceDenied("capture requires two snapshots")
            verify_capture(args.slug, args.before, args.after, args.pin)
        else:
            if not args.metadata or args.before or args.after:
                raise ProvenanceDenied("final requires one snapshot")
            verify_final(args.slug, args.metadata, args.pin)
    except (OSError, ValueError, UnicodeError, RecursionError):
        print("GENIE_QA_EDGE_BUNDLE_PROVENANCE_DENIED", file=sys.stderr)
        return 1
    print("GENIE_QA_EDGE_BUNDLE_PROVENANCE_PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
