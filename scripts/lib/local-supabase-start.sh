#!/usr/bin/env bash
# Bounded start of the disposable local Supabase stack, shared by the release-readiness gates.
# Source this file; it only defines functions.
#
# Why: `supabase start` pulls about a dozen images from ghcr.io. When the registry throttles the
# runner it answers `toomanyrequests` with a retry-after of microseconds and the CLI makes its three
# attempts back-to-back, so every attempt lands inside the same throttled instant and the job dies
# before any migration or pgTAP assertion runs. Layers that were already downloaded stay in the
# Docker cache, so a short pause between whole `supabase start` attempts makes real progress.
#
# Policy (fail closed, bounded):
#   - Only an identified registry-throttling failure is retried, at most len(delays) times
#     (default 3 pauses: 20s, 60s, 120s). Any other failure fails immediately.
#   - One retry for an identified local host-port collision, exactly as before.
#   - Nothing is skipped or weakened: success still means the full stack started and replayed.
#
# Authentication (best effort): the pinned CLI runs `docker pull`, so a `docker login` is honoured. When
# LOCAL_SCHEMA_REGISTRY_USER and LOCAL_SCHEMA_REGISTRY_TOKEN are set and SUPABASE_INTERNAL_IMAGE_REGISTRY is
# ghcr.io, the helper logs in with the token read from stdin (never as an argument, never printed) so pulls
# use the workflow identity's quota instead of the shared anonymous one. A failed login only logs a warning
# and pulls stay anonymous; it never relaxes any check. The login is removed again by
# local_supabase_registry_logout.
#
# Environment:
#   LOCAL_SCHEMA_REGISTRY_USER / LOCAL_SCHEMA_REGISTRY_TOKEN  optional registry identity (see above)
#   LOCAL_SCHEMA_PULL_RETRY_DELAYS  space-separated pause seconds between throttled attempts
#                                   (integers 0-300, at most 5 entries; default "20 60 120").
#                                   An empty value disables the throttling retry.

_local_supabase_start_note() {
  echo "LOCAL_SCHEMA_RELEASE_READINESS: $*" >&2
}

LOCAL_SUPABASE_REGISTRY_LOGGED_IN=0

# local_supabase_registry_login: best-effort, never fatal, never prints the token.
local_supabase_registry_login() {
  local registry="${SUPABASE_INTERNAL_IMAGE_REGISTRY:-}"
  [[ "$registry" == "ghcr.io" ]] || return 0
  [[ -n "${LOCAL_SCHEMA_REGISTRY_USER:-}" && -n "${LOCAL_SCHEMA_REGISTRY_TOKEN:-}" ]] || return 0
  command -v docker >/dev/null 2>&1 || return 0
  if printf '%s' "$LOCAL_SCHEMA_REGISTRY_TOKEN" \
      | docker login "$registry" --username "$LOCAL_SCHEMA_REGISTRY_USER" --password-stdin >/dev/null 2>&1; then
    LOCAL_SUPABASE_REGISTRY_LOGGED_IN=1
    _local_supabase_start_note "image pulls from ${registry} are authenticated as the workflow identity."
  else
    _local_supabase_start_note "WARNING: ${registry} login failed; image pulls stay anonymous and may be rate limited."
  fi
  return 0
}

local_supabase_registry_logout() {
  if (( LOCAL_SUPABASE_REGISTRY_LOGGED_IN == 1 )); then
    docker logout "${SUPABASE_INTERNAL_IMAGE_REGISTRY:-ghcr.io}" >/dev/null 2>&1 || true
    LOCAL_SUPABASE_REGISTRY_LOGGED_IN=0
  fi
  return 0
}

# local_supabase_start_bounded <start_log> <sanitized_log>
# Returns 0 when the stack started. Returns 1 otherwise and sets LOCAL_SUPABASE_START_FAILURE_REASON.
# shellcheck disable=SC2034 # LOCAL_SUPABASE_START_FAILURE_REASON is the output read by the sourcing script.
local_supabase_start_bounded() {
  local start_log="$1" sanitized_log="$2"
  local -a pull_delays=()
  local delay port_retried=0 pull_attempt=0

  LOCAL_SUPABASE_START_FAILURE_REASON=''
  read -r -a pull_delays <<< "${LOCAL_SCHEMA_PULL_RETRY_DELAYS-20 60 120}"
  if (( ${#pull_delays[@]} > 5 )); then
    LOCAL_SUPABASE_START_FAILURE_REASON='LOCAL_SCHEMA_PULL_RETRY_DELAYS allows at most 5 retries'
    return 1
  fi
  for delay in "${pull_delays[@]}"; do
    if [[ ! "$delay" =~ ^[0-9]+$ ]] || (( delay > 300 )); then
      LOCAL_SUPABASE_START_FAILURE_REASON='LOCAL_SCHEMA_PULL_RETRY_DELAYS must be integers between 0 and 300'
      return 1
    fi
  done

  local_supabase_registry_login

  while :; do
    if supabase start >"$start_log" 2>&1; then
      return 0
    fi
    if declare -F sanitize_log >/dev/null 2>&1; then
      sanitize_log "$start_log" "$sanitized_log"
      cat "$sanitized_log" >&2 || true
    else
      cat "$start_log" >&2 || true
    fi

    if grep -Eqi 'failed to bind host port|address already in use' "$start_log"; then
      if (( port_retried == 1 )); then
        LOCAL_SUPABASE_START_FAILURE_REASON='local Supabase stack could not start after one port-collision retry'
        return 1
      fi
      port_retried=1
      _local_supabase_start_note 'local port collision; cleaning this stack and retrying once.'
      supabase stop --no-backup >/dev/null 2>&1 || true
      continue
    fi

    if grep -Eqi 'toomanyrequests|too many requests' "$start_log"; then
      if (( pull_attempt >= ${#pull_delays[@]} )); then
        LOCAL_SUPABASE_START_FAILURE_REASON="local Supabase stack could not start: container registry throttling persisted after ${pull_attempt} bounded retries"
        return 1
      fi
      delay="${pull_delays[$pull_attempt]}"
      pull_attempt=$((pull_attempt + 1))
      _local_supabase_start_note "container registry throttled image pulls; retry ${pull_attempt}/${#pull_delays[@]} after ${delay}s (cached layers are kept)."
      supabase stop --no-backup >/dev/null 2>&1 || true
      sleep "$delay"
      continue
    fi

    LOCAL_SUPABASE_START_FAILURE_REASON='local Supabase stack could not start/replay'
    return 1
  done
}
