# shellcheck shell=bash

# DEB backend: pbuilder, dpkg-buildpackage, apt-ftparchive, graphing, signing, and publishing.

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

