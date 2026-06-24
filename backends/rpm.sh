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

rpm_diagnostic_direct_installing_packages_from_logs(){
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
      trimmed ~ /^Installing:[[:space:]]*$/ {
        in_direct_installing = 1
        next
      }
      trimmed ~ /^(Installing dependencies|Installing weak dependencies|Installing group\/module packages|Upgrading|Downgrading|Reinstalling|Removing|Transaction Summary|Running transaction check|Running transaction test|Running transaction|Complete!|Error:)/ {
        in_direct_installing = 0
        next
      }
      in_direct_installing {
        row = line
        sub(/^[[:space:]]+/, "", row)
        if (row == "" || row ~ /^=+$/ || row ~ /^Package[[:space:]]+Arch[[:space:]]+/) next
        if (row ~ /^(error:|Error[[:space:]]|Warning:|warning:|DEBUG[[:space:]]|INFO[[:space:]])/) next
        split(row, fields, /[[:space:]]+/)
        name = fields[1]
        if (name != "" && name !~ /^(Package|Arch|Version|Repository|Size|\[SKIPPED\])$/) {
          print name
        }
      }
    ' "$log" || true
  done < <(rpm_diagnostic_mock_log_files "$result") | awk 'NF && !seen[$0]++'
}

rpm_diagnostic_write_direct_provider_file(){
  local result="$1" provider_file="$2"

  rpm_diagnostic_direct_installing_packages_from_logs "$result" \
    | awk 'NF && !seen[$0]++' >"$provider_file"
}

rpm_diagnostic_write_direct_installing_report(){
  local result="$1" log="$2" provider_file="${3:-}" provider found=0

  {
    echo "=== direct Installing packages from failed transaction ==="
    if [[ -n "$provider_file" && -f "$provider_file" ]]; then
      while IFS= read -r provider; do
        [[ -n "$provider" ]] || continue
        found=1
        printf '%s\n' "$provider"
      done <"$provider_file"
    else
      while IFS= read -r provider; do
        [[ -n "$provider" ]] || continue
        found=1
        printf '%s\n' "$provider"
      done < <(rpm_diagnostic_direct_installing_packages_from_logs "$result")
    fi
    ((found)) || echo "no direct Installing packages found in mock logs"
    echo
  } >>"$log"
}

rpm_diagnostic_package_name_candidates(){
  local raw="${1:-}" value arch

  raw="${raw%%[[:space:]:,;]*}"
  raw="${raw#\"}"
  raw="${raw%\"}"
  [[ -n "$raw" ]] || return 0

  printf '%s\n' "$raw"

  value="$raw"
  for arch in x86_64 aarch64 noarch i586 i686 armv7hl armv7hnl ppc64le s390x src; do
    if [[ "$value" == *."$arch" ]]; then
      value="${value%."$arch"}"
      break
    fi
  done

  # Convert a common NEVRA-like string such as name-1.2-3.x86_64 to name.
  # This is intentionally only a candidate generator; the raw value remains
  # included above so unusual package names are not lost.
  if [[ "$value" =~ ^(.+)-([0-9][^-]*)-([^-]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
}

rpm_diagnostic_trigger_package_candidates_from_logs(){
  local result="$1" log line rest token payload

  while IFS= read -r log; do
    while IFS= read -r line; do
      rest="$line"
      while [[ "$rest" =~ %[A-Za-z0-9_]+\(([^\)]+)\) ]]; do
        payload="${BASH_REMATCH[1]}"
        rpm_diagnostic_package_name_candidates "$payload"
        rest="${rest#*%}"
        rest="${rest#*)}"
      done
    done <"$log"
  done < <(rpm_diagnostic_mock_log_files "$result") | awk 'NF && !seen[$0]++'
}

rpm_diagnostic_active_scriptlet_packages_from_logs(){
  local result="$1" log line active

  while IFS= read -r log; do
    while IFS= read -r line; do
      case "$line" in
        *'scriptlet in rpm package '*)
          active="${line#*scriptlet in rpm package }"
          active="${active%%[[:space:]:,;]*}"
          rpm_diagnostic_package_name_candidates "$active"
          ;;
      esac
    done <"$log"
  done < <(rpm_diagnostic_mock_log_files "$result") | awk 'NF && !seen[$0]++'
}

rpm_diagnostic_failure_package_candidates_from_logs(){
  local result="$1"

  {
    rpm_diagnostic_trigger_package_candidates_from_logs "$result"
    rpm_diagnostic_active_scriptlet_packages_from_logs "$result"
  } | awk 'NF && !seen[$0]++'
}

rpm_diagnostic_write_failure_focus_report(){
  local result="$1" log="$2" item found=0

  {
    echo "=== failure package candidates from mock logs ==="
    echo "[trigger/scriptlet owner candidates]"
    while IFS= read -r item; do
      [[ -n "$item" ]] || continue
      found=1
      printf '%s\n' "$item"
    done < <(rpm_diagnostic_trigger_package_candidates_from_logs "$result")
    ((found)) || echo "none found"

    found=0
    echo
    echo "[active scriptlet package candidates]"
    while IFS= read -r item; do
      [[ -n "$item" ]] || continue
      found=1
      printf '%s\n' "$item"
    done < <(rpm_diagnostic_active_scriptlet_packages_from_logs "$result")
    ((found)) || echo "none found"
    echo
  } >>"$log"
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


rpm_buildrequires_from_spec(){
  local spec_path="$1" url="${2:-}" output="$3"
  local expanded tmp

  [[ -f "$spec_path" ]] || die "Missing spec for BuildRequires parsing: $spec_path"
  mkdir -p "$(dirname "$output")"

  expanded="$output.expanded"
  tmp="$output.tmp"

  if [[ -n "$url" ]]; then
    rpmspec --define "url $url" -P "$spec_path" >"$expanded"
  else
    rpmspec -P "$spec_path" >"$expanded"
  fi

  awk '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    /^[[:space:]]*BuildRequires:[[:space:]]*/ {
      line = $0
      sub(/^[[:space:]]*BuildRequires:[[:space:]]*/, "", line)
      sub(/[[:space:]]+#.*$/, "", line)
      n = split(line, deps, /,[[:space:]]*/)
      for (i = 1; i <= n; i++) {
        dep = trim(deps[i])
        if (dep != "" && !seen[dep]++) print dep
      }
    }
  ' "$expanded" >"$tmp"

  mv "$tmp" "$output"
  rm -f "$expanded"

  [[ -s "$output" ]] || die "No BuildRequires entries found in expanded spec: $spec_path"
}

rpm_stepwise_buildrequires_failure_report(){
  local result="$1" log="$2"

  {
    echo
    rpm_diagnostic_transaction_sections_from_logs "$result"
    rpm_diagnostic_scriptlet_failures_from_logs "$result"
    rpm_diagnostic_write_failure_focus_report "$result" /dev/stdout
  } >>"$log" 2>&1 || true
}

rpm_install_buildrequires_stepwise(){
  local result="$1" msg="$2" target="$3" phase="$4" spec_path="$5" url="$6"
  shift 6

  local common_args=("$@") target_args=() mock_args=()
  local deps_file log dep status index total

  mkdir -p "$result"
  deps_file="$result/stepwise-buildrequires.txt"
  log="$result/stepwise-buildrequires.log"

  rpm_buildrequires_from_spec "$spec_path" "$url" "$deps_file"
  total="$(awk 'NF { count++ } END { print count + 0 }' "$deps_file")"

  # The stepwise dependency installs must use the exact same mock root and
  # target-specific configuration as the surrounding build. In particular,
  # TARGET_RPM_MOCK_CONFIG_OPTS and TARGET_RPM_CHROOT_SETUP_CMD are applied by
  # rpm_mock_args_array(); dropping them here can accidentally re-enable mock's
  # bootstrap/tooling path or initialize a different root.
  rpm_mock_args_array "$target" "$phase" target_args
  mock_args=("${target_args[@]}" "${common_args[@]}")

  {
    echo "=== stepwise BuildRequires installation ==="
    echo "target=$target"
    echo "phase=$phase"
    echo "spec=$spec_path"
    [[ -n "$url" ]] && echo "url=$url"
    echo "dependencies=$deps_file"
    echo "count=$total"
    echo "strategy=mock --pm-cmd install -y <BuildRequires-entry>"
    echo "target_args=${target_args[*]}"
    echo "common_args=${common_args[*]}"
    echo
    sed 's/^/  /' "$deps_file"
    echo
  } >"$log"

  index=0
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    index=$((index + 1))

    {
      echo
      echo "=== BuildRequires $index/$total ==="
      echo "dependency=$dep"
      echo "mock -r $target ... --pm-cmd install -y $dep"
    } | tee -a "$log" >&2

    if mock -r "$target" "${mock_args[@]}" --pm-cmd install -y "$dep" >>"$log" 2>&1; then
      {
        echo "status=installed"
      } >>"$log"
    else
      status=$?
      {
        echo
        echo "=== failed BuildRequires dependency ==="
        echo "dependency=$dep"
        echo "exit_status=$status"
      } >>"$log"

      rpm_stepwise_buildrequires_failure_report "$result" "$log"
      rpm_dump_mock_failure "$result" "$msg"
      echo "--- ${log#$result/} ---" >&2
      cat "$log" >&2 || true
      die "$msg; failed while installing BuildRequires entry: $dep"
    fi
  done <"$deps_file"

  {
    echo
    echo "=== all BuildRequires entries installed successfully ==="
  } >>"$log"
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
  local target="$1" unique="$2" result="$3" local_repo="$4" srpm="$5" spec_path="$6" url="${7:-}"
  local common_args=() rebuild_args=()

  common_args=(
    --uniqueext "$unique"
    --enable-network
    --addrepo "file://$local_repo"
    --resultdir "$result"
  )
  [[ -n "$url" ]] && common_args+=(--define "url $url")

  rebuild_args=("${common_args[@]}" --no-clean --rebuild "$srpm")

  rpm_diagnostic_write_srpm_host "$result" "$srpm"

  rpm_mock_with_args "$result" "mock init failed for $target" "$target" build "${common_args[@]}" --init
  rpm_install_buildrequires_stepwise \
    "$result" \
    "mock build dependency install failed for $(basename "$srpm")" \
    "$target" \
    build \
    "$spec_path" \
    "$url" \
    "${common_args[@]}"

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
  rpm_rebuild "$target" "$target-$build_id" "$result" "$local_repo" "$srpm" "$spec_path" "$url"
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

