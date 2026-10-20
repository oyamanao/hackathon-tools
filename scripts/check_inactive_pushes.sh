#!/usr/bin/env bash
#
# Push-activity auditor: identify repos in a GitHub org that had ZERO push
# events to ANY branch during a specified time window.
#
# Uses the GitHub Activity API (/activity?activity_type=push), which reflects
# actual git push timestamps across all branches — not just commits on the
# default branch.
#
# Usage:
#   ./check_inactive_pushes.sh ORG START END [-f OUTPUT_FILE] [--tz ZONE]
#
#   ORG        : GitHub organization or username whose repos to audit
#   START, END : the window in 24-hour time. Accepted formats:
#                  "HH:MM"             -> today, e.g.  17:00
#                  "YYYY-MM-DD HH:MM"  -> specific day, e.g. "2026-10-18 17:00"
#   -f FILE    : where to log inactive team/repo names
#                (default: inactive-teams_<start>_to_<end>.txt)
#   --tz ZONE  : timezone START/END are written in, e.g. Asia/Kolkata
#                (default: this machine's local timezone)
#
# Examples:
#   ./check_inactive_pushes.sh my-org 17:00 18:30
#   ./check_inactive_pushes.sh my-org "2026-10-18 17:00" "2026-10-18 18:30" --tz Asia/Kolkata
#   ./check_inactive_pushes.sh my-org 22:00 01:00 -f out.txt   # crosses midnight
#
# Requires: gh (authenticated), jq

set -uo pipefail

OUT=""; TZ_NAME=""
pos=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f)    OUT="${2:-}";     shift 2 ;;
    --tz)  TZ_NAME="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
    -*)    echo "Unknown option: $1" >&2; exit 1 ;;
    *)     pos+=("$1"); shift ;;
  esac
done

if [[ ${#pos[@]} -ne 3 ]]; then
  echo "Usage: $0 ORG START END [-f OUTPUT_FILE] [--tz ZONE]" >&2
  exit 1
fi
ORG="${pos[0]}"; START_IN="${pos[1]}"; END_IN="${pos[2]}"

command -v gh  >/dev/null || { echo "gh CLI not found" >&2; exit 1; }
command -v jq  >/dev/null || { echo "jq not found"    >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Run 'gh auth login' first" >&2; exit 1; }

# All date handling below happens in this timezone (if given)
[[ -n "$TZ_NAME" ]] && export TZ="$TZ_NAME"

# --- date helpers (GNU and BSD/macOS compatible) ------------------------------
IS_GNU=0
date --version >/dev/null 2>&1 && IS_GNU=1
TODAY="$(date +%Y-%m-%d)"

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

# If END was given as time-only and is not after START, assume next day
if [[ "$END_IN" =~ ^[0-9]{1,2}[:.][0-9]{2}$ && $END_E -le $START_E ]]; then
  END_E=$((END_E + 86400))
fi
if [[ $END_E -le $START_E ]]; then
  echo "END must be after START." >&2
  exit 1
fi

FROM="$(epoch_to_utc "$START_E")"
TO="$(epoch_to_utc "$END_E")"

if [[ -z "$OUT" ]]; then
  OUT="inactive-teams_$(echo "$START_NORM" | tr -c '0-9\n' '-' | sed 's/-*$//')_to_$(echo "$(epoch_to_local "$END_E" | cut -d' ' -f1-2)" | tr -c '0-9\n' '-' | sed 's/-*$//').txt"
fi

echo "Org:    $ORG"
echo "Window: $(epoch_to_local "$START_E")  ->  $(epoch_to_local "$END_E")"
echo "(UTC:   $FROM  ->  $TO)"
echo "------------------------------------------------"
printf "%-30s %8s  %s\n" "REPO" "PUSHES" "STATUS"

: > "$OUT"
total=0; idle=0

while read -r repo; do
  [[ -z "$repo" ]] && continue
  total=$((total + 1))

  n="$(gh api "repos/$ORG/$repo/activity?activity_type=push&per_page=100" \
      --jq "[.[] | select(.timestamp >= \"$FROM\" and .timestamp < \"$TO\")] | length" \
      2>/dev/null </dev/null)"

  if [[ "${n:-0}" -eq 0 ]]; then
    idle=$((idle + 1))
    printf "%-30s %8s  %s\n" "$repo" "0" "NO PUSH IN WINDOW"
    echo "$repo" >> "$OUT"
  else
    printf "%-30s %8s  %s\n" "$repo" "$n" "OK"
  fi
done < <(gh repo list "$ORG" --limit 500 --no-archived --json name --jq '.[].name' 2>/dev/null)

echo "------------------------------------------------"
echo "Total: $total | Active: $((total - idle)) | Inactive: $idle"

if [[ $idle -gt 0 ]]; then
  echo "Inactive teams logged to: $OUT"
  exit 2
else
  rm -f "$OUT"
  echo "All repos had at least one push in the window. No log file created."
fi
