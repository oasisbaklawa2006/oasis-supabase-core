#!/usr/bin/env bash
# Contract regression for GitHub workflow concurrency after live Issue #402.
# No live API calls, runner tokens, Supabase resources, or deployment side effects.
set -euo pipefail
repo_root="$(git rev-parse --show-toplevel)"
python3 - "$repo_root/.github/workflows/core-merge-governance.yml" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")


def fail(message: str) -> None:
    raise AssertionError("Core governance concurrency contract: " + message)


def enforce(yaml: str) -> None:
    section = re.search(r"(?ms)^concurrency:\s*\n(.*?)(?=^jobs:\s*$)", yaml)
    if section is None:
        fail("workflow-level concurrency definition missing")
    group_match = re.search(r"(?m)^  group: (.+)$", section.group(1))
    cancel_match = re.search(r"(?m)^  cancel-in-progress: (.+)$", section.group(1))
    if group_match is None or cancel_match is None:
        fail("workflow-level concurrency group/cancellation missing")

    group = group_match.group(1)
    cancel = cancel_match.group(1)

    if "github.event_name == 'workflow_run'" not in group:
        fail("handler and PR events must have separate concurrency identities")
    if "format('handler-{0}', github.run_id)" not in group:
        fail("each handler invocation must have a unique run-id namespace")
    if "format('pr-{0}', github.event.pull_request.number || github.ref)" not in group:
        fail("PR validation must retain its stable per-PR namespace")
    if cancel != "$" + "{{ github.event_name != 'workflow_run' }}":
        fail("handler runs must not be cancel-in-progress; PR validation must remain cancellable")

    if "checks: write" in yaml:
        fail("no check-result-forging permission is permitted")
    if "workflow_run:" not in yaml or "pull_request:" not in yaml:
        fail("both event types must remain enabled")
    if "  trigger-rerun-on-dependency-completion:" not in yaml:
        fail("trusted handler job is missing")
    if "  validation:" not in yaml:
        fail("original pull-request validation job is missing")

    validation = yaml.split("  validation:", 1)[1].split(
        "  trigger-rerun-on-dependency-completion:", 1
    )[0]
    handler = yaml.split("  trigger-rerun-on-dependency-completion:", 1)[1]
    test_step = "bash scripts/tests/verify-core-merge-governance-concurrency-contract.sh"

    if test_step not in validation or test_step not in handler:
        fail("concurrency contract must run in both PR and handler jobs")
    if "actions: write" in validation:
        fail("untrusted PR validation must not have Actions write")
    if "    if: github.event_name != 'workflow_run'" not in validation:
        fail("PR validation must exclude privileged workflow_run events")
    if "    if: github.event_name == 'workflow_run'" not in handler:
        fail("handler must be scoped to workflow_run events")
    if "      actions: write" not in handler:
        fail("handler must retain explicit permission to request a genuine rerun")
    if "          persist-credentials: false" not in handler:
        fail("trusted checkout credentials must not persist")
    # The only checkout on the handler path is default-branch checkout.
    before_resolver = handler.split("      - name: Resolve governance re-check context", 1)[0]
    if re.search(r"(?m)^\s+ref:\s+\$\{\{", before_resolver):
        fail("handler must never checkout a producer/PR-controlled ref")


enforce(source)
negative_cases = [
    ("shared PR group", source.replace(
        "format('handler-{0}', github.run_id)",
        "format('handler-{0}', github.event.pull_request.number)", 1
    )),
    ("handler cancellation enabled", source.replace(
        "github.event_name != 'workflow_run'", "true", 1
    )),
    ("PR group no longer stable", source.replace(
        "format('pr-{0}', github.event.pull_request.number || github.ref)",
        "format('pr-{0}', github.run_id)", 1
    )),
    ("check forging permission added", source.replace(
        "  checks: read", "  checks: write", 1
    )),
]
for description, faulty in negative_cases:
    if faulty == source:
        fail("negative fixture failed to change source: " + description)
    try:
        enforce(faulty)
    except AssertionError:
        pass
    else:
        fail("negative fixture was not rejected: " + description)

print("Core Merge Governance concurrency isolation contract verified (5 positive/negative checks).")
PY
