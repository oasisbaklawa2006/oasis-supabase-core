#!/usr/bin/env python3
"""Offline negative tests for Genie QA canonical scheduler no-egress gate."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

source = Path(__file__).resolve().parents[1] / "genie-qa" / "verify_no_outbound.py"
spec = importlib.util.spec_from_file_location("genie_qa_no_outbound", source)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

CRON = "DO $$ BEGIN PERFORM cron.schedule('x','* * * * *','SELECT 1'); END $$;"
HTTP = "CREATE FUNCTION f() RETURNS void AS $$ BEGIN PERFORM net.http_post('https://example.invalid'); END $$ LANGUAGE plpgsql;"


class NoOutboundTests(unittest.TestCase):
    def test_sha256_integrity_pin_uses_raw_bytes_not_legacy_git_sha1(self):
        # Stable NIST vector, not a 40-character Git SHA-1 object identifier.
        self.assertEqual(
            gate.sha256_digest(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        )
        self.assertEqual(len(gate.sha256_digest(b"abc")), 64)
        self.assertNotEqual(gate.sha256_digest(b"abc"), gate.sha256_digest(b"abcd"))

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.dir = Path(self.temp.name)
        self.reviewed = {}
        for n, (filename, sql) in enumerate((
            ("reviewed_a.sql", CRON),
            ("reviewed_b.sql", CRON + "\n" + HTTP),
            ("reviewed_c.sql", CRON + "\n" + HTTP),
        )):
            data = sql.encode("utf-8")
            (self.dir / filename).write_bytes(data)
            self.reviewed[filename] = (
                gate.sha256_digest(data), 1, 0 if n == 0 else 1
            )

    def test_unmodified_reviewed_scheduler_set_passes(self):
        self.assertEqual(gate.verify(self.dir, self.reviewed), 3)

    def test_changed_reviewed_sql_fails_even_with_same_call_count(self):
        path = self.dir / "reviewed_a.sql"
        path.write_text(path.read_text() + "\n-- changed\n")
        with self.assertRaisesRegex(ValueError, "Reviewed migration changed"):
            gate.verify(self.dir, self.reviewed)

    def test_missing_reviewed_file_fails(self):
        (self.dir / "reviewed_b.sql").unlink()
        with self.assertRaisesRegex(ValueError, "inventory incomplete"):
            gate.verify(self.dir, self.reviewed)

    def test_new_cron_or_network_sql_fails(self):
        for sql in (CRON, HTTP, "SELECT net.http_get('https://example.invalid');"):
            with self.subTest(sql=sql):
                p = self.dir / "new.sql"
                p.write_text(sql)
                with self.assertRaises(ValueError):
                    gate.verify(self.dir, self.reviewed)
                p.unlink()

    def test_any_egress_extension_ddl_fails(self):
        for name in ("pg_cron", "pg_net", "http", "dblink"):
            for verb in ("CREATE EXTENSION IF NOT EXISTS", "ALTER EXTENSION", "DROP EXTENSION IF EXISTS"):
                for identifier in (name, '"' + name + '"'):
                    with self.subTest(name=name, verb=verb, identifier=identifier):
                        p = self.dir / "new.sql"
                        p.write_text(verb + " " + identifier + ";")
                        with self.assertRaises(ValueError):
                            gate.verify(self.dir, self.reviewed)
                        p.unlink()

    def test_alternative_remote_calls_fail(self):
        for sql in ("SELECT cron.run_job(1);",
                    "SELECT cron.alter_job(1);",
                    "SELECT dblink_exec('remote', 'SELECT 1');",
                    "SELECT http_get('https://example.invalid');"):
            with self.subTest(sql=sql):
                p = self.dir / "new.sql"
                p.write_text(sql)
                with self.assertRaises(ValueError):
                    gate.verify(self.dir, self.reviewed)
                p.unlink()

    def test_sql_comments_and_quoted_identifiers_cannot_hide_egress(self):
        variants = (
            'CREATE/*qa*/ EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA public;',
            'CREATE /* outer /* inner */ still outer */ EXTENSION pg_cron;',
            'ALTER/**/EXTENSION "http" UPDATE;',
            'DROP /* qa */ EXTENSION IF EXISTS "dblink";',
            'SELECT "net"."http_post"(url := \'https://example.invalid\');',
            "SELECT net/* qa */. /* qa */http_get('https://example.invalid');",
            'SELECT "cron"."schedule"(\'foo\', \'* * * * *\', \'SELECT 1\');',
            r"SELECT E'it\'s'; CREATE/*qa*/ EXTENSION pg_net; -- '",
            r"SELECT E'\' --'; CREATE/*qa*/ EXTENSION pg_net;",
            r"SELECT E'a\\\'b'; CREATE/*qa*/ EXTENSION pg_cron;",
            "CREATE/* unterminated",
        )
        for sql in variants:
            with self.subTest(sql=sql):
                candidate = self.dir / "new.sql"
                candidate.write_text(sql)
                with self.assertRaises(ValueError):
                    gate.verify(self.dir, self.reviewed)
                candidate.unlink()

    def test_comment_only_egress_reference_is_not_executable(self):
        (self.dir / "safe.sql").write_text(
            "-- CREATE EXTENSION pg_net;\n"
            "CREATE TABLE public.safe_record (id bigint);\n"
            "/* SELECT net.http_post('https://example.invalid'); */\n"
        )
        self.assertEqual(gate.verify(self.dir, self.reviewed), 4)

    def test_unicode_and_plain_schema_sql_allowed(self):
        (self.dir / "safe.sql").write_text("CREATE TABLE public.qa_test (id integer); -- café")
        self.assertEqual(gate.verify(self.dir, self.reviewed), 4)

    def test_symlink_and_non_utf8_rejected(self):
        p = self.dir / "new.sql"
        p.write_bytes(b"\xff\xfe")
        with self.assertRaisesRegex(ValueError, "Non-UTF8"):
            gate.verify(self.dir, self.reviewed)
        p.unlink()
        p.symlink_to(self.dir / "reviewed_a.sql")
        with self.assertRaisesRegex(ValueError, "Unsafe migration"):
            gate.verify(self.dir, self.reviewed)


if __name__ == "__main__":
    unittest.main()
