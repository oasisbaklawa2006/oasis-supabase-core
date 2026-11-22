#!/usr/bin/env python3
"""Offline attestation of a downloaded inert Studio QA closure and API snapshots.

This checks evidence supplied by a protected release runner. It does not acquire
an exclusive writer lease, fetch evidence, deploy, delete, or run downloaded code.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
QA_PROJECT = "skhpmltfjgqitntkmclb"
SLUG = "catalogue-ai-copy"
MAX_BYTES = 1024 * 1024
FILES = frozenset({"catalogue-ai-copy/index.ts", "_shared/catalogueAiCopy.ts"})
HEX = re.compile(r"[0-9a-f]{64}\Z", re.ASCII)
UUID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\Z", re.ASCII)


class EvidenceDenied(ValueError):
    pass


def _load_builder():
    spec = importlib.util.spec_from_file_location(
        "studio_qa_overlay", ROOT / "scripts/studio-qa/build_inert_copy.py"
    )
    if spec is None or spec.loader is None:
        raise EvidenceDenied("builder unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise EvidenceDenied("duplicate JSON field")
        result[key] = value
    return result


def _invalid_number(_value):
    raise EvidenceDenied("non-JSON number")


def read_metadata(path: Path) -> dict:
    if path.is_symlink() or not path.is_file():
        raise EvidenceDenied("metadata missing or symlinked")
    with path.open("rb") as stream:
        raw = stream.read(MAX_BYTES + 1)
    if not raw or len(raw) > MAX_BYTES:
        raise EvidenceDenied("metadata size invalid")
    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=_unique,
                           parse_constant=_invalid_number)
    except (ValueError, UnicodeError, RecursionError) as exc:
        raise EvidenceDenied("metadata invalid") from exc
    if not isinstance(value, dict):
        raise EvidenceDenied("metadata must be an object")
    return value


def identity(metadata: dict) -> tuple:
    """Require explicit authoritative per-function metadata; no list defaults."""
    if not isinstance(metadata, dict):
        raise EvidenceDenied("metadata must be an object")
    function_id = metadata.get("id")
    digest = metadata.get("ezbr_sha256")
    version = metadata.get("version")
    if (metadata.get("slug") != SLUG or metadata.get("status") != "ACTIVE"
            or metadata.get("verify_jwt") is not True
            or type(version) is not int or version < 1
            or not isinstance(function_id, str) or not UUID.fullmatch(function_id)
            or not isinstance(digest, str) or not HEX.fullmatch(digest)):
        raise EvidenceDenied("incomplete or unsafe function metadata")
    return function_id, version, digest


def attest(project_ref: str, functions_root: Path, before: dict, after: dict) -> dict:
    if project_ref != QA_PROJECT:
        raise EvidenceDenied("foreign project")
    baseline = identity(before)
    if identity(after) != baseline:
        raise EvidenceDenied("function changed during source capture")
    if functions_root.is_symlink() or not functions_root.is_dir():
        raise EvidenceDenied("source root missing or symlinked")
    actual = set()
    for entry in functions_root.rglob("*"):
        if entry.is_symlink():
            raise EvidenceDenied("symlink in downloaded source")
        if entry.is_file():
            relative = entry.relative_to(functions_root).as_posix()
            if relative not in FILES or entry.stat().st_size > MAX_BYTES:
                raise EvidenceDenied("unexpected or oversized downloaded file")
            actual.add(relative)
    if actual != FILES:
        raise EvidenceDenied("incomplete downloaded source")
    builder = _load_builder()
    with tempfile.TemporaryDirectory(prefix="studio-qa-expected-") as scratch:
        expected = Path(scratch) / "functions"
        builder.build(ROOT / "supabase/functions/catalogue-ai-copy/index.ts",
                      ROOT / "supabase/functions/_shared/catalogueAiCopy.ts", expected)
        files = []
        for relative in sorted(FILES):
            with (functions_root / relative).open("rb") as stream:
                source = stream.read(MAX_BYTES + 1)
            if len(source) > MAX_BYTES:
                raise EvidenceDenied("downloaded file grew beyond size limit")
            if source != (expected / relative).read_bytes():
                raise EvidenceDenied("downloaded source differs from inert candidate")
            files.append({"path": relative, "sha256": hashlib.sha256(source).hexdigest(),
                          "size": len(source)})
    # Emit only selected nonsecret evidence. Never echo arbitrary API fields.
    return {"project_ref": QA_PROJECT, "function": SLUG, "id": baseline[0],
            "version": baseline[1], "ezbr_sha256": baseline[2],
            "verify_jwt": True, "files": files,
            "evidence_scope": "source-and-metadata-only",
            "exclusive_writer_verified": False, "authenticated_uat_executed": False}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-ref", required=True)
    parser.add_argument("--functions-root", type=Path, required=True)
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--after", type=Path, required=True)
    args = parser.parse_args()
    try:
        evidence = attest(args.project_ref, args.functions_root,
                          read_metadata(args.before), read_metadata(args.after))
    except (OSError, ValueError, RuntimeError, ImportError):
        print("STUDIO_QA_BUNDLE_EVIDENCE_DENIED", file=sys.stderr)
        return 1
    print(json.dumps(evidence, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
