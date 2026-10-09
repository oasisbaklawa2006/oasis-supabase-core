#!/usr/bin/env bash
# Regression contract for scripts/resolve-core-merge-governance-context.sh.
#
# Covers the scenarios the permanent Core Merge Governance timeout repair
# must get right: distinguishing a genuinely relevant, live PR re-check from
# an irrelevant, stale, closed, or misconfigured one -- always failing
# closed (never emitting relevant=true) when live state cannot be proven.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
script="$repo_root/scripts/resolve-core-merge-governance-context.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

fail() {
  echo "CORE MERGE GOVERNANCE CONTEXT RESOLUTION REGRESSION: $*" >&2
  exit 1
}

run() {
  local out="$tmp/output.env"
  local status=0
  : >"$out"
  GITHUB_OUTPUT="$out" bash "$script" || status=$?
  cat "$out"
  return "$status"
}

get_output() {
  local key="$1"
  grep -E "^${key}=" "$tmp/output.env" | tail -n1 | cut -d= -f2-
}

# 1. pull_request event: always relevant, values passed through unchanged.
EVENT_NAME=pull_request PR_NUMBER=399 PR_HEAD_SHA=abc123 PR_BASE_REF=main \
  run >/dev/null
[[ "$(get_output relevant)" == "true" ]] || fail 'pull_request event must be relevant'
[[ "$(get_output pr_number)" == "399" ]] || fail 'pull_request event must pass through pr_number'
[[ "$(get_output head_sha)" == "abc123" ]] || fail 'pull_request event must pass through head_sha'
[[ "$(get_output base_ref)" == "main" ]] || fail 'pull_request event must pass through base_ref'

# 2. workflow_dispatch: relevant, but no PR context (matches existing behavior).
EVENT_NAME=workflow_dispatch run >/dev/null
[[ "$(get_output relevant)" == "true" ]] || fail 'workflow_dispatch must remain relevant'
[[ "$(get_output head_sha)" == "" ]] || fail 'workflow_dispatch must not fabricate a head_sha'

# 3. Unrecognized event: fail closed to not-relevant.
EVENT_NAME=push run >/dev/null
[[ "$(get_output relevant)" == "false" ]] || fail 'unrecognized event must not be relevant'

# 4. workflow_run with a name this workflow does not depend on: not relevant.
EVENT_NAME=workflow_run WORKFLOW_RUN_NAME="Unrelated Workflow" WORKFLOW_RUN_HEAD_SHA=deadbeef \
  WORKFLOW_RUN_PR_NUMBERS=399 run >/dev/null
[[ "$(get_output relevant)" == "false" ]] || fail 'disallowed workflow_run name must not be relevant'

# 5. workflow_run with an allowed name but no associated PRs: not relevant.
EVENT_NAME=workflow_run WORKFLOW_RUN_NAME="Edge Function Governance" \
  WORKFLOW_RUN_HEAD_SHA=deadbeef WORKFLOW_RUN_PR_NUMBERS="" run >/dev/null
[[ "$(get_output relevant)" == "false" ]] || fail 'workflow_run with no associated PR must not be relevant'

mock_curl() {
  # $1: fixture script body (python) deciding the response per requested PR number
  cat >"$tmp/bin/curl" <<CURL
#!/usr/bin/env bash
set -euo pipefail
url="\${@: -1}"
num="\${url##*/pulls/}"
$1
CURL
  chmod +x "$tmp/bin/curl"
}

# 6. workflow_run, allowed name, live PR head matches, open, base main: relevant.
mock_curl 'case "$num" in
  399) printf "%s" "{\"state\":\"open\",\"head\":{\"sha\":\"deadbeef\"},\"base\":{\"ref\":\"main\"}}" ;;
  *) printf "%s" "{}" ;;
esac'
PATH="$tmp/bin:$PATH" EVENT_NAME=workflow_run WORKFLOW_RUN_NAME="Edge Function Governance" \
  WORKFLOW_RUN_HEAD_SHA=deadbeef WORKFLOW_RUN_PR_NUMBERS=399 \
  GH_TOKEN=test-token GITHUB_REPOSITORY=oasisbaklawa2006/oasis-supabase-core \
  run >/dev/null
[[ "$(get_output relevant)" == "true" ]] || fail 'matching live PR head must be relevant'
[[ "$(get_output pr_number)" == "399" ]] || fail 'matching live PR must report its number'
[[ "$(get_output head_sha)" == "deadbeef" ]] || fail 'matching live PR must report the live head sha'

# 7. workflow_run, live PR head has moved on (stale/superseded event): not relevant.
mock_curl 'printf "%s" "{\"state\":\"open\",\"head\":{\"sha\":\"NEWSHA\"},\"base\":{\"ref\":\"main\"}}"'
PATH="$tmp/bin:$PATH" EVENT_NAME=workflow_run WORKFLOW_RUN_NAME="Edge Function Governance" \
  WORKFLOW_RUN_HEAD_SHA=deadbeef WORKFLOW_RUN_PR_NUMBERS=399 \
  GH_TOKEN=test-token GITHUB_REPOSITORY=oasisbaklawa2006/oasis-supabase-core \
  run >/dev/null
[[ "$(get_output relevant)" == "false" ]] || fail 'stale workflow_run (PR head moved on) must not be relevant'

# 8. workflow_run, PR is closed: not relevant.
mock_curl 'printf "%s" "{\"state\":\"closed\",\"head\":{\"sha\":\"deadbeef\"},\"base\":{\"ref\":\"main\"}}"'
PATH="$tmp/bin:$PATH" EVENT_NAME=workflow_run WORKFLOW_RUN_NAME="Edge Function Governance" \
  WORKFLOW_RUN_HEAD_SHA=deadbeef WORKFLOW_RUN_PR_NUMBERS=399 \
  GH_TOKEN=test-token GITHUB_REPOSITORY=oasisbaklawa2006/oasis-supabase-core \
  run >/dev/null
[[ "$(get_output relevant)" == "false" ]] || fail 'closed PR must not be relevant'

# 9. workflow_run, PR targets a different base branch: not relevant.
mock_curl 'printf "%s" "{\"state\":\"open\",\"head\":{\"sha\":\"deadbeef\"},\"base\":{\"ref\":\"develop\"}}"'
PATH="$tmp/bin:$PATH" EVENT_NAME=workflow_run WORKFLOW_RUN_NAME="Edge Function Governance" \
  WORKFLOW_RUN_HEAD_SHA=deadbeef WORKFLOW_RUN_PR_NUMBERS=399 \
  GH_TOKEN=test-token GITHUB_REPOSITORY=oasisbaklawa2006/oasis-supabase-core \
  run >/dev/null
[[ "$(get_output relevant)" == "false" ]] || fail 'non-main-base PR must not be relevant'

# 10. workflow_run, multiple PR numbers: first stale, second matches -> relevant via second.
mock_curl 'case "$num" in
  111) printf "%s" "{\"state\":\"open\",\"head\":{\"sha\":\"OLDSHA\"},\"base\":{\"ref\":\"main\"}}" ;;
  222) printf "%s" "{\"state\":\"open\",\"head\":{\"sha\":\"deadbeef\"},\"base\":{\"ref\":\"main\"}}" ;;
esac'
PATH="$tmp/bin:$PATH" EVENT_NAME=workflow_run WORKFLOW_RUN_NAME="Edge Function Governance" \
  WORKFLOW_RUN_HEAD_SHA=deadbeef WORKFLOW_RUN_PR_NUMBERS="111,222" \
  GH_TOKEN=test-token GITHUB_REPOSITORY=oasisbaklawa2006/oasis-supabase-core \
  run >/dev/null
[[ "$(get_output relevant)" == "true" ]] || fail 'second matching PR in a multi-PR list must be found'
[[ "$(get_output pr_number)" == "222" ]] || fail 'the matching PR number must be reported, not the stale one'

# 11. workflow_run, allowed name, PRs present, but no GH_TOKEN: must fail closed (hard error).
unset GH_TOKEN GITHUB_TOKEN || true
if EVENT_NAME=workflow_run WORKFLOW_RUN_NAME="Edge Function Governance" \
  WORKFLOW_RUN_HEAD_SHA=deadbeef WORKFLOW_RUN_PR_NUMBERS=399 \
  GITHUB_REPOSITORY=oasisbaklawa2006/oasis-supabase-core \
  run >"$tmp/no-token.out" 2>"$tmp/no-token.err"; then
  fail 'missing GH_TOKEN must be a hard failure, not a silent not-relevant'
fi
grep -Fq 'GH_TOKEN is required' "$tmp/no-token.err" \
  || fail 'missing GH_TOKEN must report its specific cause'

# 12. every allowed producer workflow name is actually recognized.
for allowed_workflow in "Edge Function Governance" "Migration CI and Schema Drift" "WhatsApp Webhook Security"; do
  mock_curl 'printf "%s" "{\"state\":\"open\",\"head\":{\"sha\":\"deadbeef\"},\"base\":{\"ref\":\"main\"}}"'
  PATH="$tmp/bin:$PATH" EVENT_NAME=workflow_run WORKFLOW_RUN_NAME="$allowed_workflow" \
    WORKFLOW_RUN_HEAD_SHA=deadbeef WORKFLOW_RUN_PR_NUMBERS=399 \
    GH_TOKEN=test-token GITHUB_REPOSITORY=oasisbaklawa2006/oasis-supabase-core \
    run >/dev/null
  [[ "$(get_output relevant)" == "true" ]] || fail "producer workflow '${allowed_workflow}' must be recognized as relevant"
done

echo "Core Merge Governance context resolution verified."
