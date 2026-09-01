#!/usr/bin/env python3
"""Focused security assertions for Stage-1B fixture generation subprocess use."""

from __future__ import annotations

import ast
import unittest
from pathlib import Path

MODULE = Path(__file__).resolve().parent / "generate_fixtures.py"


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


if __name__ == "__main__":
    unittest.main()
