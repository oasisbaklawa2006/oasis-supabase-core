#!/usr/bin/env bash
# Regression test for the WA-100 admin-draft workflow trigger/environment boundary.
#
# Positive: the protected cutover is manual-dispatch only and still binds its protected
# production environments with the independent-approval gates; the pull-request contract is
# credential-free, binds no environment and carries the same contract job.
# Negative: re-introducing a pull-request trigger on the protected workflow, or an
# environment/secret/privileged trigger on the PR contract, is rejected by the REAL guard
# (scripts/check-preview-edge-runtime-secrets-config.sh), which this test never weakens.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

protected=".github/workflows/wa100-admin-draft-protected-cutover.yml"
contract=".github/workflows/wa100-admin-draft-pr-contract.yml"
guard="scripts/check-preview-edge-runtime-secrets-config.sh"

fail() {
  echo "WA-100 WORKFLOW BOUNDARY TEST FAILURE: $*" >&2
  exit 1
}

job_block() { # file job
  awk -v job="  $2:" '$0 == job {on = 1; print; next} on && /^  [A-Za-z0-9_-]+:/ {exit} on {print}' "$1"
}

trigger_block() { # file -> lines between top-level "on:" and the next top-level key
  awk '/^on:/ {on = 1; next} on && /^[^[:space:]#]/ {exit} on {print}' "$1"
}

# ---------------------------------------------------------------------------
# Positive contract
# ---------------------------------------------------------------------------
[[ -f "$protected" && -f "$contract" ]] || fail "both workflow files must exist"

triggers="$(trigger_block "$protected" | grep -E '^  [A-Za-z_]+:' | sed 's/[[:space:]]*:.*//; s/^[[:space:]]*//' | sort -u | tr '\n' ' ')"
[[ "$triggers" == "workflow_dispatch " ]] \
  || fail "protected cutover must be reachable only by workflow_dispatch (found: ${triggers:-none})"

grep -Eq '^    environment:[[:space:]]*supabase-production-readonly[[:space:]]*$' <<<"$(job_block "$protected" preflight)" \
  || fail "preflight must stay bound to supabase-production-readonly"
grep -Eq '^    environment:[[:space:]]*supabase-production[[:space:]]*$' <<<"$(job_block "$protected" deploy)" \
  || fail "deploy must stay bound to the protected supabase-production environment"
grep -Fq "if: github.event_name == 'workflow_dispatch' && inputs.deploy == true && inputs.central_caller_certified == true && inputs.rollback_approved == true" <<<"$(job_block "$protected" deploy)" \
  || fail "deploy must keep its explicit approval conditions"
grep -Fq "if: github.event_name == 'workflow_dispatch'" <<<"$(job_block "$protected" preflight)" \
  || fail "preflight must stay dispatch-gated"
grep -Fq 'needs: preflight' <<<"$(job_block "$protected" deploy)" || fail "deploy must depend on preflight"
grep -Fq 'needs: contract' <<<"$(job_block "$protected" preflight)" || fail "preflight must depend on the contract job"

contract_triggers="$(trigger_block "$contract" | grep -E '^  [A-Za-z_]+:' | sed 's/[[:space:]]*:.*//; s/^[[:space:]]*//' | sort -u | tr '\n' ' ')"
[[ "$contract_triggers" == "pull_request " ]] || fail "PR contract must trigger only on pull_request (found: ${contract_triggers:-none})"

if grep -Eq '^[[:space:]]+environment:|secrets[.]|^[[:space:]]+workflow_run:|^[[:space:]]+pull_request_target:|workflow_call' "$contract"; then
  fail "PR contract must bind no environment, read no secret and use no privileged trigger"
fi
grep -Eq '^[[:space:]]+contents:[[:space:]]*read[[:space:]]*$' <<<"$(awk '/^permissions:/{f=1;next} f&&/^[^[:space:]]/{exit} f{print}' "$contract")" \
  || fail "PR contract must grant contents: read only"

# Drift guard: the PR contract must run exactly the contract job the protected release requires.
[[ "$(job_block "$protected" contract)" == "$(job_block "$contract" contract)" ]] \
  || fail "contract job differs between the PR contract and the protected cutover"

bash "$guard" >/dev/null || fail "the real guard must pass on the repaired tree"
echo "positive contract: ok"

# ---------------------------------------------------------------------------
# Negative contract: mutate a throw-away copy of the tree and run the REAL guard
# ---------------------------------------------------------------------------
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fresh_copy() {
  local dir="$work/$1"
  mkdir -p "$dir"
  git ls-files --cached --others --exclude-standard -z | tar --null -T - -cf - | tar -xf - -C "$dir"
  git -C "$dir" init -q
  echo "$dir"
}

expect_guard_rejects() { # name mutation-command pattern
  local dir out
  dir="$(fresh_copy "$1")"
  (cd "$dir" && eval "$2")
  if out="$(cd "$dir" && bash "$guard" 2>&1)"; then
    fail "guard accepted mutation: $1"
  fi
  grep -Fq "$3" <<<"$out" || fail "guard rejected '$1' for the wrong reason: $out"
  echo "negative contract rejected: $1"
}

expect_guard_rejects \
  "pull-request trigger on the protected cutover" \
  "python3 - <<'PY'
p='$protected'
s=open(p).read()
s=s.replace('on:\n  workflow_dispatch:','on:\n  pull_request:\n    branches: [main]\n  workflow_dispatch:',1)
open(p,'w').write(s)
PY" \
  "must not bind a GitHub environment"

expect_guard_rejects \
  "environment on the PR contract" \
  "sed -i 's/^    runs-on: ubuntu-24.04\$/    runs-on: ubuntu-24.04\n    environment: supabase-production-readonly/' $contract" \
  "must not bind a GitHub environment"

expect_guard_rejects \
  "privileged secret on the PR contract" \
  "sed -i 's/^  FUNCTION_NAME: admin-create-draft\$/  FUNCTION_NAME: admin-create-draft\n  X: \${{ secrets.SUPABASE_ACCESS_TOKEN }}/' $contract" \
  "privileged secret"

expect_guard_rejects \
  "untrusted-code trigger on the PR contract" \
  "sed -i 's/^  pull_request:\$/  pull_request_target:/' $contract" \
  "must not use pull_request_target"

echo "WA-100 admin draft workflow boundary regression verified."
