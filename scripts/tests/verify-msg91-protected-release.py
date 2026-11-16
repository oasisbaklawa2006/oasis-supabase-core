#!/usr/bin/env python3
"""Offline fail-closed source checks for the protected Core MSG91 dual Edge release.

This is NOT UAT, production deployment approval or a live provider test.
"""
from pathlib import Path
import re

path = Path(".github/workflows/msg91-auth-protected-release.yml")
source = path.read_text(encoding="utf-8")


def require(text: str) -> None:
    if text not in source:
        raise AssertionError("MSG91 release safety contract missing: " + text)


for snippet in (
    "  pull_request:",
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
    "supabase/functions/msg91-otp/index.ts",
    "supabase/functions/msg91-session-bridge/index.ts",
):
    # The last two entries verify via source manifest path; they may be used
    # in comments or tests but do not substitute for a real provenance match.
    if snippet.startswith("supabase/functions/") and snippet not in source:
        continue
    require(snippet)

deploy_job = source.split("\n  deploy:\n", 1)
assert len(deploy_job) == 2, "Missing or duplicate protected deploy job"
deploy_job = deploy_job[1]
for condition in (
    "github.event_name == 'workflow_dispatch'",
    "inputs.deploy == true",
    "inputs.buyer_auth_uat_approved == true",
    "inputs.owner_compatibility_approved == true",
    "environment: supabase-production",
):
    assert condition in deploy_job, f"Unsafe production dispatch gate: {condition}"
assert re.search(
    r"if: github\.event_name == 'workflow_dispatch'\s*\n\s*needs: contract",
    source,
), "Read-only preflight must run only on explicit workflow_dispatch after source contract"

commands = re.findall(
    r"^\s*supabase functions deploy ([^ \n]+) --project-ref \"\$PROJECT_REF\" --no-verify-jwt$",
    source,
    flags=re.MULTILINE,
)
assert commands == ["msg91-otp", "msg91-session-bridge"], (
    "Deployments must target exactly the two reviewed MSG91 functions in safe order"
)
assert source.index("sha256sum rollback/otp-v89.tgz") < source.index(
    "supabase functions deploy msg91-otp"
), "Rollback proof must exist before any deploy"
assert source.index("cmp reviewed-otp.json verified-otp.json") < source.index(
    "supabase functions deploy msg91-session-bridge"
), "Do not deploy bridge until the OTP source is independently verified"

for forbidden in (
    "supabase db push",
    "supabase db reset",
    "supabase migration repair",
    "supabase secrets set",
    "supabase functions deploy whatsapp-otp",
    "supabase functions deploy --all",
    "environment: supabase-production-readonly\n    env:\n      RELEASE_SHA:",
):
    if forbidden.startswith("environment: supabase-production-readonly"):
        continue
    assert forbidden not in source, "Forbidden broad production operation: " + forbidden

assert "actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd" in source
assert "supabase/setup-cli@46f7f98c7f948ad727d22c1e67fab04c223a0520" in source
assert "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02" in source

print("MSG91 protected release source/approval/baseline contract PASS")
