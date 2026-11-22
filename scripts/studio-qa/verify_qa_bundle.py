#!/usr/bin/env python3
"""Offline attestation of a downloaded inert Studio QA closure and API snapshots.

This checks evidence supplied by a protected release runner. It does not acquire
an exclusive writer lease, fetch evidence, deploy, delete, or run downloaded code.
"""
from __future__ import annotations

import argparse
from contextlib import ExitStack
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import stat
import tempfile

ROOT = Path(__file__).resolve().parents[2]
QA_PROJECT = "skhpmltfjgqitntkmclb"
SLUG = "catalogue-ai-copy"
MAX_BYTES = 1024 * 1024
FILES = frozenset({"catalogue-ai-copy/index.ts", "_shared/catalogueAiCopy.ts"})
HEX = re.compile(r"[0-9a-f]{64}\Z", re.ASCII)
SAFE_OPEN_SUPPORTED = os.open in os.supports_dir_fd
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


def checked_read(path: Path) -> bytes:
    """Open each component without symlinks; validate and read the same fd.

    This is an Ubuntu runner boundary. Unsupported descriptor-relative/no-follow
    operations fail closed rather than silently reverting to pathname checks.
    """
    required = ("O_DIRECTORY", "O_NOFOLLOW", "O_CLOEXEC", "O_NONBLOCK")
    if any(not hasattr(os, name) for name in required) or not SAFE_OPEN_SUPPORTED:
        raise EvidenceDenied("safe evidence reads unavailable")
    absolute = path.absolute()
    if absolute.anchor != "/" or ".." in absolute.parts:
        raise EvidenceDenied("unsafe evidence path")
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    file_flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK
    try:
        with ExitStack() as handles:
            parent = os.open("/", directory_flags)
            handles.callback(os.close, parent)
            for component in absolute.parts[1:-1]:
                parent = os.open(component, directory_flags, dir_fd=parent)
                handles.callback(os.close, parent)
            descriptor = os.open(absolute.name, file_flags, dir_fd=parent)
            handles.callback(os.close, descriptor)
            opened = os.fstat(descriptor)
            if not stat.S_ISREG(opened.st_mode) or opened.st_size > MAX_BYTES:
                raise EvidenceDenied("evidence must be a bounded regular file")
            chunks = []
            remaining = MAX_BYTES + 1
            while remaining:
                chunk = os.read(descriptor, remaining)
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            raw = b"".join(chunks)
            if len(raw) > MAX_BYTES:
                raise EvidenceDenied("evidence exceeded size limit")
            return raw
    except OSError as exc:
        raise EvidenceDenied("evidence descriptor read denied") from exc


def read_metadata(path: Path) -> dict:
    raw = checked_read(path)
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
            source = checked_read(functions_root / relative)
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
