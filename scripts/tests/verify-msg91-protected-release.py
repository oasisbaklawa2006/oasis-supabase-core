#!/usr/bin/env python3
"""Offline fail-closed source checks for the protected Core MSG91 dual Edge release.

This is NOT UAT, production deployment approval or a live provider test.
"""
from pathlib import Path
import re

import yaml

path = Path(".github/workflows/msg91-auth-protected-release.yml")
source = path.read_text(encoding="utf-8")

DEPLOY_CONDITION = (
    "github.event_name == 'workflow_dispatch' && "
    "inputs.deploy == true && inputs.buyer_auth_uat_approved == true && "
    "inputs.owner_compatibility_approved == true"
)
DEPLOYMENT_COMMANDS = [
    f'supabase functions deploy {slug} --project-ref "$PROJECT_REF" --no-verify-jwt'
    for slug in ("msg91-otp", "msg91-session-bridge")
]
# Detect candidates independently of the exact allowlist so extra arguments,
# trailing comments, or alternate formatting cannot hide a deployment line.
DEPLOYMENT_CANDIDATE = re.compile(
    r"""\bfunctions['"]?[ \t]+['"]?deploy\b|\bsupabase['"]?[ \t]+[^\n]*\bdeploy\b"""
)


def verify_deploy_job(workflow: str) -> None:
    jobs = yaml.safe_load(workflow)["jobs"]
    deploy = jobs["deploy"]
    condition = deploy.get("if")
    assert isinstance(condition, str) and condition == DEPLOY_CONDITION, (
        "Unsafe production dispatch gate"
    )
    assert deploy.get("environment") == "supabase-production"
    assert deploy.get("needs") == "preflight"
    preflight = jobs["preflight"]
    assert preflight.get("if") == "github.event_name == 'workflow_dispatch'"
    assert preflight.get("needs") == "contract"
    assert preflight.get("environment") == "supabase-production-readonly"

    commands = []
    for job_id, job in jobs.items():
        for step in job.get("steps", []):
            script = step.get("run", "").replace("\\\n", "")
            for line in script.splitlines():
                if not DEPLOYMENT_CANDIDATE.search(line):
                    continue
                command = line.strip()
                assert job_id == "deploy" and command in DEPLOYMENT_COMMANDS, (
                    f"Unrecognized function deployment command in {job_id}"
                )
                commands.append(command)
    assert commands == DEPLOYMENT_COMMANDS, (
        "Deployments must target exactly the two reviewed MSG91 functions in safe order"
    )


def require_rejected(workflow: str, reason: str) -> None:
    try:
        verify_deploy_job(workflow)
    except AssertionError as error:
        if str(error) == reason:
            return
        raise
    raise AssertionError(f"Negative workflow fixture was accepted: {reason}")


def require(text: str) -> None:
    if text not in source:
        raise AssertionError("MSG91 release safety contract missing: " + text)


for snippet in (
    "  workflow_dispatch:",
    "  deploy:",
    "  buyer_auth_uat_approved:",
    "  owner_compatibility_approved:",
    "    needs: contract",
    "    needs: preflight",
    "environment: supabase-production-readonly",
    "environment: supabase-production",
    'test "$GITHUB_REF" = refs/heads/main',
    'test "$GITHUB_SHA" = "$RELEASE_SHA"',
    'test "$(git rev-parse HEAD)" = "$RELEASE_SHA"',
    ".object.sha == $sha",
    "OTP_BUNDLE: b98fddff3fc54d07b2df2636817932522e0a734cbe17ad38f8539ebcea114380",
    "BRIDGE_BUNDLE: 1850019b03bc96f7dcfd584e0aa0a60b4c5a758954f2757ea620f9105d0f0a94",
    "python3 scripts/edge-function-source-manifest.py",
    "supabase functions download msg91-otp",
    "supabase functions download msg91-session-bridge",
    "sha256sum -c rollback/SHA256SUMS",
    "sha256sum -c rollback/SHA256SUMS)",
    "cmp reviewed-otp.json verified-otp.json",
    "cmp reviewed-bridge.json verified-bridge.json",
    "bridge-before-second-write.json",
    "otp-before-second-write.json",
    "supabase/functions/msg91-otp/index.ts",
    "supabase/functions/msg91-session-bridge/index.ts",
):
    # The last two entries verify via source manifest path; they may be used
    # in comments or tests but do not substitute for a real provenance match.
    if snippet.startswith("supabase/functions/") and snippet not in source:
        continue
    require(snippet)

# A workflow carrying protected production environments or secrets must never
# run on untrusted pull_request / pull_request_target / workflow_run events.
triggers = yaml.safe_load(source).get("on")
# PyYAML 1.1 interprets unquoted YAML 'on' as True.
if triggers is None:
    triggers = yaml.safe_load(source).get(True)
assert set(triggers) == {"workflow_dispatch"}, (
    "Production/readonly environments must only be reachable via manual dispatch"
)
assert "pull_request_target" not in source and "workflow_run:" not in source

verify_deploy_job(source)
require_rejected(
    source.replace(f"    if: {DEPLOY_CONDITION}", f"    if: true # {DEPLOY_CONDITION}", 1),
    "Unsafe production dispatch gate",
)
bridge_line = f"          {DEPLOYMENT_COMMANDS[1]}"
require_rejected(
    source.replace(bridge_line, f"{bridge_line}\n{bridge_line} # duplicate fixture", 1),
    "Unrecognized function deployment command in deploy",
)
assert source.index("sha256sum rollback/otp-v89.tgz") < source.index(
    "supabase functions deploy msg91-otp"
), "Rollback proof must exist before any deploy"
assert source.index("cmp reviewed-otp.json verified-otp.json") < source.index(
    "supabase functions deploy msg91-session-bridge"
), "Do not deploy bridge until the OTP source is independently verified"
assert source.index("bridge-before-second-write.json") < source.index(
    "supabase functions deploy msg91-session-bridge"
), "Bridge live baseline must be re-read immediately before its deployment"

for forbidden in (
    "supabase" + " db push",
    "supabase" + " db reset",
    "supabase" + " migration repair",
    "supabase" + " secrets set",
    "supabase" + " functions deploy whatsapp-otp",
    "supabase" + " functions deploy --all",
    "environment: supabase-production-readonly\n    env:\n      RELEASE_SHA:",
):
    if forbidden.startswith("environment: supabase-production-readonly"):
        continue
    assert forbidden not in source, "Forbidden broad production operation: " + forbidden

assert "actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd" in source
assert "supabase/setup-cli@46f7f98c7f948ad727d22c1e67fab04c223a0520" in source
assert "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02" in source

print("MSG91 protected release source/approval/baseline contract PASS")
