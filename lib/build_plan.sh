# shellcheck shell=bash

# Package queue handling, dependency graph logic, and build ordering.

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
  [[ "${PACKAGE_TYPE:-}" != rpm ]] || die "RPM package-build-queue declarations are disabled; use layered specs/*.spec or specs/<layer>/*.spec instead."

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
