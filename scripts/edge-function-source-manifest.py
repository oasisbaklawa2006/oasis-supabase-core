#!/usr/bin/env python3
"""Build a deterministic manifest for an Edge Function's local source closure.

Only files reachable through relative imports/exports from the function entrypoint
are included. Remote/npm/jsr imports are intentionally excluded because they are
content-addressed by their import specifiers inside the local source files.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path

IMPORT_PATTERNS = (
    re.compile(r"""\bimport\s+["']([^"']+)["']"""),
    re.compile(r"""\b(?:import|export)\b[^\n]*?\bfrom\s+["']([^"']+)["']"""),
    re.compile(r"""\bimport\s*\(\s*["']([^"']+)["']\s*\)"""),
)

RELATIVE_SPECIFIER_PATTERNS = (
    re.compile(r"""\bimport\s+["'](\.[^"']+)["']"""),
    re.compile(r"""\b(?:import|export)\b[^\n]*?\bfrom\s+["'](\.[^"']+)["']"""),
    re.compile(r"""\bimport\s*\(\s*["'](\.[^"']+)["']\s*\)"""),
)

CANDIDATE_SUFFIXES = ("", ".ts", ".tsx", ".js", ".mjs", ".cjs", ".json")


def strip_js_comments(source: str) -> str:
    """Remove // and /* */ comments while preserving string contents."""
    out: list[str] = []
    i = 0
    length = len(source)
    while i < length:
        ch = source[i]
        if ch in "\"'`":
            quote = ch
            out.append(ch)
            i += 1
            while i < length:
                out.append(source[i])
                if source[i] == "\\" and i + 1 < length:
                    out.append(source[i + 1])
                    i += 2
                    continue
                if source[i] == quote:
                    i += 1
                    break
                i += 1
            continue
        if source.startswith("//", i):
            i += 2
            while i < length and source[i] != "\n":
                i += 1
            continue
        if source.startswith("/*", i):
            i += 2
            while i + 1 < length and source[i : i + 2] != "*/":
                i += 1
            i += 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def in_string_at(source: str, position: int) -> bool:
    in_str: str | None = None
    i = 0
    while i < position:
        if in_str is not None:
            if source[i] == "\\":
                i += 2
                continue
            if source[i] == in_str:
                in_str = None
            i += 1
            continue
        if source.startswith("//", i):
            newline = source.find("\n", i)
            i = len(source) if newline == -1 else newline + 1
            continue
        if source.startswith("/*", i):
            end = source.find("*/", i + 2)
            i = len(source) if end == -1 else end + 2
            continue
        if source[i] in "\"'`":
            in_str = source[i]
        i += 1
    return in_str is not None


def import_clause_outside_string(normalized: str, match_start: int) -> bool:
    prefix = normalized[:match_start]
    keyword_index = -1
    for token in re.finditer(r"\b(?:import|export)\b", prefix):
        keyword_index = token.start()
    if keyword_index < 0:
        tail = normalized[match_start : match_start + 16]
        head = re.match(r"\b(?:import|export)\b", tail)
        if head:
            keyword_index = match_start + head.start()
    if keyword_index < 0:
        return True
    return not in_string_at(normalized, keyword_index)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def resolve_relative(base_file: Path, specifier: str, root: Path) -> Path:
    raw = (base_file.parent / specifier).resolve()
    candidates: list[Path] = []

    if raw.suffix:
        candidates.append(raw)
    else:
        candidates.extend(Path(str(raw) + suffix) for suffix in CANDIDATE_SUFFIXES)
        candidates.extend(raw / name for name in ("index.ts", "index.tsx", "index.js", "index.mjs"))

    root_resolved = root.resolve()
    for candidate in candidates:
        if not candidate.is_file():
            continue
        resolved = candidate.resolve()
        try:
            resolved.relative_to(root_resolved)
        except ValueError as exc:
            raise SystemExit(f"relative import escapes functions root: {specifier}") from exc
        return resolved

    raise SystemExit(f"unable to resolve local import {specifier!r} from {base_file}")


def import_specifiers(source: str) -> list[str]:
    normalized = strip_js_comments(source)
    found: list[str] = []
    for pattern in IMPORT_PATTERNS:
        for match in pattern.finditer(normalized):
            if not import_clause_outside_string(normalized, match.start()):
                continue
            found.append(match.group(1))
    return found


def assert_fail_closed_import_scan(source: str, path: Path) -> None:
    normalized = strip_js_comments(source)
    discovered_set = set(import_specifiers(source))

    expected_relative: set[str] = set()
    for pattern in RELATIVE_SPECIFIER_PATTERNS:
        for match in pattern.finditer(normalized):
            if not import_clause_outside_string(normalized, match.start()):
                continue
            expected_relative.add(match.group(1))

    missing = sorted(expected_relative - discovered_set)
    if missing:
        raise SystemExit(
            f"fail-closed import scan could not account for local import(s) {missing!r} in {path}"
        )


def build_manifest(root: Path, function_name: str) -> dict:
    root = root.resolve()
    entrypoint = root / function_name / "index.ts"
    if not entrypoint.is_file():
        raise SystemExit(f"missing function entrypoint: {entrypoint}")

    pending = [entrypoint.resolve()]
    visited: set[Path] = set()

    while pending:
        current = pending.pop()
        if current in visited:
            continue
        visited.add(current)

        source = current.read_text(encoding="utf-8")
        assert_fail_closed_import_scan(source, current)
        for specifier in import_specifiers(source):
            if not specifier.startswith("."):
                allowed_external = ("http://", "https://", "npm:", "jsr:", "node:", "data:")
                if specifier.startswith(allowed_external):
                    continue
                raise SystemExit(
                    f"unsupported non-relative import {specifier!r} in {current}; "
                    "rollback/source attestation requires direct imports, not hidden import-map aliases"
                )
            target = resolve_relative(current, specifier, root)
            if target not in visited:
                pending.append(target)

    files = []
    manifest_lines = []
    for path in sorted(visited, key=lambda item: item.relative_to(root).as_posix()):
        rel = path.relative_to(root).as_posix()
        digest = sha256_file(path)
        size = path.stat().st_size
        files.append({"path": rel, "sha256": digest, "size": size})
        manifest_lines.append(f"{digest}  {size}  {rel}\n")

    closure_hash = hashlib.sha256("".join(manifest_lines).encode("utf-8")).hexdigest()
    return {
        "function": function_name,
        "entrypoint": f"{function_name}/index.ts",
        "fileCount": len(files),
        "closureSha256": closure_hash,
        "files": files,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("functions_root", type=Path)
    parser.add_argument("function_name")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    manifest = build_manifest(args.functions_root, args.function_name)
    rendered = json.dumps(manifest, indent=2, sort_keys=True) + "\n"

    if args.output:
        args.output.write_text(rendered, encoding="utf-8")
    else:
        print(rendered, end="")


if __name__ == "__main__":
    main()
