#!/usr/bin/env python3
"""Normalize cross-environment semantic census output before parity comparison.

The manifest SQL intentionally captures a broad census. A hosted Supabase project
and the pinned local Supabase stack can still differ in platform-bootstrap ACL
materialization (implicit/default relation/routine ACLs) even when application
RLS/policies and executable authority are identical. Those ACL rows are therefore
excluded from cross-environment equality and are governed by migration tests/RLS
policy semantics instead.

Function/procedure definitions are normalized only for source formatting:
CRLF/LF, SQL comments, repeated whitespace, and whitespace around punctuation or
operators. Quoted literals/identifiers are preserved byte-for-byte, so business
constants remain drift-sensitive.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

NON_PORTABLE_BOOTSTRAP_KINDS = {"default_acl", "relation_grant", "routine_grant"}
PUNCT = set("()[],;:=+*<>|-.")


def normalize_sql_source(source: str) -> str:
    source = source.replace("\r\n", "\n").replace("\r", "\n")
    out: list[str] = []
    i = 0
    n = len(source)
    quote: str | None = None
    whitespace_pending = False

    while i < n:
        ch = source[i]

        if quote is not None:
            out.append(ch)
            if ch == quote:
                # SQL quote escaping doubles the quote character.
                if i + 1 < n and source[i + 1] == quote:
                    out.append(source[i + 1])
                    i += 2
                    continue
                quote = None
            i += 1
            continue

        if ch in ("'", '"'):
            if whitespace_pending and out and out[-1] not in PUNCT:
                out.append(" ")
            whitespace_pending = False
            quote = ch
            out.append(ch)
            i += 1
            continue

        if ch == "-" and i + 1 < n and source[i + 1] == "-":
            i += 2
            while i < n and source[i] != "\n":
                i += 1
            whitespace_pending = True
            continue

        if ch == "/" and i + 1 < n and source[i + 1] == "*":
            end = source.find("*/", i + 2)
            if end == -1:
                # Malformed source should remain visibly different, not disappear.
                out.append(source[i:])
                break
            i = end + 2
            whitespace_pending = True
            continue

        if ch.isspace():
            whitespace_pending = True
            i += 1
            continue

        if ch in PUNCT:
            while out and out[-1] == " ":
                out.pop()
            out.append(ch)
            whitespace_pending = False
            i += 1
            continue

        if whitespace_pending and out and out[-1] not in PUNCT:
            out.append(" ")
        whitespace_pending = False
        out.append(ch)
        i += 1

    return "".join(out).strip()


def normalize_row(row: dict) -> dict | None:
    kind = row.get("kind")
    if kind in NON_PORTABLE_BOOTSTRAP_KINDS:
        return None

    if kind in {"function", "procedure"}:
        value = dict(row.get("value") or {})
        definition = value.get("definition")
        if isinstance(definition, str):
            value["definition"] = normalize_sql_source(definition)
        row = dict(row)
        row["value"] = value
    return row


def normalize_file(path: Path) -> None:
    normalized: list[str] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        if not raw.strip():
            continue
        row = normalize_row(json.loads(raw))
        if row is None:
            continue
        normalized.append(json.dumps(row, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
    normalized.sort()
    path.write_text("\n".join(normalized) + ("\n" if normalized else ""), encoding="utf-8")


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: normalize-schema-semantic-manifest.py <local> <remote>", file=sys.stderr)
        return 2
    normalize_file(Path(sys.argv[1]))
    normalize_file(Path(sys.argv[2]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
