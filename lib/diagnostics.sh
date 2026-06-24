# shellcheck shell=bash

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
