#!/usr/bin/env bash
# Builds the fixture the demo recording runs against.
#
# Everything here is fictional. The "leak" it plants belongs to a made-up user, so the
# recording carries no real data. That is deliberate: a terminal recording is a published
# artifact like any other, and this tool exists because people forget that.
#
# This script never deletes anything. If the work directory already exists it stops and
# tells you, rather than clearing a path it was handed.
set -euo pipefail

work="${1:-/tmp/publishable-demo}"

if [ -e "$work" ]; then
  printf 'Work directory already exists: %s\n' "$work" >&2
  printf 'Remove it yourself if you want a fresh fixture, then re-run.\n' >&2
  exit 1
fi

mkdir -p "$work/my-app"
cd "$work/my-app"

git init -q
git config user.email "dev@example.com"
git config user.name "A. Developer"

cat > "$work/rules.toml" <<'RULES'
title = "Demo rules"

[extend]
useDefault = true

[[rules]]
id = "personal-absolute-home-path"
description = "Replace this absolute home path with $HOME or a runtime-configured path."
regex = '''/Users/alice(?:/|["'`[:space:]]|$)'''
keywords = ["/Users/alice"]

[[rules]]
id = "personal-email"
description = "Replace the personal email with a placeholder or runtime configuration."
regex = '''(?i)\balice@example\.internal\b'''
keywords = ["alice@example.internal"]
RULES

printf 'CACHE = "/Users/alice/.cache/my-app"\nOWNER = "alice@example.internal"\n' > settings.py
printf 'print("hello")\n' > main.py
git add -A >/dev/null
git commit -qm "Add settings and entrypoint"

# The file gets deleted. It stays in history. That is the entire point of the demo.
git rm -q settings.py
git commit -qm "Move settings out of the repo"

printf 'author_name=A. Developer\nauthor_email=dev@example.com\nrules_path=%s/rules.toml\n' \
  "$work" > "$work/config"

printf 'Fixture ready: %s/my-app\n' "$work"
