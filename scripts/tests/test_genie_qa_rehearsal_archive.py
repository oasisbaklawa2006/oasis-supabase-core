#!/usr/bin/env python3
"""Synthetic-only recovery archive and protected workflow tests."""
import hashlib
import importlib.util
import io
import json
import pathlib
import subprocess
import tarfile
import tempfile
import unittest
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "verify_rehearsal_archive", ROOT / "scripts/genie-qa/verify_rehearsal_archive.py")
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)
SOURCE = "a" * 40
MAXIMUM = "20260102000000"


def checksum(value):
    return hashlib.sha256(value).hexdigest()


def fixture():
    census = {f"synthetic.{i}": {"count": 1, "sha256": "b" * 64} for i in range(16)}
    census["storage.objects"] = {"count": 0, "sha256": "c" * 64}
    members = {
        "database.dump": b"synthetic archive",
        "roles.sql": b"synthetic roles",
        "preservation.json": json.dumps(census).encode() + b"\n",
        "ledger.txt": b"20260101000000\n20260102000000\n",
        "source-sha.txt": (SOURCE + "\n").encode(),
        "toc.txt": b"synthetic toc",
    }
    members["manifest.sha256"] = "".join(
        f"{checksum(members[name])}  {name}\n" for name in sorted(validator.MANIFEST_FILES)
    ).encode()
    return members


def make_tar(path, members, special=None):
    with tarfile.open(path, "w") as archive:
        for name, value in members.items():
            info = tarfile.TarInfo(name)
            info.size = len(value)
            if special == name:
                info.type = tarfile.SYMTYPE
                info.linkname = "/etc/passwd"
                info.size = 0
                archive.addfile(info)
            else:
                archive.addfile(info, io.BytesIO(value))


class RehearsalArchiveTests(unittest.TestCase):
    def test_zip_digest_and_member_allowlist(self):
        encrypted = b"synthetic encrypted bytes"
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            archive = root / "artifact.zip"
            with zipfile.ZipFile(archive, "w") as zipped:
                zipped.writestr("backup.tar.gpg", encrypted)
                zipped.writestr("backup.tar.gpg.sha256",
                                checksum(encrypted) + "  backup.tar.gpg\n")
            validator.unpack_zip(archive, root / "valid", validator.digest(archive))
            with self.assertRaises(ValueError):
                validator.unpack_zip(archive, root / "wrong-digest", "0" * 64)
            with zipfile.ZipFile(archive, "a") as zipped:
                zipped.writestr("../unexpected", b"not allowed")
            with self.assertRaises(ValueError):
                validator.unpack_zip(archive, root / "traversal", validator.digest(archive))

    def test_tar_provenance_manifest_and_ledger(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            members = fixture()
            baseline = checksum(members["preservation.json"])
            archive = root / "recovery.tar"
            make_tar(archive, members)
            validator.unpack_tar(archive, root / "valid", SOURCE, baseline, 2, MAXIMUM)
            for label, source, sha, count, maximum in (
                ("source", "d" * 40, baseline, 2, MAXIMUM),
                ("baseline", SOURCE, "d" * 64, 2, MAXIMUM),
                ("count", SOURCE, baseline, 3, MAXIMUM),
                ("max", SOURCE, baseline, 2, "20260103000000"),
            ):
                with self.subTest(label=label), self.assertRaises(ValueError):
                    validator.unpack_tar(archive, root / label, source, sha, count, maximum)
            make_tar(archive, {**members, "roles.sql": b"modified roles"})
            with self.assertRaises(ValueError):
                validator.unpack_tar(archive, root / "tampered", SOURCE, baseline, 2, MAXIMUM)
            make_tar(archive, members, special="roles.sql")
            with self.assertRaises(ValueError):
                validator.unpack_tar(archive, root / "symlink", SOURCE, baseline, 2, MAXIMUM)

    def test_protected_workflow_is_manual_and_secret_scoped(self):
        path = ROOT / ".github/workflows/genie-qa-recovery-rehearsal.yml"
        parsed = subprocess.run(
            ["ruby", "-rpsych", "-rjson", "-e",
             'w=Psych.safe_load_file(ARGV[0],aliases:false); w["events"]=w["on"]||w[true]; puts JSON.generate(w)',
             str(path)], check=True, capture_output=True, text=True)
        workflow = json.loads(parsed.stdout)
        self.assertEqual(set(workflow["events"]), {"workflow_dispatch"})
        self.assertEqual(workflow["permissions"], {"contents": "read", "actions": "read"})
        self.assertEqual(set(workflow["jobs"]), {"rehearsal"})
        job = workflow["jobs"]["rehearsal"]
        self.assertEqual(job["environment"], "genie-qa-bootstrap")
        self.assertEqual(job["runs-on"], "ubuntu-24.04")
        self.assertEqual(job["if"],
                         "github.repository == 'oasisbaklawa2006/oasis-supabase-core' && github.ref == 'refs/heads/main'")
        self.assertFalse(any("continue-on-error" in scope for scope in [workflow, job, *job["steps"]]))
        secret_steps = [s for s in job["steps"] if "GENIE_QA_BACKUP_PASSPHRASE" in s.get("env", {})]
        self.assertEqual(len(secret_steps), 1)
        self.assertIn("Decrypt", secret_steps[0]["name"])
        self.assertNotIn("GENIE_QA_DATABASE_URL", path.read_text())
        self.assertNotIn("SUPABASE_ACCESS_TOKEN", path.read_text())
        self.assertNotIn("--smoke", path.read_text())
        self.assertNotIn("upload-artifact", path.read_text())
        self.assertIn("--archive", path.read_text())
