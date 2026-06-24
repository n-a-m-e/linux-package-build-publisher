# Generic diagnostic helpers.
# Backend-specific diagnostics live in the package backend files and can use these
# small helpers to keep reports consistent.
diagnostics_section(){
  printf '=== %s ===\n' "$1"
}

diagnostics_tail_file(){
  local file="$1" lines="${2:-200}"

  [[ -f "$file" ]] || return 0
  printf -- '--- %s (last %s lines) ---\n' "$file" "$lines" >&2
  tail -n "$lines" "$file" >&2 || true
}

diagnostics_bool_enabled(){
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON|enabled|ENABLED) return 0 ;;
    *) return 1 ;;
  esac
}

diagnostics_run_with_timeout(){
  local timeout_duration="$1" log_file="$2" status=0
  shift 2

  if ! command -v timeout >/dev/null 2>&1; then
    {
      echo "=== timeout-protected diagnostics skipped ==="
      echo "The 'timeout' command is not available, so the diagnostic command was not run."
      echo "This avoids the diagnostics path hanging indefinitely."
      echo
    } >>"$log_file"
    return 125
  fi

  timeout -k 10s "$timeout_duration" "$@" >>"$log_file" 2>&1 || status=$?

  case "$status" in
    0)
      return 0
      ;;
    124|137)
      {
        echo
        echo "=== diagnostic command timed out ==="
        echo "timeout=$timeout_duration"
        echo "The deep diagnostic command was stopped so failure reporting could continue."
        echo
      } >>"$log_file"
      return "$status"
      ;;
    *)
      return "$status"
      ;;
  esac
}

