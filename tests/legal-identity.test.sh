#!/usr/bin/env bash
# Boundary tests independent of scanner report generation; never print fixture contents.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
open='<p data-legal-identity>'
body="${open}Example Person</p>"
start=$((${#open}+1)); end=$((${#open}+14))
pass=0 fail=0
probe() {
  local label="$1" expected="$2" text="$3"; shift 3
  local rc=0
  printf '%s' "$text" | perl "$root/lib/legal-identity.pl" "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq "$expected" ]; then
    printf 'PASS %s\n' "$label"; pass=$((pass+1))
  else
    printf 'FAIL %s (exit %s, expected %s)\n' "$label" "$rc" "$expected"; fail=$((fail+1))
  fi
}
probe 'exact text range accepted' 0 "$body" apps/privacy/index.html '**/privacy/**' 1 "$start" 1 "$end"
probe 'root legal directory matches globstar' 0 "$body" legal/index.html '**/legal/**' 1 "$start" 1 "$end"
probe 'directory names are bounded' 1 "$body" apps/notprivacy/index.html '**/privacy/**' 1 "$start" 1 "$end"
probe 'single star never crosses a directory' 1 "$body" apps/privacy/it/index.html 'apps/privacy/*' 1 "$start" 1 "$end"
probe 'missing range refuses' 1 "$body" apps/privacy/index.html '**/privacy/**' 1 "$start" 1 ''
probe 'zero column refuses' 1 "$body" apps/privacy/index.html '**/privacy/**' 1 0 1 "$end"
probe 'range outside blob refuses' 1 "$body" apps/privacy/index.html '**/privacy/**' 1 "$start" 2 "$end"
probe 'reversed range refuses' 1 "$body" apps/privacy/index.html '**/privacy/**' 1 "$end" 1 "$start"
probe 'attribute range refuses' 1 "$body" apps/privacy/index.html '**/privacy/**' 1 2 1 10
probe 'boundary crossing refuses' 1 "$body" apps/privacy/index.html '**/privacy/**' 1 "$start" 1 "$((end+1))"
probe 'malformed trailing markup refuses' 1 "$body<broken" apps/privacy/index.html '**/privacy/**' 1 "$start" 1 "$end"
probe 'duplicate marker refuses' 1 '<p data-legal-identity data-legal-identity>Example Person</p>' apps/privacy/index.html '**/privacy/**' 1 42 1 55
probe 'marker substring is not an attribute' 1 '<p title="data-legal-identity">Example Person</p>' apps/privacy/index.html '**/privacy/**' 1 31 1 44
probe 'quoted tag delimiter does not open a block' 1 '<div title="<p data-legal-identity>Example Person</p>"></div>' apps/privacy/index.html '**/privacy/**' 1 35 1 48
printf '\nlegal-identity.test: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
