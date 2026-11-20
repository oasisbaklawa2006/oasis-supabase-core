#!/usr/bin/env python3
"""Fail-closed offline inspection of canonical migrations for Genie QA no-egress.

Only three immutable historical scheduler files are allowed. Their calls cannot
run in a QA database without pg_cron/pg_net, whose absence is independently
required by the protected workflow both before and after migration apply.
"""
from __future__ import annotations

import hashlib
import re
import sys
from pathlib import Path

# Reviewed SHA-256 digests of exact migration bytes (20 Nov 2026). Never modify or
# silently replace previously applied migration history.
REVIEWED = {
    "20260817211610_whatsapp_reconciliation_scheduler.sql":
        ("3b160d143a051991da73e36dbc1abbb0ced43a3a82af3a200cd31dee2040e97b", 1, 0),
    "20260915220000_whatsapp_packet_ai_consumer_scheduler.sql":
        ("ffe5af8b83045eef89e3e5c1cf5b28c45e4a4bfeaf774f57b2fae5d772581f58", 1, 1),
    "20260919140000_whatsapp_operator_reply_consumer_scheduler.sql":
        ("6b7aa7dbe4db010389d8b69abdb1d9e423e03dd25a25370627bca9b906780c3d", 1, 1),
}
CRON = re.compile(r"\bcron\s*\.\s*schedule\s*\(", re.I)
NETWORK = re.compile(r"\bnet\s*\.\s*http_(?:get|post|put|patch|delete)\s*\(", re.I)
# No extension that can autonomously schedule jobs or send remote HTTP from QA.
EGRESS_EXT = re.compile(
    r"\b(?:create|alter|drop)\s+extension\s+"
    r"(?:if\s+(?:not\s+)?exists\s+)?"
    r"""(?:["'](?:pg_cron|pg_net|http|dblink)["']|(?:pg_cron|pg_net|http|dblink)\b)""", re.I
)
OTHER_EGRESS = re.compile(
    r"\bcron\s*\.\s*(?:alter_job|run_job)\s*\("
    r"|(?<!\.)\b(?:http_get|http_post|http_put|http_patch|http_delete|http)\s*\("
    r"|\b(?:dblink_connect|dblink_exec|dblink)\s*\(", re.I
)


def sql_for_egress_scan(sql: str) -> str:
    """Collapse SQL comments and quoted identifiers without hiding executable SQL.

    PostgreSQL treats comments as whitespace and accepts quoted routine/schema
    identifiers. Dollar-quoted PL/pgSQL bodies must remain inspectable, since
    egress statements may occur inside function bodies. Fail on broken quoting.
    """
    out: list[str] = []
    i = 0
    size = len(sql)
    while i < size:
        if sql.startswith("--", i):
            end = sql.find("\n", i + 2)
            if end < 0:
                out.append(" ")
                break
            out.append("\n")
            i = end + 1
            continue
        if sql.startswith("/*", i):
            depth = 1
            i += 2
            while i < size and depth:
                if sql.startswith("/*", i):
                    depth += 1
                    i += 2
                elif sql.startswith("*/", i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
            if depth:
                raise ValueError("Unterminated SQL block comment")
            out.append(" ")
            continue
        if sql[i] == '"':
            i += 1
            identifier: list[str] = []
            while i < size:
                if sql[i] == '"':
                    if i + 1 < size and sql[i + 1] == '"':
                        identifier.append('"')
                        i += 2
                    else:
                        i += 1
                        break
                else:
                    identifier.append(sql[i])
                    i += 1
            else:
                raise ValueError("Unterminated quoted SQL identifier")
            out.append("".join(identifier))
            continue
        if sql[i] == "'":
            start = i
            i += 1
            while i < size:
                if sql[i] == "'":
                    if i + 1 < size and sql[i + 1] == "'":
                        i += 2
                    else:
                        i += 1
                        break
                else:
                    i += 1
            else:
                raise ValueError("Unterminated SQL string")
            out.append(sql[start:i])
            continue
        out.append(sql[i])
        i += 1
    return "".join(out)


def sha256_digest(raw: bytes) -> str:
    """Pin SHA-256 of raw migration bytes for security-critical integrity."""
    return hashlib.sha256(raw).hexdigest()


def verify(directory: Path, reviewed: dict | None = None) -> int:
    """Refuse changed reviewed sources, missing files, or new outbound paths."""
    reviewed = REVIEWED if reviewed is None else reviewed
    if not directory.is_dir() or directory.is_symlink():
        raise ValueError("Canonical migration directory missing or unsafe")
    found = set()
    count = 0
    for path in sorted(directory.glob("*.sql")):
        if path.is_symlink() or not path.is_file():
            raise ValueError("Unsafe migration file")
        count += 1
        raw = path.read_bytes()
        try:
            sql = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise ValueError("Non-UTF8 migration SQL") from exc
        expected = reviewed.get(path.name)
        if expected is not None:
            if sha256_digest(raw) != expected[0]:
                raise ValueError("Reviewed migration changed: " + path.name)
            found.add(path.name)
        scanned = sql_for_egress_scan(sql)
        if EGRESS_EXT.search(scanned) or OTHER_EGRESS.search(scanned):
            raise ValueError("QA extension/egress SQL requires review: " + path.name)
        calls = (len(CRON.findall(scanned)), len(NETWORK.findall(scanned)))
        if expected is None and calls != (0, 0):
            raise ValueError("Unreviewed scheduler/outbound SQL: " + path.name)
        if expected is not None and calls != expected[1:]:
            raise ValueError("Reviewed scheduler call inventory changed: " + path.name)
    if not count or found != set(reviewed):
        raise ValueError("Canonical scheduler inventory incomplete")
    return count


if __name__ == "__main__":
    folder = (Path(sys.argv[1]).resolve() if len(sys.argv) == 2
              else Path(__file__).resolve().parents[2] / "supabase" / "migrations")
    try:
        total = verify(folder)
    except ValueError as exc:
        print("GENIE_QA_NO_EGRESS_DENIED: " + str(exc), file=sys.stderr)
        raise SystemExit(1)
    print("GENIE_QA_NO_EGRESS_SOURCE_PASS; migration count=" + str(total))
