#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
metadata_append(){
  ensure_dir "$METADATA_DIR"
  printf '%s\n' "$2" >>"$METADATA_DIR/$1"
}
metadata_append_package(){
  metadata_append packages.txt "$1"
}
metadata_append_repo(){
  metadata_append repos.tsv "$1	$2	$3	$4"
}
sort_unique_file(){
  local file="$1"

  [[ -f "$file" ]] || : >"$file"
  sort -u "$file" -o "$file"
}
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



cached_builder_image(){
  local package_type="$1"
  local base_image="$2"
  local build_cmd="$3"
  local work cfile digest hash repo image

  work="$ROOT/.builder-image/$package_type"
  cfile="$work/Containerfile"
  mkdir -p "$work"

  digest="$(docker buildx imagetools inspect "$base_image" --format '{{json .Manifest.Digest}}' | tr -d '"')"

  cat >"$cfile" <<EOF
FROM $base_image

RUN $build_cmd
EOF

  hash="$(
    {
      printf 'package_type=%s\n' "$package_type"
      printf 'base_digest=%s\n' "$digest"
      printf 'build_cmd=%s\n' "$build_cmd"
    } | sha256_lines
  )"

  repo="${BUILDER_IMAGE_REPO:-ghcr.io/${GITHUB_REPOSITORY:?}/builder}"
  image="$repo:$package_type-${hash:0:16}"

  if docker buildx imagetools inspect "$image" >/dev/null 2>&1; then
    printf '%s' "$image"
    return 0
  fi

  docker buildx build \
    --file "$cfile" \
    --tag "$image" \
    --push \
    "$ROOT"

  printf '%s' "$image"
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
checkout_source_tree(){
  local url="$1"
  local ref="${2:-}"
  local dest="$3"

  [[ -n "$url" && "$url" != file://* ]] || die "Git source URL required when SOURCE_GIT is provided: $url"

  rm -rf "$dest"
  git clone --recursive "$url" "$dest"

  if [[ -n "$ref" ]]; then
    git -C "$dest" checkout "$ref"
  fi

  git -C "$dest" rev-parse --verify HEAD >/dev/null
}
prepare_app_workdir(){
  local app="$1"
  local url="$2"
  local root="$3"
  local app_work="$root/$app"
  local checkout

  ensure_dir "$app_work"

  if [[ -n "$url" ]]; then
    checkout="$app_work/source"
    [[ ! -e "$checkout" ]] || die "Source checkout path already exists: $checkout"

    checkout_source_tree "$url" "" "$checkout"
    cp -a "$checkout/." "$app_work/"
  fi

  printf '%s' "$app_work"
}
run_user_build_script(){
  local dir="$1"
  local script="${2:-}"
  local first candidate cmd

  [[ -z "$script" ]] && return 0

  if [[ "$script" != *$'\n'* ]]; then
    first="${script%% *}"
    candidate="$dir/$first"

    if [[ -f "$candidate" ]]; then
      chmod +x "$candidate"

      if [[ "$first" == */* ]]; then
        cmd="$script"
      else
        cmd="./$script"
      fi

      (cd "$dir" && SOURCE_ID="${SOURCE_ID:-}" PATCH_ROOT="${PATCH_ROOT:-}" bash -lc "$cmd")
      return
    fi
  fi

  printf '%s\n' "$script" >"$dir/build-extra.sh"
  (cd "$dir" && SOURCE_ID="${SOURCE_ID:-}" PATCH_ROOT="${PATCH_ROOT:-}" bash build-extra.sh)
}
source_tree_fingerprint(){
  local root="$1"
  local commit="no-git"
  local file

  if [[ -d "$root/.git" ]]; then
    commit="$(git -C "$root" rev-parse 'HEAD^{commit}')"
  fi

  {
    printf 'commit %s\n' "$commit"
    find "$root" -type d -name .git -prune -o -type f -print | sort | while IFS= read -r file; do
      printf '%s  %s\n' "$(sha256_file "$file")" "${file#$root/}"
    done
  } | sha256_lines
}
setup_gpg(){
  local fpr

  ensure_dir gpg-key
  chmod 700 gpg-key
  export GNUPGHOME="$PWD/gpg-key"

  gpg --batch --import gpg-key/private.asc
  gpg --batch --import gpg-key/public.asc

  fpr="$(cat gpg-key/fingerprint.txt)"
  write_output fingerprint "$fpr"
}
gpg_generate(){
  rm -rf gpg-key
  mkdir -p gpg-key
  chmod 700 gpg-key

  GNUPGHOME="$PWD/gpg-key" gpg --batch --generate-key < <(printf '%s\n' "$GPG_KEY_BATCH")
  GNUPGHOME="$PWD/gpg-key" gpg --armor --export-secret-keys >gpg-key/private.asc
  GNUPGHOME="$PWD/gpg-key" gpg --armor --export >gpg-key/public.asc
  GNUPGHOME="$PWD/gpg-key" gpg --list-secret-keys --with-colons \
    | awk -F: '$1=="fpr"{print $10; exit}' >gpg-key/fingerprint.txt
}
layer_names(){
  local family="$1"
  local target="$2"
  local part prefix=""
  local parts=()

  printf '.\n'

  IFS='-' read -r -a parts <<<"$family"
  for part in "${parts[@]}"; do
    prefix="${prefix:+$prefix-}$part"
    printf '%s\n' "$prefix"
  done

  if [[ "$target" != "$family" ]]; then
    printf '%s\n' "$target"
  fi
}
layered_files(){
  local root="$1" family="$2" target="$3" relglob="$4"
  local layer pattern matches

  while IFS= read -r layer; do
    if [[ "$layer" == "." ]]; then
      pattern="$root/$relglob"
    else
      pattern="$root/$layer/$relglob"
    fi

    if matches="$(compgen -G "$pattern")"; then
      printf '%s\n' "$matches"
    fi
  done < <(layer_names "$family" "$target") | sort -u
}
layered_names(){
  local root="$1"
  local family="$2"
  local target="$3"
  local category="$4"
  local pattern="$5"
  local file

  layered_files "$root" "$family" "$target" "$category/$pattern" | while IFS= read -r file; do
    basename "$file"
  done | sort -u
}
layered_best_file(){
  local root="$1"
  local family="$2"
  local target="$3"
  local category="$4"
  local name="$5"
  local layer candidate best=""

  while IFS= read -r layer; do
    if [[ "$layer" == "." ]]; then
      candidate="$root/$category/$name"
    else
      candidate="$root/$layer/$category/$name"
    fi

    [[ -f "$candidate" ]] && best="$candidate"
  done < <(layer_names "$family" "$target")

  [[ -n "$best" ]] && printf '%s' "$best"
}
layered_existing_files(){
  local root="$1"
  local family="$2"
  local target="$3"
  local category="$4"
  local name="$5"
  local layer candidate

  while IFS= read -r layer; do
    if [[ "$layer" == "." ]]; then
      candidate="$root/$category/$name"
    else
      candidate="$root/$layer/$category/$name"
    fi

    [[ -f "$candidate" ]] && printf '%s\n' "$candidate"
  done < <(layer_names "$family" "$target")
}
apply_git_patches(){
  local src="$1" root="$2" family="$3" target="$4" name f
  shift 4
  for name in "$@"; do
    while IFS= read -r f; do
      printf 'Applying patch: %s\n' "$f" >&2
      if ! git -C "$src" apply --unidiff-zero --verbose "$f" >&2; then
        die "Failed to apply zero-context patch $f"
      fi
    done < <(layered_existing_files "$root" "$family" "$target" patches "$name")
  done
}
copy_layered_files(){
  local dest="$1"
  local root="$2"
  local family="$3"
  local target="$4"
  local category="$5"
  local name file
  shift 5

  ensure_dir "$dest"

  for name in "$@"; do
    while IFS= read -r file; do
      cp "$file" "$dest/$(basename "$file")"
    done < <(layered_existing_files "$root" "$family" "$target" "$category" "$name")
  done
}
apply_sed_replacements(){
  local file="$1"
  local root="$2"
  local family="$3"
  local target="$4"
  local sed_file

  [[ -f "$file" ]] || return 0

  while IFS= read -r sed_file; do
    sed -i -f "$sed_file" "$file"
  done < <(layered_files "$root" "$family" "$target" 'replacements/*.sed')
}
prepend_layered(){
  local file="$1"
  local root="$2"
  local family="$3"
  local target="$4"
  local category="$5"
  local pattern="$6"
  local tmp
  local files=()

  [[ -f "$file" ]] || return 0

  mapfile -t files < <(layered_files "$root" "$family" "$target" "$category/$pattern")
  ((${#files[@]})) || return 0

  tmp="$(mktemp)"
  cat "${files[@]}" >"$tmp"
  printf '\n' >>"$tmp"
  cat "$file" >>"$tmp"
  mv "$tmp" "$file"
}
copy_source_tree(){
  local dest="$1"
  local src="$2"

  rm -rf "$dest"
  mkdir -p "$(dirname "$dest")"
  cp -a "$src" "$dest"

  if [[ ! -d "$dest/.git" ]]; then
    git -C "$dest" init -q
    git -C "$dest" add -A

    if ! git -C "$dest" diff --cached --quiet; then
      git -C "$dest" -c user.email=builder@example.invalid -c user.name=builder commit -qm init
    fi
  fi
}
queue_write(){
  local dir="$1"
  local safe="$2"
  local file kv key value
  shift 2

  ensure_dir "$dir"
  file="$dir/$safe-$(date +%s%N)-$$-$RANDOM.env"
  : >"$file"

  for kv in "$@"; do
    key="${kv%%=*}"
    value="${kv#*=}"
    printf '%s=%q\n' "$key" "$value" >>"$file"
  done

  printf '%s' "$file"
}
load_queue(){
  local file="$1"

  unset QUEUE_TYPE CLONE_URL REF SUBDIR SPEC PACKAGE SOURCE_ID
  source "$file"
}
queue_source_dir(){
  local clone_url="$1"
  local ref="$2"
  local source_id="$3"
  local subdir="$4"
  local queue_work="$5"
  local root="$queue_work/src"

  if [[ -n "$clone_url" ]]; then
    checkout_source_tree "$clone_url" "${ref:-main}" "$root"
    printf '%s' "$root/$subdir"
  else
    printf '%s' "/work/work/$source_id/$subdir"
  fi
}
queue_layer_root(){
  local source_id="$1"
  local queue_work="$2"

  if [[ -d "$queue_work/src" ]]; then
    printf '%s' "$queue_work/src"
  else
    printf '%s' "/work/work/$source_id"
  fi
}
cmd_package_build_queue(){
  local sub="${1:-}"
  local clone=""
  local ref="main"
  local subdir="."
  local spec=""
  local package=""
  local source_id="${SOURCE_ID:-$PRIMARY_APP}"
  local safe

  if (($#)); then
    shift
  fi

  [[ "$sub" == add ]] || die "Usage: package-build-queue add [--clone-url URL] [--ref REF] [--subdir DIR] [--spec SPEC] [--package NAME] [--source-id ID]"
  [[ "${PACKAGE_TYPE:-}" != rpm ]] || die "RPM package-build-queue declarations are disabled; use layered specs/*.spec instead."

  while (($#)); do
    case "$1" in
      --clone-url)
        clone="$2"
        shift 2
        ;;
      --ref)
        ref="$2"
        shift 2
        ;;
      --subdir)
        subdir="$2"
        shift 2
        ;;
      --spec)
        spec="$2"
        shift 2
        ;;
      --package)
        package="$2"
        shift 2
        ;;
      --source-id)
        source_id="$2"
        shift 2
        ;;
      *)
        die "Unknown package-build-queue option: $1"
        ;;
    esac
  done

  [[ -z "$clone" || "$clone" != file://* ]] || die "package-build-queue requires Git URLs when --clone-url is provided; file:// is unsupported."

  [[ -n "$package" ]] || package="${spec%.spec}"
  [[ -n "$package" ]] || package="$(basename "$subdir")"

  safe="$(safe_id "$source_id-$package-$subdir")"
  queue_write \
    "$QUEUE_DIR" \
    "$safe" \
    QUEUE_TYPE=deb \
    CLONE_URL="$clone" \
    REF="$ref" \
    SUBDIR="$subdir" \
    SPEC="$spec" \
    PACKAGE="$package" \
    SOURCE_ID="$source_id" >/dev/null

  metadata_append_package "$package"
}
graph_validate_unique_providers(){
  local file="$1"
  local label="$2"

  awk -F '\t' -v label="$label" '
    NF >= 2 {
      if (provider[$1] && provider[$1] != $2) {
        printf("::error::ambiguous internal %s provider %s: %s and %s\n", label, $1, provider[$1], $2) > "/dev/stderr"
        exit 1
      }

      provider[$1] = $2
    }
  ' "$file"
}
graph_emit_edges(){
  local providers="$1"
  local input="$2"
  local output="$3"

  : >"$output"

  awk -F '\t' '
    NR == FNR {
      provider[$1] = $2
      next
    }

    NF >= 2 && provider[$2] && provider[$2] != $1 {
      print provider[$2] "\t" $1
    }
  ' "$providers" "$input" >>"$output"

  sort_unique_file "$output"
}
runtime_closure_for(){
  local start="$1"
  local runtime_edges="$2"
  local allnodes="$3"
  local exclude="${4:-}"
  local dep next index
  local queue=()
  local seen=()
  local out=()

  [[ -f "$runtime_edges" ]] || return 0

  mapfile -t queue < <(awk -F '\t' -v node="$start" '$2==node{print $1}' "$runtime_edges")

  for ((index=0; index<${#queue[@]}; index++)); do
    dep="${queue[$index]}"

    [[ -z "$dep" || "$dep" == "$exclude" ]] && continue
    grep -qxF "$dep" "$allnodes" || continue
    printf '%s\n' "${seen[@]:-}" | grep -qxF "$dep" && continue

    seen+=("$dep")
    out+=("$dep")

    while IFS= read -r next; do
      queue+=("$next")
    done < <(awk -F '\t' -v node="$dep" '$2==node{print $1}' "$runtime_edges")
  done

  ((${#out[@]})) && printf '%s\n' "${out[@]}"
}
effective_order(){
  local nodes_file="$1" build_edges="$2" runtime_edges="${3:-}" out_edges="${4:-}" tmp nodes total dep pkg rdep node ready
  tmp="$(mktemp -d)"

  mapfile -t nodes < <(
    awk '
      NF && $1 !~ /^#/ {
        if (seen[$1]++) {
          print "duplicate graph node: " $1 > "/dev/stderr"
          exit 2
        }

        print $1
      }
    ' "$nodes_file"
  )
  total="${#nodes[@]}"
  if ! ((total)); then
    rm -rf "$tmp"
    die "graph has no nodes"
  fi

  : >"$tmp/effective"
  : >"$tmp/deps"
  : >"$tmp/allnodes"
  printf '%s\n' "${nodes[@]}" >"$tmp/allnodes"

  if [[ -f "$build_edges" ]]; then
    while IFS=$'\t' read -r dep pkg _; do
      [[ -z "$dep" || -z "$pkg" || "$dep" == "$pkg" ]] && continue
      grep -qxF "$dep" "$tmp/allnodes" && grep -qxF "$pkg" "$tmp/allnodes" || continue

      printf '%s\t%s\n' "$dep" "$pkg" >>"$tmp/effective"

      while IFS= read -r rdep; do
        [[ "$rdep" != "$pkg" ]] && printf '%s\t%s\n' "$rdep" "$pkg" >>"$tmp/effective"
      done < <(runtime_closure_for "$dep" "$runtime_edges" "$tmp/allnodes" "$pkg")
    done <"$build_edges"
  fi

  sort -u "$tmp/effective" -o "$tmp/effective"
  [[ -n "$out_edges" ]] && cp "$tmp/effective" "$out_edges"

  while IFS=$'\t' read -r dep pkg; do
    [[ -n "$dep" && -n "$pkg" ]] && printf '%s\t%s\n' "$pkg" "$dep" >>"$tmp/deps"
  done <"$tmp/effective"

  local order=()

  while :; do
    ready=""

    for node in "${nodes[@]}"; do
      [[ " ${order[*]} " == *" $node "* ]] && continue

      if ! awk -F '\t' -v n="$node" '$1==n{found=1} END{exit found?0:1}' "$tmp/deps"; then
        ready="$node"
        break
      fi
    done

    [[ -n "$ready" ]] || break

    order+=("$ready")
    awk -F '\t' -v r="$ready" '$1!=r && $2!=r' "$tmp/deps" >"$tmp/deps.new"
    mv "$tmp/deps.new" "$tmp/deps"
  done

  if ((${#order[@]} != total)); then
    error "effective build-time dependency graph is cyclic."
    echo "No package builds should be queued from this graph." >&2
    echo >&2
    echo "Unorderable packages:" >&2

    for node in "${nodes[@]}"; do
      [[ " ${order[*]} " == *" $node "* ]] || echo "  $node" >&2
    done

    echo >&2
    echo "Effective edges inside unresolved group:" >&2
    awk -F '\t' '{need[$1]=need[$1] (need[$1] ? ", " : "") $2} END{if(!length(need)) print "  none"; for (n in need) print "  " n " needs: " need[n]}' "$tmp/deps" >&2

    rm -rf "$tmp"
    exit 1
  fi

  printf '%s\n' "${order[@]}"
  rm -rf "$tmp"
}


build_graph_order(){
  local graph_root="$1"
  local target="$2"
  local family="$3"
  local queue_dir="$4"
  local empty_msg="$5"
  local backend="$6"
  local order_file="$graph_root/order.tsv"
  local node_queue="$graph_root/node-queue.tsv"
  local qfile node
  local qfiles=()

  rm -rf "$graph_root"
  mkdir -p "$graph_root"
  : >"$graph_root/nodes.tsv"
  : >"$node_queue"

  mapfile -t qfiles < <(find "$queue_dir" -maxdepth 1 -type f -name '*.env' | sort)
  ((${#qfiles[@]})) || die "$empty_msg"

  for qfile in "${qfiles[@]}"; do
    case "$backend" in
      rpm)
        node="$(rpm_graph_node_id "$qfile")"
        rpm_graph_collect_node "$qfile" "$graph_root" "$target" "$family" "$node"
        ;;
      deb)
        node="$(deb_graph_node_id "$qfile")"
        deb_graph_collect_node "$qfile" "$graph_root" "$target" "$family" "$node"
        ;;
      *)
        die "Unknown graph backend: $backend"
        ;;
    esac

    printf '%s\n' "$node" >>"$graph_root/nodes.tsv"
    printf '%s\t%s\n' "$node" "$qfile" >>"$node_queue"
  done

  sort_unique_file "$graph_root/nodes.tsv"

  case "$backend" in
    rpm) rpm_graph_finalize "$graph_root" "$target" "$family" ;;
    deb) deb_graph_finalize "$graph_root" "$target" "$family" ;;
  esac

  case "$backend" in
    rpm)
      # RPM runtime Requires commonly form cycles in desktop stacks. Use only
      # BuildRequires-derived internal edges for build ordering; keep runtime
      # deps collected in runtimedeps.tsv for diagnostics/metadata.
      effective_order "$graph_root/nodes.tsv" "$graph_root/builddeps.tsv" "" "$graph_root/effective-builddeps.tsv" >"$order_file"
      ;;
    deb)
      effective_order "$graph_root/nodes.tsv" "$graph_root/builddeps.tsv" "$graph_root/runtimedeps.tsv" "$graph_root/effective-builddeps.tsv" >"$order_file"
      ;;
  esac

  while IFS= read -r node; do
    awk -F '\t' -v n="$node" '$1==n{print $2; exit}' "$node_queue"
  done <"$order_file"
}

ordered_queue_files(){
  local -n out_files="$1"
  shift

  local graph_root="$1"
  local target="$2"
  local family="$3"
  local queue_dir="$4"
  local empty_msg="$5"
  local backend="$6"
  local order_file

  order_file="$(mktemp)"
  if ! build_graph_order "$graph_root" "$target" "$family" "$queue_dir" "$empty_msg" "$backend" >"$order_file"; then
    rm -f "$order_file"
    die "$backend graph ordering failed for $target"
  fi

  mapfile -t out_files <"$order_file"
  rm -f "$order_file"

  ((${#out_files[@]})) || die "$backend graph produced no build queue entries for $target"
}
rpm_configure_signing(){
  cat >/root/.rpmmacros <<EOF
%_signature gpg
%_gpg_name ${FPR:?}
%_gpg_path ${GNUPGHOME:-/root/.gnupg}
%_gpgbin /usr/bin/gpg
%_gpg_digest_algo sha256
%__gpg /usr/bin/gpg
EOF
}
rpm_dump_mock_failure(){
  local dir="$1" msg="$2" lines="${MOCK_LOG_TAIL_LINES:-200}"
  local log found=0

  error "$msg"

  shopt -s nullglob
  for log in "$dir"/*.log "$dir"/*/*.log; do
    [[ -f "$log" ]] || continue
    found=1
    echo "--- ${log#$dir/} (last $lines lines) ---" >&2
    tail -n "$lines" "$log" >&2 || true
  done
  shopt -u nullglob

  if ! ((found)); then
    echo "--- no mock result logs found in $dir ---" >&2
  fi
}

rpm_diagnostic_write_srpm_host(){
  local result="$1" srpm="$2" log

  [[ -n "$srpm" && -f "$srpm" ]] || return 0

  mkdir -p "$result"
  log="$result/srpm-buildrequires.log"

  {
    echo "=== SRPM ==="
    echo "srpm=$srpm"
    rpm -qp --queryformat 'name=%{NAME}\nversion=%{VERSION}\nrelease=%{RELEASE}\narch=%{ARCH}\n' "$srpm" 2>&1 || true
    echo

    echo "=== SRPM requires / BuildRequires ==="
    rpm -qpR "$srpm" 2>&1 | sort -u || true
    echo
  } >"$log"

  echo "--- ${log#$result/} ---" >&2
  cat "$log" >&2 || true
}

rpm_diagnostic_mock_log_files(){
  local result="$1" log

  shopt -s nullglob
  for log in "$result"/*.log "$result"/*/*.log; do
    [[ -f "$log" ]] && printf '%s\n' "$log"
  done
  shopt -u nullglob
}

rpm_diagnostic_parse_transaction_logs(){
  local result="$1" log

  while IFS= read -r log; do
    awk '
      function normalize(line, out) {
        out = line
        sub(/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:.]+Z[[:space:]]*/, "", out)
        sub(/^DEBUG[[:space:]]+util\.py:[0-9]+:[[:space:]]*/, "", out)
        sub(/^INFO[[:space:]]+util\.py:[0-9]+:[[:space:]]*/, "", out)
        return out
      }
      {
        line = normalize($0)
        trimmed = line
        sub(/^[[:space:]]+/, "", trimmed)
      }
      trimmed ~ /^(Installing|Installing dependencies|Installing weak dependencies|Installing group\/module packages|Upgrading|Downgrading|Reinstalling|Removing):[[:space:]]*$/ {
        section = trimmed
        sub(/:[[:space:]]*$/, "", section)
        next
      }
      trimmed ~ /^(Transaction Summary|Running transaction check|Running transaction test|Running transaction|Complete!|Error:)/ {
        section = ""
        next
      }
      section {
        row = line
        sub(/^[[:space:]]+/, "", row)
        if (row == "" || row ~ /^=+$/ || row ~ /^Package[[:space:]]+Arch[[:space:]]+/) next
        split(row, fields, /[[:space:]]+/)
        name = fields[1]
        if (name != "" && name !~ /^(Package|Arch|Version|Repository|Size|\[SKIPPED\])$/) {
          key = section "\t" name
          if (!seen[key]++) print key
        }
      }
    ' "$log" || true
  done < <(rpm_diagnostic_mock_log_files "$result") | awk -F '\t' 'NF >= 2 && !seen[$1 "\t" $2]++'
}

rpm_diagnostic_transaction_sections_from_logs(){
  local result="$1" section pkg current="" found=0

  echo "=== package transaction sections from mock logs ==="
  while IFS=$'\t' read -r section pkg; do
    [[ -n "$section" && -n "$pkg" ]] || continue
    found=1
    if [[ "$section" != "$current" ]]; then
      current="$section"
      echo "[$section]"
    fi
    printf '%s\t%s\n' "$section" "$pkg"
  done < <(rpm_diagnostic_parse_transaction_logs "$result")

  ((found)) || echo "no transaction packages found in mock logs"
  echo
}

rpm_diagnostic_transaction_packages_from_logs(){
  rpm_diagnostic_parse_transaction_logs "$1"
}

rpm_diagnostic_scriptlet_failures_from_logs(){
  local result="$1" log line owner active

  echo "=== scriptlet / trigger failures from mock logs ==="
  while IFS= read -r log; do
    while IFS= read -r line; do
      if [[ "$line" =~ %([A-Za-z0-9_]+)\(([^\)]+)\) ]]; then
        owner="${BASH_REMATCH[1]}(${BASH_REMATCH[2]})"
        echo "trigger_owner\t$owner"
      fi
      case "$line" in
        *'scriptlet in rpm package '*)
          active="${line#*scriptlet in rpm package }"
          active="${active%%[[:space:]:,;]*}"
          echo "active_package\t$active"
          ;;
      esac
    done <"$log"
  done < <(rpm_diagnostic_mock_log_files "$result")
  echo
}

rpm_diagnostic_repoquery_whatprovides(){
  local requirement="$1"

  if command -v dnf5 >/dev/null 2>&1; then
    dnf5 -q repoquery --whatprovides "$requirement" --queryformat '%{name}-%{evr}.%{arch}' 2>&1 \
      || dnf5 -q repoquery --whatprovides "$requirement" 2>&1 \
      || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf -q repoquery --whatprovides "$requirement" --qf '%{name}-%{evr}.%{arch}' 2>&1 \
      || dnf -q repoquery --whatprovides "$requirement" 2>&1 \
      || true
  elif command -v repoquery >/dev/null 2>&1; then
    repoquery --whatprovides "$requirement" 2>&1 || true
  else
    echo "no repoquery-capable command is available"
  fi
}

rpm_diagnostic_srpm_chroot(){
  local srpm="$1" requirement count=0 limit="${MOCK_DIAGNOSTIC_REQUIREMENT_LIMIT:-300}"

  echo "=== SRPM requires / BuildRequires inside chroot ==="
  if [[ ! -f "$srpm" ]]; then
    echo "SRPM is not readable inside chroot: $srpm"
    echo
    return 0
  fi

  rpm -qpR "$srpm" 2>&1 | sort -u || true
  echo

  echo "=== provider lookup for SRPM requirements ==="
  rpm -qpR "$srpm" 2>/dev/null | sort -u | while IFS= read -r requirement; do
    [[ -n "$requirement" ]] || continue
    count=$((count + 1))
    if ((count > limit)); then
      echo "provider lookup stopped after $limit requirements"
      break
    fi

    echo "--- requirement: $requirement ---"
    rpm_diagnostic_repoquery_whatprovides "$requirement" | sed '/^[[:space:]]*$/d' | sort -u || true
    echo
  done
}

rpm_diagnostic_trigger_options(){
  printf '%s\n' \
    --scripts \
    --triggers \
    --filetriggers \
    --filetriggerin \
    --filetriggerun \
    --filetriggerpostun \
    --transfiletriggerin \
    --transfiletriggerun \
    --transfiletriggerpostun
}

rpm_diagnostic_query_package(){
  local mode="$1" package="$2" option

  while IFS= read -r option; do
    echo "--- rpm $mode $option $package ---"
    rpm "$mode" "$option" "$package" 2>&1 || true
  done < <(rpm_diagnostic_trigger_options)
}

rpm_diagnostic_cached_dirs(){
  local dir

  for dir in /var/cache/dnf/*/packages /var/cache/libdnf5/*/packages /var/cache/zypp/packages/*/*; do
    [[ -d "$dir" ]] || continue
    printf '%s\n' "$dir"
  done
}

rpm_diagnostic_cached_rpm_paths_for_candidate(){
  local candidate="$1" base dir rpm_file count=0 limit="${MOCK_DIAGNOSTIC_CACHED_RPM_LIMIT:-10}"

  base="$(rpm_diagnostic_base_candidate "$candidate")"

  while IFS= read -r dir; do
    for rpm_file in "$dir"/"$candidate"*.rpm "$dir"/"$base"-*.rpm; do
      [[ -f "$rpm_file" ]] || continue
      printf '%s\n' "$rpm_file"
      count=$((count + 1))
      ((count < limit)) || return 0
    done
  done < <(rpm_diagnostic_cached_dirs)
}

rpm_diagnostic_base_candidate(){
  local candidate="$1"

  candidate="${candidate##*/}"
  candidate="${candidate%.rpm}"
  candidate="${candidate%.src}"
  candidate="${candidate%.noarch}"
  candidate="${candidate%.x86_64}"
  candidate="${candidate%.aarch64}"
  candidate="${candidate%.i686}"
  candidate="${candidate%.armv7hl}"
  candidate="${candidate%.armv7hnl}"
  candidate="${candidate%.ppc64le}"
  candidate="${candidate%.s390x}"

  if [[ "$candidate" =~ ^(.+)-[0-9][^-]*-[^-]+$ ]]; then
    candidate="${BASH_REMATCH[1]}"
  fi

  printf '%s\n' "$candidate"
}

rpm_diagnostic_query_cached_rpms_for_candidate(){
  local candidate="$1" rpm_file found=0 count=0 limit="${MOCK_DIAGNOSTIC_CACHED_RPM_LIMIT:-5}"

  while IFS= read -r rpm_file; do
    found=1
    count=$((count + 1))
    ((count <= limit)) || return 0

    echo "=== cached RPM metadata: $rpm_file ==="
    rpm -qp --queryformat 'name=%{NAME}\nversion=%{VERSION}\nrelease=%{RELEASE}\narch=%{ARCH}\n' "$rpm_file" 2>&1 || true
    rpm_diagnostic_query_package -qp "$rpm_file"
    echo
  done < <(rpm_diagnostic_cached_rpm_paths_for_candidate "$candidate")

  ((found)) || echo "no cached RPM matched candidate: $candidate"
}

rpm_diagnostic_candidates_from_logs(){
  local result="$1" log line token candidate

  while IFS= read -r log; do
    while IFS= read -r line; do
      case "$line" in
        *'rpm package '*)
          token="${line#*rpm package }"
          token="${token%%[[:space:]:,;]*}"
          printf '%s\n' "$token"
          ;;
      esac

      while [[ "$line" =~ %[A-Za-z0-9_]+\(([^\)]+)\) ]]; do
        candidate="${BASH_REMATCH[1]}"
        printf '%s\n' "$candidate"
        line="${line#*${BASH_REMATCH[0]}}"
      done
    done <"$log"
  done < <(rpm_diagnostic_mock_log_files "$result") | awk 'NF && !seen[$0]++'
}


rpm_diagnostic_capability_name(){
  local value="$1"

  value="${value%$'\r'}"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  value="${value%%[[:space:]]*}"
  printf '%s\n' "$value"
}

rpm_diagnostic_write_transaction_package_metadata(){
  local pkg="$1"
  local out_dir="$2"
  local req_file prov_file rpm_file used=0

  req_file="$out_dir/$pkg.requires"
  prov_file="$out_dir/$pkg.provides"

  : >"$req_file"
  : >"$prov_file"

  if rpm -q "$pkg" >/dev/null 2>&1; then
    rpm -q --requires "$pkg" >>"$req_file" 2>&1 || true
    rpm -q --provides "$pkg" >>"$prov_file" 2>&1 || true
    used=1
  fi

  if ! ((used)); then
    while IFS= read -r rpm_file; do
      [[ -f "$rpm_file" ]] || continue
      echo "# cached rpm: $rpm_file" >>"$req_file"
      rpm -qp --requires "$rpm_file" >>"$req_file" 2>&1 || true
      echo "# cached rpm: $rpm_file" >>"$prov_file"
      rpm -qp --provides "$rpm_file" >>"$prov_file" 2>&1 || true
      used=1
    done < <(rpm_diagnostic_cached_rpm_paths_for_candidate "$pkg")
  fi

  if ! ((used)); then
    echo "# no installed or cached RPM metadata found for $pkg" >>"$req_file"
    echo "# no installed or cached RPM metadata found for $pkg" >>"$prov_file"
  fi
}

rpm_diagnostic_report_reverse_dependencies(){
  local transaction_path="$1" output_root="${2:-}"
  local metadata_dir pkg_file pkg section pkg req_pkg req_line req_cap prov_pkg prov_line prov_cap
  local packages=()

  echo "=== transaction dependency report ==="

  if [[ ! -r "$transaction_path" ]]; then
    echo "transaction package list is not readable inside chroot: $transaction_path"
    echo
    return 0
  fi

  if [[ -n "$output_root" && -d "$output_root" ]]; then
    metadata_dir="$output_root/transaction-rpm-metadata"
  else
    metadata_dir="/tmp/repository-builder-transaction-rpm-metadata.$$"
  fi
  rm -rf "$metadata_dir"
  mkdir -p "$metadata_dir"

  pkg_file="$metadata_dir/packages.tsv"
  : >"$pkg_file"

  while IFS=$'\t' read -r section pkg _; do
    [[ -n "$section" && -n "$pkg" ]] || continue
    case "$pkg" in Package|Arch|Version|Repository|Size) continue ;; esac
    if ! grep -Fqx "$pkg" "$metadata_dir/package-names" 2>/dev/null; then
      printf '%s\n' "$pkg" >>"$metadata_dir/package-names"
      printf '%s\t%s\n' "$section" "$pkg" >>"$pkg_file"
      packages+=("$pkg")
    fi
  done <"$transaction_path"

  if ! ((${#packages[@]})); then
    echo "no transaction packages were parsed"
    echo
    return 0
  fi

  echo "transaction packages: ${#packages[@]}"
  echo "metadata directory: $metadata_dir"
  echo

  for pkg in "${packages[@]}"; do
    rpm_diagnostic_write_transaction_package_metadata "$pkg" "$metadata_dir"
  done

  while IFS=$'\t' read -r section pkg; do
    [[ -n "$pkg" ]] || continue
    echo "--- package: $pkg [$section] ---"
    echo "provided capabilities used by other transaction packages:"
    local any=0

    while IFS= read -r prov_line; do
      [[ -n "$prov_line" && "$prov_line" != \#* ]] || continue
      prov_cap="$(rpm_diagnostic_capability_name "$prov_line")"
      [[ -n "$prov_cap" ]] || continue

      for req_pkg in "${packages[@]}"; do
        [[ "$req_pkg" != "$pkg" ]] || continue
        while IFS= read -r req_line; do
          [[ -n "$req_line" && "$req_line" != \#* ]] || continue
          req_cap="$(rpm_diagnostic_capability_name "$req_line")"
          [[ -n "$req_cap" ]] || continue
          if [[ "$req_cap" == "$prov_cap" ]]; then
            printf '  %s requires: %s  [matched provide: %s]\n' "$req_pkg" "$req_line" "$prov_line"
            any=1
          fi
        done <"$metadata_dir/$req_pkg.requires"
      done
    done <"$metadata_dir/$pkg.provides"

    ((any)) || echo "  none found by capability-name match"
    echo
  done <"$pkg_file"
}

rpm_diagnostic_check_trigger_commands(){
  local candidate="$1" trigger_output command_path command_name seen_file="/tmp/repository-builder-trigger-commands.$$"

  : >"$seen_file"
  trigger_output="$(
    rpm -q --triggers "$candidate" 2>/dev/null || true
    rpm -q --filetriggers "$candidate" 2>/dev/null || true
    rpm -q --transfiletriggerin "$candidate" 2>/dev/null || true
  )"
  [[ -n "$trigger_output" ]] || {
    rm -f "$seen_file"
    return 0
  }

  echo "=== trigger command availability: $candidate ==="
  while [[ "$trigger_output" =~ rpm\.execute\(\"([^\"]+)\" ]]; do
    command_path="${BASH_REMATCH[1]}"
    trigger_output="${trigger_output#*${BASH_REMATCH[0]}}"
    grep -Fqx "$command_path" "$seen_file" 2>/dev/null && continue
    printf '%s\n' "$command_path" >>"$seen_file"

    if [[ "$command_path" == /* ]]; then
      if [[ -x "$command_path" ]]; then
        echo "$command_path: present executable"
      elif [[ -e "$command_path" ]]; then
        echo "$command_path: present but not executable"
      else
        echo "$command_path: missing"
      fi
    else
      command_name="$command_path"
      if command -v "$command_name" >/dev/null 2>&1; then
        printf '%s: ' "$command_name"
        command -v "$command_name"
      else
        echo "$command_name: missing"
      fi
    fi
  done
  rm -f "$seen_file"
  echo
}
cmd_mock_diagnostics_chroot(){
  local context="${1:-}" srpm_path="" transaction_path="" output_root="" candidate

  if (($#)); then
    shift
  fi

  while (($#)); do
    case "${1:-}" in
      --srpm)
        srpm_path="${2:-}"
        shift 2
        ;;
      --transaction)
        transaction_path="${2:-}"
        shift 2
        ;;
      --output-root)
        output_root="${2:-}"
        shift 2
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
  done

  set +e

  echo "=== diagnostic context ==="
  echo "$context"
  echo

  if [[ -n "$srpm_path" ]]; then
    rpm_diagnostic_srpm_chroot "$srpm_path"
    echo
  fi

  if [[ -n "$transaction_path" ]]; then
    rpm_diagnostic_report_reverse_dependencies "$transaction_path" "$output_root"
    echo
  fi

  echo "=== script/trigger candidates from mock logs ==="
  if (($#)); then
    printf '%s\n' "$@"
  else
    echo "none"
  fi
  echo

  for candidate in "$@"; do
    [[ -n "$candidate" ]] || continue

    echo "=== installed RPM scripts/triggers: $candidate ==="
    rpm_diagnostic_query_package -q "$candidate"
    echo
    rpm_diagnostic_check_trigger_commands "$candidate"

    echo "=== cached RPM scripts/triggers: $candidate ==="
    rpm_diagnostic_query_cached_rpms_for_candidate "$candidate"
    echo
  done
}

rpm_dump_mock_diagnostics(){
  local result="$1" target="$2" phase="$3" context="${4:-}" srpm="${5:-}" local_repo="${6:-}" lines="${MOCK_LOG_TAIL_LINES:-200}"
  local mock_args=() log diagnostic_command quoted_value candidate bind_spec srpm_dir srpm_chroot_path transaction_file

  mkdir -p "$result"
  log="$result/chroot-diagnostics.log"
  transaction_file="$result/transaction-packages.tsv"
  rpm_diagnostic_transaction_packages_from_logs "$result" >"$transaction_file" || : >"$transaction_file"
  rpm_mock_args_array "$target" "$phase" mock_args

  if [[ -n "$local_repo" ]]; then
    mock_args+=(--addrepo "file://$local_repo")
  fi

  printf -v quoted_value '%q' "$context"
  diagnostic_command="bash /tmp/publisher/repository_builder.sh mock-diagnostics-chroot $quoted_value"

  bind_spec="[('$ROOT', '/tmp/publisher'),('$result', '/tmp/diagnostic-result')"

  printf -v quoted_value '%q' /tmp/diagnostic-result/transaction-packages.tsv
  diagnostic_command+=" --transaction $quoted_value"
  printf -v quoted_value '%q' /tmp/diagnostic-result
  diagnostic_command+=" --output-root $quoted_value"

  if [[ -n "$srpm" && -f "$srpm" ]]; then
    srpm_dir="$(dirname "$srpm")"
    srpm_chroot_path="/tmp/diagnostic-srpm/$(basename "$srpm")"
    bind_spec+=",('$srpm_dir', '/tmp/diagnostic-srpm')"
    printf -v quoted_value '%q' "$srpm_chroot_path"
    diagnostic_command+=" --srpm $quoted_value"
  fi

  bind_spec+="]"

  diagnostic_command+=" --"
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    printf -v quoted_value '%q' "$candidate"
    diagnostic_command+=" $quoted_value"
  done < <(rpm_diagnostic_candidates_from_logs "$result")

  {
    echo "=== diagnostic context ==="
    echo "target=$target"
    echo "phase=$phase"
    echo "message=$context"
    echo "srpm=${srpm:-}"
    echo "local_repo=${local_repo:-}"
    echo
    rpm_diagnostic_transaction_sections_from_logs "$result"
    rpm_diagnostic_scriptlet_failures_from_logs "$result"
    echo "=== transaction package list ==="
    if [[ -s "$transaction_file" ]]; then
      cat "$transaction_file"
    else
      echo "none"
    fi
    echo
  } >"$log"

  if ! mock -r "$target" "${mock_args[@]}" \
    --enable-plugin bind_mount \
    --plugin-option "bind_mount:dirs=$bind_spec" \
    --chroot "$diagnostic_command" >>"$log" 2>&1;
  then
    echo "=== unable to run mock diagnostics inside chroot ===" >>"$log"
  fi

  echo "--- chroot-diagnostics.log (last $lines lines) ---" >&2
  tail -n "$lines" "$log" >&2 || true
}

rpm_mock_args_array(){
  local target="$1" phase="$2" family arch
  local -n out_args="$3"

  out_args=()
  IFS=$'	' read -r family arch < <(split_target "$target")
  load_target rpm "$family" "$arch"

  if [[ -n "${TARGET_RPM_MOCK_CONFIG_OPTS:-}" ]]; then
    read -r -a out_args <<<"$TARGET_RPM_MOCK_CONFIG_OPTS"
  fi

  if [[ -n "${TARGET_RPM_CHROOT_SETUP_CMD:-}" ]]; then
    out_args+=(--config-opts "chroot_setup_cmd=$TARGET_RPM_CHROOT_SETUP_CMD")
  fi

  case "$phase" in
    graph|build) ;;
    *) die "Unknown mock phase: $phase" ;;
  esac
}
rpm_mock_with_args(){
  local result="$1" msg="$2" target="$3" phase="$4"
  shift 4

  local mock_args=()
  rpm_mock_args_array "$target" "$phase" mock_args

  mkdir -p "$result"
  if mock -r "$target" "${mock_args[@]}" "$@"; then
    return 0
  fi

  rpm_dump_mock_failure "$result" "$msg"
  rpm_dump_mock_diagnostics "$result" "$target" "$phase" "$msg" "${RPM_DIAGNOSTIC_SRPM:-}" "${RPM_DIAGNOSTIC_LOCAL_REPO:-}"
  die "$msg"
}
rpm_mock_out_with_binds(){
  local result="$1" msg="$2" target="$3" phase="$4" bind_count="$5"
  shift 5

  local mock_args=() bind_spec="[" separator="" host_path chroot_path out

  while ((bind_count > 0)); do
    host_path="$1"
    chroot_path="$2"
    shift 2
    bind_spec+="$separator('$host_path', '$chroot_path')"
    separator=","
    bind_count=$((bind_count - 1))
  done
  bind_spec+="]"

  rpm_mock_args_array "$target" "$phase" mock_args
  mock_args+=(
    --enable-plugin bind_mount
    --plugin-option "bind_mount:dirs=$bind_spec"
  )

  mkdir -p "$result"
  if out="$(mock -r "$target" "${mock_args[@]}" "$@" 2>&1)"; then
    printf '%s
' "$out"
    return 0
  fi

  printf '%s
' "$out" >&2
  rpm_dump_mock_failure "$result" "$msg"
  rpm_dump_mock_diagnostics "$result" "$target" "$phase" "$msg" "${RPM_DIAGNOSTIC_SRPM:-}" "${RPM_DIAGNOSTIC_LOCAL_REPO:-}"
  die "$msg"
}
rpm_prepare_effective(){
  local src_root="$1" subdir="$2" spec_name="$3" layer_root="$4" family="$5" target="$6"
  local pkg_dir spec_path layered base

  pkg_dir="$src_root/$subdir"
  spec_path="$pkg_dir/$spec_name"

  if ! layered="$(layered_best_file "$layer_root" "$family" "$target" specs "$spec_name")"; then
    layered=""
  fi

  if [[ -n "$layered" ]]; then
    mkdir -p "$pkg_dir"
    cp "$layered" "$spec_path"
    [[ -d "$src_root/.git" ]] && (cd "$src_root" && git add -- "$subdir/$spec_name")
  fi

  [[ -d "$pkg_dir" ]] || die "Missing subdir: $subdir"
  [[ -f "$spec_path" ]] || die "Missing spec: $spec_path"

  base="${spec_name%.spec}"
  apply_git_patches "$src_root" "$layer_root" "$family" "$target" "$spec_name.patch"
  copy_layered_files "$pkg_dir" "$layer_root" "$family" "$target" patches "$base.source.patch"
  apply_sed_replacements "$spec_path" "$layer_root" "$family" "$target"
  prepend_layered "$spec_path" "$layer_root" "$family" "$target" macros '*.macros'

  printf '%s' "$spec_path"
}
rpm_build_srpm(){
  local target="$1" unique="$2" result="$3" pkg_dir="$4" spec_path="$5" url="${6:-}"
  local args=()

  args=(
    --uniqueext "$unique"
    --resultdir "$result"
    --enable-network
    --buildsrpm
    --spec "$spec_path"
    --sources "$pkg_dir"
  )
  [[ -n "$url" ]] && args+=(--define "url $url")

  rpm_mock_with_args \
    "$result" \
    "mock SRPM build failed for $(basename "$spec_path") on $target" \
    "$target" \
    build \
    "${args[@]}"
}
rpm_rebuild(){
  local target="$1" unique="$2" result="$3" local_repo="$4" srpm="$5" url="${6:-}"
  local common_args=() dep_args=() rebuild_args=()

  common_args=(
    --uniqueext "$unique"
    --enable-network
    --addrepo "file://$local_repo"
    --resultdir "$result"
  )
  [[ -n "$url" ]] && common_args+=(--define "url $url")

  dep_args=("${common_args[@]}" --installdeps "$srpm")
  rebuild_args=("${common_args[@]}" --rebuild "$srpm")

  rpm_diagnostic_write_srpm_host "$result" "$srpm"

  rpm_mock_with_args "$result" "mock init failed for $target" "$target" build --init
  RPM_DIAGNOSTIC_SRPM="$srpm" RPM_DIAGNOSTIC_LOCAL_REPO="$local_repo" \
    rpm_mock_with_args "$result" "mock build dependency install failed for $(basename "$srpm")" "$target" build "${dep_args[@]}"
  RPM_DIAGNOSTIC_SRPM="$srpm" RPM_DIAGNOSTIC_LOCAL_REPO="$local_repo" \
    rpm_mock_with_args "$result" "mock rebuild failed for $(basename "$srpm")" "$target" build "${rebuild_args[@]}"
}
cmd_rpm_list_sources_chroot(){
  local spec_dir="${1:-}"
  local spec_name="${2:-}"
  local output_name="${3:-}"
  local spec expanded output line source count=0

  (($# == 3)) || die "Usage: repository_builder.sh rpm-list-sources-chroot SPEC_DIR SPEC_NAME OUTPUT_NAME"
  [[ -n "$spec_dir" && "$spec_dir" == /* ]] || die "RPM source-list chroot spec dir must be an absolute path"
  [[ -n "$spec_name" && "$spec_name" != */* ]] || die "RPM source-list spec name must be a file name"
  [[ -n "$output_name" && "$output_name" != */* ]] || die "RPM source-list output name must be a file name"

  spec="$spec_dir/$spec_name"
  output="$spec_dir/$output_name"
  [[ -d "$spec_dir" ]] || die "RPM source-list directory is missing inside chroot: $spec_dir"
  [[ -f "$spec" ]] || die "RPM source-list spec is missing inside chroot: $spec"

  command -v rpmspec >/dev/null 2>&1 || die "rpmspec is not installed in the mock chroot"

  cd "$spec_dir"
  expanded=".repository-builder-expanded-spec.$$"
  : >"$output"

  if ! rpmspec -P "./$spec_name" >"$expanded"; then
    rm -f "$expanded" "$output"
    die "rpmspec failed to expand $spec_name inside the mock chroot"
  fi

  while IFS= read -r line; do
    line="${line%$'\r'}"

    case "$line" in
      Source:*) source="${line#*:}" ;;
      Source[0-9]*:*) source="${line#*:}" ;;
      source:*) source="${line#*:}" ;;
      source[0-9]*:*) source="${line#*:}" ;;
      *) continue ;;
    esac

    source="${source#"${source%%[![:space:]]*}"}"
    source="${source%"${source##*[![:space:]]}"}"
    [[ -n "$source" ]] || die "Empty Source entry in expanded spec: $spec_name"

    printf '%s\n' "$source" >>"$output"
    count=$((count + 1))
  done <"$expanded"

  rm -f "$expanded"
  echo "Expanded $count Source entries from $spec_name" >&2
}

rpm_source_download_filename(){
  local source="$1" download_url filename

  download_url="${source%%#*}"

  if [[ "$source" == *'#/'* ]]; then
    filename="${source##*#/}"
  elif [[ "$source" == *'#'* && "${source##*#}" != "" ]]; then
    filename="${source##*#}"
  else
    filename="${download_url%%\?*}"
    filename="${filename##*/}"
  fi

  [[ -n "$download_url" ]] || die "Cannot derive download URL from source: $source"
  [[ -n "$filename" && "$filename" != . && "$filename" != .. && "$filename" != */* ]] || \
    die "Cannot derive a safe local filename from source URL: $source"

  printf '%s\t%s\n' "$download_url" "$filename"
}

rpm_download_expanded_sources_host(){
  local spec_dir="$1" source_list="$2"
  local cache_dir="/package-cache/source-downloads"
  local source download_url filename url_hash cache_file tmp dest

  [[ -d "$spec_dir" ]] || die "Missing RPM source directory: $spec_dir"
  [[ -f "$source_list" ]] || die "Missing expanded RPM source list: $source_list"
  command -v curl >/dev/null 2>&1 || die "curl is not installed in the host builder container"
  mkdir -p "$cache_dir"

  while IFS= read -r source; do
    source="${source%$'\r'}"
    [[ -n "$source" ]] || continue

    case "$source" in
      http://*|https://*|ftp://*)
        IFS=$'\t' read -r download_url filename < <(rpm_source_download_filename "$source")
        url_hash="$(printf '%s' "$source" | sha256_lines)"
        cache_file="$cache_dir/${url_hash:0:32}-$filename"
        tmp="$cache_file.tmp.$$"
        dest="$spec_dir/$filename"

        if [[ -s "$cache_file" ]]; then
          echo "Using cached source: $source -> $filename" >&2
        else
          echo "Downloading source: $download_url -> $filename" >&2
          rm -f "$tmp"
          if ! curl -fL --retry 3 --retry-delay 2 -o "$tmp" "$download_url"; then
            rm -f "$tmp"
            die "Failed to download source: $source"
          fi
          if [[ ! -s "$tmp" ]]; then
            rm -f "$tmp"
            die "Downloaded source is empty: $source"
          fi
          mv "$tmp" "$cache_file"
        fi

        cp "$cache_file" "$dest"
        ;;
      *://*)
        die "Unsupported remote source URL scheme after RPM macro expansion: $source"
        ;;
      /*)
        [[ -f "$source" ]] || die "Expanded RPM Source file is missing: $source"
        echo "Using local source: $source" >&2
        ;;
      *)
        [[ -f "$spec_dir/$source" ]] || die "Expanded RPM Source file is missing: $spec_dir/$source"
        echo "Using local source: $source" >&2
        ;;
    esac
  done <"$source_list"
}

rpm_fetch_sources_in_mock(){
  local target="$1" result="$2" spec_dir="$3" spec_name="$4"
  local chroot_spec_dir="/tmp/rpm-source-fetch" list_name list_path quoted_dir quoted_spec quoted_list command

  [[ -d "$spec_dir" ]] || die "Missing RPM source directory: $spec_dir"
  [[ -f "$spec_dir/$spec_name" ]] || die "Missing RPM spec for source fetch: $spec_dir/$spec_name"

  list_name=".repository-builder-sources.$RANDOM.$$"
  list_path="$spec_dir/$list_name"
  rm -f "$list_path"

  printf -v quoted_dir '%q' "$chroot_spec_dir"
  printf -v quoted_spec '%q' "$spec_name"
  printf -v quoted_list '%q' "$list_name"
  command="bash /tmp/publisher/repository_builder.sh rpm-list-sources-chroot $quoted_dir $quoted_spec $quoted_list"

  rpm_mock_with_args \
    "$result/source-fetch" \
    "mock source-list init failed for $spec_name on $target" \
    "$target" \
    build \
    --init

  rpm_mock_out_with_binds \
    "$result/source-fetch" \
    "mock source expansion failed for $spec_name on $target" \
    "$target" \
    build \
    2 \
    "$spec_dir" \
    "$chroot_spec_dir" \
    "$ROOT" \
    /tmp/publisher \
    --chroot "$command" >/dev/null

  [[ -f "$list_path" ]] || die "Mock did not produce expanded source list for $spec_name"
  rpm_download_expanded_sources_host "$spec_dir" "$list_path"
  rm -f "$list_path"
}
rpm_copy_one(){
  local file="$1" repo="$2" source_repo="$3" local_repo="$4"
  local dest_name

  dest_name="$(basename "$file")"

  if [[ "$file" == *.src.rpm ]]; then
    cp "$file" "$source_repo/$dest_name"
  else
    cp "$file" "$repo/$dest_name"
  fi

  cp "$file" "$local_repo/$dest_name"
}
rpm_copy_artifacts(){
  local from="$1" repo="$2" source_repo="$3" local_repo="$4" recursive="${5:-0}"
  local file

  if [[ "$recursive" == 1 ]]; then
    while IFS= read -r file; do
      rpm_copy_one "$file" "$repo" "$source_repo" "$local_repo"
    done < <(find "$from" -name '*.rpm' -type f)
  else
    for file in "$from"/*.rpm; do
      [[ -e "$file" ]] || continue
      rpm_copy_one "$file" "$repo" "$source_repo" "$local_repo"
    done
  fi

  createrepo_c --update "$local_repo"
}

rpm_queue_fingerprint(){
  local target="$1"
  local family="$2"
  local arch="$3"
  local root="$4"
  local spec="$5"
  local source_id="$6"
  local subdir="$7"
  local base layered file

  base="${spec%.spec}"

  {
    printf '%s\n' "$source_id" "$(source_tree_fingerprint "$root")" "$subdir" "$spec" "$target" "$arch"

    if layered="$(layered_best_file "$root" "$family" "$target" specs "$spec")"; then
      [[ -n "$layered" ]] && sha256_file "$layered"
    fi

    while IFS= read -r file; do
      sha256_file "$file"
    done < <(layered_existing_files "$root" "$family" "$target" patches "$spec.patch")

    while IFS= read -r file; do
      sha256_file "$file"
    done < <(layered_existing_files "$root" "$family" "$target" patches "$base.source.patch")

    while IFS= read -r file; do
      sha256_file "$file"
    done < <(layered_files "$root" "$family" "$target" 'macros/*.macros')

    while IFS= read -r file; do
      sha256_file "$file"
    done < <(layered_files "$root" "$family" "$target" 'replacements/*.sed')
  } | sha256_lines
}
rpm_build_queued(){
  local qfile="$1" target="$2" family="$3" arch="$4" repo_path="$5"
  local build_id cache work srpm_dir result repo src_repo local_repo root fp spec_path spec_dir url srpm
  load_queue "$qfile"
  build_id="${SUBDIR//\//_}"
  cache="/package-cache/rpm/$PRIMARY_APP/$target/$build_id"
  work="/work/rpm-build/$target/$build_id"
  srpm_dir="/work/rpm-srpm/$target/$build_id"
  result="/work/rpm-result/$target/$build_id"
  repo="$PUBLIC_DIR/$repo_path"
  src_repo="$repo/source"
  local_repo="/work/localrepo-$target"
  root="/work/work/${SOURCE_ID:-$PRIMARY_APP}"

  mkdir -p "$cache" "$result" "$repo" "$src_repo" "$local_repo"
  createrepo_c "$local_repo"
  fp="$(rpm_queue_fingerprint "$target" "$family" "$arch" "$root" "$SPEC" "${SOURCE_ID:-$PRIMARY_APP}" "$SUBDIR")"
  if [[ -f "$cache/.fingerprint" && "$(cat "$cache/.fingerprint")" == "$fp" ]] && compgen -G "$cache/*.rpm" >/dev/null;
  then
    rpm_copy_artifacts "$cache" "$repo" "$src_repo" "$local_repo"
    return 0
  fi

  fresh_dir "$work";
  fresh_dir "$srpm_dir"
  copy_source_tree "$work/src" "$root"
  if ! spec_path="$(rpm_prepare_effective "$work/src" "$SUBDIR" "$SPEC" "$root" "$family" "$target")"; then
    die "RPM spec preparation failed for $SPEC on $target"
  fi
  spec_dir="$(dirname "$spec_path")"
  url="https://example.invalid/$SPEC"

  rpm_fetch_sources_in_mock "$target" "$result" "$spec_dir" "$SPEC"

  rpm_build_srpm "$target" "srpm-$target-$build_id" "$srpm_dir" "$spec_dir" "$spec_path" "$url"
  srpm="$(find "$srpm_dir" -maxdepth 1 -name '*.src.rpm' -print -quit)"
  [[ -n "$srpm" ]] || die "No SRPM created for $target/$build_id"
  rpm_rebuild "$target" "$target-$build_id" "$result" "$local_repo" "$srpm" "$url"
  rm -f "$cache"/*.rpm "$cache"/*.src.rpm
  find "$result" -name '*.rpm' -type f -exec cp {} "$cache/" \;
  printf '%s' "$fp" >"$cache/.fingerprint"
  rpm_copy_artifacts "$result" "$repo" "$src_repo" "$local_repo" 1
}

rpm_sign_index_dir(){
  local dir="$1"
  local pattern="$2"
  local file

  compgen -G "$dir/$pattern" >/dev/null || return 0

  for file in "$dir"/$pattern; do
    rpmsign --addsign "$file"
    rpm --checksig "$file"
  done

  createrepo_c "$dir"
  gpg --batch --yes --armor --detach-sign "$dir/repodata/repomd.xml"
}
rpm_publish(){
  local target="$1"
  local repo_path="$2"
  local repo="$PUBLIC_DIR/$repo_path"

  rpm_sign_index_dir "$repo" '*.rpm'
  rpm_sign_index_dir "$repo/source" '*.src.rpm'
}
rpm_write_repo(){
  local repo_id="$1"
  local repo_file="$2"
  local repo_path="$3"
  local label="$4"

  cat >"$PUBLIC_DIR/$repo_file" <<EOF
[$repo_id]
name=$label
baseurl=https://${REPO_OWNER:?}.github.io/${REPO_NAME:?}/$repo_path
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://${REPO_OWNER}.github.io/${REPO_NAME}/GPG-KEY-repo
EOF

  metadata_append_repo "$repo_id" "$repo_file" "$repo_path" "$label"
}
rpm_graph_node_id(){
  load_queue "$1"
  safe_id "$PACKAGE-$SUBDIR"
}
rpm_graph_collect_node(){
  local qfile="$1"
  local graph="$2"
  local target="$3"
  local family="$4"
  local node="$5"
  local root prepared spec_path

  load_queue "$qfile"

  root="/work/work/${SOURCE_ID:-$PRIMARY_APP}"
  prepared="$graph/prepared/$node"

  copy_source_tree "$prepared" "$root"
  if ! spec_path="$(rpm_prepare_effective "$prepared" "$SUBDIR" "$SPEC" "$root" "$family" "$target")"; then
    die "RPM graph spec preparation failed for $SPEC on $target"
  fi
  printf '%s' "$spec_path" >"$graph/$node.specpath"
}
rpm_graph_prepare_chroot_tree(){
  local graph="$1"
  local chroot_tree node spec_path dest

  chroot_tree="$graph/chroot/package-graph"
  rm -rf "$graph/chroot"
  mkdir -p "$chroot_tree/specs"

  cp "$graph/nodes.tsv" "$chroot_tree/nodes.tsv"

  while IFS= read -r node; do
    IFS= read -r spec_path <"$graph/$node.specpath"
    dest="$chroot_tree/specs/$node.spec"
    cp "$spec_path" "$dest"
  done <"$graph/nodes.tsv"
}
rpm_graph_chroot_filter_output(){
  local record="$1" node="$2" line
  local -A seen=()

  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -n "${line//[[:space:]]/}" ]] || continue

    case "$line" in
      warning:*|error:*|Mock\ Version:*|Start:*|Finish:*|Executing\(*|INFO:*|DEBUG:*|Wrote:*|Child\ return\ code\ was:*|ENTER*|LEAVE*|No\ matches\ found*)
        continue
        ;;
    esac

    [[ -z "${seen[$line]+x}" ]] || continue
    seen[$line]=1
    printf '%s\t%s\t%s\n' "$record" "$node" "$line"
  done
}
rpm_graph_chroot_emit_query(){
  local record="$1" node="$2" spec="$3" output
  shift 3

  if ! output="$("$@" "$spec" 2>&1)"; then
    printf '%s\n' "$output" >&2
    return 1
  fi

  rpm_graph_chroot_filter_output "$record" "$node" <<<"$output"
}
cmd_rpm_graph_query_chroot(){
  local graph_dir="${1:-/tmp/package-graph}" node spec

  while IFS= read -r node; do
    spec="$graph_dir/specs/$node.spec"

    rpm_graph_chroot_emit_query P "$node" "$spec" rpmspec -q --qf '%{NAME}\n'
    rpm_graph_chroot_emit_query P "$node" "$spec" rpmspec -q --qf '[%{PROVIDENAME}\n]'
    rpm_graph_chroot_emit_query B "$node" "$spec" rpmspec -q --buildrequires
    rpm_graph_chroot_emit_query R "$node" "$spec" rpmspec -q --requires
  done <"$graph_dir/nodes.tsv"
}
rpm_graph_finalize(){
  local graph="$1" target="$2" family="$3" out

  : >"$graph/providers.tsv"
  : >"$graph/raw-builddeps.tsv"
  : >"$graph/raw-runtimedeps.tsv"

  rpm_mock_with_args "$graph/mock-init" "mock graph init failed for $target" "$target" graph --init

  rpm_graph_prepare_chroot_tree "$graph"

  out="$graph/mock-graph-query.tsv"
  rpm_mock_out_with_binds \
    "$graph/mock-query" \
    "mock graph query failed for $target" \
    "$target" \
    graph \
    2 \
    "$graph/chroot/package-graph" \
    /tmp/package-graph \
    "$ROOT" \
    /tmp/publisher \
    --chroot "bash /tmp/publisher/repository_builder.sh rpm-graph-query-chroot /tmp/package-graph" >"$out"

  awk -F '\t' '$1=="P" && NF>=3{print $3 "\t" $2}' "$out" >>"$graph/providers.tsv"
  awk -F '\t' '$1=="B" && NF>=3{print $2 "\t" $3}' "$out" >>"$graph/raw-builddeps.tsv"
  awk -F '\t' '$1=="R" && NF>=3{print $2 "\t" $3}' "$out" >>"$graph/raw-runtimedeps.tsv"

  sort_unique_file "$graph/providers.tsv"
  sort_unique_file "$graph/raw-builddeps.tsv"
  sort_unique_file "$graph/raw-runtimedeps.tsv"

  graph_validate_unique_providers "$graph/providers.tsv" RPM

  graph_emit_edges "$graph/providers.tsv" "$graph/raw-builddeps.tsv" "$graph/builddeps.tsv"
  graph_emit_edges "$graph/providers.tsv" "$graph/raw-runtimedeps.tsv" "$graph/runtimedeps.tsv"
}

rpm_prepare_target_queue(){
  local target="$1"
  local family="$2"
  local qdir="/work/package-build-queue-target/rpm/$target"
  local source_id root spec_name package

  fresh_dir "$qdir"

  for source_id in "${APPS[@]}"; do
    root="/work/work/$source_id"

    while IFS= read -r spec_name; do
      package="${spec_name%.spec}"
      queue_write \
        "$qdir" \
        "$(safe_id "$source_id-layered-$package")" \
        QUEUE_TYPE=rpm \
        SUBDIR="$package" \
        SPEC="$spec_name" \
        PACKAGE="$package" \
        SOURCE_ID="$source_id" >/dev/null
      metadata_append_package "$package"
    done < <(layered_names "$root" "$family" "$target" specs '*.spec')
  done

  printf '%s' "$qdir"
}

rpm_build_targets(){
  local target family arch repo_path repo_id repo_file label qdir qfile
  local qfiles=()

  while IFS= read -r target; do
    echo "==> RPM target: $target"
    IFS=$'\t' read -r family arch repo_path repo_id repo_file label < <(repo_info rpm "$PRIMARY_APP" "$target")

    mkdir -p "$PUBLIC_DIR/$repo_path/source" "/work/localrepo-$target"
    createrepo_c "/work/localrepo-$target"

    qdir="$(rpm_prepare_target_queue "$target" "$family")"
    ordered_queue_files \
      qfiles \
      "/work/package-graph/rpm/$target" \
      "$target" \
      "$family" \
      "$qdir" \
      "No layered RPM specs were found for $target" \
      rpm

    for qfile in "${qfiles[@]}"; do
      rpm_build_queued "$qfile" "$target" "$family" "$arch" "$repo_path"
    done

    rpm_publish "$target" "$repo_path"
    rpm_write_repo "$repo_id" "$repo_file" "$repo_path" "$label"
    metadata_append targets.txt "$target"
  done < <(targets_list)
}
deb_prepare_effective(){
  local dest="$1"
  local src="$2"
  local target="$3"
  local family="$4"
  local package="$5"
  local root="$6"

  copy_source_tree "$dest" "$src"
  apply_git_patches "$dest" "$root" "$family" "$target" debian.patch "$package.debian.patch"

  [[ -d "$dest/debian" ]] || die "Missing debian/ directory for $package"
  apply_sed_replacements "$dest/debian/control" "$root" "$family" "$target"
}
deb_graph_node_id(){
  load_queue "$1"
  safe_id "${PACKAGE:-${SOURCE_ID:-package}}-${SUBDIR:-.}"
}
deb_dep_names(){
  sed -E 's/\([^)]*\)//g; s/\[[^]]*\]//g; s/<[^>]*>//g; s/\|/,/g; s/,/\n/g' \
    | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]].*//' \
    | sed '/^$/d' \
    | sort -u
}
deb_control_graph(){
  local control="$1"
  local node="$2"
  local providers="$3"
  local builddeps="$4"
  local runtimedeps="$5"
  local kind deps dep

  awk '
    BEGIN { RS=""; FS="\n" }
    {
      gsub(/\n[ \t]+/, " ")
      count = split($0, lines, "\n")
      source = ""
      package = ""

      for (i = 1; i <= count; i++) {
        if (lines[i] ~ /^Source:[[:space:]]*/) {
          source = lines[i]
          sub(/^Source:[[:space:]]*/, "", source)
          print "P\t" source
        }

        if (lines[i] ~ /^Package:[[:space:]]*/) {
          package = lines[i]
          sub(/^Package:[[:space:]]*/, "", package)
          print "P\t" package
        }

        if (lines[i] ~ /^Build-Depends(-Arch|-Indep)?:[[:space:]]*/) {
          deps = lines[i]
          sub(/^Build-Depends(-Arch|-Indep)?:[[:space:]]*/, "", deps)
          print "B\t" deps
        }

        if (lines[i] ~ /^(Pre-Depends|Depends):[[:space:]]*/) {
          deps = lines[i]
          sub(/^(Pre-Depends|Depends):[[:space:]]*/, "", deps)
          print "R\t" deps
        }
      }
    }
  ' "$control" | while IFS=$'\t' read -r kind deps; do
    case "$kind" in
      P)
        [[ -n "$deps" ]] && printf '%s\t%s\n' "$deps" "$node" >>"$providers"
        ;;
      B)
        printf '%s\n' "$deps" | deb_dep_names | while IFS= read -r dep; do
          printf '%s\t%s\n' "$node" "$dep" >>"$builddeps"
        done
        ;;
      R)
        printf '%s\n' "$deps" | deb_dep_names | while IFS= read -r dep; do
          printf '%s\t%s\n' "$node" "$dep" >>"$runtimedeps"
        done
        ;;
    esac
  done
}
deb_graph_collect_node(){
  local qfile="$1"
  local graph="$2"
  local target="$3"
  local family="$4"
  local node="$5"
  local package source_id queue_work prepared source_dir layer_root

  load_queue "$qfile"

  package="${PACKAGE:-${SOURCE_ID:-package}}"
  source_id="${SOURCE_ID:-$PRIMARY_APP}"
  queue_work="$graph/queue-src/$node"
  prepared="$graph/prepared/$node"

  source_dir="$(queue_source_dir "$CLONE_URL" "${REF:-main}" "$source_id" "${SUBDIR:-.}" "$queue_work")"
  layer_root="$(queue_layer_root "$source_id" "$queue_work")"

  deb_prepare_effective "$prepared" "$source_dir" "$target" "$family" "$package" "$layer_root"
  [[ -f "$prepared/debian/control" ]] || die "Missing debian/control for graph node $node"

  deb_control_graph "$prepared/debian/control" "$node" "$graph/providers.raw.tsv" "$graph/raw-builddeps.tsv" "$graph/raw-runtimedeps.tsv"
}
deb_graph_finalize(){
  local graph="$1"

  sort -u "$graph/providers.raw.tsv" >"$graph/providers.tsv"
  graph_validate_unique_providers "$graph/providers.tsv" DEB
  graph_emit_edges "$graph/providers.tsv" "$graph/raw-builddeps.tsv" "$graph/builddeps.tsv"
  graph_emit_edges "$graph/providers.tsv" "$graph/raw-runtimedeps.tsv" "$graph/runtimedeps.tsv"
}
deb_ensure_pbuilder(){
  local target="$1"
  local suite="$2"
  local arch="$3"
  local mirror="$4"
  local base="/package-cache/deb/pbuilder/$target/base.tgz"

  mkdir -p "$(dirname "$base")"

  if [[ ! -f "$base" ]]; then
    pbuilder --create --basetgz "$base" --distribution "$suite" --architecture "$arch" --mirror "$mirror" --debootstrapopts --variant=buildd
  else
    pbuilder --update --basetgz "$base"
  fi

  printf '%s' "$base"
}
deb_build_queued(){
  local qfile="$1"
  local target="$2"
  local family="$3"
  local arch="$4"
  local repo_path="$5"
  local package source_id queue_work build result repo source_dir layer_root dsc base suite mirror

  load_queue "$qfile"

  package="${PACKAGE:-${SOURCE_ID:-package}}"
  source_id="${SOURCE_ID:-$PRIMARY_APP}"
  queue_work="/work/deb-source-src/$target/$package"
  build="/work/deb-build/$target/$package"
  result="/work/deb-result/$target/$package"
  repo="$PUBLIC_DIR/$repo_path"

  mkdir -p "$repo/pool" "$build" "$result"

  source_dir="$(queue_source_dir "$CLONE_URL" "${REF:-main}" "$source_id" "${SUBDIR:-.}" "$queue_work")"
  layer_root="$(queue_layer_root "$source_id" "$queue_work")"

  deb_prepare_effective "$build/src" "$source_dir" "$target" "$family" "$package" "$layer_root"
  (cd "$build/src" && dpkg-buildpackage -S -us -uc)

  dsc="$(find "$build" -maxdepth 1 -name '*.dsc' -print -quit)"
  [[ -n "$dsc" ]] || die "No DSC created for $package"

  load_target deb "$family" "$arch"
  suite="$(expand_template "$TARGET_DEB_SUITE_TEMPLATE" "$family" "$arch" "$TARGET_DEB_SUITE_STRIP_PREFIX")"
  mirror="$TARGET_DEB_MIRROR"
  base="$(deb_ensure_pbuilder "$target" "$suite" "$arch" "$mirror")"

  pbuilder --build --basetgz "$base" --buildresult "$result" "$dsc"
  cp "$result"/*.deb "$repo/pool/"
}
deb_publish(){
  local repo_path="$1"
  local repo="$PUBLIC_DIR/$repo_path"
  local deb package

  mkdir -p "$repo/pool"
  compgen -G "$repo/pool/*.deb" >/dev/null || die "No DEB files found in $repo/pool"

  for deb in "$repo/pool"/*.deb; do
    package="$(dpkg-deb -f "$deb" Package)"
    metadata_append_package "$package"
  done

  (
    cd "$repo"
    apt-ftparchive packages pool >Packages
    gzip -c Packages >Packages.gz
    apt-ftparchive release . >Release
    gpg --batch --yes --armor --detach-sign -u "$FPR" -o Release.gpg Release
    gpg --batch --yes --clearsign -u "$FPR" -o InRelease Release
  )
}
deb_write_repo(){
  local repo_id="$1"
  local repo_file="$2"
  local repo_path="$3"
  local label="$4"

  cat >"$PUBLIC_DIR/$repo_file" <<EOF
Types: deb
URIs: https://${REPO_OWNER:?}.github.io/${REPO_NAME:?}/$repo_path
Suites: ./
Signed-By: /usr/share/keyrings/repository-signing.gpg
EOF

  metadata_append_repo "$repo_id" "$repo_file" "$repo_path" "$label"
}
deb_build_targets(){
  local target family arch repo_path repo_id repo_file label qfile
  local qfiles=()

  while IFS= read -r target; do
    echo "==> DEB target: $target"
    IFS=$'\t' read -r family arch repo_path repo_id repo_file label < <(repo_info deb "$PRIMARY_APP" "$target")

    mkdir -p "$PUBLIC_DIR/$repo_path/pool"
    ordered_queue_files \
      qfiles \
      "/work/package-graph/deb/$target" \
      "$target" \
      "$family" \
      "$QUEUE_DIR" \
      "No DEB package declarations were queued" \
      deb

    for qfile in "${qfiles[@]}"; do
      deb_build_queued "$qfile" "$target" "$family" "$arch" "$repo_path"
    done

    deb_publish "$repo_path"
    deb_write_repo "$repo_id" "$repo_file" "$repo_path" "$label"
    metadata_append targets.txt "$target"
  done < <(targets_list)
}
build_inside_container(){
  local app dir file i title url

  load_apps_sources "${APP:-}" "${SOURCE_GIT:-}"
  ensure_dir /work/public

  rm -rf "$METADATA_DIR"
  ensure_dir "$METADATA_DIR"
  : >"$METADATA_DIR/packages.txt"
  : >"$METADATA_DIR/repos.tsv"
  : >"$METADATA_DIR/targets.txt"

  setup_gpg

  ensure_dir "$PUBLIC_DIR"
  cp /work/gpg-key/public.asc "$PUBLIC_DIR/GPG-KEY-repo"
  case "$PACKAGE_TYPE" in
    rpm)
      rpm --import /work/public/GPG-KEY-repo
      rpm_configure_signing
      ;;
    deb)
      ;;
    *)
      die "Unsupported package-type for repository build: $PACKAGE_TYPE"
      ;;
  esac

  load_apps_sources "${APP:-}" "${SOURCE_GIT:-}"

  for i in "${!APPS[@]}"; do
    app="${APPS[$i]}"
    url="$(source_for_index "$i")"
    dir="$(prepare_app_workdir "$app" "$url" /work/work)"

    SOURCE_ID="$app" PATCH_ROOT="$dir/patches" run_user_build_script "$dir" "${BUILD_SCRIPT:-}"
  done

  case "$PACKAGE_TYPE" in
    rpm)
      rpm_build_targets
      ;;
    deb)
      deb_build_targets
      ;;
    *)
      die "Unsupported package-type for repository build: $PACKAGE_TYPE"
      ;;
  esac

  for file in packages.txt repos.tsv targets.txt; do
    sort_unique_file "$METADATA_DIR/$file"
  done

  title="$(printf '%s Packages' "${PRIMARY_APP:-Repository}" | sed 's/&/\&amp;/g')"
  cat >"$PUBLIC_DIR/index.html" <<EOF
<!doctype html><meta charset="utf-8"><title>$title</title><h1>$title</h1><p>Repository index generated by package builder.</p>
EOF

  require_file "$PUBLIC_DIR/GPG-KEY-repo"
  require_file "$METADATA_DIR/packages.txt"
  require_file "$METADATA_DIR/repos.tsv"
  require_file "$METADATA_DIR/targets.txt"

  case "$PACKAGE_TYPE" in
    rpm)
      compgen -G "$PUBLIC_DIR/*.repo" >/dev/null || die "No RPM .repo file was generated."
      find "$PUBLIC_DIR" -path '*/repodata/repomd.xml' | grep -q . || die "No RPM repodata/repomd.xml was generated."
      ;;
    deb)
      compgen -G "$PUBLIC_DIR/*.sources" >/dev/null || die "No DEB .sources file was generated."
      find "$PUBLIC_DIR" -name Release | grep -q . || die "No DEB Release file was generated."
      find "$PUBLIC_DIR" -name InRelease | grep -q . || die "No DEB InRelease file was generated."
      ;;
  esac
}
cmd_build_container(){
  if [[ "${1:-}" == --inside-container ]]; then
    build_inside_container
    return
  fi

  local package_type="${PACKAGE_TYPE:?}"
  local target family arch
  local base_image=""
  local build_cmd=""
  local first_target=""
  local target_image target_build_cmd
  local image cache_key cache_root
  local env_args=(-e PUBLIC_ROOT=/work/public -e PACKAGE_BUILD_QUEUE_DIR=/work/package-build-queue)
  local cache_args=()
  local var value spec name path

  validate_targets "$package_type"

  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    IFS=$'\t' read -r family arch < <(split_target "$target")

    target_image="$(target_container_image "$package_type" "$family" "$arch")"
    target_build_cmd="${TARGET_CONTAINER_BUILD_CMD:-}"
    [[ -n "$target_build_cmd" ]] || die "Missing TARGET_CONTAINER_BUILD_CMD for $package_type target: $target"

    if [[ -z "$first_target" ]]; then
      first_target="$target"
      base_image="$target_image"
      build_cmd="$target_build_cmd"
      continue
    fi

    [[ "$target_image" == "$base_image" ]] ||
      die "Targets use different TARGET_CONTAINER_IMAGE values: $first_target uses '$base_image', but $target uses '$target_image'"

    [[ "$target_build_cmd" == "$build_cmd" ]] ||
      die "Targets use different TARGET_CONTAINER_BUILD_CMD values: $first_target and $target differ"
  done < <(targets_list)

  [[ -n "$first_target" ]] || die "$package_type requires targets."

  image="$(cached_builder_image "$package_type" "$base_image" "$build_cmd")"

  cache_key="$(
    {
      printf 'cache_schema=%s\n' "$PACKAGE_CACHE_SCHEMA"
      printf 'package_type=%s\n' "$package_type"

      while IFS= read -r target; do
        [[ -n "$target" ]] || continue
        IFS=$'\t' read -r family arch < <(split_target "$target")
        config_file="$(find_target_config "$package_type" "$family" "$arch")"

        printf 'target=%s\n' "$target"
        printf 'config=%s\n' "${config_file#$ROOT/}"
        printf 'sha256=%s\n' "$(sha256_file "$config_file")"
      done < <(targets_list)
    } | sha256_lines
  )"
  cache_key="$package_type-v$PACKAGE_CACHE_SCHEMA-${cache_key:0:16}"
  cache_root="package-cache/$cache_key"
  mkdir -p "$cache_root"
  {
    printf 'cache_schema=%s\n' "$PACKAGE_CACHE_SCHEMA"
    printf 'package_type=%s\n' "$package_type"
    printf 'created_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    while IFS= read -r target; do
      [[ -n "$target" ]] || continue
      IFS=$'\t' read -r family arch < <(split_target "$target")
      config_file="$(find_target_config "$package_type" "$family" "$arch")"

      printf 'target=%s\n' "$target"
      printf 'config=%s\n' "${config_file#$ROOT/}"
      printf 'sha256=%s\n' "$(sha256_file "$config_file")"
    done < <(targets_list)
  } >"$cache_root/.repository-builder-cache-manifest"
  echo "Using package cache: $cache_root"

  for var in "${HOST_ENV_VARS[@]}"; do
    [[ -n "${!var+x}" ]] || continue

    value="${!var}"
    if [[ " $TRIMMED_ENV_VARS " == *" $var "* ]]; then
      value="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<<"$value")"
    fi

    env_args+=(-e "$var=$value")
  done

  for spec in "${CACHE_MOUNTS[@]}"; do
    name="${spec%%:*}"
    path="${spec#*:}"
    mkdir -p "$cache_root/$name"
    cache_args+=(-v "$PWD/$cache_root/$name:$path")
  done

  docker run \
    --rm \
    --privileged \
    -v "$PWD:/work/workspace" \
    -v "$PWD/publisher:/work/publisher" \
    -v "$PWD/public:/work/public" \
    -v "$PWD/gpg-key:/work/gpg-key" \
    -v "$PWD/$cache_root:/package-cache" \
    "${cache_args[@]}" \
    -w /work/workspace \
    "${env_args[@]}" \
    "$image" \
    bash /work/publisher/repository_builder.sh build-container --inside-container
}
cmd_prepare(){
  local package_type="${PACKAGE_TYPE:-}"
  local family arch container key changed line kind name value ref result sha pages cache_keys file
  local version=()
  local targets=()

  [[ " $PACKAGE_TYPES " == *" $package_type "* ]] || die "Unsupported package-type: $package_type"

  pages="$(gh api "repos/${GITHUB_REPOSITORY:?}/pages" --jq .build_type)"
  [[ "$pages" == workflow ]] || die "Enable GitHub Pages with Source set to GitHub Actions."

  load_apps_sources "${APP:-}" "${SOURCE_GIT:-}"
  [[ -n "${SOURCE_GIT:-}" || -n "${BUILD_SCRIPT:-}" ]] || die "$package_type requires source-git, build-script, or both."

  if [[ "$package_type" == flatpak ]]; then
    mapfile -t targets < <(targets_list)
    ((${#targets[@]} == 1)) || die "Flatpak requires exactly one target."

    validate_target flatpak "${targets[0]}"
    IFS=$'\t' read -r family arch < <(split_target "${targets[0]}")
    container="$(target_container_image flatpak "$family" "$arch")"

    write_output build-container-json "{\"image\":\"$container\",\"options\":\"--privileged\"}"
    write_output flatpak-arch "$arch"
  else
    validate_targets "$package_type"
    write_output build-container-json null
    write_output flatpak-arch x86_64
  fi

  if [[ "${GPG_CACHE_HIT:-}" != true ]]; then
    gpg_generate
  else
    for file in gpg-key/private.asc gpg-key/public.asc gpg-key/fingerprint.txt; do
      [[ -f "$file" ]] || die "Missing cached GPG file: $file"
    done
  fi

  while IFS= read -r line; do
    set -- $line
    kind="${1:-}"
    name="${2:-}"
    value="${3:-}"
    ref="${4:-}"

    case "$kind" in
      "")
        continue
        ;;
      url)
        result="$(curl -fsSL --retry 3 --retry-delay 10 --retry-all-errors "$value")"
        version+=("$name	url	$value	$result")
        ;;
      git)
        ref="${ref:-HEAD}"
        sha="$(git ls-remote "$value" "$ref" | awk 'NR==1{print $1}')"
        [[ -n "$sha" ]] || die "Unable to resolve git trigger: $value $ref"
        version+=("git $name $value $ref $sha")
        ;;
      file)
        [[ -f "$value" ]] || die "Missing trigger file: $value"
        version+=("file $name $value $(sha256_file "$value")")
        ;;
      *)
        die "Unknown rebuild-trigger type: $kind"
        ;;
    esac
  done < <(printf '%s\n' "${REBUILD_TRIGGER:-}" | sed -e 's/[[:space:]]*$//' -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d')

  printf '%b\n' "${version[@]:-}" >version.txt
  key="upstream-state-$(printf '%s' "${APP:-}" | sha256sum | awk '{print $1}')-$(sha256_file version.txt)"

  write_output version-key "$key"
  write_output gpg-cache-key package-gpg-key-v1

  if [[ "${GITHUB_EVENT_NAME:-}" == workflow_dispatch ]]; then
    changed=true
  else
    cache_keys="$(gh cache list --key "$key" --json key --jq '.[].key')"
    if grep -qxF "$key" <<<"$cache_keys"; then
      changed=false
    else
      changed=true
    fi
  fi

  write_output changed "$changed"
}
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

repo_header(){
  local title="$1"
  local packages="${2:-}"

  printf '# Repository installation\n\n> These instructions are generated from the latest published repository metadata.\n\n## %s\n\n' "$title"

  if [[ -n "$packages" ]]; then
    printf 'Packages: `%s`\n\n' "$packages"
  fi
}
cmd_update_readme(){
  local publisher_root="${GITHUB_WORKSPACE:-$PWD}/publisher"
  local template="$publisher_root/README.md"
  local package_type="${PACKAGE_TYPE:-}"
  local owner="${OWNER:-}"
  local repo="${REPO:-}"
  local remote="${REMOTE:-}"
  local metadata="../publisher-metadata"
  local generated packages row repo_id repo_file repo_path label family arch tool url app_list key_url sources_url keyring

  rm -rf repo-edit
  git clone "https://x-access-token:${GH_TOKEN:?}@github.com/${GITHUB_REPOSITORY:?}.git" repo-edit
  cd repo-edit

  app_list="$(printf '%s\n' "${APP:-}" | sed -e '/^[[:space:]]*$/d' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"

  if [[ "$package_type" == flatpak ]]; then
    generated="$(repo_header "Flatpak repository")"
    generated+=$(printf '```bash\nsudo flatpak remote-add --if-not-exists "%s" "https://%s.github.io/%s/index.flatpakrepo"\n```\n\n```bash\nsudo flatpak install "%s" %s\n```\n' "$remote" "$owner" "$repo" "$remote" "$app_list")
  else
    [[ -f "$metadata/packages.txt" && -f "$metadata/repos.tsv" ]] || die "Missing publisher metadata for ${package_type^^} README"

    packages="$(sed -e 's/[[:space:]]*$//' -e '/^[[:space:]]*$/d' "$metadata/packages.txt" | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    generated="$(repo_header "${package_type^^} repository" "$packages")"

    if [[ "$package_type" == deb ]]; then
      generated+="Signing key: \`https://$owner.github.io/$repo/GPG-KEY-repo\`\n\n"
    fi

    while IFS=$'\t' read -r repo_id repo_file repo_path label; do
      [[ -n "$repo_id" ]] || continue

      family="$(cut -d/ -f3 <<<"$repo_path")"
      arch="$(cut -d/ -f4 <<<"$repo_path")"
      load_target "$package_type" "$family" "$arch"
      tool="$TARGET_INSTALL_TOOL"
      [[ -n "$label" ]] || label="$(target_label "$package_type" "$family" "$arch")"

      url="https://$owner.github.io/$repo/$repo_file"
      generated+="### $label\n\n"

      case "$package_type" in
        rpm)
          generated+="Repository file: \`$url\`\n\n"
          case "$tool" in
            zypper)
              generated+=$(printf '```bash\nsudo zypper addrepo --gpgcheck --refresh "%s" "%s"\nsudo zypper install %s\n```\n\n' "$url" "$repo_id" "$packages")
              ;;
            dnf)
              generated+=$(printf '```bash\nsudo dnf config-manager addrepo --from-repofile="%s"\nsudo dnf install %s\n```\n\n' "$url" "$packages")
              ;;
            *)
              die "Unsupported RPM install tool for $repo_path"
              ;;
          esac
          ;;
        deb)
          [[ "$tool" == apt ]] || die "Unsupported DEB install tool for $repo_path"
          key_url="https://$owner.github.io/$repo/GPG-KEY-repo"
          sources_url="https://$owner.github.io/$repo/$repo_file"
          keyring="/usr/share/keyrings/$repo.gpg"
          generated+="Sources file: \`$url\`\n\n"
          generated+=$(printf '```bash\nsudo install -d -m 0755 /usr/share/keyrings\ncurl -fsSL "%s" | sudo gpg --dearmor -o "%s"\nsudo curl -fsSL "%s" -o "/etc/apt/sources.list.d/%s"\nsudo apt update\nsudo apt install %s\n```\n\n' \
            "$key_url" \
            "$keyring" \
            "$sources_url" \
            "$repo_file" \
            "$packages")
          ;;
      esac
    done < <(sort -t $'\t' -k4 "$metadata/repos.tsv")
  fi

  printf '%b' "$generated" >../generated-repository-instructions.md

  if [[ -f "$template" ]]; then
    {
      printf '%b' "$generated"
      printf '\n---\n\n'
      cat "$template"
    } >README.md
  else
    printf '%b' "$generated" >README.md
  fi

  git config user.name 'github-actions[bot]'
  git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
  git add README.md

  if ! git diff --cached --quiet; then
    git commit -m 'Update README'
    git push
  fi
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
    mock-diagnostics-chroot)
      cmd_mock_diagnostics_chroot "$@"
      ;;
    *)
      die "Unknown builder command: $cmd"
      ;;
  esac
}

main "$@"
