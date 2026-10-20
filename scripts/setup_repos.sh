#!/usr/bin/env bash
#
# Creates a private repo per team in a GitHub org (if missing) and invites
# every listed user as a collaborator at a given permission level.
#
# CSV format (no header). Any of these work, and you can mix them:
#   team,user1,user2,user3        <- many users on one line
#   team,user1;user2;user3        <- semicolons also work
#   team,user1                    <- repeat the team on more lines to add more users
#
# Usage:
#   ./setup_repos.sh [-o ORG] [-f CSV_FILE] [-p PERMISSION]
#
#   -o ORG        : GitHub organization to create repos in
#                   (default: currently authenticated gh user)
#   -f CSV_FILE   : path to the collaborators CSV file (default: collaborators.csv)
#   -p PERMISSION : collaborator permission level: read, triage, write, maintain, admin
#                   (default: maintain)
#
# Environment overrides:
#   CREATE_IF_MISSING=0   skip repo creation, only send invites
#
# Examples:
#   ./setup_repos.sh -o my-org
#   ./setup_repos.sh -o my-org -f teams.csv -p write
#   CREATE_IF_MISSING=0 ./setup_repos.sh -o my-org
#
# Requires: gh (authenticated)

set -uo pipefail

ORG=""; CSV_FILE="collaborators.csv"; PERMISSION="maintain"
CREATE_IF_MISSING="${CREATE_IF_MISSING:-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)    ORG="${2:-}";         shift 2 ;;
    -f)    CSV_FILE="${2:-}";    shift 2 ;;
    -p)    PERMISSION="${2:-}";  shift 2 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    -*)    echo "Unknown option: $1" >&2; exit 1 ;;
    *)     echo "Unexpected argument: $1" >&2; exit 1 ;;
  esac
done

command -v gh >/dev/null || { echo "gh CLI not found" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Run 'gh auth login' first" >&2; exit 1; }

[[ -z "$ORG" ]] && ORG="$(gh api user --jq .login)"
[[ -f "$CSV_FILE" ]] || { echo "CSV file not found: $CSV_FILE" >&2; exit 1; }

trim() { sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

echo "Org:        $ORG"
echo "CSV:        $CSV_FILE"
echo "Permission: $PERMISSION"
echo "Create if missing: $CREATE_IF_MISSING"
echo "----------------------------------------"

# ; -> , so both separators work; tr strips \r
tr -d '\r' < "$CSV_FILE" | tr ';' ',' | while IFS= read -r line || [[ -n "$line" ]]; do
    IFS=',' read -ra cols <<< "$line"

    team=$(echo "${cols[0]}" | tr -d '"' | trim)
    [[ -z "$team" ]] && continue

    repo=$(echo "$team" | sed 's/[^A-Za-z0-9._-]/-/g')
    echo "[$team] -> $ORG/$repo"

    if ! gh repo view "$ORG/$repo" --json name </dev/null >/dev/null 2>&1; then
        if [[ "$CREATE_IF_MISSING" = "1" ]]; then
            echo "  repo missing, creating..."
            gh repo create "$ORG/$repo" --private --add-readme </dev/null || { echo "  FAILED to create repo"; continue; }
        else
            echo "  SKIP: repo not found"; continue
        fi
    fi

    for col in "${cols[@]:1}"; do
        username=$(echo "$col" | tr -d '"@' | trim)
        [[ -z "$username" ]] && continue

        echo "  Adding @$username ($PERMISSION)..."
        # Only step with no native gh subcommand
        if output=$(gh api -X PUT "repos/$ORG/$repo/collaborators/$username" \
            -f permission="$PERMISSION" 2>&1 </dev/null); then
            echo "    OK"
        else
            echo "    FAILED: $output"
        fi
        sleep 1
    done
    echo "----------------------------------------"
done
