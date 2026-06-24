# shellcheck shell=bash

# Source checkout, workspace preparation, layered files, patches, and replacements.

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

