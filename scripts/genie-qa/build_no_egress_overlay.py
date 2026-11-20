#!/usr/bin/env python3
"""Create an ephemeral, no-egress QA migration replay copy; never change Git source.

Only the two exact historical baseline extension installs are suppressed.
The production baseline Git blob is immutable; all other SQL is copied bytewise.
"""
from __future__ import annotations

import argparse
from pathlib import Path

from verify_no_outbound import blob_hash, verify

BASELINE_NAME = "20260723161256_legacy_role_authority_baseline.sql"
BASELINE_BLOB = "8749dc07e8a74663e2e8b3e5aa425195c7f20f89"
EGRESS_INSTALLS = (
    b'CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";',
    b'CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "public";',
)

PRODUCTION_CONFIG_HEADER = b'project_id = "tcxvcatsqqertcnycuop"'
QA_CONFIG_HEADER = b'project_id = "skhpmltfjgqitntkmclb"'


def pin_qa_config(raw: bytes) -> bytes:
    """Only a known canonical Core config may be copied into QA scratch space."""
    if not raw.startswith(PRODUCTION_CONFIG_HEADER + b"\n"):
        raise ValueError("Canonical config project header is missing or changed")
    if raw.count(b"project_id = ") != 1:
        raise ValueError("Canonical config contains ambiguous project bindings")
    return QA_CONFIG_HEADER + raw[len(PRODUCTION_CONFIG_HEADER):]


def remove_baseline_egress(raw: bytes, *, expected_blob: str = BASELINE_BLOB) -> bytes:
    """Require exact source provenance and exactly one of each known install."""
    if blob_hash(raw) != expected_blob:
        raise ValueError("Immutable canonical baseline fingerprint mismatch")
    output = raw
    for statement in EGRESS_INSTALLS:
        if output.count(statement) != 1:
            raise ValueError("Expected exactly one historical egress extension install")
        output = output.replace(statement, b"-- QA-ONLY NO-EGRESS: suppressed reviewed extension installation")
    if output == raw:
        raise ValueError("QA overlay made no restrictive changes")
    return output


def build_overlay(repo: Path, output: Path) -> int:
    """Make a minimal migration workdir outside the repository; fail closed."""
    repo = repo.resolve(strict=True)
    output = output.resolve()
    if output == repo or repo in output.parents:
        raise ValueError("QA overlay cannot be created inside canonical repository")
    if output.exists():
        raise ValueError("QA overlay destination must not already exist")
    source_dir = repo / "supabase" / "migrations"
    if not source_dir.is_dir() or source_dir.is_symlink():
        raise ValueError("Canonical migration directory missing or unsafe")
    originals = sorted(source_dir.glob("*.sql"))
    if not originals:
        raise ValueError("Canonical migration files missing")
    baseline = source_dir / BASELINE_NAME
    if not baseline.is_file() or baseline.is_symlink():
        raise ValueError("Canonical baseline missing or unsafe")
    # Validate before creating output. A modified original must fail rather
    # than silently becoming an approved QA-only alternative.
    replacement = remove_baseline_egress(baseline.read_bytes())
    target_dir = output / "supabase" / "migrations"
    target_dir.mkdir(parents=True)
    config = repo / "supabase" / "config.toml"
    if not config.is_file() or config.is_symlink():
        raise ValueError("Canonical config missing or unsafe")
    # Never leave the production project ID in an executable QA workdir,
    # even though the release CLI also receives a separately validated QA DSN.
    qa_config = pin_qa_config(config.read_bytes())
    (output / "supabase" / "config.toml").write_bytes(qa_config)
    for source in originals:
        if source.is_symlink() or not source.is_file():
            raise ValueError("Unsafe canonical migration file")
        raw = replacement if source.name == BASELINE_NAME else source.read_bytes()
        (target_dir / source.name).write_bytes(raw)
    # All three known guarded scheduler sources must remain byte-identical;
    # newly introduced outbound DDL or functions deny replay.
    total = verify(target_dir)
    if total != len(originals):
        raise ValueError("QA overlay migration inventory incomplete")
    return total


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    count = build_overlay(root, args.output)
    print(f"GENIE_QA_OVERLAY_NO_EGRESS_PASS; migration count={count}")


if __name__ == "__main__":
    main()
