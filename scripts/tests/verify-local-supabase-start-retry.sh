#!/usr/bin/env bash
# Regression test for scripts/lib/local-supabase-start.sh.
# Uses a fake `supabase` and a fake `sleep` on PATH; it never starts Docker or pauses.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
helper="$repo_root/scripts/lib/local-supabase-start.sh"
[[ -f "$helper" ]] || { echo "missing helper: $helper" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

# Fake supabase: `start` consumes one outcome per call from $FAKE_PLAN
# (ok | throttle | port | other); once the plan is empty it repeats the last outcome.
cat >"$work/bin/supabase" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  start)
    echo start >>"$FAKE_DIR/calls"
    n="$(grep -c '^start$' "$FAKE_DIR/calls")"
    if (( n > 20 )); then touch "$FAKE_DIR/runaway"; kill -KILL "$PPID" 2>/dev/null || true; exit 125; fi
    read -r -a plan <<<"$FAKE_PLAN"
    idx=$((n - 1)); (( idx < ${#plan[@]} )) || idx=$((${#plan[@]} - 1))
    case "${plan[$idx]}" in
      ok) echo "Started supabase local development setup."; exit 0 ;;
      throttle) echo "error pulling image configuration: toomanyrequests: retry-after: 419.437µs, allowed: 44000/minute"; exit 1 ;;
      port) echo "failed to bind host port 0.0.0.0:54322"; exit 1 ;;
      other) echo "ERROR: migration 20261022130000 failed"; exit 1 ;;
    esac ;;
  stop) echo stop >>"$FAKE_DIR/calls"; exit 0 ;;
esac
FAKE
cat >"$work/bin/sleep" <<'FAKE'
#!/usr/bin/env bash
echo "$1" >>"$FAKE_DIR/sleeps"
FAKE
chmod +x "$work/bin/supabase" "$work/bin/sleep"

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

# run_case <name> <plan> <delays|__default__> <expected_rc> <expected_starts> <expected_sleeps> [reason_substring]
run_case() {
  local name="$1" plan="$2" delays="$3" want_rc="$4" want_starts="$5" want_sleeps="$6" want_reason="${7:-}"
  local dir="$work/$name"
  mkdir -p "$dir"; : >"$dir/calls"; : >"$dir/sleeps"; : >"$dir/start.log"; : >"$dir/start.sanitized.log"
  local rc=0 reason
  cat >"$dir/driver.sh" <<DRIVER
set -euo pipefail
export PATH="$work/bin:\$PATH" FAKE_DIR="$dir" FAKE_PLAN="$plan"
if [[ "$delays" == "__default__" ]]; then unset LOCAL_SCHEMA_PULL_RETRY_DELAYS; else export LOCAL_SCHEMA_PULL_RETRY_DELAYS="$delays"; fi
source "$helper"
if local_supabase_start_bounded "$dir/start.log" "$dir/start.sanitized.log" >"$dir/out" 2>&1; then
  echo "rc=0"
else
  echo "rc=1:\${LOCAL_SUPABASE_START_FAILURE_REASON}"
fi
DRIVER
  reason="$(timeout 30 bash "$dir/driver.sh" 2>/dev/null)" || rc=$?
  if [[ -e "$dir/runaway" || "$rc" -ne 0 ]]; then
    fail "$name: helper did not terminate within its bound (runaway/hang, rc=$rc)"
    return 0
  fi
  local got_rc="${reason%%:*}"; got_rc="${got_rc#rc=}"
  local starts sleeps
  starts="$(grep -c '^start$' "$dir/calls" || true)"
  sleeps="$(paste -sd' ' "$dir/sleeps")"
  [[ "$got_rc" == "$want_rc" ]] || fail "$name: expected rc=$want_rc, got '$reason'"
  [[ "$starts" == "$want_starts" ]] || fail "$name: expected $want_starts start calls, got $starts"
  [[ "$sleeps" == "$want_sleeps" ]] || fail "$name: expected sleeps '$want_sleeps', got '$sleeps'"
  if [[ -n "$want_reason" && "$reason" != *"$want_reason"* ]]; then
    fail "$name: expected reason containing '$want_reason', got '$reason'"
  fi
}

# Healthy start: no retry, no pause.
run_case healthy 'ok' __default__ 0 1 ''
# Throttled twice, then succeeds: two bounded pauses using the default 20/60 schedule.
run_case throttle-recovers 'throttle throttle ok' __default__ 0 3 '20 60'
# Persistent throttling stays bounded and fails closed with a specific reason.
run_case throttle-persistent 'throttle' __default__ 1 4 '20 60 120' 'registry throttling persisted after 3 bounded retries'
# A custom, shorter schedule is honoured.
run_case throttle-custom 'throttle' '1 2' 1 3 '1 2' 'persisted after 2 bounded retries'
# An empty schedule disables the throttling retry entirely.
run_case throttle-disabled 'throttle' '' 1 1 '' 'persisted after 0 bounded retries'
# A genuine failure (migration/replay) is never retried.
run_case other-failure 'other' __default__ 1 1 '' 'could not start/replay'
# Throttle followed by a genuine failure stops at the genuine failure.
run_case throttle-then-other 'throttle other' __default__ 1 2 '20' 'could not start/replay'
# Host-port collision keeps its single retry and its original messages.
run_case port-recovers 'port ok' __default__ 0 2 ''
run_case port-persistent 'port' __default__ 1 2 '' 'after one port-collision retry'
# Invalid or unbounded schedules fail closed before any start attempt.
run_case bad-delay 'ok' '20 abc' 1 0 '' 'must be integers between 0 and 300'
run_case huge-delay 'ok' '301' 1 0 '' 'must be integers between 0 and 300'
run_case too-many 'ok' '1 1 1 1 1 1' 1 0 '' 'at most 5 retries'

# The shared readiness gate must use the bounded start and keep its loopback and cleanup guards.
gate="$repo_root/scripts/verify-local-schema-release-readiness.sh"
grep -Fq 'local_supabase_start_bounded' "$gate" || fail 'readiness gate does not use the bounded start'
grep -Fq 'assert_loopback_postgres_url "$local_db_url"' "$gate" || fail 'readiness gate lost its loopback guard'
grep -Fq 'supabase db reset --local' "$gate" || fail 'readiness gate lost its zero-state replay'
if grep -Eq '^[[:space:]]*if ! supabase start' "$gate"; then fail 'readiness gate still has an unbounded direct supabase start'; fi

if (( failures > 0 )); then
  echo "Local Supabase start retry regression FAILED ($failures failure(s))." >&2
  exit 1
fi
echo "Local Supabase start retry regression passed (12 behaviour cases + gate wiring)."
