#!/usr/bin/env bash
# `publishable check`: can this repository be made public right now?
# Output is one machine line per finding (BLOCKING|..., WARNING|..., REMEDIATION|..., INFO|...),
# a SUMMARY block, and a final AUDIT line. Exit 0 clean, 1 blocked, 2 bad input or engine.

publishable_check() (
  set -euo pipefail
  # Inherited shell settings must not change which files a glob finds (local checks, lineage).
  set +f
  unset GLOBIGNORE
  umask 077

  local all_refs=0 repo_input=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --all-refs) all_refs=1 ;;
      *) repo_input="$1" ;;
    esac
    shift
  done
  repo_input="${repo_input:-$PWD}"

  local config_file personal_config state_dir engine_root command_text
  config_file="$(publishable_config_path)"
  personal_config="$(publishable_rules_path)"
  publishable_load_config "$config_file"
  state_dir="$(publishable_state_dir)"
  engine_root="${PUBLISHABLE_ENGINE_ROOT:?}"
  command_text="$(publishable_command_text)"

  local expected_name="$PUBLISHABLE_CONFIG_AUTHOR_NAME"
  local expected_email="$PUBLISHABLE_CONFIG_AUTHOR_EMAIL"
  local test_path_rules="${PUBLISHABLE_CONFIG_TEST_PATH_RULES:-^personal-}"
  local own_owners="${PUBLISHABLE_CONFIG_OWN_GITHUB_OWNERS:-$PUBLISHABLE_CONFIG_GITHUB_HANDLE}"
  local own_identity_re="${PUBLISHABLE_CONFIG_OWN_IDENTITY_PATTERN:-(?!)}"
  local exempt_owner="$PUBLISHABLE_CONFIG_EXEMPT_OWNER"
  local exempt_rules="$PUBLISHABLE_CONFIG_EXEMPT_RULES"
  local checks_dir="${PUBLISHABLE_CONFIG_CHECKS_DIR:-${config_file%/*}/checks.d}"
  local code_roots_raw="${PUBLISHABLE_CODE_ROOTS:-$PUBLISHABLE_CONFIG_CODE_ROOTS}"

  local secrets_blocking=0 process_blocking=0 contamination_blocking=0
  local personal_blocking=0 personal_warnings=0 attribution_blocking=0
  local env_blocking=0 basics_warnings=0 basics_blocking=0
  local blocking_total=0 warnings_total=0

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
    local section="$1" file="$2" action="$3" command="$4"
    printf 'REMEDIATION|section=%s|file=%s|action=%s|command=%s\n' \
      "$(sanitize_field "$section")" "$(sanitize_field "$file")" \
      "$(sanitize_field "$action")" "$(sanitize_field "$command")"
  }

  emit_warning() {
    local section="$1" finding="$2" command="$3"
    printf 'WARNING|section=%s|finding=%s|command=%s\n' \
      "$(sanitize_field "$section")" "$(sanitize_field "$finding")" \
      "$(sanitize_field "$command")"
  }

  local repo
  if ! repo="$(git -C "$repo_input" rev-parse --show-toplevel 2>/dev/null)"; then
    printf '%s\n' "== SECTION 0: REPOSITORY =="
    emit_blocking "REPOSITORY" "input" "$repo_input" "n/a" "n/a" "not-a-repository" \
      "Choose a valid Git work tree before running the publish audit."
    emit_remediation "REPOSITORY" "$repo_input" "Run the audit against a Git repository." \
      "$command_text check /absolute/path/to/repository"
    printf '%s\n' "== SUMMARY =="
    printf '%s\n' "SUMMARY|section=REPOSITORY|blocking=1|warnings=0"
    printf '%s\n' "AUDIT: 1 BLOCKING, 0 WARNINGS"
    exit 2
  fi
  repo="$(CDPATH='' cd -- "$repo" && pwd -P)"

  local repo_parent="${repo%/*}" repo_name="${repo##*/}"
  local clean_export="${repo_parent}/${repo_name}-public-clean"

  # History scope. The default judges exactly what `git push <remote> HEAD` exposes: HEAD's
  # ancestry, never unrelated local refs. Content scans cover that whole ancestry, published
  # commits included; identity and internal-record checks cover the unpublished range only
  # (against the upstream, else the remote default branch, else every remote-tracking ref).
  # --all-refs widens everything to every ref, for a first or full publication.
  local history_revision="HEAD"
  local -a identity_revisions=(HEAD)
  local identity_upstream ref remote branch identity_base
  local -a remote_refs=()
  if [ "$all_refs" -eq 1 ]; then
    history_revision="--all"
    identity_revisions=(--all)
  elif identity_upstream="$(git -C "$repo" rev-parse --symbolic-full-name '@{upstream}' 2>/dev/null)"; then
    identity_revisions=("${identity_upstream}..HEAD")
  else
    while IFS= read -r ref; do
      [ -n "$ref" ] && remote_refs+=("$ref")
    done < <(git -C "$repo" for-each-ref --format='%(refname)' refs/remotes/)
    if [ "${#remote_refs[@]}" -gt 0 ]; then
      identity_base=""
      for remote in origin $(git -C "$repo" remote); do
        for branch in HEAD main master; do
          ref="refs/remotes/$remote/$branch"
          if git -C "$repo" rev-parse --verify "$ref^{commit}" >/dev/null 2>&1; then
            identity_base="$ref"
            break 2
          fi
        done
      done
      if [ -n "$identity_base" ]; then
        identity_revisions=("${identity_base}..HEAD")
      else
        identity_revisions=(HEAD --not "${remote_refs[@]}")
      fi
    fi
  fi

  refs_fingerprint() {
    {
      git -C "$repo" rev-parse --verify HEAD 2>/dev/null || printf '%s\n' "UNBORN"
      git -C "$repo" for-each-ref --format='%(refname) %(objectname)'
    } | LC_ALL=C sort | publishable_sha256 | awk '{print $1}'
  }

  file_fingerprint() {
    if [ -f "$1" ]; then
      publishable_sha256 < "$1" | awk '{print $1}'
    else
      printf '%s' "MISSING"
    fi
  }

  # Every file the verdict depends on goes into the stamp with its hash, so a consumer can
  # refuse a stamp whose inputs changed after the audit. An absent file is recorded as MISSING.
  local -a stamp_inputs=()
  add_input() {
    local path="$1"
    case "$path" in *$'\n'*) return 0 ;; esac
    [ -e "$path" ] && path="$(CDPATH='' cd -- "$(dirname -- "$path")" && pwd -P)/$(basename -- "$path")"
    stamp_inputs+=("$path")
  }
  add_input "$config_file"
  add_input "$personal_config"
  add_input "$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)/config"
  add_input "$repo/.publish-denylist"
  local extra
  if [ -n "${PUBLISHABLE_FINGERPRINT_FILES:-}" ]; then
    IFS=':' read -r -a extra_inputs <<< "$PUBLISHABLE_FINGERPRINT_FILES"
    for extra in "${extra_inputs[@]}"; do
      [ -n "$extra" ] && add_input "$extra"
    done
  fi

  local engine_hash repo_hash stamp_path
  engine_hash="$(publishable_engine_hash "$engine_root")"
  repo_hash="$(printf '%s' "$repo" | publishable_sha256 | awk '{print $1}')"
  stamp_path="${state_dir}/${repo_hash}"
  mkdir -p "$state_dir"

  write_stamp() {
    local status="$1" stamp_tmp input
    stamp_tmp="$(mktemp "${state_dir}/.publishable-check.XXXXXX")"
    {
      printf 'status=%s\n' "$status"
      printf 'audited_at=%s\n' "$(date +%s)"
      printf 'repo=%s\n' "$repo"
      printf 'refs_hash=%s\n' "$(refs_fingerprint)"
      printf 'config_hash=%s\n' "$(file_fingerprint "$personal_config")"
      printf 'engine_hash=%s\n' "$engine_hash"
      printf 'history_scope=%s\n' "$history_revision"
      if [ "$status" != "running" ]; then
        for input in "${stamp_inputs[@]}"; do
          printf 'input=%s %s\n' "$(file_fingerprint "$input")" "$input"
        done | LC_ALL=C sort -u
      fi
    } > "$stamp_tmp"
    chmod 600 "$stamp_tmp"
    mv -f "$stamp_tmp" "$stamp_path"
  }

  # Invalidate any earlier clean result first: an interrupted re-audit must never leave a
  # fresh clean stamp behind.
  write_stamp "running"

  # A transformed or truncated graph cannot prove full-history cleanliness.
  local grafts_path
  grafts_path="$(git -C "$repo" rev-parse --git-path info/grafts)"
  case "$grafts_path" in /*) ;; *) grafts_path="$repo/$grafts_path" ;; esac
  if [ -n "$(git -C "$repo" replace -l)" ] \
      || [ -e "$grafts_path" ] || [ -L "$grafts_path" ] \
      || [ "$(git -C "$repo" rev-parse --is-shallow-repository)" != false ]; then
    emit_blocking "REPOSITORY" "history" "<git-history>" "n/a" "n/a" \
      "untrusted-history-shape" "Use a complete checkout without replacement refs or grafts before auditing."
    printf '%s\n' "AUDIT: 1 BLOCKING, 0 WARNINGS"
    exit 1
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

  # A public fork's parent already published its own authors. With --all-refs, commits that a
  # live GitHub lookup proves belong to that public parent leave the identity check; every
  # payload scan still covers them.
  local -a record_revisions=("${identity_revisions[@]}")
  local -a public_parent_bases=()
  local remote_url remote_slug parent parent_slug parent_branch parent_head
  if [ "$all_refs" -eq 1 ] && command -v gh >/dev/null 2>&1; then
    while IFS= read -r remote; do
      remote_url="$(git -C "$repo" remote get-url "$remote" 2>/dev/null || true)"
      case "$remote_url" in
        https://github.com/*|git@github.com:*) remote_slug="$(github_slug "$remote_url")" ;;
        *) continue ;;
      esac
      [[ "$remote_slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || continue
      parent="$(gh api --hostname github.com "repos/$remote_slug" --jq \
        'select(.fork == true and .private == false and .parent.private == false) | [.parent.full_name, .parent.default_branch] | @tsv' 2>/dev/null || true)"
      [ -n "$parent" ] || continue
      parent_slug="${parent%%$'\t'*}"
      parent_branch="${parent#*$'\t'}"
      [[ "$parent_slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || continue
      parent_head="$(gh api --hostname github.com "repos/$parent_slug/commits/$parent_branch" --jq .sha 2>/dev/null || true)"
      [[ "$parent_head" =~ ^[0-9a-f]{40}$ ]] || continue
      git -C "$repo" cat-file -e "$parent_head^{commit}" 2>/dev/null || continue
      public_parent_bases+=("$parent_head")
    done < <(git -C "$repo" remote)
    if [ "${#public_parent_bases[@]}" -gt 0 ]; then
      identity_revisions=(--all --not "${public_parent_bases[@]}")
    fi
  fi

  # A fork that keeps a third party's public history (`git config publishable.publicUpstream
  # <owner>/<repo>`) would otherwise be judged on commits it never wrote and cannot rewrite.
  # Commits reachable from that upstream's live default-branch head leave every scan, provided
  # the upstream is public, is not one of our own GitHub owners, and its head exists locally.
  # A commit under that head authored or committed by one of our identities stays in scope,
  # with everything built on it: the cut sits below our first commit, so a mistake scans more.
  local -a history_revs=("$history_revision")
  local history_logopts="$history_revision"
  local public_upstream_slug upstream_head="" upstream_owner upstream_meta upstream_name upstream_branch
  local upstream_native upstream_legacy
  upstream_native="$(git -C "$repo" config --get publishable.publicUpstream 2>/dev/null || true)"
  upstream_legacy="$(git -C "$repo" config --get publish-audit.publicUpstream 2>/dev/null || true)"
  if [ -n "$upstream_native" ] && [ -n "$upstream_legacy" ] && [ "$upstream_native" != "$upstream_legacy" ]; then
    emit_blocking "REPOSITORY" "history" "<publicUpstream>" "n/a" "n/a" \
      "public-upstream-conflict" "publishable.publicUpstream and publish-audit.publicUpstream name different upstreams; keep one."
    printf '%s\n' "AUDIT: 1 BLOCKING, 0 WARNINGS"
    exit 1
  fi
  public_upstream_slug="${upstream_native:-$upstream_legacy}"
  if [ -n "$public_upstream_slug" ]; then
    upstream_owner="${public_upstream_slug%%/*}"
    local own_owner owner_is_ours=0
    for own_owner in $own_owners; do
      [ "$(printf '%s' "$own_owner" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$upstream_owner" | tr '[:upper:]' '[:lower:]')" ] && owner_is_ours=1
    done
    if [[ "$public_upstream_slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
        && [ "$owner_is_ours" -eq 0 ] && command -v gh >/dev/null 2>&1; then
      upstream_meta="$(gh api --hostname github.com "repos/$public_upstream_slug" --jq \
        'select(.private == false) | [.full_name, .default_branch] | @tsv' 2>/dev/null || true)"
      upstream_name="${upstream_meta%%$'\t'*}"
      upstream_branch="${upstream_meta#*$'\t'}"
      if [ -n "$upstream_meta" ] && [ "$(printf '%s' "$upstream_name" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$public_upstream_slug" | tr '[:upper:]' '[:lower:]')" ] \
          && [[ "$upstream_branch" =~ ^[A-Za-z0-9_./-]+$ ]]; then
        upstream_head="$(gh api --hostname github.com "repos/$public_upstream_slug/commits/$upstream_branch" --jq .sha 2>/dev/null || true)"
        if ! [[ "$upstream_head" =~ ^[0-9a-f]{40}$ ]] || ! git -C "$repo" cat-file -e "$upstream_head^{commit}" 2>/dev/null; then
          upstream_head=""
        fi
      fi
    fi
    if [ -z "$upstream_head" ]; then
      emit_blocking "REPOSITORY" "history" "<publicUpstream>" "n/a" "n/a" \
        "public-upstream-unverified" "The declared public upstream could not be verified live (public, not ours, head fetched locally)."
      printf '%s\n' "AUDIT: 1 BLOCKING, 0 WARNINGS"
      exit 1
    fi
    local own_identity_fixed upstream_cut_out line own_in_upstream=0
    local -a upstream_cut=()
    own_identity_fixed="$( { printf '%s\n%s\n' "$expected_name" "$expected_email"
      git -C "$repo" config --get user.name; git -C "$repo" config --get user.email
      git config --global --get user.name; git config --global --get user.email; } 2>/dev/null || true)"
    if ! upstream_cut_out="$(git -C "$repo" log --topo-order "$upstream_head" --format='%H%x09%P%x09%an%x09%ae%x09%cn%x09%ce' -- \
        | OWN_RE="$own_identity_re" OWN_FIXED="$own_identity_fixed" perl -e '
          my $re = qr/$ENV{OWN_RE}/i;
          my %fixed = map { lc($_) => 1 } grep { length } split /\n/, $ENV{OWN_FIXED};
          my (@order, %parents, %own);
          while (my $l = <STDIN>) {
            chomp $l; my ($h, $p, @who) = split /\t/, $l, -1;
            push @order, $h; $parents{$h} = [ split / /, $p ];
            $own{$h} = 1 if grep { $_ =~ $re || $fixed{lc $_} } @who;
          }
          die "empty upstream walk\n" unless @order;
          my (%tainted, %cut);
          for my $h (reverse @order) {   # --topo-order lists children first: reversed, parents come first
            $tainted{$h} = 1 if $own{$h} || grep { $tainted{$_} } @{ $parents{$h} };
          }
          if (!%tainted) { print "OWN 0\n$order[0]\n"; exit 0 }
          for my $h (keys %tainted) { $cut{$_} = 1 for grep { !$tainted{$_} } @{ $parents{$h} } }
          print "OWN ", scalar(keys %own), "\n"; print "$_\n" for sort keys %cut;
        ')"; then
      emit_blocking "REPOSITORY" "history" "<publicUpstream>" "n/a" "n/a" \
        "public-upstream-unverified" "The upstream history could not be walked to separate its commits from ours."
      printf '%s\n' "AUDIT: 1 BLOCKING, 0 WARNINGS"
      exit 1
    fi
    while IFS= read -r line; do
      case "$line" in
        "OWN "*) own_in_upstream="${line#OWN }" ;;
        ?*) upstream_cut+=("$line") ;;
      esac
    done <<< "$upstream_cut_out"
    # `--not` toggles the meaning of every later revision, so a cut appended to a list that
    # already ends negated (a fork's parents, the remote refs) goes in without its own --not.
    ends_negated() {
      local arg negating=0
      for arg in "$@"; do [ "$arg" = --not ] && negating=$((1 - negating)); done
      [ "$negating" -eq 1 ]
    }
    if [ "${#upstream_cut[@]}" -gt 0 ]; then
      if ends_negated "${history_revs[@]}"; then history_revs+=("${upstream_cut[@]}"); else history_revs+=(--not "${upstream_cut[@]}"); fi
      if ends_negated "${identity_revisions[@]}"; then identity_revisions+=("${upstream_cut[@]}"); else identity_revisions+=(--not "${upstream_cut[@]}"); fi
      if ends_negated "${record_revisions[@]}"; then record_revisions+=("${upstream_cut[@]}"); else record_revisions+=(--not "${upstream_cut[@]}"); fi
    fi
    history_logopts="${history_revs[*]}"
    local excluded_count=0
    [ "${#upstream_cut[@]}" -eq 0 ] || excluded_count="$(git -C "$repo" rev-list --count "${upstream_cut[@]}")"
    printf 'INFO|section=REPOSITORY|public_upstream=%s|upstream_head=%s|own_commits_under_upstream=%s|excluded_commits=%s|scanned_commits=%s\n' \
      "$public_upstream_slug" "$upstream_head" "$own_in_upstream" "$excluded_count" \
      "$(git -C "$repo" rev-list --count "${history_revs[@]}")"
  fi

  local gitleaks_report tracked_paths history_paths denylist_hits
  gitleaks_report="$(mktemp "${TMPDIR:-/tmp}/publishable-gitleaks.XXXXXX")"
  tracked_paths="$(mktemp "${TMPDIR:-/tmp}/publishable-tracked.XXXXXX")"
  history_paths="$(mktemp "${TMPDIR:-/tmp}/publishable-history.XXXXXX")"
  denylist_hits="$(mktemp "${TMPDIR:-/tmp}/publishable-denylist-hits.XXXXXX")"
  trap 'rm -f "$gitleaks_report" "$tracked_paths" "$history_paths" "$denylist_hits"' EXIT

  git -C "$repo" ls-files > "$tracked_paths"
  if git -C "$repo" rev-parse --verify HEAD >/dev/null 2>&1; then
    # One walk: every path ever added in scope, with the newest commit that added it. Merges
    # are diffed against their automatic resolution, so a hand-resolved merge is scanned too.
    git -C "$repo" log "${history_revs[@]}" --diff-merges=remerge --diff-filter=A --name-only --format='%x01%H' -- \
      | awk '/^\001[0-9a-f]+$/ { c = substr($0, 2); next } /^[[:space:]]*$/ { next } !($0 in seen) { seen[$0] = 1; print $0 "\t" c }' \
      | LC_ALL=C sort -t "$(printf '\t')" -k1,1 > "$history_paths"
  fi

  # Findings of exempt_rules are allowed when every GitHub remote belongs to exempt_owner
  # (for example a person's name on their own organisation's repositories). One remote under
  # any other owner keeps them blocking.
  local exempt_repo=0 github_remote_count=0 foreign_remote=0 owner
  if [ -n "$exempt_owner" ] && [ -n "$exempt_rules" ]; then
    while IFS= read -r remote; do
      remote_url="$(git -C "$repo" remote get-url "$remote" 2>/dev/null || true)"
      case "$remote_url" in
        https://github.com/*|git@github.com:*|ssh://git@github.com/*)
          github_remote_count=$((github_remote_count + 1))
          owner="${remote_url#https://github.com/}"
          owner="${owner#git@github.com:}"
          owner="${owner#ssh://git@github.com/}"
          owner="${owner%%/*}"
          [ "$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$exempt_owner" | tr '[:upper:]' '[:lower:]')" ] || foreign_remote=1
          ;;
      esac
    done < <(git -C "$repo" remote 2>/dev/null)
    if [ "$github_remote_count" -gt 0 ] && [ "$foreign_remote" -eq 0 ]; then
      exempt_repo=1
    fi
  fi

  # Only identity rules can be exempted, never a secret.
  is_exempt_rule() {
    [ "$exempt_repo" -eq 1 ] || return 1
    case "$1" in personal-*) ;; *) return 1 ;; esac
    case " $exempt_rules " in
      *" $1 "*) return 0 ;;
    esac
    return 1
  }

  # Rules named personal-* in the rules file describe the user's own identifiers; any other
  # finding is a secret.
  is_personal_rule() {
    case "$1" in
      personal-*) return 0 ;;
    esac
    return 1
  }

  history_remediation() {
    local section="$1" file="$2"
    emit_remediation "$section" "$file" \
      "Deleting the current file is not enough. Prefer a fresh repository from an audited clean export; a history rewrite is incomplete once forks or retained commit objects exist." \
      "mkdir -p \"$clean_export\" && git -C \"$repo\" archive HEAD | tar -x -C \"$clean_export\""
  }

  printf '%s\n' "== SECTION 1: SECRETS =="
  printf 'INFO|section=SECRETS|repo=%s|scan=%s-history-default-plus-personal\n' \
    "$(sanitize_field "$repo")" "$history_logopts"
  local scan_available=1
  if ! command -v gitleaks >/dev/null 2>&1; then
    scan_available=0
    secrets_blocking=$((secrets_blocking + 1))
    blocking_total=$((blocking_total + 1))
    emit_blocking "SECRETS" "scanner" "<gitleaks>" "n/a" "n/a" "scanner-missing" \
      "Install gitleaks before publishing; the repository has not been scanned."
    emit_remediation "SECRETS" "<gitleaks>" "Install the required scanner." \
      "Install gitleaks from its official release or your operating system's package manager."
  elif ! command -v jq >/dev/null 2>&1; then
    scan_available=0
    secrets_blocking=$((secrets_blocking + 1))
    blocking_total=$((blocking_total + 1))
    emit_blocking "SECRETS" "scanner" "<jq>" "n/a" "n/a" "report-parser-missing" \
      "Install jq so gitleaks findings can be reported without printing secret values."
    emit_remediation "SECRETS" "<jq>" "Install the safe report parser." \
      "Install jq from your operating system's package manager."
  elif [ ! -f "$personal_config" ]; then
    scan_available=0
    secrets_blocking=$((secrets_blocking + 1))
    blocking_total=$((blocking_total + 1))
    emit_blocking "SECRETS" "scanner" "$personal_config" "n/a" "n/a" "personal-config-missing" \
      "Create the local gitleaks rules file before publishing."
    emit_remediation "SECRETS" "$personal_config" "Create and customise the local rules file." \
      "cp personal.toml.example \"$personal_config\""
  elif ! publishable_rules_are_ready; then
    scan_available=0
    secrets_blocking=$((secrets_blocking + 1))
    blocking_total=$((blocking_total + 1))
    emit_blocking "SECRETS" "scanner" "$personal_config" "n/a" "n/a" "personal-config-unconfigured" \
      "The local rules file still has starter status, so personal-data coverage is not proven."
    emit_remediation "SECRETS" "$personal_config" "Replace every placeholder, then mark the local policy ready." \
      "Set rules_ready=true in $config_file"
  fi

  local scan_rc identity_config identity_report identity_rc
  if [ "$scan_available" -eq 1 ]; then
    scan_rc=0
    gitleaks detect \
      --source "$repo" \
      --log-opts="$history_logopts --diff-merges=remerge --" \
      --config "$personal_config" \
      --redact=100 \
      --report-format json \
      --report-path "$gitleaks_report" \
      --no-banner \
      --no-color \
      --log-level error || scan_rc=$?

    # Identity pass over test, fixture and example paths. A rules file usually allowlists those
    # paths for every rule, which suits fake keys and hides real names and emails. Re-scan with
    # every allowlisted path pattern that mentions tests, fixtures or examples removed, and keep
    # only identity findings (test_path_rules) on exactly those paths, so nothing counts twice.
    # If such a pattern survives the removal (for example a one-line list), the pass blocks.
    identity_config="$(mktemp "${TMPDIR:-/tmp}/publishable-identity.XXXXXX")"
    identity_report="$(mktemp "${TMPDIR:-/tmp}/publishable-identity-report.XXXXXX")"
    perl -ne 'print unless /^\s*(?:\x27\x27\x27|"|\x27)/ && /test|fixture|example/i' "$personal_config" > "$identity_config"
    identity_rc=0
    if perl -ne '$bad = 1 if /^\s*(?:paths\s*=\s*\[\s*)?(?:\x27\x27\x27|"|\x27)/ && /test|fixture/i; END { exit($bad ? 0 : 1) }' "$identity_config"; then
      identity_rc=99
    else
      gitleaks detect --source "$repo" --log-opts="$history_logopts --diff-merges=remerge --" --config "$identity_config" \
        --redact=100 --report-format json --report-path "$identity_report" \
        --no-banner --no-color --log-level error || identity_rc=$?
    fi
    # Merge only when both reports are valid and the filter itself succeeds; anything else blocks.
    if [ "$identity_rc" -eq 0 ] || [ "$identity_rc" -eq 1 ]; then
      if jq -e 'type == "array"' "$identity_report" >/dev/null 2>&1 \
          && jq -e 'type == "array"' "$gitleaks_report" >/dev/null 2>&1 \
          && jq -s --arg rules "$test_path_rules" '.[0] + [.[1][] | select(
            (.RuleID | test($rules)) and
            (.File | test("(^|/)(test|tests|fixtures)(/|$)|(^|/)[^/]*\\.example\\.[^/]+$|\\.env\\.example$")))]' \
            "$gitleaks_report" "$identity_report" > "${identity_report}.merged" 2>/dev/null; then
        mv -f "${identity_report}.merged" "$gitleaks_report"
      else
        identity_rc=98
      fi
    fi
    if [ "$identity_rc" -ne 0 ] && [ "$identity_rc" -ne 1 ] && { [ "$scan_rc" -eq 0 ] || [ "$scan_rc" -eq 1 ]; }; then
      secrets_blocking=$((secrets_blocking + 1))
      blocking_total=$((blocking_total + 1))
      emit_blocking "SECRETS" "scanner" "<identity-test-pass>" "n/a" "n/a" "identity-test-scan-error" \
        "The identity re-scan of test and fixture paths did not run (scanner error, or an allowlist entry for those paths could not be removed). Treat test files as unscanned for identity."
    fi
    rm -f "$identity_config" "$identity_report" "${identity_report}.merged"

    if { [ "$scan_rc" -eq 0 ] || [ "$scan_rc" -eq 1 ]; } \
        && jq -e 'type == "array"' "$gitleaks_report" >/dev/null 2>&1; then
      while IFS=$'\t' read -r file line commit rule description; do
        [ -n "$rule" ] || continue
        if is_exempt_rule "$rule"; then
          continue
        elif is_personal_rule "$rule"; then
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
      emit_remediation "SECRETS" "<gitleaks>" "Reproduce and fix the scanner/configuration error." \
        "gitleaks detect --source \"$repo\" --log-opts=\"$history_logopts --diff-merges=remerge --\" --config \"$personal_config\" --redact=100 --verbose"
    fi
  fi

  is_process_path() {
    local path="$1" base="${1##*/}"
    case "$base" in
      CHANGES.log|PLAN.md|HANDOFF.md|STATE.md|AGENTS.md|TODO.md|NOTES.md|SCRATCH*) return 0 ;;
    esac
    case "/$path/" in
      */.claude/*|*/.codex/*|*/.cursor/*) return 0 ;;
    esac
    return 1
  }

  # Records of how and why the work was made: agent instructions, ledgers, lessons, drafts and
  # decision records. The published repository holds the product only.
  is_internal_record_path() {
    local path="$1" base="${1##*/}"
    case "$base" in
      CLAUDE.md|GEMINI.md|BUILD-LEDGER.md|LESSONS.md|lessons.md|ERRORS.log|*.draft.md) return 0 ;;
    esac
    case "/$path" in
      */adr/*|*/decisions/*) return 0 ;;
    esac
    return 1
  }

  printf '%s\n' "== SECTION 2: PROCESS_REVEAL =="
  local path rule quoted_path added_commit
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if is_process_path "$path"; then
      rule="process-file-in-tree"
    elif is_internal_record_path "$path"; then
      rule="internal-record-in-tree"
    else
      continue
    fi
    process_blocking=$((process_blocking + 1))
    blocking_total=$((blocking_total + 1))
    emit_blocking "PROCESS_REVEAL" "tree" "$path" "n/a" "HEAD" "$rule" \
      "Remove this internal process artifact from the publishable tree."
    quoted_path="$(printf '%q' "$path")"
    emit_remediation "PROCESS_REVEAL" "$path" "Untrack the file and ignore it in this repository." \
      "printf '%s\\n' '$path' >> \"$repo/.gitignore\" && git -C \"$repo\" rm --cached -- $quoted_path"
  done < "$tracked_paths"

  while IFS=$'\t' read -r path added_commit; do
    [ -n "$path" ] || continue
    is_process_path "$path" || continue
    process_blocking=$((process_blocking + 1))
    blocking_total=$((blocking_total + 1))
    emit_blocking "PROCESS_REVEAL" "history" "$path" "n/a" "${added_commit:-unknown}" \
      "process-file-in-history" "This internal process artifact exists in publishable history."
    history_remediation "PROCESS_REVEAL" "$path"
  done < "$history_paths"

  # Internal records in the unpublished range: additions, edits and merge additions count,
  # even when a later commit removes the file; a deletion alone does not.
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    is_internal_record_path "$path" || continue
    added_commit="$(git -C "$repo" log "${record_revisions[@]}" -m --no-renames --diff-filter=d --name-only --format='%H' -- "$path" | sed -n '1p')"
    process_blocking=$((process_blocking + 1))
    blocking_total=$((blocking_total + 1))
    emit_blocking "PROCESS_REVEAL" "unpublished-history" "$path" "n/a" "${added_commit:-unknown}" \
      "internal-record-in-history" "This internal record exists in unpublished history."
    quoted_path="$(printf '%q' "$path")"
    emit_remediation "PROCESS_REVEAL" "$path" \
      "Remove the record from unpublished commits as well as the tree before publishing." \
      "git -C \"$repo\" log --oneline -- $quoted_path"
  done < <(git -C "$repo" log "${record_revisions[@]}" -m --no-renames --diff-filter=d --name-only --format= -- 2>/dev/null \
    | sed '/^[[:space:]]*$/d' | LC_ALL=C sort -u || true)

  printf '%s\n' "== SECTION 2b: CROSS_CONTAMINATION =="
  # Hand-off and planning files in the working tree (untracked included) must hold pointers,
  # never payload: a shared tool's log is where another project's figures and live IDs leak.
  local contamination_targets="CHANGES.log HANDOFF.md STATE.md PLAN.md TODO.md NOTES.md"
  # A currency-marked amount with decimals, a thousands separator or three or more digits, so
  # shell positionals ($1) and casual two-digit mentions do not block.
  local contamination_figures='[£$€] ?[0-9]+[.,][0-9]{2}([^0-9]|$)|[£$€] ?[0-9]{1,3}(,[0-9]{3})+|[£$€] ?[0-9]{3,}|[0-9]+[.,][0-9]{2} ?(EUR|GBP|USD)([^A-Z]|$)'
  local cfile cpath _content
  for cfile in $contamination_targets; do
    cpath="$repo/$cfile"
    [ -f "$cpath" ] || continue
    while IFS=: read -r line _content; do
      [ -n "$line" ] || continue
      contamination_blocking=$((contamination_blocking + 1))
      blocking_total=$((blocking_total + 1))
      emit_blocking "CROSS_CONTAMINATION" "worktree" "$cfile" "$line" "n/a" "handoff-log-figure-payload" \
        "A hand-off/process file carries a currency figure. Entries are pointers, never payload."
      emit_remediation "CROSS_CONTAMINATION" "$cfile" \
        "Rewrite the entry as a pointer (path, note name); keep the payload in its own project's records." \
        "vi +$line -- \"$cpath\""
    done < <(grep -nE "$contamination_figures" "$cpath" 2>/dev/null | cut -c1-200 || true)
    # An opaque identifier: a token of 28 or more characters mixing lower case, upper case and
    # digits (the shape of a cloud file ID). Hex hashes and hyphenated names never match.
    while IFS=: read -r line _content; do
      [ -n "$line" ] || continue
      contamination_blocking=$((contamination_blocking + 1))
      blocking_total=$((blocking_total + 1))
      emit_blocking "CROSS_CONTAMINATION" "worktree" "$cfile" "$line" "n/a" "handoff-log-opaque-id" \
        "A hand-off/process file carries a long opaque identifier. Reference the subject by name or path, never by a live external ID."
      emit_remediation "CROSS_CONTAMINATION" "$cfile" \
        "Replace the raw ID with a named pointer; the ID belongs in the subject project's own records." \
        "vi +$line -- \"$cpath\""
    done < <(grep -nE '[A-Za-z0-9_]{28,}' "$cpath" 2>/dev/null \
        | awk -F: '{ n=split($0, toks, /[^A-Za-z0-9_]+/); for (i=1;i<=n;i++) { t=toks[i]; if (length(t)>=28 && t ~ /[a-z]/ && t ~ /[A-Z]/ && t ~ /[0-9]/) { print $1; break } } }' || true)
  done

  printf '%s\n' "== SECTION 3: PERSONAL_DATA =="
  if [ "$scan_available" -eq 1 ] && jq -e 'type == "array"' "$gitleaks_report" >/dev/null 2>&1; then
    while IFS=$'\t' read -r file line commit rule description; do
      [ -n "$rule" ] || continue
      is_personal_rule "$rule" || continue
      if is_exempt_rule "$rule"; then
        printf 'INFO|section=PERSONAL_DATA|file=%s|rule=%s|status=allowed-by-owner-exemption\n' \
          "$(sanitize_field "$file")" "$(sanitize_field "$rule")"
        continue
      fi
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
  fi

  # Repository denylists. The rules file knows the user's own identifiers; it cannot know a
  # repository's third parties (clients, colleagues, landlords) or the records it was built
  # from. Those terms live outside the published tree: a gitignored .publish-denylist, a file
  # named by the repo-local git config publishable.denylist (or publish-audit.denylist), or
  # $PUBLISHABLE_DENYLIST. Every list found is scanned; a configured list that cannot be read
  # blocks, because a blind scan that passes is the failure this section exists to prevent.
  local -a denylists=()
  local configured
  [ -r "$repo/.publish-denylist" ] && denylists+=("$repo/.publish-denylist")
  for configured in "$(git -C "$repo" config --get publishable.denylist 2>/dev/null || true)" \
      "$(git -C "$repo" config --get publish-audit.denylist 2>/dev/null || true)" "${PUBLISHABLE_DENYLIST:-}"; do
    [ -n "$configured" ] || continue
    configured="$(publishable_expand_home "$configured")"
    if [ -r "$configured" ] && [ -f "$configured" ]; then
      if [ -r "$repo/.publish-denylist" ] && [ "$(realpath "$configured")" = "$(realpath "$repo/.publish-denylist")" ]; then
        continue
      fi
      denylists+=("$configured")
    else
      personal_blocking=$((personal_blocking + 1))
      blocking_total=$((blocking_total + 1))
      emit_blocking "PERSONAL_DATA" "config" "<denylist>" "n/a" "n/a" "configured-denylist-unreadable" \
        "A denylist is configured for this repo but cannot be read, so the personal-data scan would be blind. Fix the path before publishing."
    fi
  done

  denylist_scan_failed() {
    personal_blocking=$((personal_blocking + 1))
    blocking_total=$((blocking_total + 1))
    emit_blocking "PERSONAL_DATA" "$1" "<denylist>" "n/a" "n/a" "denylist-scan-failed" \
      "The denylist scan did not complete, so this scope was not checked. Fix the cause and rerun; never publish on a partial scan."
  }

  # One pass per scope: the tracked files once, the in-scope history diffs once. Only
  # locations and commits are reported, never the term.
  scan_denylist() {
    local dl_file hfile hline dl_commit
    dl_file="$(CDPATH='' cd -- "$(dirname -- "$1")" && pwd -P)/$(basename -- "$1")"
    add_input "$dl_file"
    if ! git -C "$repo" ls-files -z 2>/dev/null | (cd "$repo" && perl "$engine_root/lib/denylist.pl" worktree "$dl_file") > "$denylist_hits"; then
      denylist_scan_failed "worktree"
    fi
    while IFS=$'\t' read -r hfile hline; do
      [ -n "$hfile" ] || continue
      personal_blocking=$((personal_blocking + 1))
      blocking_total=$((blocking_total + 1))
      emit_blocking "PERSONAL_DATA" "worktree" "$hfile" "$hline" "n/a" "repo-denylist" \
        "A term from this repo's denylist appears in a TRACKED file. Replace it with a role or a neutral example, or move the data to a gitignored file."
      emit_remediation "PERSONAL_DATA" "$hfile" \
        "Replace the denied term with a role or placeholder, or relocate the data to a gitignored file." \
        "vi +$hline -- \"$repo/$hfile\""
    done < "$denylist_hits"
    if git -C "$repo" rev-parse --verify HEAD >/dev/null 2>&1; then
      if ! git -C "$repo" log "${history_revs[@]}" --diff-merges=remerge -p -U0 --full-index --no-color --no-ext-diff --no-textconv \
           --format='%x00commit %H' -- 2>/dev/null | perl "$engine_root/lib/denylist.pl" history "$dl_file" "$repo" > "$denylist_hits"; then
        denylist_scan_failed "history"
      fi
    else
      : > "$denylist_hits"
    fi
    while IFS= read -r dl_commit; do
      [ -n "$dl_commit" ] || continue
      personal_blocking=$((personal_blocking + 1))
      blocking_total=$((blocking_total + 1))
      emit_blocking "PERSONAL_DATA" "history" "(committed history)" "n/a" "$dl_commit" "repo-denylist-history" \
        "A term from this repo's denylist exists in committed history. Publish from a clean export; a force-push does not remove it."
    done < "$denylist_hits"
  }

  # Private-data lineage. A repository built from a private-data repository is where real
  # people and figures end up in fixtures, so for it a missing denylist blocks. Lineage needs
  # no marker: a sibling repository under a code root (code_roots, default the repo's parent
  # folder) whose folder or GitHub name is <base>-data, <base>-private-data or <base>-private,
  # matched against this repo's folder and remote names (<base> or <base>-*); or a tracked file
  # that names such a repository.
  local lineage_signal="" lroot cand_dir cand_url cand_slug cand self_remote self_url base self name lineage_file i
  local -a data_repo_names=() lineage_bases=() lineage_roots=() self_names=() cand_names=() grep_args=()
  IFS=':' read -r -a lineage_roots <<< "${code_roots_raw:-$repo_parent}"
  for lroot in "${lineage_roots[@]}"; do
    lroot="$(publishable_expand_home "$lroot")"
    [ -d "$lroot" ] || continue
    for cand_dir in "$lroot"/*; do
      [ -e "$cand_dir/.git" ] || continue
      cand_names=("${cand_dir##*/}")
      cand_url="$(git -C "$cand_dir" remote get-url origin 2>/dev/null || true)"
      if [ -n "$cand_url" ]; then cand_slug="${cand_url%.git}"; cand_names+=("${cand_slug##*/}"); fi
      for cand in "${cand_names[@]}"; do
        if [[ "$cand" =~ ^(.+)-(private-data|data|private)$ ]]; then
          data_repo_names+=("$cand")
          lineage_bases+=("${BASH_REMATCH[1]}")
        fi
      done
    done
  done
  self_names=("$repo_name")
  while IFS= read -r self_remote; do
    [ -n "$self_remote" ] || continue
    self_url="$(git -C "$repo" remote get-url "$self_remote" 2>/dev/null || true)"
    self_url="${self_url%.git}"
    [ -n "$self_url" ] && self_names+=("${self_url##*/}")
  done < <(git -C "$repo" remote 2>/dev/null)
  if [ "${#lineage_bases[@]}" -gt 0 ]; then
    for i in "${!lineage_bases[@]}"; do
      base="${lineage_bases[$i]}"
      for self in "${self_names[@]}"; do
        if [ "$self" = "${data_repo_names[$i]}" ] || [ "$self" = "$base" ] || [[ "$self" == "$base"-* ]]; then
          lineage_signal="name '$self' matches private-data repo '${data_repo_names[$i]}'"
          break 2
        fi
      done
    done
    if [ -z "$lineage_signal" ]; then
      for name in "${data_repo_names[@]}"; do
        [ "${#name}" -ge 8 ] && grep_args+=(-e "$name")
      done
      if [ "${#grep_args[@]}" -gt 0 ]; then
        lineage_file="$(git -C "$repo" grep -I -l -F "${grep_args[@]}" -- . 2>/dev/null | head -1 || true)"
        [ -n "$lineage_file" ] && lineage_signal="tracked file '$lineage_file' names a private-data repo"
      fi
    fi
  fi

  local dl_file
  if [ "${#denylists[@]}" -gt 0 ]; then
    for dl_file in "${denylists[@]}"; do
      scan_denylist "$dl_file"
    done
    [ -n "$lineage_signal" ] && printf 'INFO|section=PERSONAL_DATA|lineage=%s|denylists=%d\n' \
      "$(sanitize_field "$lineage_signal")" "${#denylists[@]}"
  elif [ -n "$lineage_signal" ]; then
    personal_blocking=$((personal_blocking + 1))
    blocking_total=$((blocking_total + 1))
    emit_blocking "PERSONAL_DATA" "lineage" "<repository>" "n/a" "n/a" "private-data-lineage-without-denylist" \
      "This repo is derived from private data ($lineage_signal), and no denylist is configured, so real people, figures and records copied into fixtures are invisible to this audit. Build a denylist from the private data (names, figures, registrations, dates) and keep it outside this repo."
    emit_remediation "PERSONAL_DATA" "<repository>" \
      "Point the audit at a denylist kept in the private-data repo (repo-local git config, never tracked)." \
      "git -C \"$repo\" config publishable.denylist /absolute/path/to/private-data-repo/publish/denylist.txt"
  else
    personal_warnings=$((personal_warnings + 1))
    emit_warning "PERSONAL_DATA" \
      "No denylist for this repo: PERSONAL_DATA can only catch the owner's own identifiers, never third parties it has never heard of. A clean result here does NOT mean the repo carries no personal data." \
      "printf '%s\\n' '# one term per line, gitignored, never commit' > \"$repo/.publish-denylist\""
  fi

  printf '%s\n' "== SECTION 4: AI_ATTRIBUTION =="
  # The public commit identity (author_name, author_email in the config): the repository's
  # local config and every unpublished commit, author and committer, must use it exactly.
  local configured_name configured_email author email committer committer_email commit
  if [ -n "$expected_name" ] || [ -n "$expected_email" ]; then
    configured_name="$(git -C "$repo" config --local --get user.name 2>/dev/null || true)"
    configured_email="$(git -C "$repo" config --local --get user.email 2>/dev/null || true)"
    if { [ -n "$expected_name" ] && [ "$configured_name" != "$expected_name" ]; } \
        || { [ -n "$expected_email" ] && [ "$configured_email" != "$expected_email" ]; }; then
      attribution_blocking=$((attribution_blocking + 1))
      blocking_total=$((blocking_total + 1))
      emit_blocking "AI_ATTRIBUTION" "repository-config" ".git/config" "n/a" "HEAD" \
        "public-author-config-mismatch" "Set the repository-local author and committer identity to the configured public identity."
      emit_remediation "AI_ATTRIBUTION" ".git/config" "Set the exact public identity before committing or publishing." \
        "git -C \"$repo\" config user.name \"$expected_name\" && git -C \"$repo\" config user.email \"$expected_email\""
    fi

    while IFS=$'\t' read -r commit author email committer committer_email; do
      [ -n "$commit" ] || continue
      if { [ -n "$expected_name" ] && { [ "$author" != "$expected_name" ] || [ "$committer" != "$expected_name" ]; }; } \
          || { [ -n "$expected_email" ] && { [ "$email" != "$expected_email" ] || [ "$committer_email" != "$expected_email" ]; }; }; then
        attribution_blocking=$((attribution_blocking + 1))
        blocking_total=$((blocking_total + 1))
        emit_blocking "AI_ATTRIBUTION" "unpublished-history-metadata" "<commit-identity>" "n/a" "$commit" \
          "public-author-identity-mismatch" "Rewrite the unpublished commit so author and committer both use the configured public identity."
        emit_remediation "AI_ATTRIBUTION" "<commit-identity>" "Correct the commit identity before publishing." \
          "git -C \"$repo\" commit --amend --no-edit --author=\"$expected_name <$expected_email>\""
      fi
    done < <(git -C "$repo" log "${identity_revisions[@]}" --format='%H%x09%an%x09%ae%x09%cn%x09%ce' -- 2>/dev/null || true)
  else
    printf '%s\n' "INFO|section=AI_ATTRIBUTION|public_identity=not-configured"
  fi

  while IFS=$'\t' read -r commit author email committer committer_email; do
    [ -n "$commit" ] || continue
    if printf '%s\n%s\n%s\n%s\n' "$author" "$email" "$committer" "$committer_email" | grep -qiE 'Clau[d]e|Anthropic|Codex|OpenAI|ChatGPT|Gemini|Copilot'; then
      attribution_blocking=$((attribution_blocking + 1))
      blocking_total=$((blocking_total + 1))
      emit_blocking "AI_ATTRIBUTION" "history-metadata" "<commit-author>" "n/a" "$commit" \
        "ai-author-identity" "Replace AI author/email metadata with the responsible human author before publishing."
      history_remediation "AI_ATTRIBUTION" "<commit-author>"
    fi
  done < <(git -C "$repo" log "${history_revs[@]}" --format='%H%x09%an%x09%ae%x09%cn%x09%ce' --)

  # Clau[d]e keeps this file from matching its own pattern.
  local attribution_pattern='Co-Authored-By:[[:space:]]*.*Clau[d]e|Generated[[:space:]]+with[[:space:]]+Clau[d]e|Author[[:space:]]+of[[:space:]]+this[[:space:]]+doc:[[:space:]]*Clau[d]e'
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    attribution_blocking=$((attribution_blocking + 1))
    blocking_total=$((blocking_total + 1))
    emit_blocking "AI_ATTRIBUTION" "history-metadata" "<commit-message>" "n/a" "$commit" \
      "ai-attribution-message" "Remove AI authorship attribution from commit metadata before publishing."
    history_remediation "AI_ATTRIBUTION" "<commit-message>"
  done < <(git -C "$repo" log "${history_revs[@]}" --extended-regexp --regexp-ignore-case \
    --grep="$attribution_pattern" --format='%H' --)

  local quoted_file
  while IFS=: read -r file line _content; do
    [ -n "$file" ] || continue
    attribution_blocking=$((attribution_blocking + 1))
    blocking_total=$((blocking_total + 1))
    emit_blocking "AI_ATTRIBUTION" "tree" "$file" "$line" "HEAD" "ai-attribution-tree" \
      "Remove AI authorship attribution from the publishable file."
    quoted_file="$(printf '%q' "$file")"
    emit_remediation "AI_ATTRIBUTION" "$file" "Edit the exact flagged line and remove the attribution." \
      "vi +$line -- $quoted_file"
  done < <(git -C "$repo" grep -n -I -i -E "$attribution_pattern" -- . 2>/dev/null || true)

  printf '%s\n' "== SECTION 5: ENV_HYGIENE =="
  if ! git -C "$repo" check-ignore -v .env >/dev/null 2>&1; then
    env_blocking=$((env_blocking + 1))
    blocking_total=$((blocking_total + 1))
    emit_blocking "ENV_HYGIENE" "ignore" ".env" "n/a" "HEAD" "env-not-ignored" \
      "Add .env to a repository or global ignore before publishing."
    emit_remediation "ENV_HYGIENE" ".env" "Add the missing ignore rule." \
      "printf '%s\\n' '.env' >> \"$repo/.gitignore\""
  fi

  local forbidden
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    base="${path##*/}"
    forbidden=0
    case "$base" in
      .env.example|*.env.example) ;;
      .env|.env.*|*.pem|*.p12|id_rsa|id_ed25519|credentials.json|.mcp.json) forbidden=1 ;;
    esac
    [ "$forbidden" -eq 1 ] || continue
    env_blocking=$((env_blocking + 1))
    blocking_total=$((blocking_total + 1))
    emit_blocking "ENV_HYGIENE" "tree" "$path" "n/a" "HEAD" "tracked-sensitive-config" \
      "Untrack this sensitive configuration or key file before publishing."
    quoted_path="$(printf '%q' "$path")"
    emit_remediation "ENV_HYGIENE" "$path" "Untrack and ignore the file. Rotate any live value; deleting the file does not remove history." \
      "printf '%s\\n' '$path' >> \"$repo/.gitignore\" && git -C \"$repo\" rm --cached -- $quoted_path"
  done < "$tracked_paths"

  printf '%s\n' "== SECTION 6: PUBLISH_BASICS =="
  local root_files
  root_files="$(awk 'index($0, "/") == 0 { print }' "$tracked_paths")"
  if ! printf '%s\n' "$root_files" | grep -qiE '^README([._-].*)?$'; then
    basics_warnings=$((basics_warnings + 1))
    warnings_total=$((warnings_total + 1))
    emit_warning "PUBLISH_BASICS" "No root-level README is tracked." \
      "printf '# ${repo_name}\\n\\nDescribe what this project does and how to use it.\\n' > \"$repo/README.md\""
  fi

  if ! printf '%s\n' "$root_files" | grep -qiE '^(LICENSE|LICENCE|COPYING)([._-].*)?$'; then
    basics_warnings=$((basics_warnings + 1))
    warnings_total=$((warnings_total + 1))
    emit_warning "PUBLISH_BASICS" "No root-level LICENSE is tracked." \
      "curl -fsSL https://api.github.com/licenses/mit | jq -r .body > \"$repo/LICENSE\""
  fi

  local origin_url slug description description_rc
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
      "Install the GitHub CLI, then run: gh auth login"
  else
    description_rc=0
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

  # Local checks: every *.sh in checks_dir runs with PUBLISHABLE_REPO, PUBLISHABLE_TRACKED_PATHS
  # (a file, one tracked path per line) and PUBLISHABLE_HISTORY_SCOPE, and prints finding lines
  # in this same format. A check that fails or prints anything else blocks.
  count_finding() { # kind section
    local section="$2"
    if [ "$1" = BLOCKING ]; then
      blocking_total=$((blocking_total + 1))
      case "$section" in
        SECRETS) secrets_blocking=$((secrets_blocking + 1)) ;;
        PROCESS_REVEAL) process_blocking=$((process_blocking + 1)) ;;
        CROSS_CONTAMINATION) contamination_blocking=$((contamination_blocking + 1)) ;;
        PERSONAL_DATA) personal_blocking=$((personal_blocking + 1)) ;;
        AI_ATTRIBUTION) attribution_blocking=$((attribution_blocking + 1)) ;;
        ENV_HYGIENE) env_blocking=$((env_blocking + 1)) ;;
        *) basics_blocking=$((basics_blocking + 1)) ;;
      esac
    else
      warnings_total=$((warnings_total + 1))
      case "$section" in
        PERSONAL_DATA) personal_warnings=$((personal_warnings + 1)) ;;
        *) basics_warnings=$((basics_warnings + 1)) ;;
      esac
    fi
  }
  local plugin plugin_out plugin_rc plugin_line kind section
  if [ -d "$checks_dir" ]; then
    for plugin in "$checks_dir"/*.sh; do
      [ -f "$plugin" ] || continue
      add_input "$plugin"
      plugin_rc=0
      plugin_out="$(PUBLISHABLE_REPO="$repo" PUBLISHABLE_TRACKED_PATHS="$tracked_paths" \
        PUBLISHABLE_HISTORY_SCOPE="$history_revision" bash "$plugin" 2>/dev/null)" || plugin_rc=$?
      while IFS= read -r plugin_line; do
        [ -n "$plugin_line" ] || continue
        if [[ "$plugin_line" =~ ^(BLOCKING|WARNING|REMEDIATION|INFO)\|section=([A-Z_]+)\| ]]; then
          kind="${BASH_REMATCH[1]}"
          section="${BASH_REMATCH[2]}"
          printf '%s\n' "$plugin_line"
          case "$kind" in BLOCKING|WARNING) count_finding "$kind" "$section" ;; esac
        else
          plugin_rc=98
        fi
      done <<< "$plugin_out"
      if [ "$plugin_rc" -ne 0 ]; then
        emit_blocking "PUBLISH_BASICS" "check" "${plugin##*/}" "n/a" "n/a" "local-check-failed" \
          "A local check failed or printed an invalid line, so its rule was not applied."
        count_finding BLOCKING PUBLISH_BASICS
      fi
    done
  fi

  local unborn=0
  git -C "$repo" rev-parse --verify HEAD >/dev/null 2>&1 || unborn=1
  if [ "$unborn" -eq 1 ]; then
    # No commits means no history was scanned: zero findings here prove nothing.
    printf 'BLOCKING|section=REPOSITORY|scope=history|file=<none>|line=n/a|commit=UNBORN|rule=unscanned-history|description=This repository has no commits, so history was not scanned. A zero-finding result here is absence of evidence, not evidence of cleanliness.\n'
    printf 'REMEDIATION|section=REPOSITORY|file=<none>|action=Make the initial commit, then re-run this audit so history is actually scanned.|command=git -C %s add -A \&\& git -C %s commit -m "Initial commit"\n' "$repo" "$repo"
  fi

  printf '%s\n' "== SUMMARY =="
  printf 'SUMMARY|section=SECRETS|blocking=%d|warnings=0\n' "$secrets_blocking"
  printf 'SUMMARY|section=PROCESS_REVEAL|blocking=%d|warnings=0\n' "$process_blocking"
  printf 'SUMMARY|section=CROSS_CONTAMINATION|blocking=%d|warnings=0\n' "$contamination_blocking"
  printf 'SUMMARY|section=PERSONAL_DATA|blocking=%d|warnings=%d\n' "$personal_blocking" "$personal_warnings"
  printf 'SUMMARY|section=AI_ATTRIBUTION|blocking=%d|warnings=0\n' "$attribution_blocking"
  printf 'SUMMARY|section=ENV_HYGIENE|blocking=%d|warnings=0\n' "$env_blocking"
  printf 'SUMMARY|section=PUBLISH_BASICS|blocking=%d|warnings=%d\n' "$basics_blocking" "$basics_warnings"

  if [ "$unborn" -eq 1 ]; then
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
