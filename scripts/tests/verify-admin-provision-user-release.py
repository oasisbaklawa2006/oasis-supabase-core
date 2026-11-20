#!/usr/bin/env python3
"""Negative regression fixtures for the credential-free staff release guard."""
from __future__ import annotations

import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
CHECKER = ROOT / "scripts/check-admin-provision-user-release.rb"
WORKFLOW = ROOT / ".github/workflows/admin-provision-user-protected-update.yml"
CONFIG = ROOT / "supabase/config.toml"
VERIFY = ROOT / ".github/workflows/admin-provision-user-protected-verify.yml"

workflow = WORKFLOW.read_text()
config = CONFIG.read_text()
verifier = VERIFY.read_text()


def run_case(name: str, expected_ok: bool, wf: str = workflow, cfg: str = config,
             verify: str = verifier) -> None:
    with tempfile.TemporaryDirectory(prefix="staff-release-test-") as directory:
        temp = pathlib.Path(directory)
        (temp / "update.yml").write_text(wf)
        (temp / "config.toml").write_text(cfg)
        (temp / "verify.yml").write_text(verify)
        result = subprocess.run(
            ["ruby", str(CHECKER), str(temp / "update.yml"),
             str(temp / "config.toml"), str(temp / "verify.yml")],
            capture_output=True, text=True, check=False,
        )
        if (result.returncode == 0) != expected_ok:
            raise AssertionError(f"{name}: expected pass={expected_ok}, "
                                 f"got exit={result.returncode}: "
                                 f"{result.stdout[-500:]} {result.stderr[-600:]}")
        print(f"{name}: {'accepted' if expected_ok else 'rejected'}")


def replace_exact(value: str, needle: str, replacement: str) -> str:
    if value.count(needle) != 1:
        raise AssertionError(f"fixture anchor does not occur once: {needle[:70]}")
    return value.replace(needle, replacement, 1)


run_case("current release + recovery source", True)

run_case("quoted additional GitHub event", False,
         wf=replace_exact(workflow, "on:\n  workflow_dispatch:",
                          "on:\n  'pull_request':\n    branches: [main]\n  workflow_dispatch:"))
run_case("missing protected deploy environment", False,
         wf=replace_exact(workflow, "    environment: supabase-production\n",
                          "    environment: supabase-production-readonly\n"))
run_case("missing deploy certification despite attestations elsewhere", False,
         wf=replace_exact(workflow, " && inputs.email_config_certified == true",
                          ""))
run_case("multiline shell secret write", False,
         wf=replace_exact(workflow,
                          "      - name: Deploy only reviewed admin-provision-user while retaining verify_jwt=true\n"
                          "        shell: bash\n        run: |\n          set -euo pipefail",
                          "      - name: Deploy only reviewed admin-provision-user while retaining verify_jwt=true\n"
                          "        shell: bash\n        run: |\n          set -euo pipefail\n"
                          "          supabase \\\n            secrets \\\n            set EXAMPLE_SECRET=unsafe"))
run_case("incorrect shared production concurrency", False,
         wf=replace_exact(workflow, "group: admin-provision-user-production-first-deploy",
                          "group: admin-provision-user-only-update"))
run_case("reject JWT disabled in canonical function config", False,
         cfg=replace_exact(config,
             "[functions.admin-provision-user]\nverify_jwt = true",
             "[functions.admin-provision-user]\nverify_jwt = false"))
run_case("recovery write-environment bypass", False,
         verify=replace_exact(verifier, "environment: supabase-production-readonly",
                              "environment: supabase-production"))
run_case("recovery unexpectedly deploys again", False,
         verify=replace_exact(verifier,
             "          mkdir -p recovered-source",
             "          supabase functions deploy admin-provision-user --project-ref \"$PROJECT_REF\"\n"
             "          mkdir -p recovered-source"))
run_case("approved-origin digest missing from archive", False,
         wf=replace_exact(workflow, "            approved-origin-sha256.txt\n",
                          "            no-origin-digest.txt\n"))
print("STAFF INVITE PROTECTED RELEASE REGRESSION: 1 positive + 9 negative passed")
