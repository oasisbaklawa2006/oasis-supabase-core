#!/usr/bin/env python3
"""Offline negative tests for Buyer Preview schema gate; no network or database access."""
from __future__ import annotations

import importlib.util
import pathlib
from unittest import mock

source = pathlib.Path(__file__).resolve().parents[1] / "verify-buyer-preview-schema.py"
spec = importlib.util.spec_from_file_location("buyer_preview_schema", source)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

ref = "jssunmhwmbvjvxoqxrif"
url = f"postgresql://fixture:fixture@db.{ref}.supabase.co:5432/postgres"
for bad_ref, bad_url in [
    ("tcxvcatsqqertcnycuop", url),
    (ref, "postgresql://fixture:fixture@db.tcxvcatsqqertcnycuop.supabase.co/postgres"),
    (ref, "postgresql://fixture:fixture@db.other.supabase.co/postgres"),
    (ref, "https://example.org"),
    (ref, f"postgresql://fixture:fixture@db.{ref}.supabase.co.evil.example/postgres"),
    (ref, f"postgresql://fixture:fixture@notdb.{ref}.supabase.co/postgres"),
    (ref, f"postgresql://fixture:fixture@db.{ref}.supabase.co:15432/postgres"),
    (ref, f"postgresql://fixture:fixture@db.{ref}.supabase.co/other"),
    (ref, f"postgresql://fixture@db.{ref}.supabase.co/postgres"),
]:
    try:
        module.validate_target(bad_ref, bad_url)
    except ValueError:
        pass
    else:
        raise AssertionError("Unsafe target accepted")
module.validate_target(ref, url)

def simulate(stdout: str, returncode: int = 0, expected_ready: bool = False) -> None:
    fake = mock.Mock(returncode=returncode, stdout=stdout)
    with mock.patch.dict(
        module.os.environ,
        {"PGHOST": "db.tcxvcatsqqertcnycuop.supabase.co",
         "PGPASSWORD": "inherited-secret", "PGOPTIONS": "-c dangerous"},
    ):
        with mock.patch.object(module.subprocess, "run", return_value=fake) as runner:
            try:
                module.check(ref, url)
            except RuntimeError:
                assert not expected_ready, "Valid schema unexpectedly rejected"
            else:
                assert expected_ready, "Invalid schema unexpectedly accepted"
            assert runner.call_count == 1
            assert runner.call_args.kwargs["timeout"] == 30
            argv = runner.call_args.args[0]
            env = runner.call_args.kwargs["env"]
            assert url not in argv, "Database credential URL leaked into process arguments"
            assert env["PGHOST"] == f"db.{ref}.supabase.co"
            assert env["PGPORT"] == "5432"
            assert env["PGPASSWORD"] == "fixture"
            assert env["PGSSLMODE"] == "require"
            assert "PGOPTIONS" not in env, "Inherited libpq options may override validated target"


simulate("0|false|false|false|true\n")
simulate("480|true|false|true|true\n")
simulate("480|true|true|true|true\n", expected_ready=True)
simulate("", returncode=1)
print("Buyer Preview schema gate offline negative tests PASS")
