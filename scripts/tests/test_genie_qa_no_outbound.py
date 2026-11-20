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
                gate.blob_hash(data), 1, 0 if n == 0 else 1
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
                with self.subTest(name=name, verb=verb):
                    p = self.dir / "new.sql"
                    p.write_text(verb + " " + name + ";")
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
