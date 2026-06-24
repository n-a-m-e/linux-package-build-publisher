# shellcheck shell=bash

# Shared constants and low-level helpers.
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TARGETS_DIR="${TARGET_CONFIG_DIR:-$ROOT/targets}"
PUBLIC_DIR="/work/public"
METADATA_DIR="$PUBLIC_DIR/publisher-metadata"
QUEUE_DIR="/work/package-build-queue"
PACKAGE_TYPES=" rpm deb flatpak "
HOST_ENV_VARS=(PACKAGE_TYPE APP SOURCE_GIT BUILD_SCRIPT REPO_OWNER REPO_NAME FPR TARGETS)
TRIMMED_ENV_VARS=" PACKAGE_TYPE REPO_OWNER REPO_NAME FPR TARGETS "
CACHE_MOUNTS=("mock:/var/cache/mock")
PACKAGE_CACHE_SCHEMA=1

GPG_KEY_BATCH='%no-protection
Key-Type: RSA
Key-Length: 4096
Key-Usage: sign
Name-Real: Repository Signing
Name-Email: repo@example.invalid
Expire-Date: 0
%commit'

REQUIRED_TARGET_KEYS=(TARGET_FAMILY_REGEX TARGET_ARCHES)
REQUIRED_REPO_KEYS=(TARGET_LABEL_STRIP_PREFIX TARGET_LABEL_TEMPLATE TARGET_LABEL_CASE TARGET_INSTALL_TOOL)
REQUIRED_DEB_KEYS=(TARGET_DEB_MIRROR TARGET_DEB_SUITE_TEMPLATE TARGET_DEB_SUITE_STRIP_PREFIX)
OPTIONAL_RPM_KEYS=(TARGET_RPM_CHROOT_SETUP_CMD TARGET_RPM_MOCK_CONFIG_OPTS)
ALLOWED_RPM_KEYS=("${REQUIRED_TARGET_KEYS[@]}" "${REQUIRED_REPO_KEYS[@]}" TARGET_CONTAINER_IMAGE TARGET_CONTAINER_IMAGE_TEMPLATE TARGET_CONTAINER_IMAGE_STRIP_PREFIX TARGET_CONTAINER_BUILD_CMD "${OPTIONAL_RPM_KEYS[@]}")
ALLOWED_DEB_KEYS=("${REQUIRED_TARGET_KEYS[@]}" "${REQUIRED_REPO_KEYS[@]}" TARGET_CONTAINER_IMAGE TARGET_CONTAINER_IMAGE_TEMPLATE TARGET_CONTAINER_IMAGE_STRIP_PREFIX TARGET_CONTAINER_BUILD_CMD "${REQUIRED_DEB_KEYS[@]}")
ALLOWED_FLATPAK_KEYS=("${REQUIRED_TARGET_KEYS[@]}" TARGET_CONTAINER_IMAGE TARGET_CONTAINER_IMAGE_TEMPLATE TARGET_CONTAINER_IMAGE_STRIP_PREFIX)

PRIMARY_APP=""
APPS=()
SOURCES=()

error(){
  printf '::error::%s\n' "$*" >&2
}

die(){
  error "$*"
  exit 1
}

ensure_dir(){
  mkdir -p "$1"
}

fresh_dir(){
  rm -rf "$1"
  mkdir -p "$1"
}

sha256_file(){
  sha256sum "$1" | awk '{print $1}'
}

sha256_lines(){
  sha256sum | awk '{print $1}'
}

safe_id(){
  sed -E 's/[^A-Za-z0-9_.-]/_/g' <<<"$1"
}

write_output(){
  local name="$1"
  local value="$2"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$name" "$value" >>"$GITHUB_OUTPUT"
  else
    printf '%s=%s\n' "$name" "$value"
  fi
}

require_file(){
  [[ -f "$1" ]] || die "Missing required file: $1"
}

sort_unique_file(){
  local file="$1"

  [[ -f "$file" ]] || : >"$file"
  sort -u "$file" -o "$file"
}

main(){
  local cmd="${1:-}"
  if (($#)); then
    shift
  fi

  case "$cmd" in
    gpg)
      case "${1:-}" in
        generate) gpg_generate ;;
        setup) setup_gpg ;;
        *) die "Usage: repository_builder.sh gpg {generate|setup}" ;;
      esac
      ;;
    package-build-queue|queue)
      cmd_package_build_queue "$@"
      ;;
    build-container)
      cmd_build_container "$@"
      ;;
    prepare)
      cmd_prepare
      ;;
    flatpak-prepare)
      cmd_flatpak_prepare
      ;;
    update-readme)
      cmd_update_readme
      ;;
    rpm-graph-query-chroot)
      cmd_rpm_graph_query_chroot "$@"
      ;;
    rpm-list-sources-chroot)
      cmd_rpm_list_sources_chroot "$@"
      ;;
    *)
      die "Unknown builder command: $cmd"
      ;;
  esac
}

