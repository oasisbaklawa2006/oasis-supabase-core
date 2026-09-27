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

CANDIDATE_SUFFIXES = ("", ".ts", ".tsx", ".js", ".mjs", ".cjs", ".json")

DYNAMIC_IMPORT_PATTERN = re.compile(r"""\bimport\s*\(\s*["']([^"']+)["']\s*\)""")


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


def skip_horizontal_and_newline_whitespace(text: str, index: int) -> int:
    while index < len(text) and text[index] in " \t\n\r":
        index += 1
    return index


def read_quoted_module_specifier(text: str, index: int) -> tuple[str, int] | None:
    index = skip_horizontal_and_newline_whitespace(text, index)
    if index >= len(text) or text[index] not in "\"'":
        return None
    quote = text[index]
    index += 1
    start = index
    while index < len(text):
        if text[index] == "\\":
            index += 2
            continue
        if text[index] == quote:
            return text[start:index], index + 1
        index += 1
    return None


def clause_end_after(normalized: str, keyword_index: int) -> int:
    """End exclusive of the import/export clause starting at keyword_index."""
    end = len(normalized)
    for match in re.finditer(r"\b(?:import|export)\b", normalized):
        if match.start() <= keyword_index:
            continue
        if in_string_at(normalized, match.start()):
            continue
        end = min(end, match.start())

    search_from = keyword_index
    while search_from < end:
        semi = normalized.find(";", search_from)
        if semi < 0 or semi >= end:
            break
        if not in_string_at(normalized, semi):
            end = min(end, semi + 1)
            break
        search_from = semi + 1
    return end


def parse_static_clause_specifiers(normalized: str, keyword_index: int) -> list[str]:
    clause_end = clause_end_after(normalized, keyword_index)
    clause = normalized[keyword_index:clause_end]

    from_match = re.search(r"\bfrom\b", clause)
    if from_match:
        from_token_start = keyword_index + from_match.start()
        if in_string_at(normalized, from_token_start):
            return []
        parsed = read_quoted_module_specifier(
            normalized, keyword_index + from_match.end()
        )
        return [parsed[0]] if parsed else []

    import_match = re.match(r"\bimport\b", clause)
    if import_match:
        parsed = read_quoted_module_specifier(
            normalized, keyword_index + import_match.end()
        )
        return [parsed[0]] if parsed else []

    return []


def discover_import_specifiers(normalized: str) -> list[str]:
    found: list[str] = []
    seen: set[str] = set()

    for match in re.finditer(r"\b(?:import|export)\b", normalized):
        if in_string_at(normalized, match.start()):
            continue
        for specifier in parse_static_clause_specifiers(normalized, match.start()):
            if specifier not in seen:
                seen.add(specifier)
                found.append(specifier)

    for match in DYNAMIC_IMPORT_PATTERN.finditer(normalized):
        if not import_clause_outside_string(normalized, match.start()):
            continue
        specifier = match.group(1)
        if specifier not in seen:
            seen.add(specifier)
            found.append(specifier)

    return found


def independent_relative_specifiers(normalized: str) -> set[str]:
    """Clause-local quoted relative paths; independent of discover's extractor logic."""
    expected: set[str] = set()

    for match in re.finditer(r"\b(?:import|export)\b", normalized):
        if in_string_at(normalized, match.start()):
            continue
        keyword_index = match.start()
        clause_end = clause_end_after(normalized, keyword_index)
        clause = normalized[keyword_index:clause_end]
        for rel_match in re.finditer(r"""["'](\.[^"']+)["']""", clause):
            expected.add(rel_match.group(1))

    for match in DYNAMIC_IMPORT_PATTERN.finditer(normalized):
        if not import_clause_outside_string(normalized, match.start()):
            continue
        specifier = match.group(1)
        if specifier.startswith("."):
            expected.add(specifier)

    return expected


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
    return discover_import_specifiers(normalized)


def assert_fail_closed_import_scan(source: str, path: Path) -> None:
    normalized = strip_js_comments(source)
    discovered_set = set(import_specifiers(source))
    expected_relative = independent_relative_specifiers(normalized)

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
