#!/usr/bin/env bash

publishable_check() (
  set -euo pipefail
  umask 077

  local personal_config state_dir script_path repo_input
  personal_config="$(publishable_rules_path)"
  state_dir="$(publishable_state_dir)"
  script_path="${BASH_SOURCE[0]}"
  repo_input="${1:-$PWD}"

  local secrets_blocking=0
  local process_blocking=0
  local personal_blocking=0
  local attribution_blocking=0
  local env_blocking=0
  local basics_warnings=0
  local blocking_total=0
  local warnings_total=0

  sanitize_field() {
    local value="$1"
    value="${value//$'\n'/ }"
    value="${value//$'\r'/ }"
    value="${value//|/ }"
    printf '%s' "$value"
  }

  emit_blocking() {
    local section="$1" scope="$2" file="$3" line="$4" commit="$5" rule="$6" description="$7"
    printf 'BLOCKING|section=%s|scope=%s|file=%s|line=%s|commit=%s|rule=%s|description=%s\n' \
      "$(sanitize_field "$section")" "$(sanitize_field "$scope")" \
      "$(sanitize_field "$file")" "$(sanitize_field "$line")" \
      "$(sanitize_field "$commit")" "$(sanitize_field "$rule")" \
      "$(sanitize_field "$description")"
  }

  emit_remediation() {
    local section="$1" file="$2" action="$3" command_text="$4"
    printf 'REMEDIATION|section=%s|file=%s|action=%s|command=%s\n' \
      "$(sanitize_field "$section")" "$(sanitize_field "$file")" \
      "$(sanitize_field "$action")" "$(sanitize_field "$command_text")"
  }

  emit_warning() {
    local section="$1" finding="$2" command_text="$3"
    printf 'WARNING|section=%s|finding=%s|command=%s\n' \
      "$(sanitize_field "$section")" "$(sanitize_field "$finding")" \
      "$(sanitize_field "$command_text")"
  }

  local repo
  if ! repo="$(git -C "$repo_input" rev-parse --show-toplevel 2>/dev/null)"; then
    printf '%s\n' "== SECTION 0: REPOSITORY =="
    emit_blocking "REPOSITORY" "input" "$repo_input" "n/a" "n/a" "not-a-repository" \
      "Choose a valid Git work tree before running the publish audit."
    emit_remediation "REPOSITORY" "$repo_input" "Run the audit against a Git repository." \
      "$(publishable_command_text) check /absolute/path/to/repository"
    printf '%s\n' "== SUMMARY =="
    printf '%s\n' "SUMMARY|section=REPOSITORY|blocking=1|warnings=0"
    printf '%s\n' "AUDIT: 1 BLOCKING, 0 WARNINGS"
    exit 2
  fi
  repo="$(CDPATH= cd -- "$repo" && pwd -P)"

  local repo_parent repo_name clean_export
  repo_parent="${repo%/*}"
  repo_name="${repo##*/}"
  clean_export="${repo_parent}/${repo_name}-public-clean"

  fingerprint_stream() {
    cksum | awk '{print $1 ":" $2}'
  }

  refs_fingerprint() {
    {
      git -C "$repo" rev-parse --verify HEAD 2>/dev/null || printf '%s\n' "UNBORN"
      git -C "$repo" for-each-ref --format='%(refname) %(objectname)'
    } | LC_ALL=C sort | fingerprint_stream
  }

  file_fingerprint() {
    local file_name="$1"
    if [ -f "$file_name" ]; then
      cksum "$file_name" | awk '{print $1 ":" $2}'
    else
      printf '%s' "MISSING"
    fi
  }

  audit_fingerprint() {
    local engine_root="${PUBLISHABLE_ENGINE_ROOT:-}"
    if [ -n "$engine_root" ]; then
      {
        file_fingerprint "${engine_root}/bin/publishable"
        file_fingerprint "${engine_root}/lib/common.sh"
        file_fingerprint "${engine_root}/lib/check.sh"
      } | fingerprint_stream
    else
      file_fingerprint "$script_path"
    fi
  }

  local repo_hash stamp_path
  repo_hash="$(printf '%s' "$repo" | fingerprint_stream)"
  repo_hash="${repo_hash/:/-}"
  stamp_path="${state_dir}/${repo_hash}"
  mkdir -p "$state_dir"

  write_stamp() {
    local status="$1" stamp_tmp
    stamp_tmp="$(mktemp "${state_dir}/.publishable-check.XXXXXX")"
    {
      printf 'status=%s\n' "$status"
      printf 'audited_at=%s\n' "$(date +%s)"
      printf 'repo=%s\n' "$repo"
      printf 'refs_hash=%s\n' "$(refs_fingerprint)"
      printf 'config_hash=%s\n' "$(file_fingerprint "$personal_config")"
      printf 'audit_hash=%s\n' "$(audit_fingerprint)"
    } > "$stamp_tmp"
    chmod 600 "$stamp_tmp"
    mv -f "$stamp_tmp" "$stamp_path"
  }

  write_stamp "running"

  local gitleaks_report tracked_paths history_paths
  gitleaks_report="$(mktemp "${TMPDIR:-/tmp}/publishable-gitleaks.XXXXXX")"
  tracked_paths="$(mktemp "${TMPDIR:-/tmp}/publishable-tracked.XXXXXX")"
  history_paths="$(mktemp "${TMPDIR:-/tmp}/publishable-history.XXXXXX")"
  trap 'rm -f "$gitleaks_report" "$tracked_paths" "$history_paths"' EXIT

  git -C "$repo" ls-files > "$tracked_paths"
  git -C "$repo" log --all --diff-filter=A --name-only --format= 2>/dev/null \
    | sed '/^[[:space:]]*$/d' | LC_ALL=C sort -u > "$history_paths"

  is_personal_rule() {
    case "$1" in
      personal-*) return 0 ;;
      *) return 1 ;;
    esac
  }

  history_remediation() {
    local section="$1" file="$2"
    emit_remediation "$section" "$file" \
      "Deleting the current file is not enough. Prefer a fresh repository from an audited clean export; a history rewrite is incomplete once forks or retained commit objects exist." \
      "mkdir -p \"$clean_export\" && git -C \"$repo\" archive HEAD | tar -x -C \"$clean_export\""
  }

  printf '%s\n' "== SECTION 1: SECRETS =="
  printf 'INFO|section=SECRETS|repo=%s|scan=full-local-history-default-plus-personal\n' "$(sanitize_field "$repo")"

  local scan_available=1
  local parser_available=1
  if ! command -v git >/dev/null 2>&1; then
    scan_available=0
    secrets_blocking=$((secrets_blocking + 1))
    blocking_total=$((blocking_total + 1))
    emit_blocking "SECRETS" "scanner" "<git>" "n/a" "n/a" "git-missing" \
      "Install Git before publishing; repository history cannot be inspected."
    emit_remediation "SECRETS" "<git>" "Install the required version-control client." \
      "Install Git using your operating system's package manager."
  elif ! command -v gitleaks >/dev/null 2>&1; then
    scan_available=0
    secrets_blocking=$((secrets_blocking + 1))
    blocking_total=$((blocking_total + 1))
    emit_blocking "SECRETS" "scanner" "<gitleaks>" "n/a" "n/a" "scanner-missing" \
      "Install gitleaks before publishing; the repository has not been scanned."
    emit_remediation "SECRETS" "<gitleaks>" "Install the required scanner." \
      "Install gitleaks from its official release or your operating system's package manager."
  elif [ ! -f "$personal_config" ]; then
    scan_available=0
    secrets_blocking=$((secrets_blocking + 1))
    blocking_total=$((blocking_total + 1))
    emit_blocking "SECRETS" "scanner" "$personal_config" "n/a" "n/a" "personal-config-missing" \
      "Create the local gitleaks configuration before publishing."
    emit_remediation "SECRETS" "$personal_config" "Create and customise the local rules file." \
      "cp personal.toml.example \"$personal_config\""
  elif ! publishable_rules_are_ready; then
    scan_available=0
    secrets_blocking=$((secrets_blocking + 1))
    blocking_total=$((blocking_total + 1))
    emit_blocking "SECRETS" "scanner" "$personal_config" "n/a" "n/a" "personal-config-unconfigured" \
      "The local rules file still has starter status, so personal-data coverage is not proven."
    emit_remediation "SECRETS" "$personal_config" "Replace every placeholder, then mark the local policy ready." \
      "Set rules_ready=true in $(publishable_config_path)"
  elif ! command -v jq >/dev/null 2>&1; then
    parser_available=0
    printf '%s\n' "INFO|section=SECRETS|status=degraded|reason=jq-unavailable|detail=Findings remain redacted but cannot be classified individually."
  fi

  if [ "$(git -C "$repo" rev-parse --is-shallow-repository 2>/dev/null || printf 'false')" = "true" ]; then
    secrets_blocking=$((secrets_blocking + 1))
    blocking_total=$((blocking_total + 1))
    emit_blocking "SECRETS" "history" "<repository>" "n/a" "n/a" "shallow-history" \
      "A shallow clone cannot prove full-history safety."
    emit_remediation "SECRETS" "<repository>" "Fetch the missing history before re-running the audit." \
      "git -C \"$repo\" fetch --unshallow --tags && \"$(publishable_command_text)\" check \"$repo\""
  fi

  if [ "$scan_available" -eq 1 ]; then
    local scan_rc=0
    gitleaks detect \
      --source "$repo" \
      --config "$personal_config" \
      --redact=100 \
      --report-format json \
      --report-path "$gitleaks_report" \
      --no-banner \
      --no-color \
      --log-level error >/dev/null 2>&1 || scan_rc=$?

    if [ "$parser_available" -eq 1 ]; then
      if { [ "$scan_rc" -eq 0 ] || [ "$scan_rc" -eq 1 ]; } \
        && jq -e 'type == "array"' "$gitleaks_report" >/dev/null 2>&1; then
        while IFS=$'\t' read -r file line commit rule description; do
          [ -n "$rule" ] || continue
          if is_personal_rule "$rule"; then
            personal_blocking=$((personal_blocking + 1))
            blocking_total=$((blocking_total + 1))
          else
            secrets_blocking=$((secrets_blocking + 1))
            blocking_total=$((blocking_total + 1))
            emit_blocking "SECRETS" "history" "$file" "$line" "$commit" "$rule" "$description"
            history_remediation "SECRETS" "$file"
          fi
        done < <(jq -r '.[] | [
          (.File // "unknown"),
          ((.StartLine // "n/a") | tostring),
          (.Commit // "unknown"),
          (.RuleID // "unknown"),
          (.Description // "Remove or parameterize the flagged value before publishing.")
        ] | @tsv' "$gitleaks_report")
      else
        secrets_blocking=$((secrets_blocking + 1))
        blocking_total=$((blocking_total + 1))
        emit_blocking "SECRETS" "scanner" "<gitleaks>" "n/a" "n/a" "scanner-error" \
          "Gitleaks failed without a valid redacted report; treat the repository as unscanned."
        emit_remediation "SECRETS" "<gitleaks>" "Reproduce and fix the scanner or configuration error." \
          "gitleaks detect --source \"$repo\" --config \"$personal_config\" --redact=100 --verbose"
      fi
    elif [ "$scan_rc" -eq 1 ]; then
      secrets_blocking=$((secrets_blocking + 1))
      blocking_total=$((blocking_total + 1))
      emit_blocking "SECRETS" "history" "<redacted>" "n/a" "unknown" "unparsed-redacted-findings" \
        "Gitleaks found one or more publish-sensitive values. Install jq for per-finding remediation; no value was printed."
      emit_remediation "SECRETS" "<redacted>" "Install jq, then rerun the audit for safe per-finding details." \
        "Install jq using your operating system's package manager."
    elif [ "$scan_rc" -ne 0 ]; then
      secrets_blocking=$((secrets_blocking + 1))
      blocking_total=$((blocking_total + 1))
      emit_blocking "SECRETS" "scanner" "<gitleaks>" "n/a" "n/a" "scanner-error" \
        "Gitleaks failed; treat the repository as unscanned."
      emit_remediation "SECRETS" "<gitleaks>" "Rerun with verbose output after checking the local rules file." \
        "gitleaks detect --source \"$repo\" --config \"$personal_config\" --redact=100 --verbose"
    fi
  fi

  is_process_path() {
    local candidate="$1" base="${1##*/}"
    case "$base" in
      CHANGES.log|PLAN.md|HANDOFF.md|STATE.md|AGENTS.md|TODO.md|NOTES.md|SCRATCH*)
        return 0
        ;;
    esac
    case "/$candidate/" in
      */.claude/*|*/.codex/*|*/.cursor/*)
        return 0
        ;;
    esac
    return 1
  }

  printf '%s\n' "== SECTION 2: PROCESS_REVEAL =="
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    is_process_path "$candidate" || continue
    process_blocking=$((process_blocking + 1))
    blocking_total=$((blocking_total + 1))
    emit_blocking "PROCESS_REVEAL" "tree" "$candidate" "n/a" "HEAD" "process-file-in-tree" \
      "Remove this internal process artifact from the publishable tree."
    local quoted_candidate
    quoted_candidate="$(printf '%q' "$candidate")"
    emit_remediation "PROCESS_REVEAL" "$candidate" "Untrack the file and ignore it in this repository." \
      "printf '%s\\n' '$candidate' >> \"$repo/.gitignore\" && git -C \"$repo\" rm --cached -- $quoted_candidate"
  done < "$tracked_paths"

  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    is_process_path "$candidate" || continue
    local added_commit
    added_commit="$(git -C "$repo" log --all --diff-filter=A --format='%H' -- "$candidate" | head -n 1)"
    process_blocking=$((process_blocking + 1))
    blocking_total=$((blocking_total + 1))
    emit_blocking "PROCESS_REVEAL" "history" "$candidate" "n/a" "${added_commit:-unknown}" \
      "process-file-in-history" "This internal process artifact exists in publishable history."
    history_remediation "PROCESS_REVEAL" "$candidate"
  done < "$history_paths"

  printf '%s\n' "== SECTION 3: PERSONAL_DATA =="
  if [ "$scan_available" -eq 1 ] && [ "$parser_available" -eq 1 ] \
    && jq -e 'type == "array"' "$gitleaks_report" >/dev/null 2>&1; then
    while IFS=$'\t' read -r file line commit rule description; do
      [ -n "$rule" ] || continue
      is_personal_rule "$rule" || continue
      emit_blocking "PERSONAL_DATA" "history" "$file" "$line" "$commit" "$rule" "$description"
      history_remediation "PERSONAL_DATA" "$file"
    done < <(jq -r '.[] | [
      (.File // "unknown"),
      ((.StartLine // "n/a") | tostring),
      (.Commit // "unknown"),
      (.RuleID // "unknown"),
      (.Description // "Remove or parameterize the personal value before publishing.")
    ] | @tsv' "$gitleaks_report")
  elif [ "$scan_available" -eq 0 ]; then
    printf '%s\n' "INFO|section=PERSONAL_DATA|status=not-run|reason=shared-gitleaks-scan-unavailable"
  elif [ "$parser_available" -eq 0 ]; then
    printf '%s\n' "INFO|section=PERSONAL_DATA|status=unclassified|reason=jq-unavailable"
  fi

  printf '%s\n' "== SECTION 4: AI_ATTRIBUTION =="
  local ai_name_pattern ai_vendor_pattern attribution_pattern
  ai_name_pattern='Clau[d]e'
  ai_vendor_pattern="${ai_name_pattern}|Anthropic"
  attribution_pattern="Co-Authored-By:[[:space:]]*.*${ai_name_pattern}|Generated[[:space:]]+with[[:space:]]+${ai_name_pattern}|Author[[:space:]]+of[[:space:]]+this[[:space:]]+doc:[[:space:]]*${ai_name_pattern}"
  while IFS=$'\t' read -r commit author email; do
    [ -n "$commit" ] || continue
    if printf '%s\n%s\n' "$author" "$email" | grep -qiE "$ai_vendor_pattern"; then
      attribution_blocking=$((attribution_blocking + 1))
      blocking_total=$((blocking_total + 1))
      emit_blocking "AI_ATTRIBUTION" "history-metadata" "<commit-author>" "n/a" "$commit" \
        "ai-author-identity" "Replace AI author or email metadata with the responsible human author before publishing."
      history_remediation "AI_ATTRIBUTION" "<commit-author>"
    fi
  done < <(git -C "$repo" log --all --format='%H%x09%an%x09%ae')

  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    attribution_blocking=$((attribution_blocking + 1))
    blocking_total=$((blocking_total + 1))
    emit_blocking "AI_ATTRIBUTION" "history-metadata" "<commit-message>" "n/a" "$commit" \
      "ai-attribution-message" "Remove AI authorship attribution from commit metadata before publishing."
    history_remediation "AI_ATTRIBUTION" "<commit-message>"
  done < <(git -C "$repo" log --all --extended-regexp --regexp-ignore-case \
    --grep="$attribution_pattern" \
    --format='%H')

  local tree_attribution_pattern
  tree_attribution_pattern="$attribution_pattern"
  while IFS=: read -r file line _match; do
    [ -n "$file" ] || continue
    attribution_blocking=$((attribution_blocking + 1))
    blocking_total=$((blocking_total + 1))
    emit_blocking "AI_ATTRIBUTION" "tree" "$file" "$line" "HEAD" "ai-attribution-tree" \
      "Remove AI authorship attribution from the publishable file."
    local quoted_file
    quoted_file="$(printf '%q' "$file")"
    emit_remediation "AI_ATTRIBUTION" "$file" "Edit the exact flagged line and remove the attribution." \
      "vi +$line -- $quoted_file"
  done < <(git -C "$repo" grep -n -I -i -E "$tree_attribution_pattern" -- . 2>/dev/null || true)

  printf '%s\n' "== SECTION 5: ENV_HYGIENE =="
  if ! git -C "$repo" check-ignore -v .env >/dev/null 2>&1; then
    env_blocking=$((env_blocking + 1))
    blocking_total=$((blocking_total + 1))
    emit_blocking "ENV_HYGIENE" "ignore" ".env" "n/a" "HEAD" "env-not-ignored" \
      "Add .env to a repository or global ignore before publishing."
    emit_remediation "ENV_HYGIENE" ".env" "Add the missing ignore rule." \
      "printf '%s\\n' '.env' >> \"$repo/.gitignore\""
  fi

  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    local base forbidden=0
    base="${candidate##*/}"
    case "$base" in
      .env.example|*.env.example) ;;
      .env|.env.*|*.pem|*.p12|id_rsa|id_ed25519|credentials.json|.mcp.json)
        forbidden=1
        ;;
    esac
    [ "$forbidden" -eq 1 ] || continue
    env_blocking=$((env_blocking + 1))
    blocking_total=$((blocking_total + 1))
    emit_blocking "ENV_HYGIENE" "tree" "$candidate" "n/a" "HEAD" "tracked-sensitive-config" \
      "Untrack this sensitive configuration or key file before publishing."
    local quoted_candidate
    quoted_candidate="$(printf '%q' "$candidate")"
    emit_remediation "ENV_HYGIENE" "$candidate" "Untrack and ignore the file. Rotate any live value; deleting the file does not remove history." \
      "printf '%s\\n' '$candidate' >> \"$repo/.gitignore\" && git -C \"$repo\" rm --cached -- $quoted_candidate"
  done < "$tracked_paths"

  printf '%s\n' "== SECTION 6: PUBLISH_BASICS =="
  local root_files
  root_files="$(awk 'index($0, "/") == 0 { print }' "$tracked_paths")"
  if ! printf '%s\n' "$root_files" | grep -qiE '^README([._-].*)?$'; then
    basics_warnings=$((basics_warnings + 1))
    warnings_total=$((warnings_total + 1))
    emit_warning "PUBLISH_BASICS" "No root-level README is tracked." \
      "vi \"$repo/README.md\""
  fi

  if ! printf '%s\n' "$root_files" | grep -qiE '^(LICENSE|LICENCE|COPYING)([._-].*)?$'; then
    basics_warnings=$((basics_warnings + 1))
    warnings_total=$((warnings_total + 1))
    emit_warning "PUBLISH_BASICS" "No root-level LICENSE is tracked." \
      "vi \"$repo/LICENSE\""
  fi

  github_slug() {
    local url="$1" slug=""
    case "$url" in
      git@github.com:*) slug="${url#git@github.com:}" ;;
      ssh://git@github.com/*) slug="${url#ssh://git@github.com/}" ;;
      http://github.com/*|https://github.com/*) slug="${url#*github.com/}" ;;
    esac
    slug="${slug%.git}"
    slug="${slug%/}"
    case "$slug" in
      */*) printf '%s' "$slug" ;;
    esac
  }

  local origin_url slug
  origin_url="$(git -C "$repo" remote get-url origin 2>/dev/null || true)"
  slug="$(github_slug "$origin_url")"
  if [ -z "$slug" ]; then
    basics_warnings=$((basics_warnings + 1))
    warnings_total=$((warnings_total + 1))
    emit_warning "PUBLISH_BASICS" "No GitHub origin is available, so a real repository description cannot be verified." \
      "git -C \"$repo\" remote -v"
  elif ! command -v gh >/dev/null 2>&1; then
    basics_warnings=$((basics_warnings + 1))
    warnings_total=$((warnings_total + 1))
    emit_warning "PUBLISH_BASICS" "gh is unavailable, so the GitHub repository description cannot be verified." \
      "Install gh, authenticate, and rerun the audit."
  else
    local description_rc=0 description
    description="$(gh repo view "$slug" --json description --jq '.description // ""' 2>/dev/null)" || description_rc=$?
    if [ "$description_rc" -ne 0 ]; then
      basics_warnings=$((basics_warnings + 1))
      warnings_total=$((warnings_total + 1))
      emit_warning "PUBLISH_BASICS" "GitHub description lookup failed for $slug." \
        "gh auth status && gh repo view \"$slug\" --json description --jq '.description'"
    elif [ "${#description}" -lt 12 ] || printf '%s' "$description" | grep -qiE '^(todo|tbd|no description|description)$'; then
      basics_warnings=$((basics_warnings + 1))
      warnings_total=$((warnings_total + 1))
      emit_warning "PUBLISH_BASICS" "GitHub description is missing or not substantive for $slug." \
        "gh repo edit \"$slug\" --description \"Describe what the project does for a new user\""
    fi
  fi

  printf '%s\n' "== SUMMARY =="
  printf 'SUMMARY|section=SECRETS|blocking=%d|warnings=0\n' "$secrets_blocking"
  printf 'SUMMARY|section=PROCESS_REVEAL|blocking=%d|warnings=0\n' "$process_blocking"
  printf 'SUMMARY|section=PERSONAL_DATA|blocking=%d|warnings=0\n' "$personal_blocking"
  printf 'SUMMARY|section=AI_ATTRIBUTION|blocking=%d|warnings=0\n' "$attribution_blocking"
  printf 'SUMMARY|section=ENV_HYGIENE|blocking=%d|warnings=0\n' "$env_blocking"
  printf 'SUMMARY|section=PUBLISH_BASICS|blocking=0|warnings=%d\n' "$basics_warnings"

  if ! git -C "$repo" rev-parse --verify HEAD >/dev/null 2>&1; then
    printf 'BLOCKING|section=REPOSITORY|scope=history|file=<none>|line=n/a|commit=UNBORN|rule=unscanned-history|description=This repository has no commits, so history was not scanned. A zero-finding result here is absence of evidence, not evidence of cleanliness.\n'
    printf 'REMEDIATION|section=REPOSITORY|file=<none>|action=Make the initial commit, then re-run this audit so history is actually scanned.|command=git -C %s add -A \&\& git -C %s commit -m "Initial commit"\n' "$repo" "$repo"
    printf '%s\n' "== SUMMARY =="
    printf '%s\n' "SUMMARY|section=REPOSITORY|blocking=1|warnings=0"
    printf 'AUDIT: 1 BLOCKING, %d WARNINGS (history UNSCANNED)\n' "$warnings_total"
    write_stamp "failed"
    exit 1
  fi

  if [ "$blocking_total" -eq 0 ]; then
    printf 'AUDIT: CLEAN\n'
    write_stamp "clean"
    exit 0
  fi

  printf 'AUDIT: %d BLOCKING, %d WARNINGS\n' "$blocking_total" "$warnings_total"
  write_stamp "failed"
  exit 1
)
