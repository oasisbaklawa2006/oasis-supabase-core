#!/usr/bin/env python3
"""Focused security assertions for Stage-1B fixture generation subprocess use."""

from __future__ import annotations

import ast
import importlib.util
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock

MODULE = Path(__file__).resolve().parent / "generate_fixtures.py"


def _load_module():
    pil_mock = mock.MagicMock()
    reportlab_mock = mock.MagicMock()
    for name in [
        "PIL",
        "PIL.Image",
        "PIL.ImageDraw",
        "PIL.ImageFilter",
        "PIL.ImageFont",
        "reportlab",
        "reportlab.lib",
        "reportlab.lib.pagesizes",
        "reportlab.pdfgen",
        "reportlab.pdfgen.canvas",
    ]:
        sys.modules.setdefault(name, pil_mock if name.startswith("PIL") else reportlab_mock)
    spec = importlib.util.spec_from_file_location("generate_fixtures", MODULE)
    if spec is None or spec.loader is None:
        raise RuntimeError("MODULE_LOAD_FAILED")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class GenerateFixturesSecurityTest(unittest.TestCase):
    def test_subprocess_calls_never_use_shell(self) -> None:
        tree = ast.parse(MODULE.read_text(encoding="utf-8"))
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call):
                continue
            func = node.func
            if not (
                isinstance(func, ast.Attribute)
                and isinstance(func.value, ast.Name)
                and func.value.id == "subprocess"
                and func.attr == "run"
            ):
                continue
            shell_kw = next((kw for kw in node.keywords if kw.arg == "shell"), None)
            self.assertIsNotNone(shell_kw, "subprocess.run must pass shell=False explicitly")
            self.assertIsInstance(shell_kw.value, ast.Constant)
            self.assertIs(shell_kw.value.value, False)

    def test_subprocess_invocation_is_centralized(self) -> None:
        source = MODULE.read_text(encoding="utf-8")
        self.assertIn("def _run_subprocess(argv: list[str]) -> None:", source)
        self.assertEqual(source.count("subprocess.run("), 1)
        self.assertIn('_FFMPEG_BIN = "ffmpeg"', source)
        self.assertIn("SUBPROCESS_BINARY_REJECTED", source)

    def test_fixture_names_are_allowlisted(self) -> None:
        source = MODULE.read_text(encoding="utf-8")
        self.assertIn("_fixture_output_path", source)
        self.assertIn("INVALID_FIXTURE_NAME", source)

    def test_speech_and_video_text_are_allowlisted(self) -> None:
        source = MODULE.read_text(encoding="utf-8")
        self.assertIn("_ALLOWED_SPEECH_TEXT", source)
        self.assertIn("_ALLOWED_VIDEO_TEXT", source)
        self.assertIn("SPEECH_TEXT_REJECTED", source)

    def test_resolve_binary_returns_resolved_executable_path(self) -> None:
        source = MODULE.read_text(encoding="utf-8")
        self.assertIn("return str(resolved)", source)
        self.assertIn("_subprocess_binary_name", source)

    def test_handwritten_fixture_requires_local_input(self) -> None:
        source = MODULE.read_text(encoding="utf-8")
        self.assertIn("WA_STAGE1B_HANDWRITTEN_FIXTURE", source)
        self.assertIn("def save_handwritten_image", source)
        self.assertIn("HANDWRITTEN_SOURCE_MISSING", source)
        self.assertNotIn("save_handwritten_image(", source.split("def save_handwritten_image", 1)[1].split("def save_image", 1)[0])

    def test_transcode_passes_resolved_ffmpeg_path_to_subprocess(self) -> None:
        mod = _load_module()
        resolved = "/opt/bin/ffmpeg"
        with mock.patch.object(mod.shutil, "which", return_value=resolved):
            with mock.patch.object(mod.subprocess, "run") as run_mock:
                run_mock.return_value = subprocess.CompletedProcess([], 0)
                mod._transcode_audio_to_mp3(
                    Path("/tmp/wa-stage1b-in.wav"),
                    Path("/tmp/wa-stage1b-out.mp3"),
                )
        argv = run_mock.call_args[0][0]
        self.assertEqual(argv[0], resolved)
        self.assertTrue(Path(argv[0]).is_absolute())


if __name__ == "__main__":
    unittest.main()
