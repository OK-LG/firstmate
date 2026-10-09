#!/usr/bin/env bash
# Acknowledge a handled PR-ready handoff through its captured report endpoint.
# Usage: fm-pr-ready-ack.sh <task-id> <PR-url> <review-started|merge-started|held> <report-token>
# Call after actually dispatching an authorized review, starting landing, or
# deliberately holding the PR (for example, awaiting requested merge approval).
# This does not authorize a review, merge, or hold, and makes no forge call.
# The atomic private <task>.pr-ready-ack record contains five lines: status file
# identity, captured byte endpoint, canonical PR URL, handling reason, version.
# The watcher accepts it only for that URL and ready events through that exact
# identity/endpoint. Later ready reports cannot inherit an old acknowledgement.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-classify-lib.sh"

usage() {
  cat <<'HELP'
Usage: fm-pr-ready-ack.sh --capture <task-id> <PR-url>
       fm-pr-ready-ack.sh <task-id> <PR-url> <review-started|merge-started|held> <report-token>
Capture the ready report before starting its authorized handling. Capture prints
its identity|endpoint token to stdout and the report to stderr. Retain that token
across interruptions and pass it, quoted as one argument, after handling starts.
An overdue alarm already supplies the captured token in its acknowledgement
command. Never recapture after handling to acknowledge an earlier report.
HELP
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
CAPTURE=0
if [ "${1:-}" = --capture ]; then
  [ "$#" -eq 3 ] || { usage >&2; exit 2; }
  CAPTURE=1 ID=$2 URL=$3 REASON=''
else
  [ "$#" -eq 4 ] || { usage >&2; exit 2; }
  ID=$1 URL=$2 REASON=$3
  IDENT=${4%|*} END=${4##*|}
  case "$END" in ''|0*|*[!0-9]*) usage >&2; exit 2 ;; esac
  [ "${#END}" -le 12 ] && [ -n "$IDENT" ] || { usage >&2; exit 2; }
  case "$REASON" in review-started|merge-started|held) ;; *) usage >&2; exit 2 ;; esac
fi
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$URL"; then usage >&2; exit 2; fi
[ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo 'error: state directory unavailable' >&2; exit 1; }
[ -f "$STATE/$ID.meta" ] && [ ! -L "$STATE/$ID.meta" ] || { echo 'error: task metadata unavailable' >&2; exit 1; }
case "$(sed -n 's/^kind=//p' "$STATE/$ID.meta" | tail -1)" in ''|ship) ;; *) echo 'error: task is not a ship' >&2; exit 1 ;; esac
# shellcheck source=bin/fm-pr-ready-lib.sh
. "$SCRIPT_DIR/fm-pr-ready-lib.sh"
STATUS="$STATE/$ID.status"
[ -f "$STATUS" ] && [ ! -L "$STATUS" ] || { echo 'error: task has no readable status' >&2; exit 1; }
CURRENT_IDENT=$(_fm_open_decisions_file_ident "$STATUS") || exit 1
SIZE=$(_fm_status_file_size "$STATUS") || exit 1
if [ "$CAPTURE" -eq 1 ]; then
  IDENT=$CURRENT_IDENT END=$SIZE
fi
[ "$IDENT" = "$CURRENT_IDENT" ] && [ "$END" -le "$SIZE" ] || {
  echo 'error: captured report no longer belongs to this status log' >&2; exit 1;
}
OFFSET=0 READY_END=0 READY_URL='' READY_LINE=''
export LC_ALL=C
while IFS= read -r line; do
  OFFSET=$((OFFSET + ${#line} + 1))
  fm_pr_ready_line_url "$line" || continue
  READY_END=$OFFSET READY_URL=$FM_PR_URL READY_LINE=$line
done < <(_fm_status_read_span "$STATUS" 0 "$END")
[ "$(_fm_open_decisions_file_ident "$STATUS")" = "$IDENT" ] \
  && [ "$(_fm_status_file_size "$STATUS")" -ge "$END" ] \
  && [ "$READY_URL" = "$URL" ] && [ "$READY_END" -gt 0 ] || {
  echo 'error: captured report is unavailable or names another PR' >&2; exit 1;
}
if [ "$CAPTURE" -eq 1 ]; then
  printf '%s\n' "$READY_LINE" >&2
  printf '%s|%s\n' "$IDENT" "$READY_END"
  exit 0
fi
[ "$READY_END" -eq "$END" ] || { echo 'error: endpoint is not a complete ready report' >&2; exit 1; }
DEVICE=$(fm_pr_file_device "$STATE") || exit 1
DEST="$STATE/$ID.pr-ready-ack"
fm_pr_regular_destination_on_device_or_absent "$DEST" "$DEVICE" || exit 1
TMP=$(mktemp "$STATE/.pr-ready-ack.XXXXXX") || exit 1
trap 'rm -f -- "$TMP"' EXIT
printf '%s\n' "$IDENT" "$END" "$URL" "$REASON" fm-pr-ready-ack-v1 > "$TMP" || exit 1
chmod 600 "$TMP" || exit 1
fm_pr_regular_destination_on_device_or_absent "$DEST" "$DEVICE" || exit 1
mv -f -- "$TMP" "$DEST" || exit 1
printf 'acknowledged: task=%s PR=%s reason=%s\n' "$ID" "$URL" "$REASON"
