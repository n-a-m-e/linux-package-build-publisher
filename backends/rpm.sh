# shellcheck shell=bash

# RPM backend: mock, rpmbuild/rpmspec, createrepo, signing, graphing, publishing, and RPM-specific diagnostics.

# Normal RPM builds should keep the GitHub log summary-first. Detailed
# mock/repository diagnostics are still written under each package result
# directory, but they are only printed inline when a command fails.
RPM_QUEUE_FINGERPRINT_VERSION=v5
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
  local dir="$1" msg="$2"
  local log rel found=0

  error "$msg"

  shopt -s nullglob
  for log in "$dir"/*.log "$dir"/*/*.log; do
    [[ -f "$log" ]] || continue
    rel="${log#$dir/}"
    found=1
    echo "--- $rel (full log) ---" >&2
    cat "$log" >&2 || true
  done
  shopt -u nullglob

  if ! ((found)); then
    echo "--- no mock result logs found in $dir ---" >&2
  fi
}

rpm_emit_lines_section(){
  local title="$1" leading_blank="${2:-1}"
  shift 2

  [[ "$leading_blank" == 1 ]] && echo
  echo "=== $title ==="
  printf '%s\n' "$@"
}

rpm_log_lines_section(){
  local log="$1" title="$2" inline="${3:-0}" leading_blank="${4:-1}"
  shift 4

  if [[ "$inline" == 1 ]]; then
    rpm_emit_lines_section "$title" "$leading_blank" "$@" | tee -a "$log" >&2
  else
    rpm_emit_lines_section "$title" "$leading_blank" "$@" >>"$log"
  fi
}

rpm_write_srpm_buildrequires(){
  local result="$1" srpm="$2" deps_file="$3"
  local log tmp count

  [[ -f "$srpm" ]] || die "Missing SRPM for BuildRequires parsing: $srpm"

  mkdir -p "$result"
  log="$result/srpm-buildrequires.log"
  tmp="$deps_file.tmp"

  {
    echo "=== SRPM ==="
    echo "srpm=$srpm"
    rpm -qp --queryformat 'name=%{NAME}\nversion=%{VERSION}\nrelease=%{RELEASE}\narch=%{ARCH}\n' "$srpm" 2>&1 || true
    echo

    echo "=== SRPM requires / BuildRequires ==="
    rpm -qpR "$srpm" 2>&1 | sort -u || true
    echo
  } >"$log"

  # For source RPMs, the RPM requires metadata contains the resolved
  # BuildRequires set. Reading the built SRPM avoids expanding the raw spec in
  # the host/container macro context, which can miss target macros such as
  # distro-specific library macros.
  rpm -qp --requires "$srpm" | awk '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    {
      dep = trim($0)
      if (dep == "") next
      if (dep ~ /^rpmlib\(/) next
      if (!seen[dep]++) print dep
    }
  ' >"$tmp"
  mv "$tmp" "$deps_file"

  count="$(awk 'NF { count++ } END { print count + 0 }' "$deps_file")"
  echo "SRPM metadata captured: ${log#$result/} ($count BuildRequires entries)" >&2
}

rpm_dnf_transaction_report_from_output(){
  local dep="$1" index="$2" total="$3" attempt="$4" status_label="$5" exit_status="$6" output="$7"

  {
    echo
    echo "=== BuildRequires DNF transaction $index/$total ==="
    echo "dependency=$dep"
    echo "attempt=$attempt"
    echo "status=$status_label"
    echo "exit_status=$exit_status"
    awk '
      function normalize(line, out) {
        out = line
        sub(/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:.]+Z[[:space:]]*/, "", out)
        sub(/^DEBUG[[:space:]]+util\.py:[0-9]+:[[:space:]]*/, "", out)
        sub(/^INFO[[:space:]]+util\.py:[0-9]+:[[:space:]]*/, "", out)
        return out
      }
      function print_section(name) {
        if (!printed[name]++) print "[" name "]"
      }
      function emit(line) {
        print "  - " line
        found = 1
      }
      {
        line = normalize($0)
        trimmed = line
        sub(/^[[:space:]]+/, "", trimmed)
      }
      trimmed ~ /^Package .+ is already installed\./ {
        print_section("Already installed")
        emit(trimmed)
        next
      }
      trimmed ~ /^(Installing|Installing dependencies|Installing weak dependencies|Installing group\/module packages|Upgrading|Downgrading|Reinstalling|Removing|Removing dependent packages|Removing unused dependencies|Obsoleting):[[:space:]]*$/ {
        section = trimmed
        sub(/:[[:space:]]*$/, "", section)
        print_section(section)
        in_summary = 0
        in_error = 0
        next
      }
      trimmed ~ /^Transaction Summary/ {
        section = ""
        in_summary = 1
        in_error = 0
        print_section("Transaction Summary")
        next
      }
      trimmed ~ /^Error:/ {
        section = ""
        in_summary = 0
        in_error = 1
        print_section("DNF errors")
        emit(trimmed)
        next
      }
      in_error {
        if (trimmed == "" || trimmed ~ /^(Child return code|kill orphans|Executing command:|Please ignore)/) {
          in_error = 0
          next
        }
        emit(trimmed)
        next
      }
      in_summary {
        if (trimmed == "" || trimmed ~ /^=+$/) next
        if (trimmed ~ /^(Downloading Packages|Running transaction check|Running transaction test|Running transaction|Complete!|Error:|Is this ok)/) {
          in_summary = 0
          next
        }
        if (trimmed ~ /^(Install|Upgrade|Downgrade|Reinstall|Remove)[[:space:]]+[0-9]+[[:space:]]+Packages?/) emit(trimmed)
        else if (trimmed ~ /^Total (download )?size:/) emit(trimmed)
        next
      }
      section {
        row = line
        sub(/^[[:space:]]+/, "", row)
        if (row == "" || row ~ /^=+$/ || row ~ /^Package[[:space:]]+Arch[[:space:]]+/) next
        if (row ~ /^(error:|Error[[:space:]]|Warning:|warning:|DEBUG[[:space:]]|INFO[[:space:]])/) next
        emit(row)
      }
      END {
        if (!found) print "  no DNF transaction package rows found"
      }
    ' "$output" || true
  }
}

rpm_layered_repo_files(){
  local root="$1" family="$2" target="$3"
  local layer pattern matches

  while IFS= read -r layer; do
    if [[ "$layer" == "." ]]; then
      pattern="$root/repos/*.repo"
    else
      pattern="$root/$layer/repos/*.repo"
    fi

    if matches="$(compgen -G "$pattern")"; then
      printf '%s\n' "$matches" | sort
    fi
  done < <(layer_names "$family" "$target")
}

rpm_expand_repo_fragment(){
  local input="$1" output="$2" target="$3" family="$4" arch="$5" release="$6"
  local content

  content="$(cat "$input")"
  content="${content//\{target\}/$target}"
  content="${content//\{family\}/$family}"
  content="${content//\{arch\}/$arch}"
  content="${content//\{release\}/$release}"
  content="${content//\{suffix\}/$release}"
  printf '%s\n' "$content" >"$output"
}

rpm_repo_fragment_mode(){
  local file="$1" mode

  mode="$(sed -nE 's/^[[:space:]]*#[[:space:]]*builder-mode[[:space:]]*:[[:space:]]*([^[:space:]]+).*$/\1/p' "$file" | head -n 1 | tr '[:upper:]' '[:lower:]')"
  [[ -n "$mode" ]] || mode="add"

  case "$mode" in
    add|replace|replace-section) printf '%s' "$mode" ;;
    *) die "Unsupported builder-mode '$mode' in repo fragment: $file" ;;
  esac
}

rpm_repo_fragment_replace_ids(){
  local file="$1" found=0 line

  while IFS= read -r line; do
    found=1
    printf '%s\n' "$line"
  done < <(
    sed -nE 's/^[[:space:]]*#[[:space:]]*builder-replaces[[:space:]]*:[[:space:]]*(.*)$/\1/p' "$file" \
      | awk '{ n = split($0, ids, /[[:space:],]+/); for (i = 1; i <= n; i++) if (ids[i] != "" && !seen[ids[i]]++) print ids[i] }'
  )

  if ! ((found)); then
    sed -nE 's/^[[:space:]]*\[([^]]+)\].*$/\1/p' "$file" | awk 'NF && !seen[$0]++'
  fi
}

rpm_mock_config_resolve_include(){
  local current_dir="$1" include_ref="$2"

  if [[ "$include_ref" == /* ]]; then
    printf '%s\n' "$include_ref"
  elif [[ -f "$current_dir/$include_ref" ]]; then
    printf '%s\n' "$current_dir/$include_ref"
  elif [[ -f "/etc/mock/$include_ref" ]]; then
    printf '%s\n' "/etc/mock/$include_ref"
  else
    printf '%s\n' "$current_dir/$include_ref"
  fi
}

rpm_mock_config_render_text(){
  local target="$1" arch="$2" text="$3"

  text="${text//\{\{ target_arch \}\}/$arch}"
  text="${text//\{\{target_arch\}\}/$arch}"
  text="${text//\{\{ arch \}\}/$arch}"
  text="${text//\{\{arch\}\}/$arch}"
  text="${text//\{\{ root \}\}/$target}"
  text="${text//\{\{root\}\}/$target}"
  printf '%s\n' "$text"
}

rpm_mock_config_extract_dnf_file(){
  local file="$1" target="$2" arch="$3" current_dir line include_ref include_file op delimiter rest block

  [[ -f "$file" ]] || return 0
  current_dir="$(dirname "$file")"

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ include\([\"\']([^\"\']+)[\"\']\) ]]; then
      include_ref="${BASH_REMATCH[1]}"
      include_file="$(rpm_mock_config_resolve_include "$current_dir" "$include_ref")"
      rpm_mock_config_extract_dnf_file "$include_file" "$target" "$arch"
      continue
    fi

    [[ "$line" == *"config_opts['dnf.conf']"* ]] || continue
    if [[ "$line" == *"+="* ]]; then
      op="append"
    elif [[ "$line" == *"="* ]]; then
      op="set"
    else
      continue
    fi

    delimiter=""
    case "$line" in
      *"'''"*) delimiter="'''" ;;
      *'"""'*) delimiter='"""' ;;
      *) continue ;;
    esac

    rest="${line#*${delimiter}}"
    block=""
    if [[ "$rest" == *"$delimiter"* ]]; then
      block="${rest%%$delimiter*}"
    else
      while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == *"$delimiter"* ]]; then
          block+="${line%%$delimiter*}"
          break
        fi
        block+="$line"$'\n'
      done
    fi

    printf '\n__REPOSITORY_BUILDER_DNF_OP_%s__\n' "$op"
    rpm_mock_config_render_text "$target" "$arch" "$block"
  done <"$file"
}

rpm_mock_base_dnf_conf(){
  local target="$1" arch="$2" base_cfg="/etc/mock/$target.cfg" stream line tmp out

  [[ -f "$base_cfg" ]] || die "Missing base mock config for layered repos: $base_cfg"

  tmp="$(mktemp)"
  out="$(mktemp)"
  rpm_mock_config_extract_dnf_file "$base_cfg" "$target" "$arch" >"$tmp"
  : >"$out"

  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      __REPOSITORY_BUILDER_DNF_OP_set__)
        : >"$out"
        ;;
      __REPOSITORY_BUILDER_DNF_OP_append__)
        ;;
      *)
        printf '%s\n' "$line" >>"$out"
        ;;
    esac
  done <"$tmp"

  cat "$out"
  rm -f "$tmp" "$out"
}

rpm_dnf_remove_repo_sections(){
  local input="$1" output="$2"
  shift 2
  local ids="|" id

  for id in "$@"; do
    [[ -n "$id" ]] || continue
    ids+="$id|"
  done

  awk -v ids="$ids" '
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      repo = $0
      sub(/^[[:space:]]*\[/, "", repo)
      sub(/\][[:space:]]*$/, "", repo)
      skip = (index(ids, "|" repo "|") > 0)
    }
    !skip { print }
  ' "$input" >"$output"
}

rpm_dnf_merge_repo_section(){
  local base="$1" fragment="$2" repo_id="$3" output="$4"

  awk -v repo_id="$repo_id" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    function parse_line(line, values, seen, order, counter_name, key, value, count) {
      if (line !~ /^[[:space:]]*[^#;][^=]*=/) return
      key = line
      sub(/=.*/, "", key)
      key = trim(key)
      value = line
      sub(/^[^=]*=/, "", value)
      value = trim(value)
      if (key == "") return
      if (!(key in seen)) {
        count = counters[counter_name] + 1
        counters[counter_name] = count
        order[count] = key
        seen[key] = 1
      }
      values[key] = value
    }
    FNR == 1 { file_index++ }
    file_index == 1 {
      if ($0 ~ /^[[:space:]]*\[[^]]+\][[:space:]]*$/) {
        current = $0
        sub(/^[[:space:]]*\[/, "", current)
        sub(/\][[:space:]]*$/, "", current)
        in_existing = (current == repo_id)
        next
      }
      if (in_existing) parse_line($0, existing_values, existing_seen, existing_order, "existing")
      next
    }
    file_index == 2 {
      if ($0 ~ /^[[:space:]]*\[[^]]+\][[:space:]]*$/) {
        current = $0
        sub(/^[[:space:]]*\[/, "", current)
        sub(/\][[:space:]]*$/, "", current)
        frag_sections++
        frag_order[frag_sections] = current
        in_fragment = frag_sections
        if (current == repo_id) selected_fragment = current
        next
      }
      if (in_fragment) frag_text[in_fragment] = frag_text[in_fragment] $0 "\n"
      next
    }
    END {
      if (selected_fragment == "" && frag_sections == 1) selected_fragment = frag_order[1]
      if (selected_fragment == "") selected_fragment = repo_id

      for (i = 1; i <= frag_sections; i++) {
        if (frag_order[i] == selected_fragment) selected_text = frag_text[i]
      }
      line_count = split(selected_text, lines, "\n")
      for (i = 1; i <= line_count; i++) parse_line(lines[i], replacement_values, replacement_seen, replacement_order, "replacement")

      print "[" repo_id "]"
      for (i = 1; i <= counters["existing"]; i++) {
        key = existing_order[i]
        if (key in replacement_seen) {
          if (replacement_values[key] != "") print key "=" replacement_values[key]
        } else {
          print key "=" existing_values[key]
        }
      }
      for (i = 1; i <= counters["replacement"]; i++) {
        key = replacement_order[i]
        if (!(key in existing_seen) && replacement_values[key] != "") print key "=" replacement_values[key]
      }
    }
  ' "$base" "$fragment" >"$output"
}

rpm_effective_mock_target(){
  local target="$1" family arch root="${RPM_LAYER_ROOT:-}"
  local repo_files=() cfg_file safe_source safe_target derived_target file
  local release tmp_dir expanded mode replace_id rel current next section merged
  local local_repo="${RPM_LOCAL_REPO_PATH:-}"

  if [[ -z "$local_repo" && ( -z "$root" || ! -d "$root" ) ]]; then
    printf '%s\n' "$target"
    return 0
  fi

  IFS=$'\t' read -r family arch < <(split_target "$target")
  if [[ -n "$root" && -d "$root" ]]; then
    mapfile -t repo_files < <(rpm_layered_repo_files "$root" "$family" "$target")
  fi

  if [[ -z "$local_repo" && ${#repo_files[@]} -eq 0 ]]; then
    printf '%s\n' "$target"
    return 0
  fi

  if [[ -n "$local_repo" && ! -d "$local_repo" ]]; then
    die "Local RPM repo path does not exist: $local_repo"
  fi

  load_target rpm "$family" "$arch"
  release="${family#"${TARGET_LABEL_STRIP_PREFIX:-}"}"

  [[ -f "/etc/mock/$target.cfg" ]] || die "Missing base mock config for layered repos: /etc/mock/$target.cfg"

  safe_source="${SOURCE_ID:-$PRIMARY_APP}"
  safe_source="${safe_source//[^A-Za-z0-9_.-]/_}"
  safe_target="${target//[^A-Za-z0-9_.-]/_}"
  derived_target="$safe_target-$safe_source-layered"
  cfg_file="/etc/mock/$derived_target.cfg"
  tmp_dir="/tmp/repository-builder-repos-$derived_target"

  rm -rf "$tmp_dir"
  mkdir -p /etc/mock "$tmp_dir"

  current="$tmp_dir/dnf.conf.current"
  rpm_mock_base_dnf_conf "$target" "$arch" >"$current"

  for file in "${repo_files[@]}"; do
    rel="${file#$root/}"
    expanded="$tmp_dir/${rel//\//__}"
    rpm_expand_repo_fragment "$file" "$expanded" "$target" "$family" "$arch" "$release"
    mode="$(rpm_repo_fragment_mode "$expanded")"

    case "$mode" in
      add)
        next="$tmp_dir/dnf.conf.next"
        {
          cat "$current"
          printf '\n# layered repo fragment: %s\n' "$rel"
          cat "$expanded"
          printf '\n'
        } >"$next"
        mv "$next" "$current"
        ;;
      replace)
        while IFS= read -r replace_id; do
          [[ -n "$replace_id" ]] || continue
          section="$tmp_dir/repo-section-${replace_id//[^A-Za-z0-9_.-]/_}.repo"
          merged="$tmp_dir/dnf.conf.merged"
          next="$tmp_dir/dnf.conf.next"
          rpm_dnf_merge_repo_section "$current" "$expanded" "$replace_id" "$section"
          rpm_dnf_remove_repo_sections "$current" "$merged" "$replace_id"
          {
            cat "$merged"
            printf '\n# layered repo fragment: %s\n' "$rel"
            printf '# mode: replace\n'
            printf '# merged-replaces: %s\n' "$replace_id"
            cat "$section"
            printf '\n'
          } >"$next"
          mv "$next" "$current"
        done < <(rpm_repo_fragment_replace_ids "$expanded")
        ;;
      replace-section)
        next="$tmp_dir/dnf.conf.next"
        cp "$current" "$tmp_dir/dnf.conf.without"
        while IFS= read -r replace_id; do
          [[ -n "$replace_id" ]] || continue
          rpm_dnf_remove_repo_sections "$tmp_dir/dnf.conf.without" "$tmp_dir/dnf.conf.without.next" "$replace_id"
          mv "$tmp_dir/dnf.conf.without.next" "$tmp_dir/dnf.conf.without"
        done < <(rpm_repo_fragment_replace_ids "$expanded")
        {
          cat "$tmp_dir/dnf.conf.without"
          printf '\n# layered repo fragment: %s\n' "$rel"
          printf '# mode: replace-section\n'
          cat "$expanded"
          printf '\n'
        } >"$next"
        mv "$next" "$current"
        ;;
      *)
        die "Unsupported builder-mode '$mode' in repo fragment: $file"
        ;;
    esac
  done

  if [[ -n "$local_repo" ]]; then
    next="$tmp_dir/dnf.conf.next"
    {
      cat "$current"
      printf '\n# repository-builder local build repo\n'
      printf '[repository-builder-local]\n'
      printf 'name=Repository Builder Local RPMs\n'
      printf 'baseurl=file://%s\n' "$local_repo"
      printf 'enabled=1\n'
      printf 'gpgcheck=0\n'
      printf 'repo_gpgcheck=0\n'
      printf 'metadata_expire=0\n'
      printf 'priority=1\n'
      printf 'cost=1\n'
    } >"$next"
    mv "$next" "$current"
  fi

  {
    printf "include('/etc/mock/%s.cfg')\n" "$target"
    printf '\n# repository-builder merged dnf.conf generated in bash from layered repos\n'
    printf "config_opts['dnf.conf'] = r'''\n"
    cat "$current"
    printf "\n'''\n"
  } >"$cfg_file"

  printf '%s\n' "$derived_target"
}

rpm_mock_prepare(){
  local target="$1" phase="$2" family arch
  local -n out_args="$3" out_effective_target="$4"

  out_args=(--quiet)
  IFS=$'	' read -r family arch < <(split_target "$target")
  load_target rpm "$family" "$arch"

  case "$phase" in
    graph|build) ;;
    *) die "Unknown mock phase: $phase" ;;
  esac

  if [[ -n "${TARGET_RPM_MOCK_CONFIG_OPTS:-}" ]]; then
    local configured_args=()
    read -r -a configured_args <<<"$TARGET_RPM_MOCK_CONFIG_OPTS"
    out_args+=("${configured_args[@]}")
  fi

  if [[ -n "${TARGET_RPM_CHROOT_SETUP_CMD:-}" ]]; then
    out_args+=(--config-opts "chroot_setup_cmd=$TARGET_RPM_CHROOT_SETUP_CMD")
  fi

  out_effective_target="$(rpm_effective_mock_target "$target")"
}

rpm_mock_with_args(){
  local result="$1" msg="$2" target="$3" phase="$4"
  shift 4

  local mock_args=() effective_target
  rpm_mock_prepare "$target" "$phase" mock_args effective_target

  mkdir -p "$result"
  if mock -r "$effective_target" "${mock_args[@]}" "$@"; then
    return 0
  fi

  rpm_dump_mock_failure "$result" "$msg"
  die "$msg"
}


rpm_format_elapsed(){
  local seconds="${1:-0}"

  [[ "$seconds" =~ ^[0-9]+$ ]] || seconds=0
  printf '%dm%02ds' "$((seconds / 60))" "$((seconds % 60))"
}

rpm_rebuild_phase_markers_from_log(){
  local log="$1"

  [[ -f "$log" ]] || return 0

  awk '
    function emit(marker) {
      if (!seen[marker]++) print marker
    }
    /Executing\(%prep\)/ { emit("%prep"); next }
    /Executing\(%generate_buildrequires\)/ { emit("%generate_buildrequires"); next }
    /Executing\(%conf\)/ { emit("%conf"); next }
    /Executing\(%build\)/ { emit("%build"); next }
    /Executing\(%install\)/ { emit("%install"); next }
    /Executing\(%check\)/ { emit("%check"); next }
    /Executing\(%clean\)/ { emit("%clean"); next }
    /Processing files:/ { emit("%files"); next }
    /Checking for unpackaged file\(s\)/ { emit("unpackaged-file-check"); next }
    /Wrote:[[:space:]]/ { emit("wrote-rpms"); next }
  ' "$log" || true
}

rpm_rebuild_emit_new_phase_markers(){
  local reported_file="$1" package_name="$2" elapsed_text="$3"
  shift 3

  local marker emitted=0

  mkdir -p "$(dirname "$reported_file")"
  touch "$reported_file"

  while IFS= read -r marker; do
    [[ -n "$marker" ]] || continue
    if ! grep -Fxq -- "$marker" "$reported_file" 2>/dev/null; then
      printf '%s\n' "$marker" >>"$reported_file"
      echo "RPM rebuild phase: $package_name - $marker - elapsed $elapsed_text" >&2
      emitted=1
    fi
  done < <(
    for log in "$@"; do
      [[ -n "$log" && -f "$log" ]] || continue
      rpm_rebuild_phase_markers_from_log "$log"
    done | awk 'NF && !seen[$0]++'
  )

  [[ "$emitted" == 1 ]]
}

rpm_mock_rebuild_heartbeat_loop(){
  local result="$1" live_log="$2" reported_file="$3" package_name="$4" interval="$5" start="$6"
  local now elapsed elapsed_text

  while true; do
    sleep "$interval" || exit 0

    now="$(date +%s)"
    elapsed=$((now - start))
    elapsed_text="$(rpm_format_elapsed "$elapsed")"

    # mock --quiet can put the RPM phase markers in build.log rather than in
    # the wrapper-captured stdout/stderr log, so scan both while still only
    # printing each high-level marker once.
    if ! rpm_rebuild_emit_new_phase_markers \
      "$reported_file" \
      "$package_name" \
      "$elapsed_text" \
      "$result/build.log" \
      "$live_log"; then
      echo "Still building $package_name - elapsed $elapsed_text" >&2
    fi
  done
}

rpm_mock_rebuild_with_heartbeat(){
  local result="$1" msg="$2" target="$3" phase="$4" package_name="$5"
  shift 5

  local mock_args=() effective_target live_log reported_file heartbeat_pid status
  local interval start now elapsed elapsed_text

  interval="${RPM_BUILD_HEARTBEAT_SECONDS:-60}"
  case "$interval" in
    ''|*[!0-9]*|0) interval=60 ;;
  esac

  rpm_mock_prepare "$target" "$phase" mock_args effective_target

  mkdir -p "$result"
  live_log="$result/mock-rebuild-live.log"
  reported_file="$result/mock-rebuild-heartbeat-phases.txt"
  : >"$live_log"
  : >"$reported_file"
  # mock can leave build.log from an earlier run in the same result directory.
  # Remove it so heartbeat phases and cached summaries only reflect this rebuild.
  rm -f "$result/build.log"

  echo "Starting RPM rebuild: $package_name (heartbeat every ${interval}s; full output: ${live_log#$result/}; phases: build.log)" >&2

  start="$(date +%s)"
  rpm_mock_rebuild_heartbeat_loop "$result" "$live_log" "$reported_file" "$package_name" "$interval" "$start" &
  heartbeat_pid="$!"

  if mock -r "$effective_target" "${mock_args[@]}" "$@" >"$live_log" 2>&1; then
    status=0
  else
    status=$?
  fi

  kill "$heartbeat_pid" 2>/dev/null || true
  wait "$heartbeat_pid" 2>/dev/null || true

  now="$(date +%s)"
  elapsed=$((now - start))
  elapsed_text="$(rpm_format_elapsed "$elapsed")"
  rpm_rebuild_emit_new_phase_markers \
    "$reported_file" \
    "$package_name" \
    "$elapsed_text" \
    "$result/build.log" \
    "$live_log" || true

  if [[ "$status" -eq 0 ]]; then
    echo "RPM rebuild finished: $package_name - elapsed $elapsed_text" >&2
    return 0
  fi

  rpm_dump_mock_failure "$result" "$msg"
  die "$msg"
}

rpm_mock_out_with_binds(){
  local result="$1" msg="$2" target="$3" phase="$4" bind_count="$5"
  shift 5

  local mock_args=() bind_spec="[" separator="" host_path chroot_path out effective_target

  while ((bind_count > 0)); do
    host_path="$1"
    chroot_path="$2"
    shift 2
    bind_spec+="$separator('$host_path', '$chroot_path')"
    separator=","
    bind_count=$((bind_count - 1))
  done
  bind_spec+="]"

  rpm_mock_prepare "$target" "$phase" mock_args effective_target
  mock_args+=(
    --enable-plugin bind_mount
    --plugin-option "bind_mount:dirs=$bind_spec"
  )

  mkdir -p "$result"
  if out="$(mock -r "$effective_target" "${mock_args[@]}" "$@" 2>&1)"; then
    printf '%s\n' "$out"
    return 0
  fi

  printf '%s\n' "$out" >&2
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


rpm_finalize_stepwise_buildroot(){
  local result="$1" target="$2" log="$3"
  shift 3

  local mock_args=("$@") status
  local finalize_cmd='if command -v ldconfig >/dev/null 2>&1; then ldconfig; else echo "ldconfig not available; skipping"; fi'

  {
    echo
    echo "=== finalise buildroot after BuildRequires installs ==="
    echo "command=$finalize_cmd"
  } >>"$log"

  echo "BuildRequires are installed with scriptlets/triggers suppressed; refreshing the linker cache before rebuilds." >&2
  echo "Refreshing linker cache for $target" >&2

  if mock -r "$target" "${mock_args[@]}" --chroot "$finalize_cmd" >>"$log" 2>&1; then
    {
      echo "status=buildroot-finalised"
    } >>"$log"
  else
    status=$?
    {
      echo "status=buildroot-finalise-warning"
      echo "exit_status=$status"
      echo "continuing=true"
    } >>"$log"
    echo "warning: buildroot finalisation command exited with status $status; continuing to rebuild" >&2
  fi
}

rpm_buildrequires_install_attempt(){
  local result="$1" effective_target="$2" log="$3" txn_log="$4" dep="$5" index="$6" total="$7" attempt="$8" success_status="$9"
  local -n install_args="${10}"
  shift 10

  local mock_args=("$@") cmd_output status status_label

  cmd_output="$(mktemp "$result/stepwise-buildrequires.${index}.${attempt}.XXXXXX.log")"
  if mock -r "$effective_target" "${mock_args[@]}" --pm-cmd install "${install_args[@]}" "$dep" >"$cmd_output" 2>&1; then
    status=0
    status_label="$success_status"
  else
    status=$?
    status_label="failed"
  fi

  cat "$cmd_output" >>"$log"
  rpm_dnf_transaction_report_from_output "$dep" "$index" "$total" "$attempt" "$status_label" "$status" "$cmd_output" | tee -a "$txn_log" >&2
  rm -f "$cmd_output"

  return "$status"
}

rpm_install_buildrequires_stepwise(){
  local result="$1" msg="$2" target="$3" phase="$4" srpm="$5" deps_file="$6"
  shift 6

  local common_args=("$@") target_args=() mock_args=() effective_target
  local log txn_log dep status index total
  local install_flags=(-y --setopt=tsflags=noscripts,notriggers)
  local retry_flags=(-y --allowerasing --setopt=tsflags=noscripts,notriggers)

  mkdir -p "$result"
  log="$result/stepwise-buildrequires.log"
  txn_log="$result/stepwise-buildrequires-transactions.log"

  [[ -f "$deps_file" ]] || die "Missing BuildRequires list for stepwise install: $deps_file"
  total="$(awk 'NF { count++ } END { print count + 0 }' "$deps_file")"

  # The stepwise dependency installs must use the exact same mock root and
  # target-specific configuration as the surrounding build. In particular,
  # TARGET_RPM_MOCK_CONFIG_OPTS and TARGET_RPM_CHROOT_SETUP_CMD are applied by
  # rpm_mock_prepare(); dropping them here can accidentally re-enable mock's
  # bootstrap/tooling path or initialize a different root.
  rpm_mock_prepare "$target" "$phase" target_args effective_target
  mock_args=("${target_args[@]}" "${common_args[@]}")

  {
    echo "=== stepwise BuildRequires installation ==="
    echo "target=$target"
    echo "effective_target=$effective_target"
    echo "phase=$phase"
    echo "srpm=$srpm"
    echo "dependencies=$deps_file"
    echo "count=$total"
    echo "strategy=mock --pm-cmd install ${install_flags[*]} <BuildRequires-entry>"
    echo "retry_strategy=on failure only: mock --pm-cmd install ${retry_flags[*]} <BuildRequires-entry>"
    echo "target_args=${target_args[*]}"
    echo "common_args=${common_args[*]}"
    echo
    if [[ "$total" -gt 0 ]]; then
      sed 's/^/  /' "$deps_file"
    else
      echo "  no BuildRequires entries found in SRPM metadata after filtering internal rpmlib capabilities"
    fi
    echo
  } >"$log"

  {
    echo "=== stepwise BuildRequires DNF transaction results ==="
    echo "target=$target"
    echo "effective_target=$effective_target"
    echo "phase=$phase"
    echo "srpm=$srpm"
    echo "count=$total"
  } >"$txn_log"

  if [[ "$total" -eq 0 ]]; then
    local skip_status=(
      "status=no-buildrequires"
      "reason=SRPM has no real BuildRequires after filtering rpmlib capabilities"
    )

    rpm_log_lines_section "$log" "no BuildRequires entries" 1 0 "${skip_status[@]}"
    rpm_log_lines_section "$txn_log" "no BuildRequires transactions" 0 1 "${skip_status[@]}"
    return 0
  fi

  index=0
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    index=$((index + 1))

    rpm_log_lines_section \
      "$log" \
      "BuildRequires $index/$total" \
      1 \
      1 \
      "dependency=$dep" \
      "mock -r $effective_target ... --pm-cmd install ${install_flags[*]} $dep"

    if rpm_buildrequires_install_attempt "$result" "$effective_target" "$log" "$txn_log" "$dep" "$index" "$total" "normal" "installed" install_flags "${mock_args[@]}"; then
      echo "status=installed" >>"$log"
    else
      status=$?
      rpm_log_lines_section \
        "$log" \
        "normal BuildRequires install failed" \
        1 \
        1 \
        "dependency=$dep" \
        "exit_status=$status" \
        "retry=true" \
        "retry_strategy=mock --pm-cmd install ${retry_flags[*]} <BuildRequires-entry>" \
        "mock -r $effective_target ... --pm-cmd install ${retry_flags[*]} $dep"

      if rpm_buildrequires_install_attempt "$result" "$effective_target" "$log" "$txn_log" "$dep" "$index" "$total" "allowerasing-retry" "installed-after-allowerasing" retry_flags "${mock_args[@]}"; then
        echo "status=installed-after-allowerasing" >>"$log"
      else
        status=$?
        rpm_log_lines_section \
          "$log" \
          "failed BuildRequires dependency" \
          0 \
          1 \
          "dependency=$dep" \
          "exit_status=$status" \
          "normal_install_failed=true" \
          "allowerasing_retry_failed=true"

        rpm_dump_mock_failure "$result" "$msg"
        die "$msg; failed while installing BuildRequires entry: $dep"
      fi
    fi
  done <"$deps_file"

  rpm_log_lines_section "$log" "all BuildRequires entries installed successfully" 0 1

  rpm_finalize_stepwise_buildroot "$result" "$effective_target" "$log" "${mock_args[@]}"
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

rpm_build_srpm_and_prepare_dependencies(){
  local target="$1" unique="$2" result="$3" srpm_dir="$4" pkg_dir="$5" spec_path="$6" deps_file="$7" out_name="$8" url="${9:-}"
  local -n out_srpm="$out_name"

  rpm_build_srpm "$target" "$unique" "$srpm_dir" "$pkg_dir" "$spec_path" "$url"
  out_srpm="$(find "$srpm_dir" -maxdepth 1 -name '*.src.rpm' -print -quit)"
  [[ -n "$out_srpm" ]] || die "No SRPM created for $target/$(basename "$spec_path")"
  rpm_write_srpm_buildrequires "$result" "$out_srpm" "$deps_file"
}

rpm_rebuild(){
  local target="$1" unique="$2" result="$3" local_repo="$4" srpm="$5" deps_file="$6" spec_path="$7" url="${8:-}"
  local common_args=() rebuild_args=()

  common_args=(
    --uniqueext "$unique"
    --enable-network
    --resultdir "$result"
  )
  [[ -n "$url" ]] && common_args+=(--define "url $url")

  rebuild_args=("${common_args[@]}" --no-clean --rebuild "$srpm")

  RPM_LOCAL_REPO_PATH="$local_repo" rpm_mock_with_args "$result" "mock init failed for $target" "$target" build "${common_args[@]}" --init
  RPM_LOCAL_REPO_PATH="$local_repo" rpm_install_buildrequires_stepwise \
    "$result" \
    "mock build dependency install failed for $(basename "$srpm")" \
    "$target" \
    build \
    "$srpm" \
    "$deps_file" \
    "${common_args[@]}"

  RPM_LOCAL_REPO_PATH="$local_repo" rpm_mock_rebuild_with_heartbeat \
    "$result" \
    "mock rebuild failed for $(basename "$srpm")" \
    "$target" \
    build \
    "$(basename "$srpm")" \
    "${rebuild_args[@]}"
}

rpm_rebuild_and_write_cache_summary(){
  local target="$1" unique="$2" result="$3" local_repo="$4" srpm="$5" deps_file="$6" spec_path="$7" url="$8"
  local cache="$9" display_id="${10}" fingerprint="${11}" quick_fingerprint="${12}"

  rpm_rebuild "$target" "$unique" "$result" "$local_repo" "$srpm" "$deps_file" "$spec_path" "$url"
  rpm_write_cache_summary "$result" "$cache" "$target" "$display_id" "$fingerprint" "$quick_fingerprint"
  rpm_cache_summary_print "$cache" "$display_id"
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

    [[ "$line" =~ ^[[:space:]]*[Ss]ource[0-9]*[[:space:]]*:(.*)$ ]] || continue
    source="${BASH_REMATCH[1]}"

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

rpm_update_local_repo(){
  local dir="$1" log count

  mkdir -p "$dir"
  log="$(mktemp /tmp/repository-builder-createrepo.XXXXXX.log)"
  count="$(find "$dir" -maxdepth 1 -type f -name '*.rpm' | wc -l | awk '{print $1}')"

  if createrepo_c --update "$dir" >"$log" 2>&1; then
    rm -f "$log"
    echo "Updated local repo: $count binary RPMs available" >&2
  else
    echo "createrepo_c failed for $dir" >&2
    cat "$log" >&2 || true
    rm -f "$log"
    return 1
  fi
}

rpm_copy_artifacts(){
  local from="$1" repo="$2" source_repo="$3" local_repo="$4" recursive="${5:-0}"
  local file dest_name
  local artifacts=()

  if [[ "$recursive" == 1 ]]; then
    mapfile -t artifacts < <(find "$from" -name '*.rpm' -type f)
  else
    shopt -s nullglob
    artifacts=("$from"/*.rpm)
    shopt -u nullglob
  fi

  for file in "${artifacts[@]}"; do
    [[ -n "$file" ]] || continue
    dest_name="$(basename "$file")"
    if [[ "$file" == *.src.rpm ]]; then
      cp "$file" "$source_repo/$dest_name"
    else
      cp "$file" "$repo/$dest_name"
    fi
    cp "$file" "$local_repo/$dest_name"
  done

  rpm_update_local_repo "$local_repo"
}

rpm_cache_mode(){
  case "${CACHE_MODE:-normal}" in
    normal|debug) printf '%s' "${CACHE_MODE:-normal}" ;;
    *) die "Unsupported CACHE_MODE: ${CACHE_MODE}. Expected normal or debug." ;;
  esac
}

rpm_cache_has_required_artifacts(){
  local cache="$1"

  [[ -s "$cache/.build-summary.log" ]] || return 1
  find "$cache" -maxdepth 1 -type f \
    -name '*.rpm' \
    ! -name '*.src.rpm' \
    -print -quit | grep -q .
}


rpm_cache_summary_print(){
  local cache="$1" display_id="$2" result="${3:-}"
  local summary="$cache/.build-summary.log"
  local report="$summary" tmp

  [[ -s "$summary" ]] || die "Missing cached RPM dependency/build report for $display_id: $summary"

  if [[ -n "$result" ]]; then
    mkdir -p "$result"
    report="$result/rpm-build-report.log"
    tmp="$report.tmp.$$"
    {
      echo "=== RPM dependency/build report replay ==="
      echo "package=$display_id"
      echo "cache_status=reused"
      echo "replayed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "cached_report=$summary"
      echo
      cat "$summary"
    } >"$tmp"
    mv "$tmp" "$report"
  fi

  echo "--- RPM dependency/build report for $display_id ---" >&2
  cat "$report" >&2 || true
  echo "--- end RPM dependency/build report for $display_id ---" >&2
}

rpm_report_file(){
  local title="$1" file="$2"

  echo "=== $title ==="
  [[ -f "$file" ]] || die "Missing RPM report input: $file"
  cat "$file"
  echo
}

rpm_report_artifacts(){
  local title="$1" result="$2" kind="$3" file count=0
  local find_args=()

  echo "=== $title ==="
  case "$kind" in
    binary) find_args=(-name '*.rpm' ! -name '*.src.rpm') ;;
    source) find_args=(-name '*.src.rpm') ;;
    *) die "Unknown RPM artifact report kind: $kind" ;;
  esac

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    count=$((count + 1))
    printf '  - %s\n' "$(basename "$file")"
  done < <(find "$result" -type f "${find_args[@]}" | sort)

  ((count)) || echo "  none"
  echo "count=$count"
  echo
}

rpm_write_cache_summary(){
  local result="$1" cache="$2" target="$3" display_id="$4" fingerprint="$5" quick_fingerprint="$6"
  local summary="$cache/.build-summary.log" report="$result/rpm-build-report.log" tmp

  mkdir -p "$cache" "$result"
  tmp="$report.tmp.$$"

  {
    echo "=== RPM dependency/build report ==="
    echo "package=$display_id"
    echo "target=$target"
    echo "cache_status=built"
    echo "created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "fingerprint=$fingerprint"
    echo "quick_fingerprint=$quick_fingerprint"
    echo

    rpm_report_artifacts "binary RPM artifacts" "$result" binary
    rpm_report_artifacts "source RPM artifacts" "$result" source
    rpm_report_file "SRPM metadata and requested BuildRequires" "$result/srpm-buildrequires.log"
    rpm_report_file "requested BuildRequires list" "$result/stepwise-buildrequires.txt"
    rpm_report_file "exact stepwise BuildRequires DNF log" "$result/stepwise-buildrequires.log"
    rpm_report_file "stepwise BuildRequires DNF transaction summary" "$result/stepwise-buildrequires-transactions.log"
  } >"$tmp"

  mv "$tmp" "$report"
  cp "$report" "$summary"
  echo "RPM dependency/build report captured: ${report#$result/}" >&2
}


rpm_queue_fingerprint(){
  local mode="$1"
  local target="$2"
  local family="$3"
  local arch="$4"
  local staged_root="$5"
  local spec="$6"
  local source_id="$7"
  local subdir="$8"
  local srpm="${9:-}"
  local target_config_fp package_fp label config_file pkg_dir file

  case "$mode" in
    quick) label="rpm-queue-quick-fingerprint-$RPM_QUEUE_FINGERPRINT_VERSION" ;;
    srpm)
      label="rpm-queue-srpm-fingerprint-$RPM_QUEUE_FINGERPRINT_VERSION"
      [[ -f "$srpm" ]] || die "Missing SRPM for cache fingerprint: $srpm"
      ;;
    *) die "Unknown RPM queue fingerprint mode: $mode" ;;
  esac

  config_file="$(find_target_config rpm "$family" "$arch")"
  target_config_fp="$(
    {
      printf 'target_config_path=%s\n' "${config_file#$ROOT/}"
      printf 'target_config_sha256=%s\n' "$(sha256_file "$config_file")"
    } | sha256_lines
  )"

  pkg_dir="$staged_root/$subdir"
  [[ -d "$staged_root" ]] || die "Missing RPM packaging staging root for fingerprint: $staged_root"
  [[ -d "$pkg_dir" ]] || die "Missing RPM package directory for fingerprint: $pkg_dir"
  package_fp="$(
    cd "$staged_root"
    {
      find "$subdir" \
        -type d \( -name .git -o -name .github -o -name .cache -o -name __pycache__ -o -name BUILD -o -name RPMS -o -name SRPMS -o -name SOURCES -o -name tmp \) -prune \
        -o -type f \
        ! -name '*.rpm' \
        ! -name '*.src.rpm' \
        -print | sort | while IFS= read -r file; do
          printf '%s  %s\n' "$(sha256_file "$file")" "$file"
        done
    } | sha256_lines
  )"

  {
    printf '%s\n' "$label" "$source_id" "$subdir" "$spec" "$target" "$arch" "$target_config_fp" "$package_fp"
    if [[ "$mode" == srpm ]]; then
      sha256_file "$srpm"
    fi
  } | sha256_lines
}

rpm_build_queued(){
  local qfile="$1" target="$2" family="$3" arch="$4" repo_path="$5"
  local source_id source_safe package_id build_id display_id cache work srpm_dir result repo src_repo local_repo root mode
  local quick_fp cached_quick_fp fp cache_fp spec_path spec_dir url srpm deps_file

  load_queue "$qfile"
  source_id="${SOURCE_ID:-$PRIMARY_APP}"
  source_safe="$(safe_id "$source_id")"
  package_id="${PACKAGE:-${SPEC%.spec}}"
  build_id="$(safe_id "$package_id")"
  display_id="$source_id/$build_id"
  cache="/package-cache/rpm/$PRIMARY_APP/$target/$source_safe/$build_id"
  work="/work/rpm-build/$target/$source_safe/$build_id"
  srpm_dir="/work/rpm-srpm/$target/$source_safe/$build_id"
  result="/work/rpm-result/$target/$source_safe/$build_id"
  repo="$PUBLIC_DIR/$repo_path"
  src_repo="$repo/source"
  local_repo="/work/localrepo-$target"
  root="/work/work/$source_id"
  mode="$(rpm_cache_mode)"

  mkdir -p "$cache" "$result" "$repo" "$src_repo" "$local_repo"
  rpm_update_local_repo "$local_repo"

  fresh_dir "$work"
  fresh_dir "$srpm_dir"
  copy_source_tree "$work/src" "$root"
  if ! spec_path="$(rpm_prepare_effective "$work/src" "$SUBDIR" "$SPEC" "$root" "$family" "$target")"; then
    die "RPM spec preparation failed for $SPEC on $target"
  fi
  spec_dir="$(dirname "$spec_path")"
  url="https://example.invalid/$SPEC"
  deps_file="$result/stepwise-buildrequires.txt"

  quick_fp="$(rpm_queue_fingerprint quick "$target" "$family" "$arch" "$work/src" "$SPEC" "$source_id" "$SUBDIR")"

  if [[ "$mode" == debug ]]; then
    cached_quick_fp=""
    [[ -f "$cache/.quick-fingerprint" ]] && cached_quick_fp="$(cat "$cache/.quick-fingerprint")"

    if [[ "$cached_quick_fp" == "$quick_fp" ]] && rpm_cache_has_required_artifacts "$cache"; then
      echo "Using debug cached RPM artifacts for $target/$display_id: quick fingerprint matched" >&2
      rpm_cache_summary_print "$cache" "$target/$display_id" "$result"
      rpm_copy_artifacts "$cache" "$repo" "$src_repo" "$local_repo"
      return 0
    fi

    if [[ -z "$cached_quick_fp" ]]; then
      echo "RPM debug cache miss for $target/$display_id: no cached quick fingerprint" >&2
    elif [[ "$cached_quick_fp" != "$quick_fp" ]]; then
      echo "RPM debug cache miss for $target/$display_id: quick fingerprint changed" >&2
    else
      echo "RPM debug cache miss for $target/$display_id: cached RPM artifacts or dependency report missing" >&2
    fi
  fi

  RPM_LAYER_ROOT="$root" rpm_fetch_sources_in_mock "$target" "$result" "$spec_dir" "$SPEC"

  RPM_LAYER_ROOT="$root" rpm_build_srpm_and_prepare_dependencies "$target" "srpm-$target-$source_safe-$build_id" "$result" "$srpm_dir" "$spec_dir" "$spec_path" "$deps_file" srpm "$url"

  fp="$(rpm_queue_fingerprint srpm "$target" "$family" "$arch" "$work/src" "$SPEC" "$source_id" "$SUBDIR" "$srpm")"

  cache_fp=""
  [[ -f "$cache/.fingerprint" ]] && cache_fp="$(cat "$cache/.fingerprint")"

  if [[ "$cache_fp" == "$fp" ]] && rpm_cache_has_required_artifacts "$cache"; then
    echo "Using cached RPM artifacts for $target/$display_id: SRPM fingerprint matched" >&2
    printf '%s' "$quick_fp" >"$cache/.quick-fingerprint"
    rpm_cache_summary_print "$cache" "$target/$display_id" "$result"
    rpm_copy_artifacts "$cache" "$repo" "$src_repo" "$local_repo"
    return 0
  fi

  if [[ -z "$cache_fp" ]]; then
    echo "RPM cache miss for $target/$display_id: no cached SRPM fingerprint" >&2
  elif [[ "$cache_fp" != "$fp" ]]; then
    echo "RPM cache miss for $target/$display_id: SRPM or repository inputs changed" >&2
  else
    echo "RPM cache miss for $target/$display_id: cached RPM artifacts or dependency report missing" >&2
  fi

  RPM_LAYER_ROOT="$root" rpm_rebuild_and_write_cache_summary \
    "$target" \
    "$target-$source_safe-$build_id" \
    "$result" \
    "$local_repo" \
    "$srpm" \
    "$deps_file" \
    "$spec_path" \
    "$url" \
    "$cache" \
    "$target/$display_id" \
    "$fp" \
    "$quick_fp"
  rm -f "$cache"/*.rpm "$cache"/*.src.rpm
  find "$result" -name '*.rpm' -type f -exec cp {} "$cache/" \;
  printf '%s' "$fp" >"$cache/.fingerprint"
  printf '%s' "$quick_fp" >"$cache/.quick-fingerprint"
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

  rpm_update_local_repo "$dir"
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
  local package

  load_queue "$1"
  package="${PACKAGE:-${SPEC%.spec}}"
  safe_id "${SOURCE_ID:-$PRIMARY_APP}-$package-$SUBDIR"
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

rpm_queue_spec(){
  local qdir="$1" queue_id="$2" source_id="$3" package="$4" spec_name="$5" subdir="$6"

  queue_write \
    "$qdir" \
    "$(safe_id "$queue_id")" \
    QUEUE_TYPE=rpm \
    SUBDIR="$subdir" \
    SPEC="$spec_name" \
    PACKAGE="$package" \
    SOURCE_ID="$source_id" >/dev/null
  metadata_append_package "$package"
}

rpm_prepare_target_queue(){
  local target="$1"
  local family="$2"
  local qdir="/work/package-build-queue-target/rpm/$target"
  local source_id root spec_name spec_path package subdir key package_key
  local -A queued=()
  local -A queued_package=()

  fresh_dir "$qdir"

  for source_id in "${APPS[@]}"; do
    root="/work/work/$source_id"

    while IFS= read -r spec_name; do
      package="${spec_name%.spec}"
      key="$source_id|$package|$spec_name|$package"
      package_key="$source_id|$package"
      queued[$key]=1
      queued_package[$package_key]=1
      rpm_queue_spec "$qdir" "$source_id-layered-$package" "$source_id" "$package" "$spec_name" "$package"
    done < <(layered_names "$root" "$family" "$target" specs '*.spec')

    while IFS= read -r subdir; do
      package="$(basename "$subdir")"
      spec_name="$package.spec"
      spec_path="$root/$subdir/$spec_name"
      key="$source_id|$package|$spec_name|$subdir"
      package_key="$source_id|$package"
      [[ -z "${queued[$key]+x}" ]] || continue
      [[ -z "${queued_package[$package_key]+x}" ]] || continue
      queued[$key]=1
      queued_package[$package_key]=1
      rpm_queue_spec "$qdir" "$source_id-repo-$package-$subdir" "$source_id" "$package" "$spec_name" "$subdir"
    done < <(
      find "$root" -mindepth 1 -maxdepth 1 -type d \
        ! -name .git \
        ! -name .github \
        ! -name .cache \
        ! -name __pycache__ \
        ! -name BUILD \
        ! -name RPMS \
        ! -name SRPMS \
        ! -name SOURCES \
        ! -name tmp \
        ! -name macros \
        ! -name patches \
        ! -name replacements \
        ! -name specs \
        -printf '%f\n' | sort | while IFS= read -r subdir; do
          [[ -f "$root/$subdir/$subdir.spec" ]] && printf '%s\n' "$subdir"
        done
    )
  done

  printf '%s' "$qdir"
}

rpm_build_targets(){
  local target family arch repo_path repo_id repo_file label qdir qfile index total progress_name
  local qfiles=()

  echo "RPM cache mode: $(rpm_cache_mode)" >&2

  while IFS= read -r target; do
    echo "==> RPM target: $target"
    IFS=$'\t' read -r family arch repo_path repo_id repo_file label < <(repo_info rpm "$PRIMARY_APP" "$target")

    mkdir -p "$PUBLIC_DIR/$repo_path/source" "/work/localrepo-$target"
    rpm_update_local_repo "/work/localrepo-$target"

    qdir="$(rpm_prepare_target_queue "$target" "$family")"
    ordered_queue_files \
      qfiles \
      "/work/package-graph/rpm/$target" \
      "$target" \
      "$family" \
      "$qdir" \
      "No layered RPM specs were found for $target" \
      rpm

    total="${#qfiles[@]}"
    index=0

    for qfile in "${qfiles[@]}"; do
      index=$((index + 1))

      load_queue "$qfile"
      progress_name="${PACKAGE:-${SPEC%.spec}}"

      echo "[$index/$total] Building $progress_name" >&2

      rpm_build_queued "$qfile" "$target" "$family" "$arch" "$repo_path"
    done

    rpm_publish "$target" "$repo_path"
    rpm_write_repo "$repo_id" "$repo_file" "$repo_path" "$label"
    metadata_append targets.txt "$target"
  done < <(targets_list)
}
