#!/usr/bin/env bash

publishable_config_path() {
  if [ -n "${PUBLISHABLE_CONFIG_FILE:-}" ]; then
    printf '%s' "$PUBLISHABLE_CONFIG_FILE"
  else
    printf '%s/publishable/config' "${XDG_CONFIG_HOME:-${HOME}/.config}"
  fi
}

publishable_trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

publishable_unquote() {
  local value="$1"
  case "$value" in
    \"*\")
      value="${value#\"}"
      value="${value%\"}"
      ;;
    \'*\')
      value="${value#\'}"
      value="${value%\'}"
      ;;
  esac
  printf '%s' "$value"
}

# A leading ~ stands for $HOME, so one config works for every account that uses it. It is
# replaced as written ("~name" becomes "$HOMEname"), never resolved against the working folder.
publishable_expand_home() {
  printf '%s' "${1/#\~/$HOME}"
}

publishable_load_config() {
  local config_file="${1:-$(publishable_config_path)}"
  local raw_key raw_value key value

  PUBLISHABLE_CONFIG_AUTHOR_NAME=""
  PUBLISHABLE_CONFIG_AUTHOR_EMAIL=""
  PUBLISHABLE_CONFIG_GITHUB_HANDLE=""
  PUBLISHABLE_CONFIG_RULES_PATH=""
  PUBLISHABLE_CONFIG_RULES_READY=""
  PUBLISHABLE_CONFIG_CHECKS_DIR=""
  PUBLISHABLE_CONFIG_CODE_ROOTS=""
  PUBLISHABLE_CONFIG_OWN_GITHUB_OWNERS=""
  PUBLISHABLE_CONFIG_OWN_IDENTITY_PATTERN=""
  PUBLISHABLE_CONFIG_TEST_PATH_RULES=""
  PUBLISHABLE_CONFIG_EXEMPT_OWNER=""
  PUBLISHABLE_CONFIG_EXEMPT_RULES=""
  PUBLISHABLE_CONFIG_EXEMPT_README_LINE_PATTERN=""
  PUBLISHABLE_CONFIG_EXEMPT_IDENTITIES=""
  PUBLISHABLE_CONFIG_LEGAL_IDENTITY_PATHS=""
  PUBLISHABLE_CONFIG_LEGAL_IDENTITY_RULES=""

  [ -f "$config_file" ] || return 0

  while IFS='=' read -r raw_key raw_value; do
    key="$(publishable_trim "$raw_key")"
    case "$key" in
      ''|'#'*) continue ;;
    esac
    value="$(publishable_trim "${raw_value:-}")"
    value="$(publishable_unquote "$value")"
    case "$key" in
      author_name) PUBLISHABLE_CONFIG_AUTHOR_NAME="$value" ;;
      author_email) PUBLISHABLE_CONFIG_AUTHOR_EMAIL="$value" ;;
      github_handle) PUBLISHABLE_CONFIG_GITHUB_HANDLE="$value" ;;
      rules_path) PUBLISHABLE_CONFIG_RULES_PATH="$(publishable_expand_home "$value")" ;;
      rules_ready) PUBLISHABLE_CONFIG_RULES_READY="$value" ;;
      checks_dir) PUBLISHABLE_CONFIG_CHECKS_DIR="$(publishable_expand_home "$value")" ;;
      code_roots) PUBLISHABLE_CONFIG_CODE_ROOTS="$value" ;;
      own_github_owners) PUBLISHABLE_CONFIG_OWN_GITHUB_OWNERS="$value" ;;
      own_identity_pattern) PUBLISHABLE_CONFIG_OWN_IDENTITY_PATTERN="$value" ;;
      test_path_rules) PUBLISHABLE_CONFIG_TEST_PATH_RULES="$value" ;;
      exempt_owner) PUBLISHABLE_CONFIG_EXEMPT_OWNER="$value" ;;
      exempt_rules) PUBLISHABLE_CONFIG_EXEMPT_RULES="$value" ;;
      exempt_readme_line_pattern) PUBLISHABLE_CONFIG_EXEMPT_README_LINE_PATTERN="$value" ;;
      exempt_identities) PUBLISHABLE_CONFIG_EXEMPT_IDENTITIES="$value" ;;
      legal_identity_paths) PUBLISHABLE_CONFIG_LEGAL_IDENTITY_PATHS="$value" ;;
      legal_identity_rules) PUBLISHABLE_CONFIG_LEGAL_IDENTITY_RULES="$value" ;;
      *)
        printf 'WARNING: ignoring unknown key %s in %s\n' "$key" "$config_file" >&2
        ;;
    esac
  done < "$config_file"
}

publishable_rules_are_ready() {
  local config_file value
  config_file="$(publishable_config_path)"
  publishable_load_config "$config_file"

  if [ -n "$PUBLISHABLE_CONFIG_RULES_READY" ]; then
    value="$PUBLISHABLE_CONFIG_RULES_READY"
  elif [ -n "${PUBLISHABLE_RULES_READY:-}" ]; then
    value="$PUBLISHABLE_RULES_READY"
  elif [ -n "$PUBLISHABLE_CONFIG_RULES_PATH" ] || [ -n "${PUBLISHABLE_RULES_PATH:-}" ]; then
    value="true"
  else
    value="false"
  fi

  case "$value" in
    true|TRUE|yes|YES|1) return 0 ;;
    *) return 1 ;;
  esac
}

publishable_rules_path() {
  local config_file
  config_file="$(publishable_config_path)"
  publishable_load_config "$config_file"

  if [ -n "$PUBLISHABLE_CONFIG_RULES_PATH" ]; then
    printf '%s' "$PUBLISHABLE_CONFIG_RULES_PATH"
  elif [ -n "${PUBLISHABLE_RULES_PATH:-}" ]; then
    printf '%s' "$PUBLISHABLE_RULES_PATH"
  else
    printf '%s/publishable/personal.toml' "${XDG_CONFIG_HOME:-${HOME}/.config}"
  fi
}

publishable_state_dir() {
  if [ -n "${PUBLISHABLE_STATE_DIR:-}" ]; then
    printf '%s' "$PUBLISHABLE_STATE_DIR"
  else
    printf '%s/publishable' "${XDG_STATE_HOME:-${HOME}/.local/state}"
  fi
}

publishable_command_text() {
  printf '%s' "${PUBLISHABLE_CLI:-publishable}"
}

# The command a remediation line tells the user to run for a fresh check.
publishable_check_command() {
  printf '%s' "${PUBLISHABLE_CHECK_COMMAND:-$(publishable_command_text) check}"
}

# SHA-256 of standard input, printed as "<hash>  -".
publishable_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256
  else
    sha256sum
  fi
}

# The engine's identity: one hash over every file under bin/ and lib/ of an installed engine.
# A hook that trusts a stamp recomputes this the same way, so an edited engine cannot ride an
# older clean result.
publishable_engine_hash() {
  (
    cd "$1" || exit 1
    find bin lib ! -type d -print | LC_ALL=C sort | while IFS= read -r file; do
      printf '%s  %s\n' "$(publishable_sha256 < "$file" | awk '{print $1}')" "$file"
    done
  ) | publishable_sha256 | awk '{print $1}'
}
