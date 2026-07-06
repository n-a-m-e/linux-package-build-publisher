# shellcheck shell=bash

# RPM backend: mock, rpmbuild/rpmspec, createrepo, signing, graphing, publishing, and RPM-specific diagnostics.

# Normal RPM builds should keep the GitHub log summary-first. Detailed
# mock/repository diagnostics are still written under each package result
# directory, but they are only printed inline when a command fails.
declare -Ag RPM_REPO_DEBUG_SEEN=()
RPM_LDCONFIG_EXPLANATION_PRINTED=0

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

rpm_mock_log_inline_candidate(){
  local rel="$1"

  # These logs are useful as saved artifacts, but very noisy inline:
  # - installed_pkgs.log can contain hundreds of rpm-queryformat "pkgid" warnings
  # - state.log is mostly mock lifecycle/cleanup chatter
  # - mock-repo-debug logs contain full config/repolist dumps
  case "$rel" in
    installed_pkgs.log|*/installed_pkgs.log|state.log|*/state.log|mock-repo-debug/*|*/mock-repo-debug/*)
      return 1
      ;;
  esac

  return 0
}

rpm_filter_noisy_mock_tail(){
  awk '
    /incorrect format: unknown tag: "pkgid"/ { next }
    /Child return code was: 0/ { next }
    /child environment: None/ { next }
    index($0, "Executing command: [") && index($0, "/bin/umount") { next }
    index($0, "Executing command: [") && index($0, "/bin/mount") { next }
    /Start: cleaning package manager metadata/ { next }
    /Finish: cleaning package manager metadata/ { next }
    /Start: chroot init/ { next }
    /Finish: chroot init/ { next }
    /Finish: run/ { next }
    { print }
  '
}

rpm_dump_mock_failure(){
  local dir="$1" msg="$2" lines="${MOCK_LOG_TAIL_LINES:-200}"
  local log rel found=0 skipped=0

  error "$msg"

  shopt -s nullglob
  for log in "$dir"/*.log "$dir"/*/*.log; do
    [[ -f "$log" ]] || continue
    rel="${log#$dir/}"
    if ! rpm_mock_log_inline_candidate "$rel"; then
      skipped=$((skipped + 1))
      continue
    fi
    found=1
    echo "--- $rel (last $lines lines, filtered) ---" >&2
    tail -n "$lines" "$log" | rpm_filter_noisy_mock_tail >&2 || true
  done
  shopt -u nullglob

  if ((skipped)); then
    echo "--- skipped $skipped noisy mock diagnostic log(s); full logs remain in the result artifacts ---" >&2
  fi

  if ! ((found)); then
    echo "--- no primary mock result logs found in $dir ---" >&2
  fi
}

rpm_diagnostic_write_srpm_host(){
  local result="$1" srpm="$2" log count

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

  count="$(rpm -qpR "$srpm" 2>/dev/null | awk 'NF && $0 !~ /^rpmlib\(/ { count++ } END { print count + 0 }')"
  echo "SRPM metadata captured: ${log#$result/} ($count BuildRequires entries)" >&2
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

rpm_repo_fragment_section_ids(){
  local file="$1"

  sed -nE 's/^[[:space:]]*\[([^]]+)\].*$/\1/p' "$file" | awk 'NF && !seen[$0]++'
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
    rpm_repo_fragment_section_ids "$file"
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

rpm_write_mock_config_text_assignment(){
  local cfg_file="$1" text_file="$2"

  {
    printf "config_opts['dnf.conf'] = r'''\n"
    cat "$text_file"
    printf "\n'''\n"
  } >>"$cfg_file"
}

rpm_effective_mock_target(){
  local target="$1" family arch root="${RPM_LAYER_ROOT:-}"
  local repo_files=() cfg_file safe_source safe_target derived_target file
  local release tmp_dir expanded mode replace_id rel current next section merged

  [[ -n "$root" && -d "$root" ]] || { printf '%s\n' "$target"; return 0; }

  IFS=$'\t' read -r family arch < <(split_target "$target")
  mapfile -t repo_files < <(rpm_layered_repo_files "$root" "$family" "$target")
  ((${#repo_files[@]})) || { printf '%s\n' "$target"; return 0; }

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

  {
    printf "include('/etc/mock/%s.cfg')\n" "$target"
    printf '\n# repository-builder merged dnf.conf generated in bash from layered repos\n'
  } >"$cfg_file"
  rpm_write_mock_config_text_assignment "$cfg_file" "$current"

  printf '%s\n' "$derived_target"
}

rpm_mock_args_array(){
  local target="$1" phase="$2" family arch
  local -n out_args="$3"

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

}

rpm_mock_with_args(){
  local result="$1" msg="$2" target="$3" phase="$4"
  shift 4

  local mock_args=() effective_target
  rpm_mock_args_array "$target" "$phase" mock_args
  effective_target="$(rpm_effective_mock_target "$target")"

  mkdir -p "$result"
  rpm_mock_repo_debug "$result" "$target" "$effective_target" "before-${phase}-mock-command" "${mock_args[@]}"
  if mock -r "$effective_target" "${mock_args[@]}" "$@"; then
    return 0
  fi

  rpm_mock_repo_failure_debug "$result" "$target" "$effective_target" "failure-${phase}-mock-command" "${mock_args[@]}"
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

  rpm_mock_args_array "$target" "$phase" mock_args
  effective_target="$(rpm_effective_mock_target "$target")"
  rpm_mock_repo_debug "$result" "$target" "$effective_target" "before-${phase}-mock-bind-command" "${mock_args[@]}"
  mock_args+=(
    --enable-plugin bind_mount
    --plugin-option "bind_mount:dirs=$bind_spec"
  )

  mkdir -p "$result"
  if out="$(mock -r "$effective_target" "${mock_args[@]}" "$@" 2>&1)"; then
    printf '%s
' "$out"
    return 0
  fi

  printf '%s
' "$out" >&2
  rpm_mock_repo_failure_debug "$result" "$target" "$effective_target" "failure-${phase}-mock-bind-command" "${mock_args[@]}"
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


rpm_buildrequires_from_srpm(){
  local srpm="$1" output="$2"
  local tmp

  [[ -f "$srpm" ]] || die "Missing SRPM for BuildRequires parsing: $srpm"
  mkdir -p "$(dirname "$output")"
  tmp="$output.tmp"

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

  mv "$tmp" "$output"
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

  if [[ "${RPM_LDCONFIG_EXPLANATION_PRINTED:-0}" != 1 ]]; then
    echo "BuildRequires are installed with scriptlets/triggers suppressed; refreshing the linker cache before rebuilds." >&2
    RPM_LDCONFIG_EXPLANATION_PRINTED=1
  fi
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

rpm_safe_filename(){
  local value="$1"
  value="${value//[^A-Za-z0-9_.:+@%=-]/_}"
  [[ -n "$value" ]] || value="unknown"
  printf '%s\n' "$value"
}

rpm_dnf_dependency_diagnostics(){
  local result="$1" effective_target="$2" log="$3" dep="$4" label="$5"
  shift 5

  local mock_args=("$@") diag_root diag_dir safe_dep safe_label
  local providers_file missing_file provider missing safe provider_count missing_count

  safe_dep="$(rpm_safe_filename "$dep")"
  safe_label="$(rpm_safe_filename "$label")"
  diag_root="$result/dnf-dependency-diagnostics"
  diag_dir="$diag_root/$safe_label-$safe_dep"
  mkdir -p "$diag_dir"

  {
    echo
    echo "=== generic DNF dependency diagnostics ==="
    echo "label=$label"
    echo "dependency=$dep"
    echo "effective_target=$effective_target"
    echo "diagnostics_dir=${diag_dir#$result/}"
  } | tee -a "$log" >&2

  mock -r "$effective_target" "${mock_args[@]}" \
    --pm-cmd repoquery --whatprovides "$dep" \
    >"$diag_dir/whatprovides-dependency.txt" 2>&1 || true

  mock -r "$effective_target" "${mock_args[@]}" \
    --pm-cmd repoquery --whatprovides --showduplicates "$dep" \
    >"$diag_dir/whatprovides-dependency-showduplicates.txt" 2>&1 || true

  mock -r "$effective_target" "${mock_args[@]}" \
    --pm-cmd repoquery --qf '%{name}' --whatprovides "$dep" \
    >"$diag_dir/provider-names.raw.txt" 2>&1 || true

  providers_file="$diag_dir/provider-names.txt"
  awk '
    /^[[:space:]]*$/ { next }
    /^Last metadata expiration check:/ { next }
    /^No matching Packages/ { next }
    /^Error:/ { next }
    /^Unable to/ { next }
    /^[A-Za-z0-9_.:+@%-]+$/ { print }
  ' "$diag_dir/provider-names.raw.txt" | sort -u >"$providers_file"

  # Fall back to parsing normal repoquery output if queryformat is unavailable
  # or if the active package manager returns full NEVRAs despite --qf.
  if [[ ! -s "$providers_file" ]]; then
    awk '
      /^[[:space:]]*$/ { next }
      /^Last metadata expiration check:/ { next }
      /^No matching Packages/ { next }
      /^Error:/ { next }
      /^Unable to/ { next }
      {
        item=$1
        sub(/\.[A-Za-z0-9_]+$/, "", item)
        n=split(item, parts, "-")
        if (n >= 3) {
          name=parts[1]
          for (i=2; i<=n-2; i++) name=name "-" parts[i]
          print name
        } else {
          print item
        }
      }
    ' "$diag_dir/whatprovides-dependency.txt" | sort -u >"$providers_file"
  fi

  provider_count="$(awk 'NF { count++ } END { print count + 0 }' "$providers_file")"

  while IFS= read -r provider; do
    [[ -n "$provider" ]] || continue
    safe="$(rpm_safe_filename "$provider")"

    mock -r "$effective_target" "${mock_args[@]}" \
      --pm-cmd repoquery --available --showduplicates "$provider" \
      >"$diag_dir/showduplicates-$safe.txt" 2>&1 || true

    mock -r "$effective_target" "${mock_args[@]}" \
      --pm-cmd repoquery --requires "$provider" \
      >"$diag_dir/requires-$safe.txt" 2>&1 || true

    mock -r "$effective_target" "${mock_args[@]}" \
      --pm-cmd repoquery --requires --resolve "$provider" \
      >"$diag_dir/requires-resolve-$safe.txt" 2>&1 || true
  done <"$providers_file"

  missing_file="$diag_dir/missing-capabilities.txt"
  grep -Eo 'nothing provides [^[:space:]]+' "$log" \
    | sed -E 's/^nothing provides //' \
    | sort -u >"$missing_file" || true

  missing_count="$(awk 'NF { count++ } END { print count + 0 }' "$missing_file")"

  while IFS= read -r missing; do
    [[ -n "$missing" ]] || continue
    safe="$(rpm_safe_filename "$missing")"

    mock -r "$effective_target" "${mock_args[@]}" \
      --pm-cmd repoquery --whatprovides "$missing" \
      >"$diag_dir/whatprovides-missing-$safe.txt" 2>&1 || true

    mock -r "$effective_target" "${mock_args[@]}" \
      --pm-cmd repoquery --whatprovides --showduplicates "$missing" \
      >"$diag_dir/whatprovides-missing-showduplicates-$safe.txt" 2>&1 || true
  done <"$missing_file"

  {
    echo "provider_count=$provider_count"
    if [[ "$provider_count" -gt 0 ]]; then
      echo "providers:"
      sed 's/^/  - /' "$providers_file"
    else
      echo "providers: none found"
    fi
    echo "missing_capability_count=$missing_count"
    if [[ "$missing_count" -gt 0 ]]; then
      echo "missing_capabilities:"
      sed 's/^/  - /' "$missing_file"
    else
      echo "missing_capabilities: none found in install log so far"
    fi
    echo "diagnostic_files:"
    find "$diag_dir" -maxdepth 1 -type f -printf '  - %f\n' | sort
  } | tee -a "$log" >&2
}


rpm_mock_config_debug_dump(){
  local log="$1" cfg="$2" depth="${3:-0}" file dir include inc_path

  [[ -n "$cfg" ]] || return 0
  [[ "$depth" -le 4 ]] || {
    echo "config_include_depth_limit_reached=$cfg" >>"$log"
    return 0
  }

  if [[ ! -f "$cfg" ]]; then
    {
      echo
      echo "--- missing mock config: $cfg ---"
    } >>"$log"
    return 0
  fi

  {
    echo
    echo "--- mock config: $cfg ---"
    cat "$cfg"
  } >>"$log"

  dir="$(dirname "$cfg")"
  while IFS= read -r include; do
    [[ -n "$include" ]] || continue
    if [[ "$include" = /* ]]; then
      inc_path="$include"
    else
      inc_path="$dir/$include"
      [[ -f "$inc_path" ]] || inc_path="/etc/mock/$include"
    fi
    rpm_mock_config_debug_dump "$log" "$inc_path" $((depth + 1))
  done < <(
    awk '
      /^[[:space:]]*include\(/ {
        line = $0
        sub(/^[[:space:]]*include\(/, "", line)
        sub(/\).*/, "", line)
        gsub(/\047/, "", line)
        gsub(/"/, "", line)
        if (line != "" && !seen[line]++) print line
      }
    ' "$cfg"
  )
}

rpm_debug_dump_file(){
  local log="$1" title="$2" file="$3" inline="${4:-0}"
  {
    echo
    echo "=== $title ==="
    if [[ -f "$file" ]]; then
      cat "$file"
    else
      echo "missing_file=$file"
    fi
  } >>"$log"

  if [[ "$inline" == 1 ]]; then
    {
      echo
      echo "=== $title ==="
      if [[ -f "$file" ]]; then
        cat "$file"
      else
        echo "missing_file=$file"
      fi
    } >&2
  fi
}

rpm_mock_repo_fragment_debug(){
  local log="$1" root="$2" family="$3" target="$4" rel file

  if [[ -n "$root" && -d "$root" ]]; then
    {
      echo
      echo "=== layered repo fragments visible to this source ==="
    } >>"$log"
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      rel="${file#$root/}"
      {
        echo
        echo "--- layered repo fragment: $rel ---"
        cat "$file"
      } >>"$log"
    done < <(rpm_layered_repo_files "$root" "$family" "$target")
  else
    echo "layered_repo_fragments=not_checked_no_RPM_LAYER_ROOT" >>"$log"
  fi
}

rpm_mock_repo_debug(){
  local result="$1" target="$2" effective_target="$3" label="$4"
  shift 4

  local mock_args=("$@") diag_dir log root family arch status cfg key hash

  key="$effective_target"
  if [[ -n "${RPM_REPO_DEBUG_SEEN[$key]:-}" ]]; then
    return 0
  fi
  RPM_REPO_DEBUG_SEEN[$key]=1

  mkdir -p "$result"
  diag_dir="$result/mock-repo-debug"
  mkdir -p "$diag_dir"
  log="$diag_dir/$label.log"
  : >"$log"

  cfg="/etc/mock/$effective_target.cfg"
  hash="missing"
  [[ -f "$cfg" ]] && hash="$(sha256_file "$cfg")"

  {
    echo "=== mock repository debug ==="
    echo "label=$label"
    echo "target=$target"
    echo "effective_target=$effective_target"
    echo "mock_args=${mock_args[*]}"
    echo "mock_config=$cfg"
    echo "mock_config_sha256=$hash"
    echo "debug_dir=${diag_dir#$result/}"
    echo
    echo "=== generated and included mock config tree ==="
  } >>"$log"

  rpm_mock_config_debug_dump "$log" "$cfg" 0

  root="${RPM_LAYER_ROOT:-}"
  IFS=$'\t' read -r family arch < <(split_target "$target") || true
  if [[ -n "${family:-}" ]]; then
    rpm_mock_repo_fragment_debug "$log" "$root" "$family" "$target"
  fi

  {
    echo
    echo "=== mock --pm-cmd repolist --enabled ==="
  } >>"$log"
  if mock -r "$effective_target" "${mock_args[@]}" --pm-cmd repolist --enabled >>"$log" 2>&1; then
    echo "repolist_enabled_status=0" >>"$log"
  else
    status=$?
    echo "repolist_enabled_status=$status" >>"$log"
    echo "note=enabled repolist may not be supported before the package-manager environment exists" >>"$log"
  fi

  {
    echo
    echo "=== mock repo debug complete ==="
    echo "mock_repo_debug_log=${log#$result/}"
  } >>"$log"

  echo "Mock repo diagnostics captured for $effective_target: ${log#$result/} (config sha256: $hash)" >&2
}

rpm_mock_repo_failure_debug(){
  local result="$1" target="$2" effective_target="$3" label="$4"
  shift 4

  local mock_args=("$@") diag_dir log root family arch status cfg hash

  mkdir -p "$result"
  diag_dir="$result/mock-repo-debug"
  mkdir -p "$diag_dir"
  log="$diag_dir/$label.log"
  : >"$log"

  cfg="/etc/mock/$effective_target.cfg"
  hash="missing"
  [[ -f "$cfg" ]] && hash="$(sha256_file "$cfg")"

  {
    echo "=== mock repository failure debug ==="
    echo "label=$label"
    echo "target=$target"
    echo "effective_target=$effective_target"
    echo "mock_args=${mock_args[*]}"
    echo "mock_config=$cfg"
    echo "mock_config_sha256=$hash"
    echo "debug_dir=${diag_dir#$result/}"
    echo
    echo "=== generated and included mock config tree ==="
  } >>"$log"

  rpm_mock_config_debug_dump "$log" "$cfg" 0

  root="${RPM_LAYER_ROOT:-}"
  IFS=$'\t' read -r family arch < <(split_target "$target") || true
  if [[ -n "${family:-}" ]]; then
    rpm_mock_repo_fragment_debug "$log" "$root" "$family" "$target"
  fi

  {
    echo
    echo "=== mock --pm-cmd repolist --enabled ==="
  } >>"$log"
  mock -r "$effective_target" "${mock_args[@]}" --pm-cmd repolist --enabled >>"$log" 2>&1 || { status=$?; echo "repolist_enabled_status=$status" >>"$log"; }

  {
    echo
    echo "=== mock --pm-cmd repolist --all ==="
  } >>"$log"
  mock -r "$effective_target" "${mock_args[@]}" --pm-cmd repolist --all >>"$log" 2>&1 || { status=$?; echo "repolist_all_status=$status" >>"$log"; }

  {
    echo
    echo "=== mock --pm-cmd repolist -v ==="
  } >>"$log"
  mock -r "$effective_target" "${mock_args[@]}" --pm-cmd repolist -v >>"$log" 2>&1 || { status=$?; echo "repolist_verbose_status=$status" >>"$log"; }

  {
    echo
    echo "=== mock repo failure debug complete ==="
    echo "mock_repo_failure_debug_log=${log#$result/}"
  } >>"$log"

  echo "Mock failure diagnostics captured: ${log#$result/}" >&2
}

rpm_install_buildrequires_stepwise(){
  local result="$1" msg="$2" target="$3" phase="$4" srpm="$5"
  shift 5

  local common_args=("$@") target_args=() mock_args=() effective_target
  local deps_file log dep status index total
  local install_flags=(-y --setopt=tsflags=noscripts,notriggers)
  local retry_flags=(-y --allowerasing --setopt=tsflags=noscripts,notriggers)

  mkdir -p "$result"
  deps_file="$result/stepwise-buildrequires.txt"
  log="$result/stepwise-buildrequires.log"

  rpm_buildrequires_from_srpm "$srpm" "$deps_file"
  total="$(awk 'NF { count++ } END { print count + 0 }' "$deps_file")"

  # The stepwise dependency installs must use the exact same mock root and
  # target-specific configuration as the surrounding build. In particular,
  # TARGET_RPM_MOCK_CONFIG_OPTS and TARGET_RPM_CHROOT_SETUP_CMD are applied by
  # rpm_mock_args_array(); dropping them here can accidentally re-enable mock's
  # bootstrap/tooling path or initialize a different root.
  rpm_mock_args_array "$target" "$phase" target_args
  effective_target="$(rpm_effective_mock_target "$target")"
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

  rpm_mock_repo_debug "$result" "$target" "$effective_target" "before-stepwise-buildrequires" "${mock_args[@]}"

  if [[ "$total" -eq 0 ]]; then
    {
      echo "=== no BuildRequires entries ==="
      echo "status=skipped-stepwise-install"
      echo "reason=SRPM has no real BuildRequires after filtering rpmlib capabilities"
    } | tee -a "$log" >&2
    return 0
  fi

  index=0
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    index=$((index + 1))

    {
      echo
      echo "=== BuildRequires $index/$total ==="
      echo "dependency=$dep"
      echo "mock -r $effective_target ... --pm-cmd install ${install_flags[*]} $dep"
    } | tee -a "$log" >&2

    if mock -r "$effective_target" "${mock_args[@]}" --pm-cmd install "${install_flags[@]}" "$dep" >>"$log" 2>&1; then
      {
        echo "status=installed"
      } >>"$log"
    else
      status=$?
      {
        echo
        echo "=== normal BuildRequires install failed ==="
        echo "dependency=$dep"
        echo "exit_status=$status"
        echo "retry=true"
        echo "retry_strategy=mock --pm-cmd install ${retry_flags[*]} <BuildRequires-entry>"
        echo "mock -r $effective_target ... --pm-cmd install ${retry_flags[*]} $dep"
      } | tee -a "$log" >&2

      rpm_dnf_dependency_diagnostics "$result" "$effective_target" "$log" "$dep" "normal-install-failed" "${mock_args[@]}"

      if mock -r "$effective_target" "${mock_args[@]}" --pm-cmd install "${retry_flags[@]}" "$dep" >>"$log" 2>&1; then
        {
          echo "status=installed-after-allowerasing"
        } >>"$log"
      else
        status=$?
        {
          echo
          echo "=== failed BuildRequires dependency ==="
          echo "dependency=$dep"
          echo "exit_status=$status"
          echo "normal_install_failed=true"
          echo "allowerasing_retry_failed=true"
        } >>"$log"

        rpm_dnf_dependency_diagnostics "$result" "$effective_target" "$log" "$dep" "allowerasing-retry-failed" "${mock_args[@]}"

        rpm_stepwise_buildrequires_failure_report "$result" "$log"
        rpm_mock_repo_failure_debug "$result" "$target" "$effective_target" "failure-stepwise-buildrequires" "${mock_args[@]}"
        rpm_dump_mock_failure "$result" "$msg"
        echo "--- ${log#$result/} (last ${MOCK_LOG_TAIL_LINES:-200} lines) ---" >&2
        tail -n "${MOCK_LOG_TAIL_LINES:-200}" "$log" >&2 || true
        die "$msg; failed while installing BuildRequires entry: $dep"
      fi
    fi
  done <"$deps_file"

  {
    echo
    echo "=== all BuildRequires entries installed successfully ==="
  } >>"$log"

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
    "$srpm" \
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
  local source download_url filename url_hash cache_file tmp dest mode

  [[ -d "$spec_dir" ]] || die "Missing RPM source directory: $spec_dir"
  [[ -f "$source_list" ]] || die "Missing expanded RPM source list: $source_list"
  command -v curl >/dev/null 2>&1 || die "curl is not installed in the host builder container"
  mkdir -p "$cache_dir"
  mode="$(rpm_cache_mode)"

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

        if [[ "$mode" != off && -s "$cache_file" ]]; then
          echo "Using cached source: $source -> $filename" >&2
        else
          if [[ "$mode" == off ]]; then
            echo "Downloading source without cache read: $download_url -> $filename" >&2
          else
            echo "Downloading source: $download_url -> $filename" >&2
          fi
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
    echo "Updated local repo: $count packages" >&2
  else
    echo "createrepo_c failed for $dir" >&2
    tail -n "${MOCK_LOG_TAIL_LINES:-200}" "$log" >&2 || true
    rm -f "$log"
    return 1
  fi
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

  rpm_update_local_repo "$local_repo"
}

rpm_cache_mode(){
  case "${CACHE_MODE:-normal}" in
    normal|debug|off) printf '%s' "${CACHE_MODE:-normal}" ;;
    *) die "Unsupported CACHE_MODE: ${CACHE_MODE}. Expected normal, debug, or off." ;;
  esac
}

rpm_cache_has_binary_rpms(){
  local cache="$1"

  find "$cache" -maxdepth 1 -type f \
    -name '*.rpm' \
    ! -name '*.src.rpm' \
    -print -quit | grep -q .
}


rpm_target_config_fingerprint(){
  local package_type="$1"
  local family="$2"
  local arch="$3"
  local config_file

  config_file="$(find_target_config "$package_type" "$family" "$arch")"
  {
    printf 'target_config_path=%s\n' "${config_file#$ROOT/}"
    printf 'target_config_sha256=%s\n' "$(sha256_file "$config_file")"
  } | sha256_lines
}

rpm_package_input_fingerprint(){
  local staged_root="$1"
  local subdir="$2"
  local pkg_dir="$staged_root/$subdir"
  local file

  [[ -d "$staged_root" ]] || die "Missing RPM packaging staging root for fingerprint: $staged_root"
  [[ -d "$pkg_dir" ]] || die "Missing RPM package directory for fingerprint: $pkg_dir"
  (
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
  )
}

rpm_queue_quick_fingerprint(){
  local target="$1"
  local family="$2"
  local arch="$3"
  local staged_root="$4"
  local spec="$5"
  local source_id="$6"
  local subdir="$7"
  local target_config_fp package_fp

  target_config_fp="$(rpm_target_config_fingerprint rpm "$family" "$arch")"
  package_fp="$(rpm_package_input_fingerprint "$staged_root" "$subdir")"

  {
    printf '%s\n' "rpm-queue-quick-fingerprint-v5" "$source_id" "$subdir" "$spec" "$target" "$arch" "$target_config_fp" "$package_fp"
  } | sha256_lines
}

rpm_queue_srpm_fingerprint(){
  local target="$1"
  local family="$2"
  local arch="$3"
  local staged_root="$4"
  local spec="$5"
  local source_id="$6"
  local subdir="$7"
  local srpm="$8"
  local target_config_fp package_fp

  [[ -f "$srpm" ]] || die "Missing SRPM for cache fingerprint: $srpm"
  target_config_fp="$(rpm_target_config_fingerprint rpm "$family" "$arch")"
  package_fp="$(rpm_package_input_fingerprint "$staged_root" "$subdir")"

  {
    printf '%s\n' "rpm-queue-srpm-fingerprint-v5" "$source_id" "$subdir" "$spec" "$target" "$arch" "$target_config_fp" "$package_fp"
    sha256_file "$srpm"
  } | sha256_lines
}

rpm_build_queued(){
  local qfile="$1" target="$2" family="$3" arch="$4" repo_path="$5"
  local source_id source_safe package_id build_id display_id cache work srpm_dir result repo src_repo local_repo root mode
  local quick_fp cached_quick_fp fp cache_fp spec_path spec_dir url srpm

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

  quick_fp="$(rpm_queue_quick_fingerprint "$target" "$family" "$arch" "$work/src" "$SPEC" "$source_id" "$SUBDIR")"

  if [[ "$mode" == debug ]]; then
    cached_quick_fp=""
    [[ -f "$cache/.quick-fingerprint" ]] && cached_quick_fp="$(cat "$cache/.quick-fingerprint")"

    if [[ "$cached_quick_fp" == "$quick_fp" ]] && rpm_cache_has_binary_rpms "$cache"; then
      echo "Using debug cached RPM artifacts for $target/$display_id: quick fingerprint matched" >&2
      rpm_copy_artifacts "$cache" "$repo" "$src_repo" "$local_repo"
      return 0
    fi

    if [[ -z "$cached_quick_fp" ]]; then
      echo "RPM debug cache miss for $target/$display_id: no cached quick fingerprint" >&2
    elif [[ "$cached_quick_fp" != "$quick_fp" ]]; then
      echo "RPM debug cache miss for $target/$display_id: quick fingerprint changed" >&2
    else
      echo "RPM debug cache miss for $target/$display_id: cached binary RPM artifacts missing" >&2
    fi
  elif [[ "$mode" == off ]]; then
    echo "RPM cache disabled for $target/$display_id" >&2
  fi

  RPM_LAYER_ROOT="$root" rpm_fetch_sources_in_mock "$target" "$result" "$spec_dir" "$SPEC"

  RPM_LAYER_ROOT="$root" rpm_build_srpm "$target" "srpm-$target-$source_safe-$build_id" "$srpm_dir" "$spec_dir" "$spec_path" "$url"
  srpm="$(find "$srpm_dir" -maxdepth 1 -name '*.src.rpm' -print -quit)"
  [[ -n "$srpm" ]] || die "No SRPM created for $target/$display_id"

  fp="$(rpm_queue_srpm_fingerprint "$target" "$family" "$arch" "$work/src" "$SPEC" "$source_id" "$SUBDIR" "$srpm")"

  if [[ "$mode" != off ]]; then
    cache_fp=""
    [[ -f "$cache/.fingerprint" ]] && cache_fp="$(cat "$cache/.fingerprint")"

    if [[ "$cache_fp" == "$fp" ]] && rpm_cache_has_binary_rpms "$cache"; then
      echo "Using cached RPM artifacts for $target/$display_id: SRPM fingerprint matched" >&2
      printf '%s' "$quick_fp" >"$cache/.quick-fingerprint"
      rpm_copy_artifacts "$cache" "$repo" "$src_repo" "$local_repo"
      return 0
    fi

    if [[ -z "$cache_fp" ]]; then
      echo "RPM cache miss for $target/$display_id: no cached SRPM fingerprint" >&2
    elif [[ "$cache_fp" != "$fp" ]]; then
      echo "RPM cache miss for $target/$display_id: SRPM or repository inputs changed" >&2
    else
      echo "RPM cache miss for $target/$display_id: cached binary RPM artifacts missing" >&2
    fi
  fi

  RPM_LAYER_ROOT="$root" rpm_rebuild "$target" "$target-$source_safe-$build_id" "$result" "$local_repo" "$srpm" "$spec_path" "$url"
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
  load_queue "$1"
  safe_id "${SOURCE_ID:-$PRIMARY_APP}-${PACKAGE:-${SPEC%.spec}}-$SUBDIR"
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

    while IFS= read -r spec_path; do
      spec_name="$(basename "$spec_path")"
      package="${spec_name%.spec}"
      subdir="$(dirname "${spec_path#$root/}")"
      [[ "$subdir" == . ]] || subdir="${subdir#./}"
      key="$source_id|$package|$spec_name|$subdir"
      package_key="$source_id|$package"
      [[ -z "${queued[$key]+x}" ]] || continue
      [[ -z "${queued_package[$package_key]+x}" ]] || continue
      queued[$key]=1
      queued_package[$package_key]=1
      queue_write \
        "$qdir" \
        "$(safe_id "$source_id-repo-$package-$subdir")" \
        QUEUE_TYPE=rpm \
        SUBDIR="$subdir" \
        SPEC="$spec_name" \
        PACKAGE="$package" \
        SOURCE_ID="$source_id" >/dev/null
      metadata_append_package "$package"
    done < <(find "$root" \
      -type d \( -name .git -o -name .github -o -name .cache -o -name __pycache__ -o -name BUILD -o -name RPMS -o -name SRPMS -o -name SOURCES -o -name tmp \) -prune \
      -o -type f -name '*.spec' \
      ! -path "$root/specs/*" \
      -print | sort)
  done

  printf '%s' "$qdir"
}

rpm_build_targets(){
  local target family arch repo_path repo_id repo_file label qdir qfile
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

    for qfile in "${qfiles[@]}"; do
      rpm_build_queued "$qfile" "$target" "$family" "$arch" "$repo_path"
    done

    rpm_publish "$target" "$repo_path"
    rpm_write_repo "$repo_id" "$repo_file" "$repo_path" "$label"
    metadata_append targets.txt "$target"
  done < <(targets_list)
}

