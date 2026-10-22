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
# Registry pinning: without SUPABASE_INTERNAL_IMAGE_REGISTRY the CLI resolves every image through its built-in
# fallback chain (public.ecr.aws, then ghcr.io, then Docker Hub). `supabase/setup-cli` exports
# SUPABASE_INTERNAL_IMAGE_REGISTRY=ghcr.io, which makes the CLI use ONLY that registry, so one throttled registry
# is fatal even though identical tag-pinned images are published on the others. The helper therefore clears the
# variable before starting the stack. Set LOCAL_SCHEMA_PIN_IMAGE_REGISTRY=1 to keep an explicitly pinned registry.
#
# Policy (fail closed, bounded):
#   - Only an identified registry-throttling failure is retried, at most len(delays) times
#     (default 3 pauses: 20s, 60s, 120s). Any other failure fails immediately.
#   - One retry for an identified local host-port collision, exactly as before.
#   - Nothing is skipped or weakened: success still means the full stack started and replayed.
#
# Environment:
#   LOCAL_SCHEMA_PIN_IMAGE_REGISTRY  set to 1 to keep SUPABASE_INTERNAL_IMAGE_REGISTRY as exported (default: cleared)
#   LOCAL_SCHEMA_PULL_RETRY_DELAYS  space-separated pause seconds between throttled attempts
#                                   (integers 0-300, at most 5 entries; default "20 60 120").
#                                   An empty value disables the throttling retry.

_local_supabase_start_note() {
  echo "LOCAL_SCHEMA_RELEASE_READINESS: $*" >&2
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
    if [[ ! "$delay" =~ ^[0-9]{1,3}$ ]] || (( 10#$delay > 300 )); then
      LOCAL_SUPABASE_START_FAILURE_REASON='LOCAL_SCHEMA_PULL_RETRY_DELAYS must be integers between 0 and 300'
      return 1
    fi
  done

  if [[ "${LOCAL_SCHEMA_PIN_IMAGE_REGISTRY:-0}" != "1" && -n "${SUPABASE_INTERNAL_IMAGE_REGISTRY:-}" ]]; then
    _local_supabase_start_note "clearing SUPABASE_INTERNAL_IMAGE_REGISTRY=${SUPABASE_INTERNAL_IMAGE_REGISTRY} so the CLI can fall back across registries."
  fi
  if [[ "${LOCAL_SCHEMA_PIN_IMAGE_REGISTRY:-0}" != "1" ]]; then
    unset SUPABASE_INTERNAL_IMAGE_REGISTRY
  fi

  while :; do
    LOCAL_SUPABASE_START_ATTEMPTED=1
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
