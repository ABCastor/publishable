#!/usr/bin/env bash

publishable_render_human() {
  local report_path="$1"
  local check_rc="$2"
  local use_color="${3:-0}"
  local red="" yellow="" green="" reset=""

  if [ "$use_color" -eq 1 ]; then
    red=$'\033[31m'
    yellow=$'\033[33m'
    green=$'\033[32m'
    reset=$'\033[0m'
  fi

  awk \
    -v check_rc="$check_rc" \
    -v red="$red" \
    -v yellow="$yellow" \
    -v green="$green" \
    -v reset="$reset" '
    BEGIN {
      FS = "|"
    }

    function field(name,    i, prefix) {
      prefix = name "="
      for (i = 2; i <= NF; i++) {
        if (index($i, prefix) == 1) {
          return substr($i, length(prefix) + 1)
        }
      }
      return ""
    }

    function category(scope) {
      if (index(scope, "history") == 1) {
        return 2
      }
      if (scope == "tree" || scope == "ignore") {
        return 1
      }
      return 3
    }

    function section_name(name) {
      gsub(/_/, " ", name)
      return name
    }

    function category_heading(category_id, label, guidance, colour,    count) {
      count = category_count[category_id] + 0
      printf "%s%s: %d blocking%s\n", colour, label, count, reset
      print guidance
      if (count == 0) {
        print "  None."
        print ""
      }
    }

    function render_category(category_id, label, guidance, colour,    count, section_count, file_count, i, j, k, section_key, file_key, action_key, section, file_name, hidden, has_visible, section_action, same_action) {
      count = category_count[category_id] + 0
      category_heading(category_id, label, guidance, colour)
      if (count == 0) {
        return
      }

      section_count = 0
      for (i = 1; i <= blocking_count; i++) {
        if (finding_category[i] != category_id || section_rank[i] > 10) {
          continue
        }
        section_key = category_id SUBSEP finding_section[i]
        if (!(section_key in seen_section)) {
          seen_section[section_key] = 1
          category_sections[++section_count] = finding_section[i]
        }
      }

      has_visible = 0
      for (j = 1; j <= section_count; j++) {
        section = category_sections[j]
        has_visible = 1
        printf "  %s\n", section_name(section)

        section_action = ""
        same_action = 1
        for (i = 1; i <= blocking_count; i++) {
          if (finding_category[i] != category_id || finding_section[i] != section) {
            continue
          }
          if (finding_action[i] == "") {
            same_action = 0
          } else if (section_action == "") {
            section_action = finding_action[i]
          } else if (finding_action[i] != section_action) {
            same_action = 0
          }
        }

        file_count = 0
        for (i = 1; i <= blocking_count; i++) {
          if (finding_category[i] != category_id || finding_section[i] != section || section_rank[i] > 10) {
            continue
          }
          file_key = category_id SUBSEP section SUBSEP finding_file[i]
          if (!(file_key in seen_file)) {
            seen_file[file_key] = 1
            section_files[++file_count] = finding_file[i]
          }
        }

        for (k = 1; k <= file_count; k++) {
          file_name = section_files[k]
          printf "    %s\n", file_name

          for (i = 1; i <= blocking_count; i++) {
            if (finding_category[i] == category_id && finding_section[i] == section && finding_file[i] == file_name && section_rank[i] <= 10) {
              printf "      line %s  [%s]\n", finding_line[i], finding_rule[i]
            }
          }

          if (!same_action) {
            for (i = 1; i <= blocking_count; i++) {
              if (finding_category[i] != category_id || finding_section[i] != section || finding_file[i] != file_name || section_rank[i] > 10 || finding_action[i] == "") {
                continue
              }
              action_key = category_id SUBSEP section SUBSEP file_name SUBSEP finding_action[i]
              if (!(action_key in seen_action)) {
                seen_action[action_key] = 1
                printf "      Fix: %s\n", finding_action[i]
              }
            }
          }
        }

        if (same_action && section_action != "") {
          printf "    Fix: %s\n", section_action
        }

        hidden = section_total[section] - 10
        if (hidden > 0 && !(section in announced_truncation)) {
          announced_truncation[section] = 1
          printf "    ... %d more finding%s in this section. Re-run with --format machine to see all.\n", hidden, (hidden == 1 ? "" : "s")
        }
      }

      if (!has_visible) {
        print "  Details are hidden by the 10-finding section limit above. Re-run with --format machine to see all."
      }
      print ""
    }

    $1 == "BLOCKING" {
      blocking_count++
      finding_section[blocking_count] = field("section")
      finding_scope[blocking_count] = field("scope")
      finding_file[blocking_count] = field("file")
      finding_line[blocking_count] = field("line")
      finding_rule[blocking_count] = field("rule")
      finding_category[blocking_count] = category(finding_scope[blocking_count])
      section_total[finding_section[blocking_count]]++
      section_rank[blocking_count] = section_total[finding_section[blocking_count]]
      category_count[finding_category[blocking_count]]++
      next
    }

    $1 == "REMEDIATION" {
      remediation_section = field("section")
      remediation_file = field("file")
      remediation_action = field("action")
      for (i = blocking_count; i >= 1; i--) {
        if (finding_section[i] == remediation_section && finding_file[i] == remediation_file && finding_action[i] == "") {
          finding_action[i] = remediation_action
          break
        }
      }
      next
    }

    $1 == "WARNING" {
      warning_count++
      warning_section[warning_count] = field("section")
      warning_text[warning_count] = field("finding")
      warning_fix[warning_count] = field("command")
      next
    }

    END {
      print "PUBLISHABLE CHECK"
      print ""

      render_category(1, "WORKING TREE", "Edit or untrack these files, then run the check again.", (category_count[1] ? red : green))
      render_category(2, "HISTORY", "Editing current files will not remove these findings. Publish from an audited clean export.", (category_count[2] ? red : green))

      if (category_count[3] > 0) {
        render_category(3, "AUDIT SETUP", "Fix these prerequisites before trusting the audit.", red)
      }

      if (warning_count > 0) {
        printf "%sWARNINGS: %d%s\n", yellow, warning_count, reset
        warning_section_count = 0
        for (i = 1; i <= warning_count; i++) {
          if (!(warning_section[i] in seen_warning_section)) {
            seen_warning_section[warning_section[i]] = 1
            warning_sections[++warning_section_count] = warning_section[i]
          }
        }
        for (j = 1; j <= warning_section_count; j++) {
          section = warning_sections[j]
          printf "  %s\n", section_name(section)
          for (i = 1; i <= warning_count; i++) {
            if (warning_section[i] == section) {
              printf "    %s\n", warning_text[i]
              if (warning_fix[i] != "") {
                printf "      Fix: %s\n", warning_fix[i]
              }
            }
          }
        }
        print ""
      }

      printf "SUMMARY: %d blocking (%d tree, %d history, %d setup), %d warning%s\n", \
        blocking_count, category_count[1] + 0, category_count[2] + 0, category_count[3] + 0, \
        warning_count, (warning_count == 1 ? "" : "s")

      if (check_rc == 0) {
        printf "%sVERDICT: READY TO PUBLISH%s\n", green, reset
      } else if (check_rc == 1) {
        printf "%sVERDICT: DO NOT PUBLISH%s\n", red, reset
      } else {
        printf "%sVERDICT: CHECK FAILED, DO NOT PUBLISH%s\n", red, reset
      }
    }
  ' "$report_path"
}
