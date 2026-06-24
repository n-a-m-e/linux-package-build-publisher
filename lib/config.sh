# shellcheck shell=bash

# Input parsing, package-type validation, and target configuration.

load_apps_sources(){
  local app_list="${1:-${APP:-}}"
  local source_list="${2:-${SOURCE_GIT:-}}"
  local source

  mapfile -t APPS < <(printf '%s\n' "$app_list" | sed -e 's/[[:space:]]*$//' -e '/^[[:space:]]*$/d')
  mapfile -t SOURCES < <(printf '%s\n' "$source_list" | sed -e 's/[[:space:]]*$//' -e '/^[[:space:]]*$/d')

  ((${#APPS[@]})) || die "APP/app-id is required."
  PRIMARY_APP="${APPS[0]}"

  for source in "${SOURCES[@]}"; do
    [[ -n "$source" && "$source" != file://* ]] ||
      die "SOURCE_GIT entries must be Git URLs; file:// is unsupported."
  done

  if ((${#SOURCES[@]} > 1 && ${#SOURCES[@]} != ${#APPS[@]})); then
    die "SOURCE_GIT must contain zero entries, one Git URL, or one Git URL per APP."
  fi
}

source_for_index(){
  local index="$1"

  if ((${#SOURCES[@]} == 0)); then
    printf ''
  elif ((${#SOURCES[@]} == 1)); then
    printf '%s' "${SOURCES[0]}"
  else
    printf '%s' "${SOURCES[$index]}"
  fi
}

load_target_config_file(){
  local package_type="$1"
  local file="$2"
  local key allowed_key matched var
  local allowed=()
  local target_vars=(
    TARGET_FAMILY_REGEX
    TARGET_ARCHES
    TARGET_LABEL_STRIP_PREFIX
    TARGET_LABEL_TEMPLATE
    TARGET_LABEL_CASE
    TARGET_INSTALL_TOOL
    TARGET_CONTAINER_IMAGE
    TARGET_CONTAINER_IMAGE_TEMPLATE
    TARGET_CONTAINER_IMAGE_STRIP_PREFIX
    TARGET_CONTAINER_BUILD_CMD
    TARGET_RPM_CHROOT_SETUP_CMD
    TARGET_RPM_MOCK_CONFIG_OPTS
    TARGET_DEB_MIRROR
    TARGET_DEB_SUITE_TEMPLATE
    TARGET_DEB_SUITE_STRIP_PREFIX
  )
  local required_keys=("${REQUIRED_TARGET_KEYS[@]}")

  [[ -f "$file" ]] || die "Missing target config: $file"

  case "$package_type" in
    rpm)
      allowed=("${ALLOWED_RPM_KEYS[@]}")
      required_keys+=("${REQUIRED_REPO_KEYS[@]}")
      ;;
    deb)
      allowed=("${ALLOWED_DEB_KEYS[@]}")
      required_keys+=("${REQUIRED_REPO_KEYS[@]}" "${REQUIRED_DEB_KEYS[@]}")
      ;;
    flatpak)
      allowed=("${ALLOWED_FLATPAK_KEYS[@]}")
      ;;
    *)
      die "Unsupported package type: $package_type"
      ;;
  esac

  while IFS= read -r key; do
    [[ -z "$key" ]] && continue

    matched=0
    for allowed_key in "${allowed[@]}"; do
      if [[ "$key" == "$allowed_key" ]]; then
        matched=1
        break
      fi
    done

    ((matched)) || die "Unknown target config key $key in $file"
  done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$file" | sed 's/=.*//')

  for var in "${target_vars[@]}"; do
    unset "$var"
  done

  # shellcheck source=/dev/null
  source "$file"

  for key in "${required_keys[@]}"; do
    [[ -n "${!key+x}" ]] || die "Missing required key $key in $file"
  done

  if [[ -n "${TARGET_CONTAINER_IMAGE:-}" && -n "${TARGET_CONTAINER_IMAGE_TEMPLATE:-}" ]]; then
    die "Set only one of TARGET_CONTAINER_IMAGE or TARGET_CONTAINER_IMAGE_TEMPLATE in $file"
  fi

  if [[ -z "${TARGET_CONTAINER_IMAGE:-}" && -z "${TARGET_CONTAINER_IMAGE_TEMPLATE:-}" ]]; then
    die "Set one of TARGET_CONTAINER_IMAGE or TARGET_CONTAINER_IMAGE_TEMPLATE in $file"
  fi

  case "$package_type" in
    rpm|deb)
      [[ -n "${TARGET_CONTAINER_BUILD_CMD:-}" ]] ||
        die "Missing required key TARGET_CONTAINER_BUILD_CMD in $file"
      ;;
  esac
}

split_target(){
  local target="$1"
  printf '%s\t%s\n' "${target%-*}" "${target##*-}"
}

find_target_config(){
  local package_type="$1"
  local family="$2"
  local arch="${3:-}"
  local dir file

  case "$package_type" in
    rpm|deb|flatpak) dir="$TARGETS_DIR/$package_type" ;;
    *) die "Unsupported package type: $package_type" ;;
  esac

  [[ -d "$dir" ]] || die "Missing target config directory: $dir"

  while IFS= read -r -d '' file; do
    load_target_config_file "$package_type" "$file"

    if [[ "$family" =~ $TARGET_FAMILY_REGEX ]] &&
       [[ -z "$arch" || " $TARGET_ARCHES " == *" $arch "* ]]; then
      printf '%s' "$file"
      return 0
    fi
  done < <(find "$dir" -maxdepth 1 -type f -name '*.conf' -print0 | sort -z)

  die "Unsupported $package_type target: ${family}${arch:+-$arch}. Expected a match in $dir/*.conf"
}

load_target(){
  local package_type="$1"
  local family="$2"
  local arch="${3:-}"

  load_target_config_file "$package_type" "$(find_target_config "$package_type" "$family" "$arch")"
}

targets_list(){
  printf '%s\n' "${TARGETS:-}" | sed -e 's/[[:space:]]*$//' -e '/^[[:space:]]*$/d'
}

validate_target(){
  local package_type="$1"
  local target="$2"
  local family arch

  IFS=$'\t' read -r family arch < <(split_target "$target")
  load_target "$package_type" "$family" "$arch"
}

validate_targets(){
  local package_type="$1"
  local found=0 target

  while IFS= read -r target; do
    found=1
    validate_target "$package_type" "$target"
  done < <(targets_list)

  ((found)) || die "$package_type requires at least one target."
}

expand_template(){
  local template="$1"
  local family="$2"
  local arch="$3"
  local strip="${4:-}"
  local suffix="${5:-}"
  local output

  [[ -n "$suffix" ]] || suffix="${family#"$strip"}"

  output="${template//\{suffix\}/$suffix}"
  output="${output//\{family\}/$family}"
  output="${output//\{arch\}/$arch}"

  printf '%s' "$output"
}

target_label(){
  local package_type="$1"
  local family="$2"
  local arch="${3:-}"
  local suffix label

  load_target "$package_type" "$family" "$arch"
  suffix="${family#"${TARGET_LABEL_STRIP_PREFIX:-}"}"

  case "${TARGET_LABEL_CASE:-raw}" in
    title)
      suffix="$(sed -E 's/[-_]+/ /g; s/(^| )[a-z]/\U&/g' <<<"$suffix")"
      ;;
    upper-first)
      suffix="$(sed -E 's/^./\U&/' <<<"$suffix")"
      ;;
    raw)
      ;;
    *)
      die "Unsupported TARGET_LABEL_CASE: $TARGET_LABEL_CASE"
      ;;
  esac

  label="$(expand_template "$TARGET_LABEL_TEMPLATE" "$family" "$arch" "$TARGET_LABEL_STRIP_PREFIX" "$suffix")"
  printf '%s' "$label"
}

target_container_image(){
  local package_type="$1"
  local family="$2"
  local arch="${3:-}"

  load_target "$package_type" "$family" "$arch"

  if [[ -n "${TARGET_CONTAINER_IMAGE:-}" ]]; then
    printf '%s' "$TARGET_CONTAINER_IMAGE"
  else
    expand_template "$TARGET_CONTAINER_IMAGE_TEMPLATE" "$family" "$arch" "$TARGET_CONTAINER_IMAGE_STRIP_PREFIX"
  fi
}

repo_info(){
  local package_type="$1"
  local app="$2"
  local target="$3"
  local family arch repo_path repo_id repo_file label

  IFS=$'\t' read -r family arch < <(split_target "$target")

  repo_path="repos/$package_type/$family/$arch"
  repo_id="$(safe_id "$app-$target")"
  label="$(target_label "$package_type" "$family" "$arch")"

  case "$package_type" in
    rpm) repo_file="$repo_id.repo" ;;
    deb) repo_file="$repo_id.sources" ;;
    *) repo_file="" ;;
  esac

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$family" "$arch" "$repo_path" "$repo_id" "$repo_file" "$label"
}

