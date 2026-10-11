#!/usr/bin/env bash
# Runs every test file; exits non-zero if any fails.
set -u
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
status=0
for test_file in "$dir"/*.test.sh; do
  printf '== %s\n' "${test_file##*/}"
  bash "$test_file" || status=1
done
exit "$status"
