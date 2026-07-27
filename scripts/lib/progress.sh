#!/usr/bin/env bash

progress_heartbeat_pid=""

progress_format_duration() {
  local seconds="$1"
  local hours=$((seconds / 3600))
  local minutes=$(((seconds % 3600) / 60))
  local remaining=$((seconds % 60))
  if (( hours > 0 )); then
    printf '%02d:%02d:%02d' "$hours" "$minutes" "$remaining"
  else
    printf '%02d:%02d' "$minutes" "$remaining"
  fi
}

progress_stop_heartbeat() {
  if [[ -n "${progress_heartbeat_pid}" ]]; then
    kill "${progress_heartbeat_pid}" 2>/dev/null || true
    wait "${progress_heartbeat_pid}" 2>/dev/null || true
    progress_heartbeat_pid=""
  fi
}

progress_run() {
  local label="$1"
  shift

  local start_ts
  start_ts=$(date +%s)

  printf '[%s] start\n' "${label}" >&2

  (
    while sleep 30; do
      local now elapsed
      now=$(date +%s)
      elapsed=$((now - start_ts))
      printf '[%s] heartbeat after %s\n' "${label}" "$(progress_format_duration "${elapsed}")" >&2
    done
  ) &
  progress_heartbeat_pid=$!

  "$@"
  local status=$?

  progress_stop_heartbeat

  local elapsed
  elapsed=$(( $(date +%s) - start_ts ))
  if [[ ${status} -eq 0 ]]; then
    printf '[%s] done in %s\n' "${label}" "$(progress_format_duration "${elapsed}")" >&2
  else
    printf '[%s] failed after %s\n' "${label}" "$(progress_format_duration "${elapsed}")" >&2
  fi

  return "${status}"
}
