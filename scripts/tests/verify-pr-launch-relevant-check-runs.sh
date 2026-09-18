#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
checker="$repo_root/scripts/check-pr-launch-relevant-check-runs.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat > "$tmp/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
cat "${MOCK_CHECK_RUNS_JSON:?}"
CURL
chmod +x "$tmp/bin/curl"

run_checker() {
  local payload="$1"
  MOCK_CHECK_RUNS_JSON="$payload" \
  PATH="$tmp/bin:$PATH" \
  GH_TOKEN="test-token" \
  GITHUB_REPOSITORY="oasisbaklawa2006/oasis-supabase-core" \
  GITHUB_PR_HEAD_SHA="$(git rev-parse HEAD)" \
  GITHUB_BASE_REF="main" \
  PR_LAUNCH_CHECK_WAIT_ATTEMPTS=1 \
  PR_LAUNCH_CHECK_WAIT_SECONDS=0 \
  PR_LAUNCH_FORCE_REQUIRED_CHECKS="Clean database replay and pgTAP contracts" \
  bash "$checker"
}

cat > "$tmp/newer-success.json" <<'JSON'
{
  "check_runs": [
    {
      "id": 200,
      "name": "Clean database replay and pgTAP contracts",
      "conclusion": "success"
    },
    {
      "id": 100,
      "name": "Clean database replay and pgTAP contracts",
      "conclusion": "cancelled"
    }
  ]
}
JSON

run_checker "$tmp/newer-success.json" >"$tmp/success.out" 2>"$tmp/success.err" || {
  cat "$tmp/success.out" "$tmp/success.err" >&2
  echo "launch-check selector regression: older cancelled run overrode newer success" >&2
  exit 1
}
grep -Fq "Launch-relevant PR head checks satisfied" "$tmp/success.out" || {
  cat "$tmp/success.out" "$tmp/success.err" >&2
  echo "launch-check selector regression: expected success confirmation missing" >&2
  exit 1
}

cat > "$tmp/newer-failure.json" <<'JSON'
{
  "check_runs": [
    {
      "id": 100,
      "name": "Clean database replay and pgTAP contracts",
      "conclusion": "success"
    },
    {
      "id": 300,
      "name": "Clean database replay and pgTAP contracts",
      "conclusion": "failure"
    }
  ]
}
JSON

if run_checker "$tmp/newer-failure.json" >"$tmp/failure.out" 2>"$tmp/failure.err"; then
  cat "$tmp/failure.out" "$tmp/failure.err" >&2
  echo "launch-check selector regression: newer failure was incorrectly ignored" >&2
  exit 1
fi
grep -Fq "concluded failure; success required" "$tmp/failure.err" || {
  cat "$tmp/failure.out" "$tmp/failure.err" >&2
  echo "launch-check selector regression: expected fail-closed error missing" >&2
  exit 1
}

echo "Launch-relevant duplicate check-run selection verified."
