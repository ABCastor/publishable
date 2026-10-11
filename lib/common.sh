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

publishable_load_config() {
  local config_file="${1:-$(publishable_config_path)}"
  local raw_key raw_value key value

  PUBLISHABLE_CONFIG_AUTHOR_NAME=""
  PUBLISHABLE_CONFIG_AUTHOR_EMAIL=""
  PUBLISHABLE_CONFIG_GITHUB_HANDLE=""
  PUBLISHABLE_CONFIG_RULES_PATH=""
  PUBLISHABLE_CONFIG_RULES_READY=""

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
      rules_path) PUBLISHABLE_CONFIG_RULES_PATH="$value" ;;
      rules_ready) PUBLISHABLE_CONFIG_RULES_READY="$value" ;;
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
