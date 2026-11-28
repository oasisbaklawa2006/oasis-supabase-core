#!/usr/bin/env python3
"""Validate/extract only expected recovery archive members, never log payloads."""
import argparse
import hashlib
import json
import pathlib
import re
import shutil
import tarfile
import zipfile

LIMIT = 256 * 1024 * 1024
ZIP_FILES = {"backup.tar.gpg", "backup.tar.gpg.sha256"}
MANIFEST_FILES = {"database.dump", "roles.sql", "preservation.json", "ledger.txt", "source-sha.txt"}
TAR_FILES = MANIFEST_FILES | {"manifest.sha256", "toc.txt"}
HEX = re.compile(r"[0-9a-f]{64}")
VERSION = re.compile(r"[0-9]{14}")


def require(ok, reason):
    if not ok:
        raise ValueError(reason)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def copy_member(stream, target):
    with stream, target.open("xb") as output:
        shutil.copyfileobj(stream, output)


def unpack_zip(archive, dest, expected):
    require(HEX.fullmatch(expected) and digest(archive) == expected, "outer archive digest")
    with zipfile.ZipFile(archive) as zipped:
        members = zipped.infolist()
        require(len(members) == len(ZIP_FILES) and {m.filename for m in members} == ZIP_FILES,
                "unexpected ZIP members")
        require(all(not m.is_dir() for m in members) and sum(m.file_size for m in members) <= LIMIT,
                "ZIP member size/type")
        dest.mkdir(mode=0o700)
        for member in members:
            copy_member(zipped.open(member), dest / member.filename)
    require((dest / "backup.tar.gpg.sha256").read_text().strip()
            == digest(dest / "backup.tar.gpg") + "  backup.tar.gpg", "encrypted file checksum")


def unpack_tar(archive, dest, source, baseline, count, maximum):
    require(archive.stat().st_size <= LIMIT, "tar size")
    with tarfile.open(archive, "r:") as tar:
        members = tar.getmembers()
        require(len(members) == len(TAR_FILES) and {m.name for m in members} == TAR_FILES,
                "unexpected tar members")
        require(all(m.isfile() for m in members) and sum(m.size for m in members) <= LIMIT,
                "tar member size/type")
        dest.mkdir(mode=0o700)
        for member in members:
            copy_member(tar.extractfile(member), dest / member.name)
    manifest = (dest / "manifest.sha256").read_text().splitlines()
    entries = {}
    for line in manifest:
        match = re.fullmatch(r"([0-9a-f]{64})  ([a-z0-9.-]+)", line)
        require(match is not None and match[2] not in entries, "invalid manifest entry")
        entries[match[2]] = match[1]
    require(set(entries) == MANIFEST_FILES, "manifest coverage")
    require(all(digest(dest / name) == checksum for name, checksum in entries.items()),
            "manifest checksum")
    require(re.fullmatch(r"[0-9a-f]{40}", source) and
            (dest / "source-sha.txt").read_text().strip() == source, "source SHA")
    require(HEX.fullmatch(baseline) and digest(dest / "preservation.json") == baseline,
            "protected baseline digest")
    census = json.loads((dest / "preservation.json").read_text())
    require(len(census) == 17 and all(isinstance(v["count"], int) and
            v["count"] >= 0 and HEX.fullmatch(v["sha256"]) for v in census.values()),
            "protected census format")
    require(census["storage.objects"]["count"] == 0, "storage object backup required")
    ledger = (dest / "ledger.txt").read_text().splitlines()
    require(len(ledger) == count and ledger == sorted(set(ledger)) and
            all(VERSION.fullmatch(v) for v in ledger) and ledger[-1] == maximum,
            "migration ledger identity")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="mode", required=True)
    for name in ("zip", "tar"):
        cmd = sub.add_parser(name)
        cmd.add_argument("archive", type=pathlib.Path)
        cmd.add_argument("dest", type=pathlib.Path)
        if name == "zip":
            cmd.add_argument("digest")
        else:
            cmd.add_argument("source")
            cmd.add_argument("baseline")
            cmd.add_argument("count", type=int)
            cmd.add_argument("maximum")
    args = parser.parse_args()
    try:
        if args.mode == "zip":
            unpack_zip(args.archive, args.dest, args.digest)
        else:
            unpack_tar(args.archive, args.dest, args.source, args.baseline, args.count, args.maximum)
    except Exception:
        raise SystemExit("QA_REHEARSAL_ARCHIVE_VERIFICATION_FAILED") from None
    print("QA_REHEARSAL_ARCHIVE_MEMBERS_VERIFIED")


if __name__ == "__main__":
    main()
