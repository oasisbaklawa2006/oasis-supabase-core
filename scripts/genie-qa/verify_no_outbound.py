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

# Reviewed exact Git blob IDs from Core main (20 Nov 2026). Never modify or
# silently replace previously applied migration history.
REVIEWED = {
    "20260817211610_whatsapp_reconciliation_scheduler.sql":
        ("a2c9c57bcd25eff303f3cd50bcfe85929eaa4542", 1, 0),
    "20260915220000_whatsapp_packet_ai_consumer_scheduler.sql":
        ("946b86414ec47d52be4e4bdf93c17850b6e99ea6", 1, 1),
    "20260919140000_whatsapp_operator_reply_consumer_scheduler.sql":
        ("016a6f8d3dd462bf17722b0f178f6bc069241b55", 1, 1),
}
CRON = re.compile(r"\bcron\s*\.\s*schedule\s*\(", re.I)
NETWORK = re.compile(r"\bnet\s*\.\s*http_(?:get|post|put|patch|delete)\s*\(", re.I)
# No extension that can autonomously schedule jobs or send remote HTTP from QA.
EGRESS_EXT = re.compile(
    r"\b(?:create|alter|drop)\s+extension\s+"
    r"(?:if\s+(?:not\s+)?exists\s+)?"
    r"""["']?(?:pg_cron|pg_net|http|dblink)["']?\b""", re.I
)
OTHER_EGRESS = re.compile(
    r"\bcron\s*\.\s*(?:alter_job|run_job)\s*\("
    r"|(?<!\.)\b(?:http_get|http_post|http_put|http_patch|http_delete|http)\s*\("
    r"|\b(?:dblink_connect|dblink_exec|dblink)\s*\(", re.I
)


def blob_hash(raw: bytes) -> str:
    return hashlib.sha1(
        b"blob " + str(len(raw)).encode("ascii") + b"\0" + raw
    ).hexdigest()


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
            if blob_hash(raw) != expected[0]:
                raise ValueError("Reviewed migration changed: " + path.name)
            found.add(path.name)
        if EGRESS_EXT.search(sql) or OTHER_EGRESS.search(sql):
            raise ValueError("QA extension/egress SQL requires review: " + path.name)
        calls = (len(CRON.findall(sql)), len(NETWORK.findall(sql)))
        if expected is None and calls != (0, 0):
            raise ValueError("Unreviewed scheduler/outbound SQL: " + path.name)
        if expected is not None and calls != expected[1:]:
            raise ValueError("Reviewed scheduler call inventory changed: " + path.name)
    if not count or found != set(reviewed):
        raise ValueError("Canonical scheduler inventory incomplete")
    return count


if __name__ == "__main__":
    folder = Path(__file__).resolve().parents[2] / "supabase" / "migrations"
    try:
        total = verify(folder)
    except ValueError as exc:
        print("GENIE_QA_NO_EGRESS_DENIED: " + str(exc), file=sys.stderr)
        raise SystemExit(1)
    print("GENIE_QA_NO_EGRESS_SOURCE_PASS; migration count=" + str(total))
