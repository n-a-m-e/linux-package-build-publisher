# shellcheck shell=bash

# Generated repository metadata, install instructions, and README updates.

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

