# shellcheck shell=bash

# Flatpak backend: manifest discovery and flatter preparation.

cmd_flatpak_prepare(){
  rm -rf work flatpak-files.txt
  mkdir -p work
  load_apps_sources "${APP:-}" "${SOURCE_GIT:-}"

  local files=() app dir i found ext

  for i in "${!APPS[@]}"; do
    app="${APPS[$i]}"
    dir="$(prepare_app_workdir "$app" "$(source_for_index "$i")" "$PWD/work")"
    SOURCE_ID="$app" PATCH_ROOT="$dir/patches" run_user_build_script "$dir" "${BUILD_SCRIPT:-}"

    found=""
    for ext in yaml yml json; do
      if [[ -f "$dir/$app.$ext" ]]; then
        found="$dir/$app.$ext"
        break
      fi
    done

    [[ -n "$found" ]] || die "Missing Flatpak manifest for $app. Expected $app.yaml, $app.yml, or $app.json"
    files+=("$found")
  done

  printf '%s\n' "${files[@]}" >flatpak-files.txt

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      printf 'files<<EOF\n'
      printf '%s\n' "${files[@]}"
      printf 'EOF\n'
    } >>"$GITHUB_OUTPUT"
  else
    printf '%s\n' "${files[@]}"
  fi
}

