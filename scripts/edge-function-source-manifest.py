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
    re.compile(r"""\b(?:import|export)\s+(?:[^"'()]*?\s+from\s+)?["']([^"']+)["']"""),
    re.compile(r"""\bimport\s*\(\s*["']([^"']+)["']\s*\)"""),
)

CANDIDATE_SUFFIXES = ("", ".ts", ".tsx", ".js", ".mjs", ".cjs", ".json")


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
    found: list[str] = []
    for pattern in IMPORT_PATTERNS:
        found.extend(match.group(1) for match in pattern.finditer(source))
    return found


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
