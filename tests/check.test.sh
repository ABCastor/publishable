#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # ok() and bad() always succeed (A && ok || bad is if-then-else); fixture text keeps a literal $.
# Behaviour tests for `publishable check`. Every case plants one defect in a throwaway
# repository and demands the rule that should catch it. Needs git, gitleaks, jq and perl.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$root/bin/publishable"
T="$(mktemp -d "${TMPDIR:-/tmp}/publishable-test.XXXXXX")"
T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 XDG_CONFIG_HOME="$T/xdg"
unset PUBLISHABLE_DENYLIST PUBLISHABLE_CODE_ROOTS PUBLISHABLE_RULES_PATH PUBLISHABLE_RULES_READY PUBLISHABLE_FINGERPRINT_FILES
mkdir -p "$T/bin" "$T/code" "$T/state"
cat > "$T/bin/gh" <<'SH'
#!/bin/sh
case "$*" in
  *"--json description"*) echo "A fixture repository used by the tests" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

NAME="Pub Lisher"
EMAIL="publisher@example.com"
rules="$T/rules.toml"
cp "$root/personal.toml.example" "$rules"
config="$T/config"
write_config() {
  {
    printf 'author_name=%s\nauthor_email=%s\ngithub_handle=example-user\n' "$NAME" "$EMAIL"
    printf 'rules_path=%s\nrules_ready=true\ncode_roots=%s\n' "$rules" "$T/code"
    printf 'checks_dir=%s\n' "$T/checks.d"
    printf '%s\n' "$@"
  } > "$config"
}
write_config
export PUBLISHABLE_CONFIG_FILE="$config" PUBLISHABLE_STATE_DIR="$T/state"

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/     /' | head -30; }

g() { git -C "$repo" "$@"; }
mkfix() { # name [remote-url ...]
  local name="$1" url i=0; shift
  repo="$T/code/$name"
  git -c init.templateDir= init -q -b main "$repo"
  g config core.hooksPath /dev/null; g config commit.gpgsign false
  g config user.name "$NAME"; g config user.email "$EMAIL"
  [ "$#" -gt 0 ] || set -- "https://github.com/example-org/${name}.git"
  for url in "$@"; do
    if [ "$i" -eq 0 ]; then g remote add origin "$url"; else g remote add "extra$i" "$url"; fi
    i=$((i + 1))
  done
  printf '# Fixture\n\nA fixture.\n' > "$repo/README.md"
  printf 'MIT License\n' > "$repo/LICENSE"
  printf '.env\n.publish-denylist\nCHANGES.log\n' > "$repo/.gitignore"
  printf 'print("hello")\n' > "$repo/app.py"
  g add -A; g commit -qm "Initial commit"
}
commit_all() { g add -A; g commit -qm "${1:-Change}"; }
check() { out="$("$cli" check --format machine "$@" 2>&1)"; rc=$?; }
has() { printf '%s\n' "$out" | grep -q "^BLOCKING|section=$1|.*|rule=$2|"; }
want_block() { # label section rule
  if [ "$rc" -eq 1 ] && has "$2" "$3"; then ok "$1"; else bad "$1 (rc=$rc, want $2/$3)" "$(printf '%s\n' "$out" | grep -E '^(BLOCKING|AUDIT)')"; fi
}
want_clean() {
  if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^AUDIT: CLEAN$'; then ok "$1"; else bad "$1 (rc=$rc, want clean)" "$(printf '%s\n' "$out" | grep -E '^(BLOCKING|AUDIT)')"; fi
}
stamp_of() { printf '%s/%s' "$T/state" "$(printf '%s' "$1" | { shasum -a 256 2>/dev/null || sha256sum; } | awk '{print $1}')"; }

# --- clean baseline and the stamp ------------------------------------------------------
mkfix clean
check "$repo"; want_clean "clean repository passes"
stamp="$(stamp_of "$repo")"
grep -q '^status=clean$' "$stamp" && ok "stamp says clean" || bad "stamp says clean" "$(cat "$stamp")"
grep -q '^history_scope=HEAD$' "$stamp" && ok "stamp records the HEAD scope" || bad "stamp records the HEAD scope"
. "$root/lib/common.sh"
grep -q "^engine_hash=$(publishable_engine_hash "$root")$" "$stamp" && ok "stamp carries the engine hash" || bad "stamp carries the engine hash"
grep -q "^input=MISSING $repo/.publish-denylist$" "$stamp" && ok "stamp records an absent denylist" || bad "stamp records an absent denylist" "$(cat "$stamp")"
grep -q "^input=[0-9a-f]\{64\} $rules$" "$stamp" && ok "stamp records the rules file" || bad "stamp records the rules file"
check --all-refs "$repo"; grep -q '^history_scope=--all$' "$stamp" && ok "--all-refs stamp records the wide scope" || bad "--all-refs stamp records the wide scope"

# --- secrets and history scope ---------------------------------------------------------
mkfix secret
tok="ghp_$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 36)"
printf 'token = "%s"\n' "$tok" > "$repo/settings.txt"; commit_all "Add"
rm "$repo/settings.txt"; commit_all "Remove"
check "$repo"; want_block "secret in an old commit" SECRETS github-pat
printf '%s\n' "$out" | grep -q "$tok" && bad "secret value never printed" || ok "secret value never printed"
mkfix scope
g checkout -q -b side; printf 'token = "%s"\n' "$tok" > "$repo/side.txt"; commit_all "Side"; g checkout -q main
check "$repo"; want_clean "HEAD scope ignores an unrelated local branch"
check --all-refs "$repo"; want_block "--all-refs scans every branch" SECRETS github-pat

# --- identity in test paths ------------------------------------------------------------
mkfix testpaths
mkdir -p "$repo/tests"; printf 'author = "Example Person"\n' > "$repo/tests/test_a.py"; commit_all "Tests"
check "$repo"; want_block "identity inside tests/ is scanned" PERSONAL_DATA personal-primary-name
perl -pi -e 's/\(\?:test\|tests\|fixtures\)/(?:fixtures|tests|test)/' "$rules"
check "$repo"; want_block "a reordered test allowlist is still removed" PERSONAL_DATA personal-primary-name
cp "$root/personal.toml.example" "$rules"
printf '\n[[allowlists]]\ndescription = "one-line"\npaths = ["(?:^|/)tests/"]\n' >> "$rules"
check "$repo"; want_block "an unremovable test allowlist blocks" SECRETS identity-test-scan-error
cp "$root/personal.toml.example" "$rules"

# --- owner exemption -------------------------------------------------------------------
write_config "exempt_owner=example-org" "exempt_rules=personal-primary-name"
mkfix exempt
printf 'Made by Example Person.\n' > "$repo/CREDITS.md"; commit_all "Credits"
check "$repo"; want_clean "exempt rule passes when every remote is the exempt owner"
printf '%s\n' "$out" | grep -q 'status=allowed-by-owner-exemption' && ok "exemption is reported" || bad "exemption is reported"
g remote add other "https://github.com/someone-else/exempt.git"
check "$repo"; want_block "one foreign remote keeps the rule blocking" PERSONAL_DATA personal-primary-name
write_config

write_config "exempt_owner=example-org" "exempt_rules=personal-primary-name" 'exempt_readme_line_pattern=link-profile\.svg'
mkfix readme-row "https://github.com/someone-else/readme-row.git"
printf '# Fixture\n\n<a href="https://example.com/p"><img src="docs/link-profile.svg"> Example Person</a>\n' > "$repo/README.md"; commit_all "Row"
check "$repo"; want_clean "an exempt rule passes on a README line matching the line pattern, on any remote"
printf 'By Example Person.\n' >> "$repo/README.md"; commit_all "Prose"
check "$repo"; want_block "the same rule on another README line blocks" PERSONAL_DATA personal-primary-name
mkfix readme-row-elsewhere "https://github.com/someone-else/readme-row-elsewhere.git"
printf '<img src="docs/link-profile.svg"> Example Person\n' > "$repo/NOTES.md"; commit_all "Notes"
check "$repo"; want_block "the line pattern applies to README files only" PERSONAL_DATA personal-primary-name
write_config

# --- process files and internal records ------------------------------------------------
mkfix records
mkdir -p "$repo/docs/adr" "$repo/.claude"
printf 'x\n' > "$repo/CLAUDE.md"; printf 'x\n' > "$repo/docs/adr/0001.md"; printf '{}\n' > "$repo/.claude/s.json"
printf 'x\n' > "$repo/CHANGES.log"; g add -A; g add -f CHANGES.log; g commit -qm "Records"
check "$repo"
want_block "agent instructions in the tree" PROCESS_REVEAL internal-record-in-tree
printf '%s\n' "$out" | grep -q 'file=docs/adr/0001.md|.*rule=internal-record-in-tree' && ok "decision record in the tree" || bad "decision record in the tree"
printf '%s\n' "$out" | grep -q 'file=CHANGES.log|.*rule=process-file-in-tree' && ok "hand-off log in the tree" || bad "hand-off log in the tree"
g rm -rq --cached CLAUDE.md docs .claude CHANGES.log; g commit -qm "Untrack"
check "$repo"
want_block "internal record in unpublished history" PROCESS_REVEAL internal-record-in-history
want_block "process file in history" PROCESS_REVEAL process-file-in-history

# --- hand-off payload ------------------------------------------------------------------
mkfix handoff
printf 'paid $1,234.56\n' > "$repo/CHANGES.log"
check "$repo"; want_block "currency figure in an untracked hand-off log" CROSS_CONTAMINATION handoff-log-figure-payload
printf 'see aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY\n' > "$repo/CHANGES.log"
check "$repo"; want_block "opaque id in an untracked hand-off log" CROSS_CONTAMINATION handoff-log-opaque-id

# --- denylists -------------------------------------------------------------------------
mkfix deny
printf 'zorblax\n' > "$repo/.publish-denylist"
printf 'my_zorblax_value = 1\n' > "$repo/model.py"; commit_all "Model"
check "$repo"; want_block "denylist term in a tracked file (snake_case)" PERSONAL_DATA repo-denylist
rm "$repo/model.py"; commit_all "Remove"
check "$repo"; want_block "denylist term in history" PERSONAL_DATA repo-denylist-history
grep -q "^input=[0-9a-f]\{64\} $repo/.publish-denylist$" "$(stamp_of "$repo")" && ok "stamp records the denylist" || bad "stamp records the denylist"
mkfix deny2
printf 'quintessa\n' > "$T/external-list.txt"
g config publishable.denylist "$T/external-list.txt"
printf 'quintessa lives here\n' > "$repo/notes.md"; commit_all "Notes"
check "$repo"; want_block "configured external denylist" PERSONAL_DATA repo-denylist
g config publishable.denylist "$T/missing-list.txt"
check "$repo"; want_block "unreadable configured denylist" PERSONAL_DATA configured-denylist-unreadable

# --- private-data lineage --------------------------------------------------------------
mkfix lineage
git -c init.templateDir= init -q "$T/code/lineage-data"
check "$repo"; want_block "private-data sibling without a denylist" PERSONAL_DATA private-data-lineage-without-denylist

# --- public identity and AI attribution ------------------------------------------------
mkfix ident
printf 'a\n' > "$repo/a.txt"; g add -A; g -c user.name=Someone -c user.email=s@example.com commit -qm "Wrong"
check "$repo"; want_block "wrong author in unpublished history" AI_ATTRIBUTION public-author-identity-mismatch
g config user.email other@example.com
check "$repo"; want_block "wrong repo-local identity" AI_ATTRIBUTION public-author-config-mismatch
write_config_no_identity() { printf 'rules_path=%s\nrules_ready=true\n' "$rules" > "$config"; }
write_config_no_identity
check "$repo"
printf '%s\n' "$out" | grep -q 'public_identity=not-configured' && ! has AI_ATTRIBUTION public-author-identity-mismatch \
  && ok "identity check is off when no identity is configured" || bad "identity check is off when no identity is configured"
write_config
mkfix ai
printf 'a\n' > "$repo/a.txt"; g add -A; GIT_AUTHOR_NAME="Copilot" GIT_AUTHOR_EMAIL="c@example.com" g commit -qm "AI"
check "$repo"; want_block "AI vendor as author" AI_ATTRIBUTION ai-author-identity
mkfix ai2
printf 'a\n' > "$repo/a.txt"; g add -A; GIT_COMMITTER_NAME="ChatGPT" GIT_COMMITTER_EMAIL="c@example.com" g commit -qm "AI"
check "$repo"; want_block "AI vendor as committer" AI_ATTRIBUTION ai-author-identity
mkfix ai3
ai_name="Clau""de"
printf 'a\n' > "$repo/a.txt"; g add -A; g commit -qm "Change" -m "Co-Authored-By: $ai_name <noreply@example.com>"
check "$repo"; want_block "AI co-author in a commit message" AI_ATTRIBUTION ai-attribution-message
printf 'Generated with %s\n' "$ai_name" > "$repo/NOTES.txt"; commit_all "Notes"
check "$repo"; want_block "AI attribution in a tracked file" AI_ATTRIBUTION ai-attribution-tree

# --- environment hygiene ---------------------------------------------------------------
mkfix envh
printf 'x\n' > "$repo/.gitignore"; printf 'KEY=1\n' > "$repo/.env.local"; commit_all "Env"
check "$repo"; want_block ".env not ignored" ENV_HYGIENE env-not-ignored
want_block "tracked env file" ENV_HYGIENE tracked-sensitive-config

# --- untrusted history and unborn repositories -----------------------------------------
mkfix shape
printf 'a\n' > "$repo/a.txt"; commit_all "Second"
git -c init.templateDir= clone -q --depth 1 "file://$repo" "$T/code/shallow" 2>/dev/null
check "$T/code/shallow"; want_block "shallow clone" REPOSITORY untrusted-history-shape
head_sha="$(g rev-parse HEAD)"; g replace "$head_sha" "$(g rev-parse HEAD~1)"
check "$repo"; want_block "replacement ref" REPOSITORY untrusted-history-shape
g replace -d "$head_sha" >/dev/null
mkdir -p "$repo/.git/info"; : > "$repo/.git/info/grafts"
check "$repo"; want_block "grafts file" REPOSITORY untrusted-history-shape
grep -q '^status=clean$' "$(stamp_of "$repo")" && bad "an early refusal leaves no clean stamp" || ok "an early refusal leaves no clean stamp"
rm -f "$repo/.git/info/grafts"
git -c init.templateDir= init -q "$T/code/unborn"
check "$T/code/unborn"
if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q 'rule=unscanned-history' && [ "$(printf '%s\n' "$out" | grep -c '^== SUMMARY ==$')" -eq 1 ]; then
  ok "unborn repository is UNSCANNED with one summary"
else
  bad "unborn repository is UNSCANNED with one summary" "$out"
fi
check "$T/does-not-exist"; [ "$rc" -eq 2 ] && has REPOSITORY not-a-repository && ok "not a repository exits 2" || bad "not a repository exits 2"
out="$(cd "$T" && "$cli" check --format machine -- --help 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && has REPOSITORY not-a-repository && ok "a path after -- is a path, even --help" || bad "a path after -- is a path, even --help (rc=$rc)" "$out"

# --- missing tools and rules -----------------------------------------------------------
restricted_path() { # tool -> PATH without it
  local dir="$T/without-$1" f
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
    for f in /usr/local/bin/* /usr/bin/* /bin/* /opt/homebrew/bin/* "$T"/bin/*; do
      [ -x "$f" ] && [ ! -d "$f" ] && ln -sf "$f" "$dir/${f##*/}"
    done
    rm -f "$dir/$1"
  fi
  printf '%s' "$dir"
}
mkfix tools
out="$(PATH="$(restricted_path gitleaks)" "$cli" check --format machine "$repo" 2>&1)"; rc=$?
want_block "gitleaks missing blocks" SECRETS scanner-missing
out="$(PATH="$(restricted_path jq)" "$cli" check --format machine "$repo" 2>&1)"; rc=$?
want_block "jq missing blocks" SECRETS report-parser-missing
write_config "rules_path=$T/no-such-rules.toml"
check "$repo"; want_block "missing rules file blocks" SECRETS personal-config-missing
write_config "rules_ready=false"
check "$repo"; want_block "rules not ready blocks" SECRETS personal-config-unconfigured
write_config

# --- local checks ----------------------------------------------------------------------
mkdir -p "$T/checks.d"
mkfix plugins
printf '%s\n' '#!/usr/bin/env bash' \
  'grep -q "^app.py$" "$PUBLISHABLE_TRACKED_PATHS" && printf "BLOCKING|section=PUBLISH_BASICS|scope=tree|file=app.py|line=n/a|commit=HEAD|rule=house-rule|description=Fixture rule.\n"' \
  'exit 0' > "$T/checks.d/house.sh"
check "$repo"; want_block "a local check's finding blocks" PUBLISH_BASICS house-rule
printf '%s\n' "$out" | grep -q '^SUMMARY|section=PUBLISH_BASICS|blocking=1|' && ok "a local finding is counted" || bad "a local finding is counted"
grep -q "^input=[0-9a-f]\{64\} $T/checks.d/house.sh$" "$(stamp_of "$repo")" && ok "stamp records the local check" || bad "stamp records the local check"
printf '#!/usr/bin/env bash\nexit 3\n' > "$T/checks.d/house.sh"
check "$repo"; want_block "a failing local check blocks" PUBLISH_BASICS local-check-failed
printf '#!/usr/bin/env bash\necho "AUDIT: CLEAN"\n' > "$T/checks.d/house.sh"
check "$repo"; want_block "a local check printing anything else blocks" PUBLISH_BASICS local-check-failed
rm -f "$T/checks.d/house.sh"

# --- configuration and environment cannot switch a check off ---------------------------
mkfix hardening
mkdir -p "$repo/tests"; printf 'author = "Example Person"\n' > "$repo/tests/test_a.py"; commit_all "Tests"
write_config "test_path_rules=["
check "$repo"; want_block "an invalid test_path_rules pattern blocks instead of dropping findings" SECRETS invalid-test-path-rules
mkfix hardening-empty
write_config "test_path_rules=["
check "$repo"; want_block "an invalid test_path_rules pattern blocks even with nothing found" SECRETS invalid-test-path-rules
mkfix tilde-list
g config publishable.denylist "~nosuchuser-list/denylist"
mkdir -p "$T/cwd/~nosuchuser-list"; printf '# empty\n' > "$T/cwd/~nosuchuser-list/denylist"
out="$(cd "$T/cwd" && "$cli" check --format machine "$repo" 2>&1)"; rc=$?
want_block "a ~name denylist path resolves under HOME, never the working folder" PERSONAL_DATA configured-denylist-unreadable
# A multi-line keyword list mentioning "example" keeps every keyword in the test-path pass.
write_config
mkfix keywords
cat >> "$rules" <<'TOML'

[[rules]]
id = "personal-contact"
description = "Replace the contact address."
regex = '''contact@example\.org'''
keywords = [
  "contact@example.org",
  "zzzz-not-in-the-file",
]
TOML
mkdir -p "$repo/tests"; printf 'to = "contact@example.org"\n' > "$repo/tests/test_mail.py"; commit_all "Mail"
check "$repo"; want_block "a keyword mentioning example survives the test-path pass" PERSONAL_DATA personal-contact
cp "$root/personal.toml.example" "$rules"
# A one-line allowlist for example files cannot be removed, so the pass blocks.
mkfix example-line
printf '\n[[allowlists]]\ndescription = "one-line"\npaths = ["(?:^|/)[^/]*[.]example[.][^/]+$"]\n' >> "$rules"
printf 'author = "Example Person"\n' > "$repo/settings.example.py"; commit_all "Example"
check "$repo"; want_block "an unremovable example-path allowlist blocks" SECRETS identity-test-scan-error
cp "$root/personal.toml.example" "$rules"
# An exported shell function named like a command cannot skip a local check.
mkdir -p "$T/checks.d"
printf '%s\n' '#!/usr/bin/env bash' 'printf "BLOCKING|section=PUBLISH_BASICS|scope=tree|file=x|line=n/a|commit=HEAD|rule=always|description=Fixture.\n"' > "$T/checks.d/always.sh"
mkfix exported-function
out="$(env 'BASH_FUNC_bash%%=() { :; }' "$cli" check --format machine "$repo" 2>&1)"; rc=$?
want_block "an exported bash function cannot skip local checks" PUBLISH_BASICS always
rm -f "$T/checks.d/always.sh"
write_config "exempt_owner=example-org" "exempt_rules=github-pat personal-primary-name"
mkfix exempt-secret
printf 'token = "%s"\n' "$tok" > "$repo/settings.txt"; commit_all "Settings"
check "$repo"; want_block "an exemption never covers a secret rule" SECRETS github-pat
write_config
mkdir -p "$T/checks.d"
printf '%s\n' '#!/usr/bin/env bash' 'printf "BLOCKING|section=PUBLISH_BASICS|scope=tree|file=x|line=n/a|commit=HEAD|rule=always|description=Fixture.\n"' > "$T/checks.d/always.sh"
mkfix globs
out="$(env SHELLOPTS=noglob "$cli" check --format machine "$repo" 2>&1)"; rc=$?
want_block "an inherited noglob still runs local checks" PUBLISH_BASICS always
rm -f "$T/checks.d/always.sh"
mkfix noglob-lineage
git -c init.templateDir= init -q "$T/code/noglob-lineage-data"
out="$(env SHELLOPTS=noglob "$cli" check --format machine "$repo" 2>&1)"; rc=$?
want_block "an inherited noglob still finds a private-data sibling" PERSONAL_DATA private-data-lineage-without-denylist
mkfix upstream-conflict
g config publish-audit.publicUpstream example-user/product
g config publishable.publicUpstream someone/else
check "$repo"; want_block "two different publicUpstream declarations block" REPOSITORY public-upstream-conflict

# --- human report ----------------------------------------------------------------------
mkfix human
printf 'x\n' > "$repo/CLAUDE.md"; commit_all "Record"
out="$("$cli" check --format human "$repo" 2>&1)"; rc=$?
printf '%s\n' "$out" | grep -q 'VERDICT: DO NOT PUBLISH' && printf '%s\n' "$out" | grep -q 'WORKING TREE: 1 blocking' \
  && ok "human report gives the verdict" || bad "human report gives the verdict" "$out"

# --- init produces a repository that passes ---------------------------------------------
"$cli" init made --lang shell --dir "$T/code" >/dev/null 2>&1
repo="$T/code/made"
if [ -f "$repo/README.md" ]; then
  git -c init.templateDir= init -q -b main "$repo"
  g config core.hooksPath /dev/null; g config user.name "$NAME"; g config user.email "$EMAIL"
  g add -A >/dev/null 2>&1; g commit -qm "Initial commit" >/dev/null 2>&1
  check "$repo"
  if ! printf '%s\n' "$out" | grep -qE 'rule=(internal-record|process-file)'; then ok "init scaffolds no internal records"; else bad "init scaffolds no internal records" "$out"; fi
else
  bad "init creates a project"
fi

printf '\ncheck.test: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
