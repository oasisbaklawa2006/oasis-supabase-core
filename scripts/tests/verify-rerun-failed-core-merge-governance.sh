#!/usr/bin/env bash
# Regression contract for scripts/rerun-failed-core-merge-governance.sh.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
script="$repo_root/scripts/rerun-failed-core-merge-governance.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

fail() {
  echo "RERUN FAILED CORE MERGE GOVERNANCE REGRESSION: $*" >&2
  exit 1
}

# $1: JSON fixture for the GET .../runs lookup response
# $2: path to a file capturing whether (and to which run id) a rerun POST happened
mock_curl() {
  local list_fixture="$1" capture_file="$2"
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
cat <<'JSON'
$list_fixture
JSON
CURL
  chmod +x "$tmp/bin/curl"
}

run() {
  PATH="$tmp/bin:$PATH" HEAD_SHA=deadbeef GH_TOKEN=t GITHUB_REPOSITORY=o/r bash "$script"
}

# 1. Missing required inputs fail closed.
if HEAD_SHA="" GH_TOKEN=t GITHUB_REPOSITORY=o/r bash "$script" >/dev/null 2>"$tmp/err1"; then
  fail 'missing HEAD_SHA must fail'
fi
grep -Fq 'HEAD_SHA is required' "$tmp/err1" || fail 'missing HEAD_SHA must report its cause'

unset GH_TOKEN GITHUB_TOKEN || true
if HEAD_SHA=deadbeef GITHUB_REPOSITORY=o/r bash "$script" >/dev/null 2>"$tmp/err2"; then
  fail 'missing GH_TOKEN must fail'
fi
grep -Fq 'GH_TOKEN is required' "$tmp/err2" || fail 'missing GH_TOKEN must report its cause'

# 2. No matching failed run: no-op, exits 0, no POST made.
mock_curl '{"workflow_runs": []}' "$tmp/post1.txt"
run >"$tmp/out1.txt"
[[ ! -f "$tmp/post1.txt" ]] || fail 'no failed run found must not trigger a rerun POST'
grep -Fq 'nothing to re-run' "$tmp/out1.txt" || fail 'no failed run found must say so'

# 3. A matching failed run below the attempt cap triggers exactly one rerun POST for its id.
mock_curl '{"workflow_runs": [
  {"id": 555, "conclusion": "success", "run_attempt": 1, "created_at": "2026-01-01T00:00:02Z"},
  {"id": 111, "conclusion": "failure", "run_attempt": 1, "created_at": "2026-01-01T00:00:01Z"}
]}' "$tmp/post2.txt"
run >"$tmp/out2.txt"
[[ -f "$tmp/post2.txt" ]] || fail 'a failed run below the cap must trigger a rerun POST'
grep -Fq '/actions/runs/111/rerun-failed-jobs' "$tmp/post2.txt" \
  || fail 'rerun must target the failed run id, not the successful one'
grep -Fq 'Re-running failed jobs for run 111' "$tmp/out2.txt" || fail 'must report the run it re-ran'

# 4. Multiple runs: the most recently created failed run is selected, not just any failed run.
mock_curl '{"workflow_runs": [
  {"id": 222, "conclusion": "failure", "run_attempt": 1, "created_at": "2026-01-01T00:00:01Z"},
  {"id": 333, "conclusion": "failure", "run_attempt": 1, "created_at": "2026-01-01T00:00:05Z"}
]}' "$tmp/post3.txt"
run >"$tmp/out3.txt"
grep -Fq '/actions/runs/333/rerun-failed-jobs' "$tmp/post3.txt" \
  || fail 'must select the most recently created failed run'

# 5. A run already at/above the attempt cap is not re-run again.
mock_curl '{"workflow_runs": [
  {"id": 444, "conclusion": "failure", "run_attempt": 3, "created_at": "2026-01-01T00:00:01Z"}
]}' "$tmp/post4.txt"
PATH="$tmp/bin:$PATH" HEAD_SHA=deadbeef GH_TOKEN=t GITHUB_REPOSITORY=o/r MAX_RUN_ATTEMPT=3 \
  bash "$script" >"$tmp/out4.txt"
[[ ! -f "$tmp/post4.txt" ]] || fail 'a run at the attempt cap must not be re-run again'
grep -Fq 'already at attempt 3' "$tmp/out4.txt" || fail 'must explain why it declined to re-run'

echo "Rerun failed Core Merge Governance regression verified."
