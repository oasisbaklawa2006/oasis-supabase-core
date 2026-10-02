#!/usr/bin/env python3
"""Structural regression guard for whatsapp-webhook non-order reply authority."""
from __future__ import annotations
import pathlib
import re
import sys

START = re.compile(
    r"}\s*else\s+if\s*\(\s*messageBody\s*&&\s*companyId\s*&&\s*!hasOrderIntent\s*\)\s*\{",
    re.MULTILINE,
)
END = re.compile(r"\n\s*if\s*\(\s*waAutoOrderWritesEnabled\s*\)\s*\{", re.MULTILINE)
DIRECT_SEND = re.compile(r"\bsendReply\s*\(", re.MULTILINE)
MARKER = "Direct non-order reply suppressed"


def assert_governed(source: str) -> None:
    start = START.search(source)
    if not start:
        raise AssertionError("non-order webhook branch not found")
    end = END.search(source, start.end())
    if not end:
        raise AssertionError("non-order webhook branch terminator not found")
    block = source[start.start():end.start()]
    if MARKER not in block:
        raise AssertionError("governed non-order suppression marker missing")
    if DIRECT_SEND.search(block):
        raise AssertionError("direct non-order acknowledgement bypass detected")


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: verify-whatsapp-webhook-nonorder-authority.py <webhook-source>", file=sys.stderr)
        return 2
    path = pathlib.Path(sys.argv[1])
    source = path.read_text(encoding="utf-8")
    try:
        assert_governed(source)
    except AssertionError as exc:
        print(f"WHATSAPP WEBHOOK RECERTIFICATION VIOLATION: {exc}", file=sys.stderr)
        return 1

    # Regression fixture: reintroduce the bypass with multiline formatting.
    # The structural guard must still reject it.
    fixture = source.replace(
        MARKER,
        MARKER + """\n      await sendReply(
        phone91,
        ackMsg,
        supabaseAdmin,
        companyId,
      );""",
        1,
    )
    try:
        assert_governed(fixture)
    except AssertionError as exc:
        if "direct non-order acknowledgement bypass detected" in str(exc):
            print("WhatsApp non-order reply authority structural guard passed.")
            return 0
        print(f"fixture failed for unexpected reason: {exc}", file=sys.stderr)
        return 1

    print("fixture unexpectedly allowed multiline direct sendReply bypass", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
