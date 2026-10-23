#!/usr/bin/env python3
"""Fail-closed helpers for Edge Function rollback source capture.

`supabase functions download --use-api` returns only modules that survive
bundling. TypeScript `import type` dependencies are erased, so a live download
can legitimately omit a file that the source still imports. A rollback archive
without that file does not form a buildable module graph.

complete
    Validate a pinned completion record against the live metadata and the
    retrieved tree, then add the omitted type-only files from the pinned
    historical git commit. The record is accepted only when every retrieved file
    is byte-identical to its pinned hash, every completed path is referenced
    exclusively by type-only imports, and the git bytes match the pinned hash.
    Completed files are never presented as live evidence.

verify-archive
    Extract a rollback tarball and prove it restores exactly what the manifest
    describes: the archive holds precisely the manifest files, each file matches
    its recorded SHA-256 and size, and the recursive local import closure
    recomputed from the extracted tree equals the manifest closure.

Every failure exits non-zero. Nothing here falls back to a weaker claim.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import re
import stat
import subprocess  # nosec B404 - fixed argument lists only, no shell
import sys
import tarfile
import tempfile
from pathlib import Path

HEX64 = re.compile(r"^[0-9a-f]{64}$")
HEX40 = re.compile(r"^[0-9a-f]{40}$")


def fail(message: str) -> "None":
    """Print a capture failure and exit non-zero."""
    print(f"ROLLBACK_CAPTURE_FAILED: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_manifest_module():
    """Load the sibling deterministic source-manifest module (its filename is not importable)."""
    path = Path(__file__).resolve().parent / "edge-function-source-manifest.py"
    spec = importlib.util.spec_from_file_location("edge_function_source_manifest", path)
    if spec is None or spec.loader is None:
        fail(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


MANIFEST = load_manifest_module()


def sha256_bytes(data: bytes) -> str:
    """Return the lowercase hex SHA-256 of data."""
    return hashlib.sha256(data).hexdigest()


def tree_files(root: Path) -> dict[str, Path]:
    """Map relative POSIX path to file for every regular file under root; reject symlinks."""
    files: dict[str, Path] = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            fail(f"symlink in captured tree: {path}")
        if path.is_file():
            files[path.relative_to(root).as_posix()] = path
    return files


def safe_relative(rel: str, label: str) -> str:
    """Return rel unchanged if it is a plain relative path, otherwise fail."""
    parts = rel.split("/")
    if not rel or rel.startswith("/") or any(p in ("", ".", "..") for p in parts):
        fail(f"{label} is not a plain relative path: {rel!r}")
    return rel


def load_pin(path: Path) -> dict:
    """Load and strictly validate a completion pin record."""
    try:
        pin = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        fail(f"cannot read completion pin {path}: {exc}")
    if not isinstance(pin.get("liveVersion"), int):
        fail("pin.liveVersion must be an integer")
    if not HEX64.match(str(pin.get("liveBundleSha256", ""))):
        fail("pin.liveBundleSha256 must be 64 lowercase hex characters")
    if not HEX40.match(str(pin.get("provenanceCommit", ""))):
        fail("pin.provenanceCommit must be a 40 character commit id")
    retrieved = pin.get("retrievedFiles")
    completions = pin.get("completions")
    if not isinstance(retrieved, list) or not retrieved:
        fail("pin.retrievedFiles must be a non-empty list")
    if not isinstance(completions, list) or not completions:
        fail("pin.completions must be a non-empty list")
    for entry in retrieved:
        safe_relative(str(entry.get("path", "")), "pin.retrievedFiles path")
        if not HEX64.match(str(entry.get("sha256", ""))):
            fail(f"pin.retrievedFiles sha256 invalid for {entry.get('path')!r}")
    for entry in completions:
        safe_relative(str(entry.get("path", "")), "pin.completions path")
        safe_relative(str(entry.get("importedBy", "")), "pin.completions importedBy")
        if not HEX64.match(str(entry.get("sha256", ""))):
            fail(f"pin.completions sha256 invalid for {entry.get('path')!r}")
        if entry.get("kind") != "type-only":
            fail(f"pin.completions kind must be 'type-only' for {entry.get('path')!r}")
    return pin


def import_statements(source: str) -> list[tuple[str, str]]:
    """Return (clause_text, specifier) for each static import/export-from, plus
    dynamic imports as ('import()', specifier)."""
    normalized = MANIFEST.strip_js_comments(source)
    out: list[tuple[str, str]] = []
    for match in re.finditer(r"\b(?:import|export)\b", normalized):
        if MANIFEST.in_string_at(normalized, match.start()):
            continue
        keyword_index = match.start()
        clause_end = MANIFEST.clause_end_after(normalized, keyword_index)
        clause = normalized[keyword_index:clause_end]
        for specifier in MANIFEST.parse_static_clause_specifiers(normalized, keyword_index):
            out.append((clause, specifier))
    for match in MANIFEST.DYNAMIC_IMPORT_PATTERN.finditer(normalized):
        if MANIFEST.import_clause_outside_string(normalized, match.start()):
            out.append(("import()", match.group(1)))
    return out


def is_type_only_clause(clause: str) -> bool:
    """True when an import/export clause starts with `import type` or `export type`."""
    return re.match(r"\s*(?:import|export)\s+type\b", clause) is not None


def assert_type_only_references(root: Path, files: dict[str, Path], target_rel: str, importer: str) -> None:
    """The target must be referenced, and only through type-only statements."""
    target = (root / target_rel).resolve()
    referenced_by_importer = False
    for rel, path in files.items():
        if not rel.endswith((".ts", ".tsx", ".js", ".mjs", ".cjs")):
            continue
        for clause, specifier in import_statements(path.read_text(encoding="utf-8")):
            if not specifier.startswith("."):
                continue
            raw = (path.parent / specifier).resolve()
            candidates = [raw] if raw.suffix else [Path(str(raw) + s) for s in MANIFEST.CANDIDATE_SUFFIXES]
            if target not in candidates:
                continue
            if not is_type_only_clause(clause):
                fail(
                    f"{target_rel} is imported by a value import in {rel}; "
                    "a runtime dependency cannot be completed from history"
                )
            if rel == importer:
                referenced_by_importer = True
    if not referenced_by_importer:
        fail(f"{importer} has no type-only import of {target_rel}")


def git_show(repo_root: Path, commit: str, repo_path: str) -> bytes:
    """Return the bytes of repo_path at commit, failing if the commit or path is absent."""
    # commit is validated as 40 hex characters by load_pin; no shell is involved.
    exists = subprocess.run(  # nosec B603 B607
        ["git", "-C", str(repo_root), "cat-file", "-e", f"{commit}^{{commit}}"],
        capture_output=True,
    )
    if exists.returncode != 0:
        fail(
            f"provenance commit {commit} is not present in this checkout "
            "(shallow clone?); fetch full history before capturing"
        )
    # repo_path is built from a pin path restricted to a plain relative path by safe_relative.
    shown = subprocess.run(  # nosec B603 B607
        ["git", "-C", str(repo_root), "show", f"{commit}:{repo_path}"],
        capture_output=True,
    )
    if shown.returncode != 0:
        fail(f"{repo_path} does not exist at provenance commit {commit}")
    return shown.stdout


def cmd_complete(args: argparse.Namespace) -> None:
    """Validate the pin against live metadata and the retrieved tree, then restore the omitted files."""
    root = args.functions_root.resolve()
    pin = load_pin(args.pin)
    try:
        live = json.loads(args.live_metadata.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        fail(f"cannot read live metadata: {exc}")

    if live.get("version") != pin["liveVersion"] or live.get("ezbr_sha256") != pin["liveBundleSha256"]:
        fail(
            "completion pin does not describe the live worker: "
            f"pin v{pin['liveVersion']} {pin['liveBundleSha256']} vs live "
            f"v{live.get('version')} {live.get('ezbr_sha256')}"
        )

    files = tree_files(root)
    expected = {entry["path"]: entry["sha256"] for entry in pin["retrievedFiles"]}
    if set(files) != set(expected):
        missing = sorted(set(expected) - set(files))
        extra = sorted(set(files) - set(expected))
        fail(f"retrieved tree does not match pinned file set (missing={missing}, unexpected={extra})")
    for rel, digest in expected.items():
        actual = sha256_bytes(files[rel].read_bytes())
        if actual != digest:
            fail(f"retrieved {rel} sha256 {actual} differs from pinned {digest}")

    origins = {rel: {"origin": "live_api_download"} for rel in files}
    completed = []
    for entry in pin["completions"]:
        rel = entry["path"]
        if rel in files:
            fail(f"{rel} was returned by the live download; it is not an omission")
        assert_type_only_references(root, files, rel, entry["importedBy"])
        data = git_show(args.repo_root.resolve(), pin["provenanceCommit"], f"supabase/functions/{rel}")
        actual = sha256_bytes(data)
        if actual != entry["sha256"]:
            fail(f"{rel} at {pin['provenanceCommit']} has sha256 {actual}, pinned {entry['sha256']}")
        target = root / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        origins[rel] = {
            "origin": "pinned_historical_git",
            "provenanceCommit": pin["provenanceCommit"],
            "importedBy": entry["importedBy"],
            "kind": "type-only",
        }
        completed.append(rel)

    args.origins_out.write_text(
        json.dumps({"completed": completed, "origins": origins}, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def extract_archive(tarball: Path, dest: Path) -> None:
    """Validate every member of a rollback tarball, then extract it under dest."""
    with tarfile.open(tarball, "r:gz") as archive:
        seen: set[str] = set()
        members = archive.getmembers()
        for member in members:
            name = member.name
            if name.startswith("/") or ".." in name.split("/"):
                fail(f"unsafe archive path: {name!r}")
            if name in seen:
                fail(f"duplicate archive entry: {name!r}")
            seen.add(name)
            if member.isdir():
                continue
            if not member.isreg() or stat.S_ISLNK(member.mode):
                fail(f"archive entry is not a regular file: {name!r}")
            if not name.startswith("functions/"):
                fail(f"archive entry outside functions/: {name!r}")
        # Members were validated above; additionally apply the stdlib "data" filter where available.
        extract_kwargs = {"filter": "data"} if hasattr(tarfile, "data_filter") else {}
        archive.extractall(dest, members=members, **extract_kwargs)  # nosec B202


def cmd_verify_archive(args: argparse.Namespace) -> None:
    """Prove an archive restores exactly what its manifest describes."""
    try:
        manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        fail(f"cannot read manifest: {exc}")
    recorded = {entry["path"]: entry for entry in manifest.get("files", [])}
    if not recorded:
        fail("manifest lists no files")

    with tempfile.TemporaryDirectory() as tmp:
        dest = Path(tmp)
        try:
            extract_archive(args.tarball, dest)
        except (tarfile.TarError, OSError) as exc:
            fail(f"archive cannot be extracted: {exc}")
        functions_root = dest / "functions"
        if not functions_root.is_dir():
            fail("archive has no functions/ directory")
        files = tree_files(functions_root)

        if set(files) != set(recorded):
            missing = sorted(set(recorded) - set(files))
            extra = sorted(set(files) - set(recorded))
            fail(f"archive file set differs from manifest (missing={missing}, unaccounted={extra})")
        for rel, path in files.items():
            data = path.read_bytes()
            if sha256_bytes(data) != recorded[rel]["sha256"]:
                fail(f"archive file {rel} sha256 differs from manifest")
            if len(data) != recorded[rel]["size"]:
                fail(f"archive file {rel} size differs from manifest")

        try:
            rebuilt = MANIFEST.build_manifest(functions_root, manifest["function"])
        except SystemExit as exc:
            fail(f"extracted archive does not form a complete import closure: {exc}")
        if rebuilt["closureSha256"] != manifest.get("closureSha256"):
            fail(
                "extracted archive closure "
                f"{rebuilt['closureSha256']} differs from manifest {manifest.get('closureSha256')}"
            )
        if {entry["path"] for entry in rebuilt["files"]} != set(recorded):
            fail("recursive import closure does not cover every archived file")


def main() -> None:
    """Parse arguments and dispatch the subcommand."""
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    complete = sub.add_parser("complete")
    complete.add_argument("--functions-root", type=Path, required=True)
    complete.add_argument("--pin", type=Path, required=True)
    complete.add_argument("--live-metadata", type=Path, required=True)
    complete.add_argument("--repo-root", type=Path, required=True)
    complete.add_argument("--origins-out", type=Path, required=True)
    complete.set_defaults(func=cmd_complete)

    verify = sub.add_parser("verify-archive")
    verify.add_argument("--tarball", type=Path, required=True)
    verify.add_argument("--manifest", type=Path, required=True)
    verify.set_defaults(func=cmd_verify_archive)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
