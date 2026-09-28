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

LAUNCH_RELEVANT_CHECKS=(
  "Static Edge Function governance"
  "Preview Edge Runtime readiness"
  "Provision encrypted preview Edge Runtime env"
  "Clean database replay and pgTAP contracts"
  "verification-primitives"
)

write_json() {
  local path="$1"
  shift
  python3 - "$path" "$@" <<'PY'
import json
import sys

path = sys.argv[1]
runs = []
for spec in sys.argv[2:]:
    check_id, name, conclusion = spec.split("|", 2)
    run = {
        "id": int(check_id),
        "name": name,
        "conclusion": None if conclusion == "__NULL__" else conclusion,
    }
    if conclusion == "__EMPTY__":
        run.pop("conclusion", None)
    runs.append(run)

with open(path, "w", encoding="utf-8") as handle:
    json.dump({"check_runs": runs}, handle)
PY
}

run_checker() {
  local payload="$1"
  local force_checks="${2:-Clean database replay and pgTAP contracts}"
  MOCK_CHECK_RUNS_JSON="$payload" \
  PATH="$tmp/bin:$PATH" \
  GH_TOKEN="test-token" \
  GITHUB_REPOSITORY="oasisbaklawa2006/oasis-supabase-core" \
  GITHUB_PR_HEAD_SHA="$(git rev-parse HEAD)" \
  GITHUB_BASE_REF="main" \
  PR_LAUNCH_CHECK_WAIT_ATTEMPTS=1 \
  PR_LAUNCH_CHECK_WAIT_SECONDS=0 \
  PR_LAUNCH_FORCE_REQUIRED_CHECKS="$force_checks" \
  bash "$checker"
}

expect_success() {
  local label="$1"
  local payload="$2"
  local force_checks="${3:-Clean database replay and pgTAP contracts}"
  run_checker "$payload" "$force_checks" >"$tmp/out" 2>"$tmp/err" || {
    cat "$tmp/out" "$tmp/err" >&2
    echo "launch-check selector regression (${label}): expected success" >&2
    exit 1
  }
  grep -Fq "Launch-relevant PR head checks satisfied" "$tmp/out" || {
    cat "$tmp/out" "$tmp/err" >&2
    echo "launch-check selector regression (${label}): success confirmation missing" >&2
    exit 1
  }
}

expect_failure() {
  local label="$1"
  local payload="$2"
  local needle="$3"
  local force_checks="${4:-Clean database replay and pgTAP contracts}"
  if run_checker "$payload" "$force_checks" >"$tmp/out" 2>"$tmp/err"; then
    cat "$tmp/out" "$tmp/err" >&2
    echo "launch-check selector regression (${label}): expected failure" >&2
    exit 1
  fi
  grep -Fq "$needle" "$tmp/err" || {
    cat "$tmp/out" "$tmp/err" >&2
    echo "launch-check selector regression (${label}): expected error missing: ${needle}" >&2
    exit 1
  }
}

check_name="Clean database replay and pgTAP contracts"

# 1. single required success
write_json "$tmp/single-success.json" "500|${check_name}|success"
expect_success "single required success" "$tmp/single-success.json"

# 2. missing required check
write_json "$tmp/missing-check.json" "500|Unrelated check 0|success"
expect_failure \
  "missing required check" \
  "$tmp/missing-check.json" \
  "required check-runs still pending on PR head after timeout: ${check_name}"

# 3. older success + newer failure
write_json "$tmp/newer-failure.json" \
  "100|${check_name}|success" \
  "300|${check_name}|failure"
expect_failure \
  "older success + newer failure" \
  "$tmp/newer-failure.json" \
  "required check-run ${check_name} concluded failure; success required"

# 4. older failure + newer success
write_json "$tmp/newer-success-after-failure.json" \
  "100|${check_name}|failure" \
  "300|${check_name}|success"
expect_success "older failure + newer success" "$tmp/newer-success-after-failure.json"

# 5. older cancelled + newer success
write_json "$tmp/newer-success-after-cancelled.json" \
  "100|${check_name}|cancelled" \
  "200|${check_name}|success"
expect_success "older cancelled + newer success" "$tmp/newer-success-after-cancelled.json"

# 6. older success + newer cancelled
write_json "$tmp/newer-cancelled-after-success.json" \
  "100|${check_name}|success" \
  "200|${check_name}|cancelled"
expect_failure \
  "older success + newer cancelled" \
  "$tmp/newer-cancelled-after-success.json" \
  "required check-run ${check_name} concluded cancelled; success required"

# 7. duplicate successes
write_json "$tmp/duplicate-success.json" \
  "100|${check_name}|success" \
  "500|${check_name}|success"
expect_success "duplicate successes" "$tmp/duplicate-success.json"

# 8. duplicate failures
write_json "$tmp/duplicate-failure.json" \
  "100|${check_name}|failure" \
  "500|${check_name}|failure"
expect_failure \
  "duplicate failures" \
  "$tmp/duplicate-failure.json" \
  "required check-run ${check_name} concluded failure; success required"

# 9. shuffled GitHub API result ordering
write_json "$tmp/shuffled-success.json" \
  "200|${check_name}|success" \
  "100|${check_name}|cancelled"
expect_success "shuffled success ordering" "$tmp/shuffled-success.json"
write_json "$tmp/shuffled-failure.json" \
  "300|${check_name}|failure" \
  "100|${check_name}|success"
expect_failure \
  "shuffled failure ordering" \
  "$tmp/shuffled-failure.json" \
  "required check-run ${check_name} concluded failure; success required"

# 10/11. head SHA scoping is enforced by the commits/{head_sha}/check-runs endpoint.
# Verify the checker queries the current PR head SHA rather than silently accepting
# a fixture scoped to another commit.
head_sha="$(git rev-parse HEAD)"
cat > "$tmp/bin/curl" <<CURL
#!/usr/bin/env bash
set -euo pipefail
url="\${@: -1}"
if [[ "\$url" != *"/commits/${head_sha}/check-runs"* ]]; then
  echo "PR LAUNCH-RELEVANT CHECK FAILURE: check-run lookup must target current PR head SHA" >&2
  exit 1
fi
cat "\${MOCK_CHECK_RUNS_JSON:?}"
CURL
chmod +x "$tmp/bin/curl"
MOCK_CHECK_RUNS_JSON="$tmp/single-success.json" \
PATH="$tmp/bin:$PATH" \
GH_TOKEN="test-token" \
GITHUB_REPOSITORY="oasisbaklawa2006/oasis-supabase-core" \
GITHUB_PR_HEAD_SHA="$head_sha" \
GITHUB_BASE_REF="main" \
PR_LAUNCH_CHECK_WAIT_ATTEMPTS=1 \
PR_LAUNCH_CHECK_WAIT_SECONDS=0 \
PR_LAUNCH_FORCE_REQUIRED_CHECKS="$check_name" \
bash "$checker" >"$tmp/head-audit.out" 2>"$tmp/head-audit.err" || {
  cat "$tmp/head-audit.out" "$tmp/head-audit.err" >&2
  echo "launch-check selector regression (head SHA scoping): checker did not target current head" >&2
  exit 1
}

cat > "$tmp/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
cat "${MOCK_CHECK_RUNS_JSON:?}"
CURL
chmod +x "$tmp/bin/curl"

# 12. unrelated similarly named checks must not satisfy the required check
write_json "$tmp/similar-name-collision.json" \
  "500|Clean database replay and pgTAP contracts extra|success"
expect_failure \
  "similarly named unrelated check" \
  "$tmp/similar-name-collision.json" \
  "required check-runs still pending on PR head after timeout: ${check_name}"

# 13. malformed check-run payload
cat > "$tmp/malformed.json" <<'JSON'
{"check_runs": [{"id": "not-a-number", "name": "Clean database replay and pgTAP contracts", "conclusion": "success"}]}
JSON
expect_failure \
  "malformed check-run payload" \
  "$tmp/malformed.json" \
  "required check-runs still pending on PR head after timeout: ${check_name}"

# 14. null/missing conclusion
write_json "$tmp/null-conclusion.json" "500|${check_name}|__NULL__"
expect_failure \
  "null conclusion" \
  "$tmp/null-conclusion.json" \
  "required check-runs still pending on PR head after timeout: ${check_name}"
write_json "$tmp/missing-conclusion.json" "500|${check_name}|__EMPTY__"
expect_failure \
  "missing conclusion field" \
  "$tmp/missing-conclusion.json" \
  "required check-runs still pending on PR head after timeout: ${check_name}"

# 15. in-progress required check (treated as pending)
write_json "$tmp/in-progress.json" "500|${check_name}|"
expect_failure \
  "in-progress required check" \
  "$tmp/in-progress.json" \
  "required check-runs still pending on PR head after timeout: ${check_name}"

# 16. skipped required check where success is required
write_json "$tmp/skipped-required.json" "500|${check_name}|skipped"
expect_failure \
  "skipped required check" \
  "$tmp/skipped-required.json" \
  "required check-run ${check_name} concluded skipped; success required"

# Provision encrypted preview Edge Runtime env may legitimately conclude skipped.
preview_env_check="Provision encrypted preview Edge Runtime env"
write_json "$tmp/preview-env-skipped-allowed.json" "500|${preview_env_check}|skipped"
expect_success \
  "preview env skipped allowed" \
  "$tmp/preview-env-skipped-allowed.json" \
  "$preview_env_check"

# Large payload transport regression (pagination-safe parsing).
python3 - "$tmp/large-success.json" <<'PY'
import json
import sys

path = sys.argv[1]
runs = []
for idx in range(98):
    runs.append(
        {
            "id": idx + 1,
            "name": f"Unrelated check {idx}",
            "conclusion": "success",
            "output": {"text": "x" * 5000},
        }
    )
runs.append(
    {
        "id": 1000,
        "name": "Clean database replay and pgTAP contracts",
        "conclusion": "success",
        "output": {"text": "x" * 5000},
    }
)
with open(path, "w", encoding="utf-8") as handle:
    json.dump({"check_runs": runs}, handle)
PY
expect_success "large check-run payload" "$tmp/large-success.json"

# 17. every launch-relevant required check represented by the governance contract
for launch_check in "${LAUNCH_RELEVANT_CHECKS[@]}"; do
  write_json "$tmp/launch-check-${launch_check// /-}.json" "700|${launch_check}|success"
  expect_success "launch check ${launch_check}" "$tmp/launch-check-${launch_check// /-}.json" "$launch_check"
done

echo "Launch-relevant duplicate check-run selection verified."
