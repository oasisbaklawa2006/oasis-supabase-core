#!/usr/bin/env python3
"""Negative evidence cases; all fixtures are local and no remote code is run."""
from pathlib import Path
import copy
import importlib.util
import json
import os
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "studio_qa_bundle", ROOT / "scripts/studio-qa/verify_qa_bundle.py")
GUARD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GUARD)


class BundleEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "functions"
        GUARD._load_builder().build(
            ROOT / "supabase/functions/catalogue-ai-copy/index.ts",
            ROOT / "supabase/functions/_shared/catalogueAiCopy.ts", self.root)
        self.metadata = {"id": "11111111-1111-4111-8111-111111111111",
                         "slug": "catalogue-ai-copy", "version": 1,
                         "status": "ACTIVE", "verify_jwt": True,
                         "ezbr_sha256": "a" * 64}

    def attest(self, before=None, after=None, project=GUARD.QA_PROJECT):
        return GUARD.attest(project, self.root,
                            self.metadata if before is None else before,
                            self.metadata if after is None else after)

    def test_exact_inert_evidence_is_not_uat_or_lease_certification(self):
        result = self.attest()
        self.assertTrue(result["verify_jwt"])
        self.assertFalse(result["exclusive_writer_verified"])
        self.assertFalse(result["authenticated_uat_executed"])
        self.assertEqual(len(result["files"]), 2)

    def test_foreign_and_production_projects_denied(self):
        for project in ("tcxvcatsqqertcnycuop", "", "unknown"):
            with self.subTest(project=project), self.assertRaises(GUARD.EvidenceDenied):
                self.attest(project=project)

    def test_incomplete_or_unsafe_metadata_denied(self):
        for key, bad_values in {
            "id": (None, "", "not-a-uuid"), "slug": (None, "msg91-otp"),
            "version": (None, True, 0, -1, "1"), "status": (None, "REMOVED"),
            "verify_jwt": (None, False, 1, "true"),
            "ezbr_sha256": (None, "", "f" * 63, "G" * 64),
        }.items():
            for value in bad_values:
                candidate = dict(self.metadata, **{key: value})
                with self.subTest(key=key, value=value), self.assertRaises(GUARD.EvidenceDenied):
                    self.attest(candidate, candidate)
        for key in self.metadata:
            candidate = dict(self.metadata)
            del candidate[key]
            with self.subTest(missing=key), self.assertRaises(GUARD.EvidenceDenied):
                self.attest(candidate, candidate)

    def test_capture_replacement_denied(self):
        for key, value in (("id", "22222222-2222-4222-8222-222222222222"),
                           ("version", 2), ("ezbr_sha256", "b" * 64)):
            with self.subTest(key=key), self.assertRaises(GUARD.EvidenceDenied):
                self.attest(after=dict(self.metadata, **{key: value}))

    def test_source_and_helper_modification_denied(self):
        for relative in GUARD.FILES:
            target = self.root / relative
            original = target.read_bytes()
            target.write_bytes(original + b"\n// mutated\n")
            with self.subTest(relative=relative), self.assertRaises(GUARD.EvidenceDenied):
                self.attest()
            target.write_bytes(original)

    def test_canonical_provider_source_cannot_pass_as_inert(self):
        (self.root / "catalogue-ai-copy/index.ts").write_bytes(
            (ROOT / "supabase/functions/catalogue-ai-copy/index.ts").read_bytes())
        with self.assertRaises(GUARD.EvidenceDenied):
            self.attest()

    def test_missing_extra_and_symlink_files_denied(self):
        index = self.root / "catalogue-ai-copy/index.ts"
        content = index.read_bytes()
        index.unlink()
        with self.assertRaises(GUARD.EvidenceDenied):
            self.attest()
        index.write_bytes(content)
        extra = self.root / "unexpected.ts"
        extra.write_text("export const unexpected = true;")
        with self.assertRaises(GUARD.EvidenceDenied):
            self.attest()
        extra.unlink()
        external = Path(self.tmp.name) / "external.ts"
        external.write_bytes(content)
        index.unlink()
        index.symlink_to(external)
        with self.assertRaises(GUARD.EvidenceDenied):
            self.attest()

    def test_invalid_json_is_rejected(self):
        path = Path(self.tmp.name) / "metadata.json"
        for raw in (b'', b'[]', b'{"version":1,"version":2}', b'{"x":NaN}',
                    b'{"x":Infinity}', b'\xff', b' ' * (GUARD.MAX_BYTES + 1)):
            path.write_bytes(raw)
            with self.subTest(raw=raw[:30]), self.assertRaises(GUARD.EvidenceDenied):
                GUARD.read_metadata(path)

    def test_metadata_symlink_swap_at_open_is_denied(self):
        path = Path(self.tmp.name) / "metadata.json"
        path.write_text(json.dumps(self.metadata))
        replacement = Path(self.tmp.name) / "replacement.json"
        replacement.write_text(json.dumps(self.metadata))
        original_open = os.open
        swapped = False

        def racing_open(name, flags, *args, **kwargs):
            nonlocal swapped
            if name == path.name and kwargs.get("dir_fd") is not None:
                path.unlink()
                path.symlink_to(replacement)
                swapped = True
            return original_open(name, flags, *args, **kwargs)

        with mock.patch.object(GUARD.os, "open", side_effect=racing_open):
            with self.assertRaises(GUARD.EvidenceDenied):
                GUARD.read_metadata(path)
        self.assertTrue(swapped, "the test must reach the vulnerable read site")

    def test_source_symlink_swap_after_inventory_is_denied(self):
        path = self.root / "catalogue-ai-copy/index.ts"
        replacement = Path(self.tmp.name) / "matching-inert.ts"
        replacement.write_bytes(path.read_bytes())
        original_open = os.open
        swapped = False

        def racing_open(name, flags, *args, **kwargs):
            nonlocal swapped
            if name == "index.ts" and kwargs.get("dir_fd") is not None:
                path.unlink()
                path.symlink_to(replacement)
                swapped = True
            return original_open(name, flags, *args, **kwargs)

        with mock.patch.object(GUARD.os, "open", side_effect=racing_open):
            with self.assertRaises(GUARD.EvidenceDenied):
                self.attest()
        self.assertTrue(swapped, "inventory must finish before the replacement")

    def test_metadata_parent_symlink_swap_is_denied(self):
        parent = Path(self.tmp.name) / "metadata-parent"
        parent.mkdir()
        path = parent / "metadata.json"
        path.write_text(json.dumps(self.metadata))
        parked = Path(self.tmp.name) / "metadata-parent-parked"
        original_open = os.open
        swapped = False

        def racing_open(name, flags, *args, **kwargs):
            nonlocal swapped
            if name == parent.name and kwargs.get("dir_fd") is not None:
                parent.rename(parked)
                parent.symlink_to(parked, target_is_directory=True)
                swapped = True
            return original_open(name, flags, *args, **kwargs)

        with mock.patch.object(GUARD.os, "open", side_effect=racing_open):
            with self.assertRaises(GUARD.EvidenceDenied):
                GUARD.read_metadata(path)
        self.assertTrue(swapped)

    def test_source_parent_symlink_swap_after_inventory_is_denied(self):
        parent = self.root / "catalogue-ai-copy"
        parked = Path(self.tmp.name) / "parked-source"
        original_open = os.open
        swapped = False

        def racing_open(name, flags, *args, **kwargs):
            nonlocal swapped
            if name == parent.name and kwargs.get("dir_fd") is not None:
                parent.rename(parked)
                parent.symlink_to(parked, target_is_directory=True)
                swapped = True
            return original_open(name, flags, *args, **kwargs)

        with mock.patch.object(GUARD.os, "open", side_effect=racing_open):
            with self.assertRaises(GUARD.EvidenceDenied):
                self.attest()
        self.assertTrue(swapped)

    def test_opened_nonregular_file_is_denied_without_blocking(self):
        path = Path(self.tmp.name) / "evidence.fifo"
        os.mkfifo(path)
        with self.assertRaises(GUARD.EvidenceDenied):
            GUARD.read_metadata(path)
        with self.assertRaises(GUARD.EvidenceDenied):
            GUARD.checked_read(self.root)

    def test_unsupported_secure_open_and_parent_traversal_are_denied(self):
        path = Path(self.tmp.name) / "metadata.json"
        path.write_text(json.dumps(self.metadata))
        with mock.patch.object(GUARD, "SAFE_OPEN_SUPPORTED", False):
            with self.assertRaises(GUARD.EvidenceDenied):
                GUARD.read_metadata(path)
        with self.assertRaises(GUARD.EvidenceDenied):
            GUARD.checked_read(path.parent / ".." / path.parent.name / path.name)

    def test_metadata_read_stays_bound_to_opened_descriptor(self):
        path = Path(self.tmp.name) / "metadata.json"
        path.write_text(json.dumps(self.metadata))
        replacement = Path(self.tmp.name) / "replacement.json"
        replacement.write_text('{"untrusted":true}')
        original_fstat = os.fstat
        swapped = False

        def racing_fstat(descriptor):
            nonlocal swapped
            result = original_fstat(descriptor)
            if not swapped:
                path.unlink()
                path.symlink_to(replacement)
                swapped = True
            return result

        with mock.patch.object(GUARD.os, "fstat", side_effect=racing_fstat):
            self.assertEqual(GUARD.read_metadata(path), self.metadata)
        self.assertTrue(swapped)

    def test_arbitrary_metadata_fields_do_not_leak(self):
        candidate = copy.deepcopy(self.metadata)
        candidate["sensitive_extra"] = "never-emit-this"
        result = self.attest(candidate, candidate)
        self.assertNotIn("never-emit-this", json.dumps(result))


if __name__ == "__main__":
    unittest.main()
