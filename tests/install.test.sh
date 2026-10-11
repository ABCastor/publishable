#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # ok() and bad() always succeed (A && ok || bad is if-then-else); fixture text keeps a literal $.
# Installer and pre-commit hook tests, each in a throwaway HOME.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T="$(mktemp -d "${TMPDIR:-/tmp}/publishable-install.XXXXXX")"
T="$(cd "$T" && pwd -P)"
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
unset XDG_DATA_HOME XDG_CONFIG_HOME XDG_STATE_HOME PUBLISHABLE_CONFIG_FILE PUBLISHABLE_HOME PUBLISHABLE_BIN_DIR
export GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/     /' | head -20; }
. "$root/lib/common.sh"

# --- a fresh home ------------------------------------------------------------------------
H="$T/fresh"; mkdir -p "$H"
out="$(HOME="$H" GIT_CONFIG_GLOBAL="$H/.gitconfig" bash "$root/install.sh" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "fresh install succeeds" || bad "fresh install succeeds (rc=$rc)" "$out"
engine="$(printf '%s\n' "$out" | sed -n 's/^ENGINE: //p')"
[ -d "$engine" ] && [ "$(readlink "$H/.local/share/publishable/current")" = "engines/${engine##*/}" ] \
  && ok "engine installed in its own folder with current pointing at it" || bad "engine installed in its own folder" "$out"
[ "$(printf '%s\n' "$out" | sed -n 's/^ENGINE_SHA256: //p')" = "$(publishable_engine_hash "$engine")" ] \
  && [ "$(publishable_engine_hash "$engine")" = "$(publishable_engine_hash "$root")" ] \
  && ok "printed engine hash matches the installed engine and the source" || bad "printed engine hash matches"
[ ! -w "$engine/lib/check.sh" ] && ok "installed engine files are read-only" || bad "installed engine files are read-only"
[ -x "$H/.git-template/hooks/pre-commit" ] && ok "pre-commit installed into an empty template" || bad "pre-commit installed into an empty template"
[ ! -e "$H/.git-template/hooks/pre-push" ] && ok "no pre-push hook is installed" || bad "no pre-push hook is installed"
grep -q '^rules_ready=false$' "$H/.config/publishable/config" && ok "starter config is not ready" || bad "starter config is not ready"
out="$(HOME="$H" GIT_CONFIG_GLOBAL="$H/.gitconfig" bash "$root/install.sh" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q "^UNCHANGED: $engine$" && ok "reinstall is idempotent" || bad "reinstall is idempotent (rc=$rc)" "$out"

# --- an existing hook is never replaced --------------------------------------------------
H="$T/existing"; mkdir -p "$H/.git-template/hooks"
printf '#!/bin/sh\n# my own hook\nexit 0\n' > "$H/.git-template/hooks/pre-commit"
cp -p "$H/.git-template/hooks/pre-commit" "$T/original-hook"
out="$(HOME="$H" GIT_CONFIG_GLOBAL="$H/.gitconfig" bash "$root/install.sh" 2>&1)"; rc=$?
cmp -s "$T/original-hook" "$H/.git-template/hooks/pre-commit" && ok "existing template hook left untouched" || bad "existing template hook left untouched"
[ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q '^ACTION: ' && ok "installer reports the kept hook" || bad "installer reports the kept hook (rc=$rc)" "$out"
backups=("$H"/.git-template/hooks/*before-publishable*)
[ -e "${backups[0]}" ] && bad "no backup-and-replace copy is made" || ok "no backup-and-replace copy is made"

# --- engine only -------------------------------------------------------------------------
H="$T/engine-only"; mkdir -p "$H"
out="$(HOME="$H" GIT_CONFIG_GLOBAL="$H/.gitconfig" bash "$root/install.sh" --engine-only 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ -n "$(printf '%s\n' "$out" | sed -n 's/^ENGINE: //p')" ] && [ ! -e "$H/.git-template" ] \
  && [ ! -e "$H/.config/publishable" ] && [ ! -e "$H/.local/bin/publishable" ] && [ ! -e "$H/.gitconfig" ] \
  && ok "--engine-only installs the engine and nothing else" || bad "--engine-only installs the engine and nothing else (rc=$rc)" "$out"

# --- the pre-commit hook -----------------------------------------------------------------
H="$T/fresh"
repo="$T/hooked"
GIT_CONFIG_GLOBAL="$H/.gitconfig" HOME="$H" git init -q "$repo"
git -C "$repo" config user.name Tester; git -C "$repo" config user.email tester@example.com
cp "$root/personal.toml.example" "$H/.config/publishable/personal.toml"
commit() { HOME="$H" GIT_CONFIG_GLOBAL="$H/.gitconfig" git -C "$repo" commit -qm "$1" 2>&1; }
printf 'hello\n' > "$repo/a.txt"; git -C "$repo" add a.txt
out="$(commit first)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'starter status' && ok "hook blocks while the rules are not ready" || bad "hook blocks while the rules are not ready (rc=$rc)" "$out"
perl -pi -e 's/^rules_ready=false$/rules_ready=true/' "$H/.config/publishable/config"
out="$(commit first)"; rc=$?
[ "$rc" -eq 0 ] && ok "hook allows clean content" || bad "hook allows clean content (rc=$rc)" "$out"
printf 'by Example Person\n' > "$repo/b.txt"; git -C "$repo" add b.txt
out="$(commit second)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'personal-primary-name' && ok "hook blocks a staged identity" || bad "hook blocks a staged identity (rc=$rc)" "$out"
perl -ni -e 'print unless /^rules_(path|ready)=/' "$H/.config/publishable/config"
git -C "$repo" restore --staged b.txt; printf 'fine\n' > "$repo/c.txt"; git -C "$repo" add c.txt
out="$(commit third)"; rc=$?
[ "$rc" -ne 0 ] && ok "hook and check agree: no rules path configured is not ready" || bad "hook and check agree on readiness (rc=$rc)" "$out"

printf '\ninstall.test: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
