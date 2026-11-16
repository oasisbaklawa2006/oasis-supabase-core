#!/usr/bin/env python3
"""Offline negative tests for Buyer Preview schema gate; no network or database access."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import pathlib
import tempfile
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
    (ref, f"postgresql://fixture:line%0Abreak@db.{ref}.supabase.co/postgres"),
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
    with tempfile.TemporaryDirectory() as root:
        ca = pathlib.Path(root) / "approved-preview-root-ca.pem"
        ca.write_text("offline-only nonempty certificate fixture", encoding="utf-8")
        with mock.patch.dict(
            module.os.environ,
            {"PGHOST": "db.tcxvcatsqqertcnycuop.supabase.co",
             "PATH": "/tmp/attacker-writable-bin:/usr/bin",
             "PGPASSWORD": "inherited-secret",
             "PGOPTIONS": "-c dangerous",
             "PGSSLROOTCERT": "/some/other/untrusted/root.pem",
             "PGSSLMODE": "disable",
             "PREVIEW_CA_CERT_FILE": str(ca),
             "GITHUB_TOKEN": "should-never-reach-psql",
             "SUPABASE_SERVICE_ROLE_KEY": "should-never-reach-psql",
             "CLICK2API_API_KEY": "should-never-reach-psql"},
        ):
            def inspect_psql(_argv, **kwargs):
                pgpass = pathlib.Path(kwargs["env"]["PGPASSFILE"])
                assert pgpass.is_file(), "Required private passfile missing"
                assert pgpass.stat().st_mode & 0o077 == 0, "Password file is not private"
                assert pgpass.parent.stat().st_mode & 0o077 == 0, "Credential directory is not private"
                assert pgpass.read_text(encoding="utf-8") == (
                    f"db.{ref}.supabase.co:5432:postgres:fixture:fixture\n"
                ), "Password file did not contain the expected protected credentials"
                return fake

            with mock.patch.object(module, "trusted_psql_path", return_value="/usr/bin/psql"), \
                 mock.patch.object(module.subprocess, "run", side_effect=inspect_psql) as runner:
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
                assert argv == [
                    "/usr/bin/psql", "-X", "-A", "-t", "-v",
                    "ON_ERROR_STOP=1", "-c", module.SQL,
                ], "Only the approved, fixed executable and SQL may reach psql"
                assert runner.call_args.kwargs.get("shell", False) is False, "Shell execution must be disabled"
                assert env["PGHOST"] == f"db.{ref}.supabase.co"
                assert env["PGPORT"] == "5432"
                assert "PGPASSWORD" not in env, "Database password leaked into child environment"
                assert "PATH" not in env, "Attacker-controlled PATH leaked into subprocess"
                assert pathlib.Path(env["PGPASSFILE"]).is_absolute()
                assert not pathlib.Path(env["PGPASSFILE"]).exists(), "Temporary credentials were not removed"
                assert env["PGSSLMODE"] == "verify-full", "Database TLS server verification must not be downgraded"
                assert env["PGSSLROOTCERT"] == str(ca.resolve(strict=True)), "Configured CA must replace untrusted inherited PGSSLROOTCERT"
                assert "PGOPTIONS" not in env, "Inherited libpq options may override validated target"
                assert "PREVIEW_DATABASE_URL" not in env, "Credential-bearing URI leaked into child environment"
                assert "PREVIEW_CA_CERT_FILE" not in env, "Do not propagate CA config override to libpq child"
                assert not any(key in env for key in (
                    "GITHUB_TOKEN", "SUPABASE_SERVICE_ROLE_KEY", "CLICK2API_API_KEY"
                )), "Unrelated CI or provider secrets leaked into psql environment"
                assert set(env) == {
                    "LC_ALL", "PGHOST", "PGPORT", "PGUSER",
                    "PGPASSFILE", "PGDATABASE", "PGSSLMODE", "PGSSLROOTCERT",
                }, "Unexpected inherited variables reached the database subprocess"

assert module.pgpass_escape("p:ass\\word") == r"p\:ass\\word", "libpq delimiters must be escaped"
fingerprint = module.CANONICAL_BASELINE_FINGERPRINT
assert len(fingerprint) == 64, "Only collision-resistant SHA-256 lineage fingerprints are accepted"
simulate(f"0|false|false|false|true|false|false|false|{fingerprint}\n")
simulate(f"480|true|false|true|true|true|true|true|{fingerprint}\n")
simulate(f"480|true|true|true|true|true|true|true|{fingerprint}\n")
simulate(f"481|true|true|true|true|true|true|true|{fingerprint}\n", expected_ready=True)
# A Preview can have all required Buyer migrations and MORE than 481 versions,
# yet replay a different historical lineage than the approved Core authority.
simulate("486|true|true|true|true|true|true|true|cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd\n")
simulate("481|true|true|true|true|true|true|true|0000000000000000000000000000000000000000000000000000000000000000\n")
simulate(f"481|true|true|true|true|false|true|true|{fingerprint}\n")
simulate(f"481|true|true|true|true|true|false|true|{fingerprint}\n")
simulate(f"481|true|true|true|true|true|true|false|{fingerprint}\n")
simulate("", returncode=1)

# Executable resolution must fail closed before opening network connections.
with mock.patch.object(module.Path, "resolve", side_effect=OSError("unavailable")):
    try:
        module.trusted_psql_path()
    except RuntimeError:
        pass
    else:
        raise AssertionError("Missing system psql executable was accepted")
with tempfile.TemporaryDirectory() as root:
    unsafe_psql = pathlib.Path(root) / "psql"
    unsafe_psql.write_text("#!/bin/sh\\nexit 0\\n", encoding="utf-8")
    unsafe_psql.chmod(0o777)
    with mock.patch.object(module.Path, "resolve", return_value=unsafe_psql):
        try:
            module.trusted_psql_path()
        except RuntimeError:
            pass
        else:
            raise AssertionError("Untrusted writable psql executable was accepted")
# Preserve the /usr/bin/psql invocation name for Debian's pg_wrapper.
# The resolved executable is validated, but cannot replace argv[0].
with mock.patch.object(module.Path, "resolve", return_value=pathlib.Path("/usr/share/postgresql-common/pg_wrapper")), \
     mock.patch.object(module.Path, "is_file", return_value=True), \
     mock.patch.object(module.Path, "stat", return_value=mock.Mock(st_uid=0, st_mode=0o755)), \
     mock.patch.object(module.os, "access", return_value=True):
    assert module.trusted_psql_path() == "/usr/bin/psql"

# CA directory substitution is rejected, even if the CA file is read-only.
with tempfile.TemporaryDirectory() as root:
    parent = pathlib.Path(root) / "unsafe-parent"
    parent.mkdir()
    ca = parent / "root-ca.pem"
    ca.write_text("offline fixture", encoding="utf-8")
    parent.chmod(0o777)
    try:
        module.trusted_ca_path(str(ca))
    except RuntimeError:
        pass
    else:
        raise AssertionError("Writable CA ancestor was accepted")
    parent.chmod(0o700)

# If executable validation fails, psql must never be launched.
with tempfile.TemporaryDirectory() as root:
    ca = pathlib.Path(root) / "trusted-ca.pem"
    ca.write_text("offline fixture", encoding="utf-8")
    with mock.patch.dict(module.os.environ, {"PREVIEW_CA_CERT_FILE": str(ca)}):
        with mock.patch.object(module, "trusted_psql_path", side_effect=RuntimeError("untrusted")), \
             mock.patch.object(module.subprocess, "run") as runner:
            try:
                module.check(ref, url)
            except RuntimeError:
                pass
            else:
                raise AssertionError("Unsafe psql executable was accepted")
            runner.assert_not_called()

# No root certificate or an untrusted writable certificate must fail closed
# before trying to connect; TLS require-only is never an allowed fallback.
with mock.patch.dict(module.os.environ, {"PREVIEW_CA_CERT_FILE": ""}):
    with mock.patch.object(module, "trusted_psql_path", return_value="/usr/bin/psql"), \
             mock.patch.object(module.subprocess, "run") as runner:
        try:
            module.check(ref, url)
        except RuntimeError:
            pass
        else:
            raise AssertionError("Missing trusted CA was accepted")
        runner.assert_not_called()
with tempfile.TemporaryDirectory() as root:
    writable_ca = pathlib.Path(root) / "unsafe-ca.pem"
    writable_ca.write_text("not a valid certificate", encoding="utf-8")
    writable_ca.chmod(0o666)
    with mock.patch.dict(module.os.environ, {"PREVIEW_CA_CERT_FILE": str(writable_ca)}):
        with mock.patch.object(module, "trusted_psql_path", return_value="/usr/bin/psql"), \
             mock.patch.object(module.subprocess, "run") as runner:
            try:
                module.check(ref, url)
            except RuntimeError:
                pass
            else:
                raise AssertionError("World-writable root CA was accepted")
            runner.assert_not_called()
# Group-writable CA files allow replacement by other runner group members
# even if world-writable is false: reject before spawning psql.
with tempfile.TemporaryDirectory() as root:
    group_writable_ca = pathlib.Path(root) / "group-writable-ca.pem"
    group_writable_ca.write_text("not a valid certificate", encoding="utf-8")
    group_writable_ca.chmod(0o664)
    with mock.patch.dict(module.os.environ, {"PREVIEW_CA_CERT_FILE": str(group_writable_ca)}):
        with mock.patch.object(module, "trusted_psql_path", return_value="/usr/bin/psql"), \
             mock.patch.object(module.subprocess, "run") as runner:
            try:
                module.check(ref, url)
            except RuntimeError:
                pass
            else:
                raise AssertionError("Group-writable root CA was accepted")
            runner.assert_not_called()
# urlparse may embed raw database passwords in ValueError details when
# Unicode full-width separators appear in URI authority. CLI must redact it.
password_canary = "canary-" + "do-not-disclose"
bad_url = f"postgresql://fixture:{password_canary}／broken@db.{ref}.supabase.co/postgres"
with mock.patch.dict(
    module.os.environ,
    {"PREVIEW_PROJECT_REF": ref, "PREVIEW_DATABASE_URL": bad_url},
    clear=True,
):
    stderr = io.StringIO()
    with contextlib.redirect_stderr(stderr):
        assert module.cli() == 1
    assert password_canary not in stderr.getvalue(), "Credentials appeared in CLI errors"
    assert bad_url not in stderr.getvalue(), "Database URI appeared in CLI errors"
    assert "details redacted" in stderr.getvalue(), "Expected explicit redacted failure"

print("Buyer Preview schema gate offline negative tests PASS")
