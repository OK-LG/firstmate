#!/usr/bin/env bash
# Acknowledge a handled PR-ready handoff through the current status endpoint.
# Usage: fm-pr-ready-ack.sh <task-id> <PR-url> <review-started|merge-started|held>
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
  echo 'Usage: fm-pr-ready-ack.sh <task-id> <PR-url> <review-started|merge-started|held>'
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ "$#" -eq 3 ] || { usage >&2; exit 2; }
ID=$1 URL=$2 REASON=$3
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$URL"; then usage >&2; exit 2; fi
case "$REASON" in review-started|merge-started|held) ;; *) usage >&2; exit 2 ;; esac
[ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo 'error: state directory unavailable' >&2; exit 1; }
[ -f "$STATE/$ID.meta" ] && [ ! -L "$STATE/$ID.meta" ] || { echo 'error: task metadata unavailable' >&2; exit 1; }
case "$(sed -n 's/^kind=//p' "$STATE/$ID.meta" | tail -1)" in ''|ship) ;; *) echo 'error: task is not a ship' >&2; exit 1 ;; esac
IDENT='' END=0
SNAPSHOT=$(status_presentation_snapshot "$STATE") || exit 1
while IFS=$'\t' read -r task endpoint identity; do
  [ "$task" = "$ID" ] || continue
  IDENT=$identity END=$endpoint
done <<< "$SNAPSHOT"
[ -n "$IDENT" ] && [ "$END" -gt 0 ] || { echo 'error: task has no readable status' >&2; exit 1; }
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
