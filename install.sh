#!/usr/bin/env bash
set -euo pipefail
umask 022

# shellcheck disable=SC1007  # `CDPATH= cd` clears CDPATH for this command only; the empty
# assignment is the intended idiom, not a typo.
root_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
data_home="${XDG_DATA_HOME:-${HOME}/.local/share}"
config_home="${XDG_CONFIG_HOME:-${HOME}/.config}"
install_root="${data_home}/publishable"
bin_dir="${PUBLISHABLE_BIN_DIR:-${HOME}/.local/bin}"
bin_link="${bin_dir}/publishable"
template_dir="${HOME}/.git-template"
config_dir="${config_home}/publishable"
config_file="${config_dir}/config"
rules_file="${config_dir}/personal.toml"
install_status=0
engine_only=0
case "${1:-}" in
  --engine-only) engine_only=1 ;;
  '') ;;
  *) printf 'Usage: %s [--engine-only]\n' "$0" >&2; exit 2 ;;
esac

if ! command -v git >/dev/null 2>&1; then
  printf '%s\n' "ERROR: git is required but is not on PATH." >&2
  exit 2
fi

if ! command -v gitleaks >/dev/null 2>&1; then
  printf '%s\n' "ERROR: gitleaks is required but is not on PATH." >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' "NOTICE: jq is unavailable. publishable check blocks until it is installed."
fi

if ! command -v gh >/dev/null 2>&1; then
  printf '%s\n' "NOTICE: gh is unavailable. Local checks work; GitHub description verification will be skipped."
fi

# shellcheck source=lib/common.sh
. "${root_dir}/lib/common.sh"

install_file() {
  local source_file="$1" destination_file="$2" mode="$3"
  mkdir -p "${destination_file%/*}"
  if [ -f "$destination_file" ] && cmp -s "$source_file" "$destination_file"; then
    printf 'UNCHANGED: %s\n' "$destination_file"
  else
    install -m "$mode" "$source_file" "$destination_file"
    printf 'CHANGED: installed %s\n' "$destination_file"
  fi
}

# Each engine version installs into its own read-only folder and is never edited in place, so a
# caller can pin one folder and its hash. `current` points at the newest install.
if git -C "$root_dir" rev-parse --verify HEAD >/dev/null 2>&1 \
    && [ -z "$(git -C "$root_dir" status --porcelain -- bin lib)" ]; then
  engine_id="$(git -C "$root_dir" rev-parse --short=12 HEAD)"
else
  engine_id="local-$(publishable_engine_hash "$root_dir" | cut -c1-12)"
fi
engine_dir="${install_root}/engines/${engine_id}"
source_hash="$(publishable_engine_hash "$root_dir")"
if [ -d "$engine_dir" ]; then
  if [ "$(publishable_engine_hash "$engine_dir")" = "$source_hash" ]; then
    printf 'UNCHANGED: %s\n' "$engine_dir"
  else
    printf 'ERROR: %s exists with different content; move it aside and rerun.\n' "$engine_dir" >&2
    exit 1
  fi
else
  mkdir -p "${install_root}/engines"
  staging="$(mktemp -d "${install_root}/engines/.install.XXXXXX")"
  cp -R "${root_dir}/bin" "${root_dir}/lib" "$staging/"
  chmod -R a-w "$staging/bin" "$staging/lib"
  chmod 0755 "$staging"
  mv "$staging" "$engine_dir"
  printf 'CHANGED: installed %s\n' "$engine_dir"
fi
[ "$engine_only" -eq 1 ] || ln -sfn "engines/${engine_id}" "${install_root}/current"
[ "$engine_only" -eq 1 ] || install_file "${root_dir}/personal.toml.example" "${install_root}/personal.toml.example" 0644
printf 'ENGINE: %s\n' "$engine_dir"
printf 'ENGINE_SHA256: %s\n' "$source_hash"
[ "$engine_only" -eq 0 ] || exit 0

mkdir -p "$bin_dir"
if [ -L "$bin_link" ] && [ "$(readlink "$bin_link")" = "${install_root}/current/bin/publishable" ]; then
  printf 'UNCHANGED: %s\n' "$bin_link"
elif [ -e "$bin_link" ] || [ -L "$bin_link" ]; then
  printf 'UNCHANGED: %s already exists and was not clobbered.\n' "$bin_link" >&2
  printf 'ACTION: move it aside, then link %s to %s.\n' "$bin_link" "${install_root}/current/bin/publishable" >&2
  install_status=1
else
  ln -s "${install_root}/current/bin/publishable" "$bin_link"
  printf 'CHANGED: linked %s -> %s\n' "$bin_link" "${install_root}/current/bin/publishable"
fi

# The pre-commit hook goes into the git template only when the template has none: an existing
# hook belongs to the user and is never replaced.
hook_source="${root_dir}/hooks/pre-commit"
hook_destination="${template_dir}/hooks/pre-commit"
mkdir -p "${template_dir}/hooks"
if [ -f "$hook_destination" ] && cmp -s "$hook_source" "$hook_destination"; then
  printf 'UNCHANGED: %s\n' "$hook_destination"
elif [ -e "$hook_destination" ] || [ -L "$hook_destination" ]; then
  printf 'UNCHANGED: %s already exists and was not replaced.\n' "$hook_destination" >&2
  printf 'ACTION: to add the Publishable scan, run %s from your hook.\n' "$hook_source" >&2
  install_status=1
else
  install -m 0755 "$hook_source" "$hook_destination"
  printf 'CHANGED: installed %s\n' "$hook_destination"
fi

mkdir -p "$config_dir"
chmod 700 "$config_dir" 2>/dev/null || true

if [ -f "$rules_file" ]; then
  printf 'UNCHANGED: %s\n' "$rules_file"
else
  install -m 0600 "${root_dir}/personal.toml.example" "$rules_file"
  printf 'CHANGED: wrote starter rules to %s\n' "$rules_file"
  printf '%s\n' "ACTION: replace every placeholder in that file with your own local policy values."
fi

if [ -f "$config_file" ]; then
  printf 'UNCHANGED: %s\n' "$config_file"
else
  {
    printf '%s\n' '# Local publishable policy. This file stays outside project repositories.'
    printf '%s\n' 'author_name='
    printf '%s\n' 'author_email='
    printf '%s\n' 'github_handle='
    printf 'rules_path=%s\n' "$rules_file"
    printf '%s\n' 'rules_ready=false'
  } > "$config_file"
  chmod 600 "$config_file"
  printf 'CHANGED: wrote starter config to %s\n' "$config_file"
fi

# git stores init.templateDir verbatim, so a user who typed a literal ~ has that exact
# string in their config rather than an expanded path. Compare against both forms.
# shellcheck disable=SC2088  # not expanded on purpose: this is the literal string to match.
literal_tilde_template="~/.git-template"
current_template="$(git config --global --get init.templateDir 2>/dev/null || true)"
if [ -z "$current_template" ]; then
  git config --global init.templateDir "$template_dir"
  printf 'CHANGED: set init.templateDir to %s\n' "$template_dir"
elif [ "$current_template" = "$template_dir" ] || [ "$current_template" = "$literal_tilde_template" ]; then
  printf 'UNCHANGED: init.templateDir is already %s\n' "$current_template"
else
  printf 'UNCHANGED: init.templateDir remains %s; it was not clobbered.\n' "$current_template" >&2
  printf 'ACTION: choose whether to keep it or run: git config --global init.templateDir %q\n' "$template_dir" >&2
  install_status=1
fi

printf '%s\n' "Install complete. New repositories inherit the template hook only when init.templateDir points to the installed template."
exit "$install_status"
