#!/usr/bin/env bash
#
# Checkpoint checker: verify each team's repo has at least ONE commit
# inside a given time window. Teams with no commit in the window (or whose
# repo is missing) are logged to a text file.
#
# Usage:
#   ./check_commits_window.sh teams.json START END [-o OWNER] [-f OUTPUT_FILE] [--tz ZONE]
#
#   teams.json : same file used by setup_repos.sh
#   START, END : the window, in 24-hour time. Accepted formats:
#                  "HH:MM"             -> today, e.g.  13:30   (13.30 also works)
#                  "YYYY-MM-DD HH:MM"  -> specific day, e.g. "2026-10-18 13:30"
#   -o OWNER   : GitHub user/org that owns the repos
#                (default: currently authenticated gh user)
#   -f FILE    : where to log failing team names
#                (default: teams_no_commit_<start>_<end>.txt)
#   --tz ZONE  : timezone START/END are written in, e.g. Asia/Kolkata
#                (default: this machine's local timezone)
#
# Examples:
#   ./check_commits_window.sh teams.json 13:30 16:30
#   ./check_commits_window.sh teams.json "2026-10-18 13:30" "2026-10-18 16:30"
#   ./check_commits_window.sh teams.json 22:00 01:00 --tz Asia/Kolkata   # crosses midnight
#
# Requires: gh (authenticated), jq
# Note: checks the default branch of each repo.

set -uo pipefail

OWNER=""; OUT=""; TZ_NAME=""
pos=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)    OWNER="${2:-}";   shift 2 ;;
    -f)    OUT="${2:-}";     shift 2 ;;
    --tz)  TZ_NAME="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
    -*)    echo "Unknown option: $1" >&2; exit 1 ;;
    *)     pos+=("$1"); shift ;;
  esac
done

if [[ ${#pos[@]} -ne 3 ]]; then
  echo "Usage: $0 teams.json START END [-o OWNER] [-f OUTPUT_FILE] [--tz ZONE]" >&2
  exit 1
fi
JSON_FILE="${pos[0]}"; START_IN="${pos[1]}"; END_IN="${pos[2]}"

[[ -f "$JSON_FILE" ]] || { echo "File not found: $JSON_FILE" >&2; exit 1; }
command -v gh >/dev/null || { echo "gh CLI not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Run 'gh auth login' first" >&2; exit 1; }

# All date handling below happens in this timezone (if given)
[[ -n "$TZ_NAME" ]] && export TZ="$TZ_NAME"

# --- date helpers (GNU and BSD/macOS compatible) ------------------------------
IS_GNU=0
date --version >/dev/null 2>&1 && IS_GNU=1
TODAY="$(date +%Y-%m-%d)"

# Normalise input to "YYYY-MM-DD HH:MM"; returns 1 if the format is invalid
normalize() {
  local in="${1//./:}"
  if [[ "$in" =~ ^[0-9]{1,2}:[0-9]{2}$ ]]; then
    printf '%s %02d:%s' "$TODAY" "$((10#${in%%:*}))" "${in##*:}"
  elif [[ "$in" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{1,2}:[0-9]{2}$ ]]; then
    local d="${in%%[[:space:]]*}" t="${in##*[[:space:]]}"
    printf '%s %02d:%s' "$d" "$((10#${t%%:*}))" "${t##*:}"
  else
    return 1
  fi
}

to_epoch() {
  if [[ $IS_GNU -eq 1 ]]; then
    date -d "$1:00" +%s 2>/dev/null
  else
    date -j -f "%Y-%m-%d %H:%M:%S" "$1:00" +%s 2>/dev/null
  fi
}

epoch_to_utc() {
  if [[ $IS_GNU -eq 1 ]]; then
    date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
  else
    date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
  fi
}

epoch_to_local() {
  if [[ $IS_GNU -eq 1 ]]; then
    date -d "@$1" "+%Y-%m-%d %H:%M %Z"
  else
    date -r "$1" "+%Y-%m-%d %H:%M %Z"
  fi
}

START_NORM="$(normalize "$START_IN")" || { echo "Bad START '$START_IN'. Use HH:MM or \"YYYY-MM-DD HH:MM\" (24-hour)." >&2; exit 1; }
END_NORM="$(normalize "$END_IN")"     || { echo "Bad END '$END_IN'. Use HH:MM or \"YYYY-MM-DD HH:MM\" (24-hour)." >&2; exit 1; }

START_E="$(to_epoch "$START_NORM")" || true
END_E="$(to_epoch "$END_NORM")"     || true
if [[ -z "$START_E" || -z "$END_E" ]]; then
  echo "Could not parse the times (check the date/time values and --tz)." >&2
  exit 1
fi

# If END was given as time-only and is not after START, assume it's the next day
if [[ "$END_IN" =~ ^[0-9]{1,2}[:.][0-9]{2}$ && $END_E -le $START_E ]]; then
  END_E=$((END_E + 86400))
fi
if [[ $END_E -le $START_E ]]; then
  echo "END must be after START." >&2
  exit 1
fi

SINCE="$(epoch_to_utc "$START_E")"
UNTIL="$(epoch_to_utc "$END_E")"

[[ -z "$OWNER" ]] && OWNER="$(gh api user --jq .login)"
if [[ -z "$OUT" ]]; then
  OUT="teams_no_commit_$(echo "$START_NORM" | tr -c '0-9\n' '-' | sed 's/-*$//')_to_$(echo "$(epoch_to_local "$END_E" | cut -d' ' -f1-2)" | tr -c '0-9\n' '-' | sed 's/-*$//').txt"
fi

echo "Owner:  $OWNER"
echo "Window: $(epoch_to_local "$START_E")  ->  $(epoch_to_local "$END_E")"
echo "(UTC:   $SINCE  ->  $UNTIL)"
echo "------------------------------------------------"
printf "%-30s %8s  %s\n" "TEAM" "COMMITS" "STATUS"

: > "$OUT"
total=0; passed=0; failed=0

# --- main loop ---------------------------------------------------------------
while read -r team; do
  [[ -z "$team" ]] && continue
  total=$((total + 1))

  resp="$(gh api "repos/$OWNER/$team/commits?since=$SINCE&until=$UNTIL&per_page=100" \
            --jq 'length' </dev/null 2>&1)"
  rc=$?

  if [[ $rc -eq 0 && "$resp" =~ ^[0-9]+$ ]]; then
    count="$resp"
  elif [[ "$resp" == *"empty"* || "$resp" == *"409"* ]]; then
    count=0   # repo exists but has no commits at all
  else
    printf "%-30s %8s  %s\n" "$team" "-" "MISSING/ERROR"
    echo "$team" >> "$OUT"
    failed=$((failed + 1))
    continue
  fi

  shown="$count"; [[ $count -ge 100 ]] && shown="100+"

  if [[ $count -ge 1 ]]; then
    printf "%-30s %8s  %s\n" "$team" "$shown" "OK"
    passed=$((passed + 1))
  else
    printf "%-30s %8s  %s\n" "$team" "0" "NO COMMIT IN WINDOW"
    echo "$team" >> "$OUT"
    failed=$((failed + 1))
  fi
done < <(jq -r 'keys_unsorted[]' "$JSON_FILE")

# --- summary -----------------------------------------------------------------
echo "------------------------------------------------"
echo "Total: $total | Passed: $passed | Failed: $failed"

if [[ $failed -gt 0 ]]; then
  echo "Failing teams logged to: $OUT"
  exit 2
else
  rm -f "$OUT"
  echo "Every team has at least one commit in the window. No log file created."
fi
