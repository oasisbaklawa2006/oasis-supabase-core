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
  bash "$checker"
}

cat > "$tmp/newer-success.json" <<'JSON'
{
  "check_runs": [
    {
      "id": 200,
      "name": "Static Edge Function governance",
      "conclusion": "success"
    },
    {
      "id": 100,
      "name": "Static Edge Function governance",
      "conclusion": "cancelled"
    },
    {
      "id": 201,
      "name": "Preview Edge Runtime readiness",
      "conclusion": "success"
    },
    {
      "id": 101,
      "name": "Preview Edge Runtime readiness",
      "conclusion": "cancelled"
    },
    {
      "id": 202,
      "name": "Provision encrypted preview Edge Runtime env",
      "conclusion": "success"
    },
    {
      "id": 102,
      "name": "Provision encrypted preview Edge Runtime env",
      "conclusion": "cancelled"
    },
    {
      "id": 203,
      "name": "Clean database replay and pgTAP contracts",
      "conclusion": "success"
    },
    {
      "id": 103,
      "name": "Clean database replay and pgTAP contracts",
      "conclusion": "cancelled"
    },
    {
      "id": 204,
      "name": "verification-primitives",
      "conclusion": "success"
    },
    {
      "id": 104,
      "name": "verification-primitives",
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

run_checker "$tmp/large-success.json" >"$tmp/large-success.out" 2>"$tmp/large-success.err" || {
  cat "$tmp/large-success.out" "$tmp/large-success.err" >&2
  echo "launch-check selector regression: large check-run payload exceeded transport limits" >&2
  exit 1
}
grep -Fq "Launch-relevant PR head checks satisfied" "$tmp/large-success.out" || {
  cat "$tmp/large-success.out" "$tmp/large-success.err" >&2
  echo "launch-check selector regression: large payload success confirmation missing" >&2
  exit 1
}

cat > "$tmp/newer-failure.json" <<'JSON'
{
  "check_runs": [
    {
      "id": 100,
      "name": "Static Edge Function governance",
      "conclusion": "success"
    },
    {
      "id": 300,
      "name": "Static Edge Function governance",
      "conclusion": "failure"
    },
    {
      "id": 101,
      "name": "Preview Edge Runtime readiness",
      "conclusion": "success"
    },
    {
      "id": 301,
      "name": "Preview Edge Runtime readiness",
      "conclusion": "failure"
    },
    {
      "id": 102,
      "name": "Provision encrypted preview Edge Runtime env",
      "conclusion": "success"
    },
    {
      "id": 302,
      "name": "Provision encrypted preview Edge Runtime env",
      "conclusion": "failure"
    },
    {
      "id": 103,
      "name": "Clean database replay and pgTAP contracts",
      "conclusion": "success"
    },
    {
      "id": 303,
      "name": "Clean database replay and pgTAP contracts",
      "conclusion": "failure"
    },
    {
      "id": 104,
      "name": "verification-primitives",
      "conclusion": "success"
    },
    {
      "id": 304,
      "name": "verification-primitives",
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
