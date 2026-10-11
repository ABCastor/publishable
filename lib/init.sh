#!/usr/bin/env bash

publishable_write_prompted_author() {
  local config_file="$1" author_name="$2"
  local config_dir config_tmp
  config_dir="${config_file%/*}"
  mkdir -p "$config_dir"
  chmod 700 "$config_dir" 2>/dev/null || true
  umask 077

  if [ -f "$config_file" ]; then
    config_tmp="$(mktemp "${config_dir}/.publishable-config.XXXXXX")"
    awk -v author_name="$author_name" '
      BEGIN { replaced = 0 }
      /^[[:space:]]*author_name[[:space:]]*=/ {
        print "author_name=" author_name
        replaced = 1
        next
      }
      { print }
      END {
        if (!replaced) print "author_name=" author_name
      }
    ' "$config_file" > "$config_tmp"
    chmod 600 "$config_tmp"
    mv -f "$config_tmp" "$config_file"
  else
    {
      printf '%s\n' '# Local publishable policy. This file stays outside project repositories.'
      printf 'author_name=%s\n' "$author_name"
      printf '%s\n' 'author_email='
      printf '%s\n' 'github_handle='
      printf '%s\n' 'rules_path='
      printf '%s\n' 'rules_ready=false'
    } > "$config_file"
    chmod 600 "$config_file"
  fi
}

publishable_init() (
  set -euo pipefail
  umask 022

  local script_name="publishable init"

  usage() {
    printf 'Usage: %s <name> [--lang python|node|rust|shell] [--dir <parent>] [--license mit|apache]\n' "$script_name"
  }

  die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 2
  }

  [ "$#" -ge 1 ] || {
    usage >&2
    exit 2
  }

  local name="$1"
  shift
  local lang="shell"
  local parent="$PWD"
  local license_key="mit"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --lang)
        [ "$#" -ge 2 ] || die "--lang needs a value"
        lang="$2"
        shift 2
        ;;
      --dir)
        [ "$#" -ge 2 ] || die "--dir needs a value"
        parent="$2"
        shift 2
        ;;
      --license)
        [ "$#" -ge 2 ] || die "--license needs a value"
        license_key="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done

  [[ "$name" =~ ^[A-Za-z][A-Za-z0-9._-]*$ ]] \
    || die "name must be one safe directory component beginning with a letter"

  case "$lang" in
    python|node|rust|shell) ;;
    *) die "unsupported language: $lang" ;;
  esac

  case "$license_key" in
    mit|apache) ;;
    *) die "unsupported license: $license_key" ;;
  esac

  local config_file author_name author_email github_handle
  config_file="$(publishable_config_path)"
  publishable_load_config "$config_file"

  author_name="$PUBLISHABLE_CONFIG_AUTHOR_NAME"
  author_email="$PUBLISHABLE_CONFIG_AUTHOR_EMAIL"
  github_handle="$PUBLISHABLE_CONFIG_GITHUB_HANDLE"

  [ -n "$author_name" ] || author_name="${PUBLISHABLE_AUTHOR_NAME:-}"
  [ -n "$author_email" ] || author_email="${PUBLISHABLE_AUTHOR_EMAIL:-}"
  [ -n "$github_handle" ] || github_handle="${PUBLISHABLE_GITHUB_HANDLE:-}"
  # Reserved profile values are resolved but never embedded by the current
  # scaffold. It has no legitimate use for them, and collecting public
  # identity into generated files would defeat the born-public boundary.
  : "$author_email" "$github_handle"

  if [ -z "$author_name" ]; then
    if [ -t 0 ]; then
      printf 'License author name: ' >&2
      IFS= read -r author_name
      [ -n "$author_name" ] || die "author name cannot be empty"
      publishable_write_prompted_author "$config_file" "$author_name"
      printf 'Saved author_name to %s\n' "$config_file"
    else
      printf 'ERROR: no author is configured and this shell is non-interactive.\n' >&2
      printf 'Config: %s\n' "$config_file" >&2
      printf '%s\n' "Keys: author_name (required for LICENSE), author_email (optional), github_handle (optional), rules_path and rules_ready (audit policy)." >&2
      printf '%s\n' "Environment fallback: PUBLISHABLE_AUTHOR_NAME." >&2
      exit 2
    fi
  fi

  local target staging module_name package_name env_prefix year out_dir
  target="${parent%/}/${name}"
  if [ -e "$target" ] || [ -L "$target" ]; then
    die "refusing to overwrite existing path: $target"
  fi

  module_name="$(printf '%s' "$name" | tr '[:upper:].-' '[:lower:]__' | sed 's/[^a-z0-9_]/_/g')"
  package_name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[_.]/-/g; s/[^a-z0-9-]/-/g')"
  env_prefix="$(printf '%s' "$name" | tr '[:lower:].-' '[:upper:]__' | sed 's/[^A-Z0-9_]/_/g')"
  year="$(date +%Y)"

  mkdir -p "$parent"
  staging="${target}.publishable.$$"
  if [ -e "$staging" ] || [ -L "$staging" ]; then
    die "temporary scaffold path already exists: $staging"
  fi
  mkdir -p "$staging"
  out_dir="$staging"
  trap 'rm -rf "$staging"' EXIT

  write_gitignore() {
    cat > "$out_dir/.gitignore" <<'EOF'
.env*
!.env.example
CHANGES.log
STATE.md
PLAN.md
HANDOFF.md
NOTES.md
SCRATCH*
.claude/
.codex/
.cursor/
*.local.*
.DS_Store
EOF

    case "$lang" in
      python)
        cat >> "$out_dir/.gitignore" <<'EOF'
__pycache__/
*.py[cod]
.pytest_cache/
.mypy_cache/
.ruff_cache/
.venv/
build/
dist/
*.egg-info/
EOF
        ;;
      node)
        cat >> "$out_dir/.gitignore" <<'EOF'
node_modules/
npm-debug.log*
yarn-debug.log*
yarn-error.log*
pnpm-debug.log*
coverage/
dist/
EOF
        ;;
      rust)
        cat >> "$out_dir/.gitignore" <<'EOF'
/target/
EOF
        ;;
      shell)
        cat >> "$out_dir/.gitignore" <<'EOF'
*.log
EOF
        ;;
    esac
  }

  write_readme() {
    cat > "$out_dir/README.md" <<EOF
# $name

<!-- Define the project in one line, anchored to a tool or idea the reader already knows. -->
<!-- State one real constraint or default in sentence two, not a benefit. -->
<!-- Add only badges that can fail and answer a question a stranger has. -->

## Why does this exist?

<!-- Name the concrete problem that made the project worth building. -->

## Quickstart

<!-- Add a copy-pasteable install and the smallest tested working example. -->

## Usage

<!-- Show the common cases with commands that run and output that is real. -->

## Configuration

<!-- Document the defaults, then config file, environment, and flags resolution order. -->

## Why shouldn't I use this?

<!-- State a real limitation, tradeoff, or case where another tool is the better choice. -->

## Contributing

<!-- State the smallest useful contribution path, or remove this section until one exists. -->

## License

<!-- Name the chosen license and point to LICENSE. -->
EOF
  }

  write_mit_license() {
    cat > "$out_dir/LICENSE" <<EOF
MIT License

Copyright (c) $year $author_name

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
EOF
  }

  write_apache_license() {
    cat > "$out_dir/LICENSE" <<EOF
Copyright $year $author_name

                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright [yyyy] [name of copyright owner]

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
EOF
  }

  write_adr() {
    mkdir -p "$out_dir/docs/adr"
    cat > "$out_dir/docs/adr/0001-record-architecture-decisions.md" <<'EOF'
# Record architecture decisions

## Status

Accepted

## Context

Architecture choices need a durable record, but open work journals expose unfinished reasoning and private process.

## Decision

Record closed architecture decisions as ADRs using Status, Context, Decision, and Consequences. Keep plans, hand-offs, scratch notes, and deliberation outside the publishable repository.

## Consequences

Readers can recover why the architecture changed without inheriting the private process that led to the decision. Each later reversal needs a new ADR that supersedes the old one.
EOF
  }

  write_changes_log() {
    printf '%s\n' '# CHANGES.log · local hand-off journal · read the last entry before starting, append one when you finish.' > "$out_dir/CHANGES.log"
  }

  write_demo() {
    cat > "$out_dir/demo.tape" <<'EOF'
# This demo is source code, not a recording. Regenerate it after interface changes so it cannot show a stale UI.
Output demo.gif
Set Shell "bash"

# Add VHS Type, Enter, and Sleep commands after the first real command exists.
EOF
  }

  write_readme_runner() {
    mkdir -p "$out_dir/scripts"
    cat > "$out_dir/scripts/check-readme.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

repo_root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readme="${repo_root}/README.md"
commands_file="$(mktemp "${TMPDIR:-/tmp}/readme-commands.XXXXXX")"
trap 'rm -f "$commands_file"' EXIT

awk '
  /^```(bash|sh|shell)[[:space:]]*$/ { in_block = 1; next }
  /^```[[:space:]]*$/ && in_block { print ""; in_block = 0; next }
  in_block { print }
  END { if (in_block) exit 2 }
' "$readme" > "$commands_file"

if [ ! -s "$commands_file" ]; then
  printf 'README: no shell examples yet\n'
  exit 0
fi

(cd "$repo_root" && bash -euo pipefail "$commands_file")
printf 'README: shell examples passed\n'
EOF
    chmod +x "$out_dir/scripts/check-readme.sh"
  }

  write_shell_files() {
    mkdir -p "$out_dir/src"
    cat > "$out_dir/config.example.conf" <<EOF
# Copy to \${XDG_CONFIG_HOME:-\$HOME/.config}/$name/config and change only local values.
log_level=info
output_format=text
EOF

    cat > "$out_dir/src/config.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

readonly ${env_prefix}_CONFIG_PATH="\${XDG_CONFIG_HOME:-\$HOME/.config}/$name/config"

load_config() {
  local env_log_level="\${${env_prefix}_LOG_LEVEL:-}"
  local env_output_format="\${${env_prefix}_OUTPUT_FORMAT:-}"
  ${env_prefix}_LOG_LEVEL="info"
  ${env_prefix}_OUTPUT_FORMAT="text"

  if [ -f "\$${env_prefix}_CONFIG_PATH" ]; then
    while IFS='=' read -r key value; do
      case "\$key" in
        ''|'#'*) ;;
        log_level) ${env_prefix}_LOG_LEVEL="\$value" ;;
        output_format) ${env_prefix}_OUTPUT_FORMAT="\$value" ;;
        *) printf 'Unknown config key: %s\n' "\$key" >&2; return 2 ;;
      esac
    done < "\$${env_prefix}_CONFIG_PATH"
  fi

  [ -z "\$env_log_level" ] || ${env_prefix}_LOG_LEVEL="\$env_log_level"
  [ -z "\$env_output_format" ] || ${env_prefix}_OUTPUT_FORMAT="\$env_output_format"
}
EOF
    chmod +x "$out_dir/src/config.sh"
    write_readme_runner
  }

  write_python_files() {
    mkdir -p "$out_dir/src/$module_name"
    : > "$out_dir/src/$module_name/__init__.py"
    cat > "$out_dir/config.example.toml" <<EOF
# Copy to \${XDG_CONFIG_HOME:-\$HOME/.config}/$name/config and change only local values.
log_level = "info"
output_format = "text"
EOF

    cat > "$out_dir/src/$module_name/config.py" <<EOF
"""Resolve configuration as defaults, file, environment, then flags."""

from __future__ import annotations

import argparse
import os
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping, Sequence


@dataclass(frozen=True)
class Config:
    log_level: str
    output_format: str


DEFAULTS = {"log_level": "info", "output_format": "text"}


def load_config(
    argv: Sequence[str] | None = None,
    environ: Mapping[str, str] | None = None,
) -> Config:
    env = dict(os.environ if environ is None else environ)
    config = dict(DEFAULTS)
    config_home = Path(env.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    config_path = config_home / "$name" / "config"

    if config_path.exists():
        with config_path.open("rb") as handle:
            config.update(tomllib.load(handle))

    if value := env.get("${env_prefix}_LOG_LEVEL"):
        config["log_level"] = value
    if value := env.get("${env_prefix}_OUTPUT_FORMAT"):
        config["output_format"] = value

    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--log-level")
    parser.add_argument("--output-format")
    flags = vars(parser.parse_args(argv))
    config.update({key: value for key, value in flags.items() if value is not None})

    return Config(**config)
EOF
  }

  write_node_files() {
    mkdir -p "$out_dir/src"
    cat > "$out_dir/config.example.json" <<EOF
{
  "_copyTo": "\${XDG_CONFIG_HOME:-\$HOME/.config}/$name/config",
  "logLevel": "info",
  "outputFormat": "text"
}
EOF

    cat > "$out_dir/src/config.mjs" <<EOF
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

const defaults = Object.freeze({ logLevel: "info", outputFormat: "text" });

export async function loadConfig({ argv = process.argv.slice(2), env = process.env } = {}) {
  const configHome = env.XDG_CONFIG_HOME ?? join(env.HOME ?? homedir(), ".config");
  const configPath = join(configHome, "$name", "config");
  let fileValues = {};
  try {
    fileValues = JSON.parse(await readFile(configPath, "utf8"));
    delete fileValues._copyTo;
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }

  const values = { ...defaults, ...fileValues };
  if (env.${env_prefix}_LOG_LEVEL) values.logLevel = env.${env_prefix}_LOG_LEVEL;
  if (env.${env_prefix}_OUTPUT_FORMAT) values.outputFormat = env.${env_prefix}_OUTPUT_FORMAT;

  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (value === undefined) throw new Error(\`Missing value for \${flag}\`);
    if (flag === "--log-level") values.logLevel = value;
    else if (flag === "--output-format") values.outputFormat = value;
    else throw new Error(\`Unknown flag: \${flag}\`);
    index += 1;
  }
  return values;
}
EOF

    cat > "$out_dir/package.json" <<EOF
{
  "name": "$package_name",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "license": "$(if [ "$license_key" = "mit" ]; then printf 'MIT'; else printf 'Apache-2.0'; fi)",
  "scripts": {
    "test:readme": "bash scripts/check-readme.sh"
  }
}
EOF
    write_readme_runner
  }

  write_rust_files() {
    mkdir -p "$out_dir/src"
    cat > "$out_dir/config.example.toml" <<EOF
# Copy to \${XDG_CONFIG_HOME:-\$HOME/.config}/$name/config and change only local values.
log_level = "info"
output_format = "text"
EOF

    cat > "$out_dir/Cargo.toml" <<EOF
[package]
name = "$package_name"
version = "0.1.0"
edition = "2024"
license = "$(if [ "$license_key" = "mit" ]; then printf 'MIT'; else printf 'Apache-2.0'; fi)"
publish = false
EOF

    cat > "$out_dir/src/lib.rs" <<'EOF'
#![doc = include_str!("../README.md")]

pub mod config;
EOF

    cat > "$out_dir/src/config.rs" <<EOF
use std::env;
use std::error::Error;
use std::fs;
use std::path::PathBuf;

#[derive(Debug, PartialEq)]
pub struct Config {
    pub log_level: String,
    pub output_format: String,
}

impl Config {
    pub fn load() -> Result<Self, Box<dyn Error>> {
        let mut config = Self {
            log_level: "info".into(),
            output_format: "text".into(),
        };
        let config_home = env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(
                env::var_os("HOME").unwrap_or_else(|| ".".into())
            ).join(".config"));
        let config_path = config_home.join("$name").join("config");
        if config_path.exists() {
            config.apply_file(&fs::read_to_string(config_path)?)?;
        }
        if let Ok(value) = env::var("${env_prefix}_LOG_LEVEL") {
            config.log_level = value;
        }
        if let Ok(value) = env::var("${env_prefix}_OUTPUT_FORMAT") {
            config.output_format = value;
        }
        Ok(config)
    }

    fn apply_file(&mut self, contents: &str) -> Result<(), Box<dyn Error>> {
        for (index, raw_line) in contents.lines().enumerate() {
            let line = raw_line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let (key, raw_value) = line
                .split_once('=')
                .ok_or_else(|| format!("invalid config line {}", index + 1))?;
            let value = raw_value.trim().trim_matches('"').to_owned();
            match key.trim() {
                "log_level" => self.log_level = value,
                "output_format" => self.output_format = value,
                unknown => return Err(format!("unknown config key: {unknown}").into()),
            }
        }
        Ok(())
    }
}
EOF
  }

  write_checks() {
    local readme_step
    case "$lang" in
      python)
        readme_step="$(printf '%s\n' \
          '      - name: Run README examples' \
          '        run: |' \
          '          python -m pip install pytest' \
          "          pytest --doctest-glob='*.md' README.md")"
        ;;
      node)
        readme_step="$(printf '%s\n' \
          '      - name: Run README examples' \
          '        run: npm run test:readme')"
        ;;
      rust)
        readme_step="$(printf '%s\n' \
          '      - name: Run README examples' \
          '        run: cargo test --doc')"
        ;;
      shell)
        readme_step="$(printf '%s\n' \
          '      - name: Run README examples' \
          '        run: bash scripts/check-readme.sh')"
        ;;
    esac

    mkdir -p "$out_dir/.github/workflows"
    cat > "$out_dir/.github/workflows/checks.yml" <<EOF
name: Checks

on:
  push:
  pull_request:

permissions:
  contents: read

jobs:
  checks:
    runs-on: ubuntu-latest
    steps:
      - name: Check out full history
        uses: actions/checkout@v5
        with:
          fetch-depth: 0

      - name: Scan for secrets
        uses: gitleaks/gitleaks-action@v2
        env:
          GITHUB_TOKEN: \${{ secrets.GITHUB_TOKEN }}

      - name: Check links
        uses: lycheeverse/lychee-action@v2
        with:
          args: --no-progress './**/*.md'

$readme_step
EOF
  }

  write_gitignore
  write_readme
  if [ "$license_key" = "mit" ]; then
    write_mit_license
  else
    write_apache_license
  fi
  write_adr
  write_changes_log
  write_demo

  case "$lang" in
    shell) write_shell_files ;;
    python) write_python_files ;;
    node) write_node_files ;;
    rust) write_rust_files ;;
  esac

  write_checks

  mv "$staging" "$target"
  trap - EXIT

  printf 'Created %s project at %s\n' "$lang" "$target"
  printf '%s\n' "No Git repository was initialised; repository creation remains an explicit caller action."
  printf 'Configuration resolves as defaults -> config file -> environment -> flags.\n'
  # shellcheck disable=SC2016  # the literal ${XDG_CONFIG_HOME:-$HOME/.config} is printed for
  # the reader to copy; expanding it here would defeat the message.
  printf 'Local state belongs at ${XDG_CONFIG_HOME:-$HOME/.config}/%s/config.\n' "$name"
)
