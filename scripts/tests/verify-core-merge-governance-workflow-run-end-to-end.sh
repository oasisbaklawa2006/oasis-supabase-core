#!/usr/bin/env bash
# End-to-end composition contract: proves that
# scripts/resolve-core-merge-governance-context.sh's output correctly drives
# scripts/rerun-failed-core-merge-governance.sh exactly the way
# .github/workflows/core-merge-governance.yml wires them together
# (`trigger-rerun-on-dependency-completion` only invokes the rerun script
# when `steps.ctx.outputs.relevant == 'true'`, passing its `head_sha`
# straight through as HEAD_SHA).
#
# The two scripts already have their own unit regression suites
# (verify-core-merge-governance-context-resolution.sh,
# verify-rerun-failed-core-merge-governance.sh); this suite exists to prove
# they compose correctly, not to re-prove either one in isolation.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
resolve_script="$repo_root/scripts/resolve-core-merge-governance-context.sh"
rerun_script="$repo_root/scripts/rerun-failed-core-merge-governance.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

fail() {
  echo "CORE MERGE GOVERNANCE WORKFLOW_RUN END-TO-END REGRESSION: $*" >&2
  exit 1
}

# $1: python case body deciding the PR-lookup response per requested PR number (var: num)
# $2: JSON fixture for the runs-lookup response (rerun script's GET)
# $3: capture file path for a rerun POST (created only if one happens)
mock_curl() {
  local pr_lookup_case="$1" runs_fixture="$2" capture_file="$3"
  cat >"$tmp/bin/curl" <<CURL
#!/usr/bin/env bash
set -euo pipefail
is_post=false
url=""
prev=""
for arg in "\$@"; do
  if [[ "\$prev" == "-X" && "\$arg" == "POST" ]]; then
    is_post=true
  fi
  url="\$arg"
  prev="\$arg"
done

if [[ "\$is_post" == "true" ]]; then
  echo "\$url" > "$capture_file"
  exit 0
fi

if [[ "\$url" == *"/pulls/"* ]]; then
  num="\${url##*/pulls/}"
  $pr_lookup_case
  exit 0
fi

if [[ "\$url" == *"/actions/workflows/"*"/runs"* ]]; then
  cat <<'JSON'
$runs_fixture
JSON
  exit 0
fi

echo "mock_curl: unhandled URL: \$url" >&2
exit 1
CURL
  chmod +x "$tmp/bin/curl"
}

# Runs the orchestration exactly as the workflow YAML does: resolve context,
# then invoke the rerun script only if, and with the exact head_sha, that
# context resolution reported as relevant.
compose() {
  local ctx_out="$tmp/ctx.env"
  local resolve_status=0
  : >"$ctx_out"
  PATH="$tmp/bin:$PATH" GITHUB_OUTPUT="$ctx_out" \
    EVENT_NAME=workflow_run \
    WORKFLOW_RUN_NAME="${WORKFLOW_RUN_NAME:-Edge Function Governance}" \
    WORKFLOW_RUN_HEAD_SHA="${WORKFLOW_RUN_HEAD_SHA:-deadbeef}" \
    WORKFLOW_RUN_PR_NUMBERS="${WORKFLOW_RUN_PR_NUMBERS:-399}" \
    GH_TOKEN="${RESOLVE_GH_TOKEN-${GH_TOKEN:-test-token}}" \
    GITHUB_REPOSITORY=oasisbaklawa2006/oasis-supabase-core \
    bash "$resolve_script" || resolve_status=$?

  if [[ "$resolve_status" -ne 0 ]]; then
    echo "resolve-context failed closed (exit $resolve_status); rerun script correctly not invoked."
    return 10
  fi

  relevant="$(grep -E '^relevant=' "$ctx_out" | tail -n1 | cut -d= -f2-)"
  head_sha="$(grep -E '^head_sha=' "$ctx_out" | tail -n1 | cut -d= -f2-)"

  if [[ "$relevant" != "true" ]]; then
    echo "context resolution reported relevant=false; rerun script correctly not invoked."
    return 20
  fi

  PATH="$tmp/bin:$PATH" HEAD_SHA="$head_sha" GH_TOKEN="${RERUN_GH_TOKEN:-test-token}" \
    GITHUB_REPOSITORY=oasisbaklawa2006/oasis-supabase-core \
    bash "$rerun_script"
}

# 1. Success: live PR head matches, a failed run below the attempt cap exists
#    -> rerun script is invoked with the context's own head_sha and triggers
#    exactly one rerun POST against the correct run id.
mock_curl 'case "$num" in
  399) printf "%s" "{\"state\":\"open\",\"head\":{\"sha\":\"deadbeef\"},\"base\":{\"ref\":\"main\"}}" ;;
  *) printf "%s" "{}" ;;
esac' '{"workflow_runs": [
  {"id": 111, "conclusion": "failure", "run_attempt": 1, "created_at": "2026-01-01T00:00:01Z"}
]}' "$tmp/post-success.txt"
compose >"$tmp/out-success.txt" || fail 'success scenario must not fail'
[[ -f "$tmp/post-success.txt" ]] || fail 'success scenario must trigger a rerun POST'
grep -Fq '/actions/runs/111/rerun-failed-jobs' "$tmp/post-success.txt" \
  || fail 'success scenario must target the correct run id, using the head_sha the context resolved'
grep -Fq 'Re-running failed jobs for run 111' "$tmp/out-success.txt" \
  || fail 'success scenario must report the rerun it performed'

# 2. Failure (no failed run to re-run, e.g. the dependency is still mid-flight
#    or the original run already succeeded): relevant=true, but the rerun
#    script correctly no-ops -- no POST.
mock_curl 'case "$num" in
  399) printf "%s" "{\"state\":\"open\",\"head\":{\"sha\":\"deadbeef\"},\"base\":{\"ref\":\"main\"}}" ;;
  *) printf "%s" "{}" ;;
esac' '{"workflow_runs": [
  {"id": 222, "conclusion": "success", "run_attempt": 1, "created_at": "2026-01-01T00:00:01Z"}
]}' "$tmp/post-no-failure.txt"
compose >"$tmp/out-no-failure.txt" || fail 'no-failed-run scenario must exit 0, not fail'
[[ ! -f "$tmp/post-no-failure.txt" ]] || fail 'no genuinely failed run must never trigger a rerun POST'
grep -Fq 'nothing to re-run' "$tmp/out-no-failure.txt" || fail 'must report there was nothing to re-run'

# 3. Stale head: the PR's live head has moved on since the workflow_run event
#    was queued (new push during the approval wait) -> context resolution
#    must report relevant=false, and the rerun script must never be invoked
#    at all (proven by it never consuming the mock's runs-lookup fixture --
#    if it were, status would be 0, not the compose() sentinel 20).
mock_curl 'printf "%s" "{\"state\":\"open\",\"head\":{\"sha\":\"NEWSHA-AFTER-PUSH\"},\"base\":{\"ref\":\"main\"}}"' \
  '{"workflow_runs": [{"id": 999, "conclusion": "failure", "run_attempt": 1, "created_at": "2026-01-01T00:00:01Z"}]}' \
  "$tmp/post-stale.txt"
status=0
compose >"$tmp/out-stale.txt" || status=$?
[[ "$status" -eq 20 ]] || fail 'stale head must resolve to relevant=false (rerun script must not run)'
[[ ! -f "$tmp/post-stale.txt" ]] || fail 'stale head must never trigger a rerun POST'

# 4. Wrong PR: the PR number carried by the event resolves to a real, open PR,
#    but targeting a different base branch than this governance workflow
#    protects -- must not be treated as relevant, and must not leak into a
#    rerun of some unrelated PR's check.
WORKFLOW_RUN_PR_NUMBERS=777 \
  mock_curl 'case "$num" in
  777) printf "%s" "{\"state\":\"open\",\"head\":{\"sha\":\"deadbeef\"},\"base\":{\"ref\":\"develop\"}}" ;;
  *) printf "%s" "{}" ;;
esac' '{"workflow_runs": [{"id": 888, "conclusion": "failure", "run_attempt": 1, "created_at": "2026-01-01T00:00:01Z"}]}' \
  "$tmp/post-wrong-pr.txt"
status=0
WORKFLOW_RUN_PR_NUMBERS=777 compose >"$tmp/out-wrong-pr.txt" || status=$?
[[ "$status" -eq 20 ]] || fail 'wrong-base-branch PR must resolve to relevant=false'
[[ ! -f "$tmp/post-wrong-pr.txt" ]] || fail 'wrong-base-branch PR must never trigger a rerun POST'

# 5. Missing token: context resolution itself requires GH_TOKEN to resolve a
#    workflow_run-triggered PR context and must fail closed (hard error) --
#    the rerun script must never be reached, let alone run with no token.
unset GH_TOKEN GITHUB_TOKEN || true
mock_curl 'printf "%s" "{\"state\":\"open\",\"head\":{\"sha\":\"deadbeef\"},\"base\":{\"ref\":\"main\"}}"' \
  '{"workflow_runs": [{"id": 1010, "conclusion": "failure", "run_attempt": 1, "created_at": "2026-01-01T00:00:01Z"}]}' \
  "$tmp/post-no-token.txt"
status=0
RESOLVE_GH_TOKEN="" compose >"$tmp/out-no-token.txt" 2>"$tmp/err-no-token.txt" || status=$?
[[ "$status" -eq 10 ]] || fail 'missing GH_TOKEN must fail closed at context resolution, not proceed'
[[ ! -f "$tmp/post-no-token.txt" ]] || fail 'missing GH_TOKEN must never reach the rerun script'
grep -Fq 'GH_TOKEN is required' "$tmp/err-no-token.txt" \
  || fail 'missing GH_TOKEN must report its specific cause'

# 6. Duplicate-rerun protection: a second workflow_run completion for the
#    same PR head arrives after the first rerun already made the original
#    run succeed (or after it hit the attempt cap) -- the second composed
#    pass must not trigger a second POST.
# 6a. Already succeeded on a later attempt after the first rerun. The GitHub
#     Actions runs API reports one entry per run id, carrying its *latest*
#     attempt's conclusion/run_attempt -- it does not keep the superseded
#     attempt as a separate list entry, so the fixture models that as a
#     single entry whose conclusion already flipped to success.
mock_curl 'case "$num" in
  399) printf "%s" "{\"state\":\"open\",\"head\":{\"sha\":\"deadbeef\"},\"base\":{\"ref\":\"main\"}}" ;;
  *) printf "%s" "{}" ;;
esac' '{"workflow_runs": [
  {"id": 111, "conclusion": "success", "run_attempt": 2, "created_at": "2026-01-01T00:05:00Z"}
]}' "$tmp/post-dup-succeeded.txt"
compose >"$tmp/out-dup-succeeded.txt" || fail 'post-rerun-success duplicate pass must exit 0'
[[ ! -f "$tmp/post-dup-succeeded.txt" ]] || fail 'a run that already succeeded on rerun must not be re-run again'
grep -Fq 'nothing to re-run' "$tmp/out-dup-succeeded.txt" \
  || fail 'must report nothing to re-run once the most recent attempt succeeded'

# 6b. Still failing, but already at the attempt cap -- must not rerun forever.
mock_curl 'case "$num" in
  399) printf "%s" "{\"state\":\"open\",\"head\":{\"sha\":\"deadbeef\"},\"base\":{\"ref\":\"main\"}}" ;;
  *) printf "%s" "{}" ;;
esac' '{"workflow_runs": [
  {"id": 111, "conclusion": "failure", "run_attempt": 5, "created_at": "2026-01-01T00:10:00Z"}
]}' "$tmp/post-dup-capped.txt"
compose >"$tmp/out-dup-capped.txt" || fail 'attempt-capped duplicate pass must exit 0, not fail'
[[ ! -f "$tmp/post-dup-capped.txt" ]] || fail 'a run already at the attempt cap must not be re-run again'
grep -Fq 'already at attempt 5' "$tmp/out-dup-capped.txt" \
  || fail 'must explain why a capped run was not re-run'

echo "Core Merge Governance workflow_run end-to-end composition verified."
