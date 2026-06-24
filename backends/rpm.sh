# shellcheck shell=bash

# RPM backend: mock, rpmbuild/rpmspec, createrepo, signing, graphing, publishing, and RPM-specific diagnostics.

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
        if (row ~ /^(error:|Error[[:space:]]|Warning:|warning:|DEBUG[[:space:]]|INFO[[:space:]])/) next
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
        printf 'trigger_owner\t%s\n' "$owner"
      fi
      case "$line" in
        *'scriptlet in rpm package '*)
          active="${line#*scriptlet in rpm package }"
          active="${active%%[[:space:]:,;]*}"
          printf 'active_package\t%s\n' "$active"
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
  local deep_enabled="${RPM_DEEP_DIAGNOSTICS:-${MOCK_DEEP_DIAGNOSTICS:-0}}" timeout_duration="${RPM_DIAGNOSTIC_TIMEOUT:-${MOCK_DIAGNOSTIC_TIMEOUT:-45s}}"
  local status=0

  mkdir -p "$result"
  log="$result/chroot-diagnostics.log"
  transaction_file="$result/transaction-packages.tsv"
  rpm_diagnostic_transaction_packages_from_logs "$result" >"$transaction_file" || : >"$transaction_file"

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

  if ! diagnostics_bool_enabled "$deep_enabled"; then
    {
      echo "=== deep mock chroot diagnostics skipped ==="
      echo "RPM_DEEP_DIAGNOSTICS is not enabled, so diagnostics were limited to existing mock logs."
      echo "Set RPM_DEEP_DIAGNOSTICS=1 to run the extra mock --chroot probe."
      echo "The deep probe is timeout-protected by RPM_DIAGNOSTIC_TIMEOUT=${timeout_duration}."
      echo
    } >>"$log"

    echo "--- chroot-diagnostics.log (last $lines lines) ---" >&2
    tail -n "$lines" "$log" >&2 || true
    return 0
  fi

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
    echo "=== running deep mock chroot diagnostics ==="
    echo "timeout=$timeout_duration"
    echo "The deep probe is optional and will be stopped if it exceeds the timeout."
    echo
  } >>"$log"
  echo "Running RPM deep diagnostics with timeout $timeout_duration ..." >&2

  diagnostics_run_with_timeout "$timeout_duration" "$log"     mock -r "$target" "${mock_args[@]}"       --enable-plugin bind_mount       --plugin-option "bind_mount:dirs=$bind_spec"       --chroot "$diagnostic_command" || status=$?

  case "$status" in
    0)
      ;;
    124|137)
      echo "RPM deep diagnostics timed out after $timeout_duration; continuing with collected diagnostics." >&2
      ;;
    125)
      echo "RPM deep diagnostics skipped because timeout support is unavailable." >&2
      ;;
    *)
      echo "=== unable to run mock diagnostics inside chroot ===" >>"$log"
      echo "exit_status=$status" >>"$log"
      ;;
  esac

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

