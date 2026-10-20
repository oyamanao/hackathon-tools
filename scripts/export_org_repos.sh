#!/usr/bin/env bash
#
# List every repo in a GitHub org (or user account) and write them out as a
# teams.json-style file, ready to feed into check_commits_window.sh /
# check_inactive_pushes.sh.
#
# Usage:
#   ./export_org_repos.sh ORG [-f OUTPUT] [--prefix STR] [--exclude REGEX]
#                        [--include-archived] [--include-forks] [--members] [--force]
#
#   ORG                 : GitHub org (or user) whose repos to list
#                         (default: currently authenticated gh user)
#   -f OUTPUT           : output file (default: repos.json)
#   --prefix STR        : only repos whose name starts with STR (e.g. "team-")
#   --exclude REGEX     : skip repos whose name matches REGEX
#                         (e.g. "^(\.github|template.*)$")
#   --include-archived  : also include archived repos (default: skipped)
#   --include-forks     : also include forks (default: skipped)
#   --members           : also fetch each repo's direct collaborators and fill them in
#                         as the member list (slower: one API call per repo).
#                         Without it every team gets an empty list, which is all
#                         the commit checkers need.
#   --force             : overwrite OUTPUT if it already exists
#
# Output format (same shape as the teams.json used by setup_repos.sh):
#   { "team-a": [], "team-b": [], ... }
#
# Examples:
#   ./export_org_repos.sh my-org
#   ./export_org_repos.sh my-org --prefix team- -f teams.json
#   ./export_org_repos.sh my-org --exclude '^(\.github|starter-template)$' --members
#
# Then:
#   ./check_commits_window.sh repos.json 13:30 16:30 -o my-org
#
# Requires: gh (authenticated, with access to the org's repos), jq

set -uo pipefail

ORG=""; OUT="repos.json"; PREFIX=""; EXCLUDE=""
INC_ARCHIVED=0; INC_FORKS=0; MEMBERS=0; FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f)                 OUT="${2:-}";     shift 2 ;;
    --prefix)           PREFIX="${2:-}";  shift 2 ;;
    --exclude)          EXCLUDE="${2:-}"; shift 2 ;;
    --include-archived) INC_ARCHIVED=1;   shift ;;
    --include-forks)    INC_FORKS=1;      shift ;;
    --members)          MEMBERS=1;        shift ;;
    --force)            FORCE=1;          shift ;;
    -h|--help)          sed -n '2,36p' "$0"; exit 0 ;;
    -*)                 echo "Unknown option: $1" >&2; exit 1 ;;
    *)  if [[ -z "$ORG" ]]; then ORG="$1"; else echo "Unexpected argument: $1" >&2; exit 1; fi; shift ;;
  esac
done

# --- sanity checks -----------------------------------------------------------
command -v gh >/dev/null || { echo "gh CLI not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Run 'gh auth login' first" >&2; exit 1; }
[[ -z "$ORG" ]] && ORG="$(gh api user --jq .login)"

if [[ -e "$OUT" && $FORCE -ne 1 ]]; then
  echo "$OUT already exists. Use --force to overwrite, or pick another file with -f." >&2
  exit 1
fi

# --- fetch + filter repo names ----------------------------------------------
echo "Fetching repos for: $ORG ..."
raw="$(gh repo list "$ORG" --limit 10000 --json name,isArchived,isFork 2>&1)"
if [[ $? -ne 0 ]]; then
  echo "Failed to list repos for '$ORG':" >&2
  echo "$raw" >&2
  exit 1
fi

names=()
while IFS= read -r n; do
  [[ -n "$n" ]] && names+=("$n")
done < <(
  printf '%s' "$raw" | jq -r \
    --arg prefix "$PREFIX" --arg ex "$EXCLUDE" \
    --argjson arch "$INC_ARCHIVED" --argjson forks "$INC_FORKS" '
      .[]
      | select($arch == 1 or (.isArchived | not))
      | select($forks == 1 or (.isFork | not))
      | select(.name | startswith($prefix))
      | select($ex == "" or ((.name | test($ex)) | not))
      | .name' | sort
)

if [[ ${#names[@]} -eq 0 ]]; then
  echo "No repos matched (after filters). Nothing written." >&2
  exit 1
fi

# --- build the JSON ------------------------------------------------------------
if [[ $MEMBERS -eq 0 ]]; then
  jq -n '$ARGS.positional | map({(.): []}) | add' --args "${names[@]}" > "$OUT"
else
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  i=0
  for name in "${names[@]}"; do
    i=$((i + 1))
    printf '\r  collaborators: %d/%d' "$i" "${#names[@]}" >&2
    if logins="$(gh api --paginate \
          "repos/$ORG/$name/collaborators?affiliation=direct&per_page=100" \
          --jq '.[].login' </dev/null 2>/dev/null)"; then
      :
    else
      printf '\n  !! could not read collaborators for %s (leaving empty)\n' "$name" >&2
      logins=""
    fi
    m="$(printf '%s\n' "$logins" | jq -R 'select(length > 0)' | jq -s .)"
    jq -n --arg n "$name" --argjson m "$m" '{($n): $m}' >> "$tmp"
  done
  printf '\n' >&2
  jq -s 'add' "$tmp" > "$OUT"
fi

echo "Found ${#names[@]} repos -> wrote $OUT"
printf '  %s\n' "${names[@]}" | head -10
[[ ${#names[@]} -gt 10 ]] && echo "  ... and $(( ${#names[@]} - 10 )) more"
