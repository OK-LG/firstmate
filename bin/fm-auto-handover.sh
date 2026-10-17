#!/usr/bin/env bash
# Opt-in automatic PR handover for GitHub pull requests of this home's ships:
# start the configured review once a ready PR's checks are green, merge on a
# passing review receipt through bin/fm-pr-merge.sh, and steer the workers whose
# open PRs a merge left conflicting.
#
# Usage:
#   fm-auto-handover.sh tick
#   fm-auto-handover.sh conflicts <merged-task-id> <merged-PR-url> <project>
#
# Configuration is the local, gitignored config/auto-handover, one directive
# per line; blank lines and lines starting with # are ignored:
#   review <project> <command>     start <command> for each new ready PR
#   merge <project>                merge on a passing receipt
#   conflict-steer <project>       steer conflicting PRs after a merge
#   receipt-author <login>         trust receipts by <login> (repeatable)
# <project> is the registry name, the basename of the task's project= path.
# Without the file every subcommand exits at once and changes nothing.
# An invalid file changes nothing and queues one check wake per distinct content.
#
# tick (bin/fm-watch.sh runs it detached, on its own cadence):
# - A ship's latest done:/ready: report (bin/fm-pr-ready-lib.sh owns that
#   parse) names a PR. Review starts only while that handoff is unacknowledged,
#   the PR is open and not a draft, no check is still running, and
#   bin/fm-pr-lib.sh's fm_pr_github_checks_not_green finds nothing red.
#   <command> runs under `bash -c` in $FM_HOME with $1 task id, $2 PR URL,
#   $3 PR number, $4 head commit, bounded by FM_AUTO_REVIEW_TIMEOUT_SECS
#   (default 900); output goes to state/<task>.auto-review.log. Success
#   acknowledges the handoff as review-started through bin/fm-pr-ready-ack.sh.
#   One review starts per PR head. A failed start retries after
#   FM_AUTO_HANDOVER_RETRY_SECS (default 300); the third failure queues a wake.
# - Merge needs yolo=on in the task record AND in the project's registered
#   posture (bin/fm-project-mode.sh), so this never widens merge authority.
#   The receipt is the newest PR comment by a trusted author whose first line
#   is `GATE: pass @ <head>` or `GATE: fail @ <head>`; only a pass naming the
#   live head counts. The default trusted author is gh's authenticated login.
#   With a passing receipt and settled checks, a PR labelled do-not-merge,
#   needs-captain, security, or destructive queues a wake for the captain's
#   call instead; red checks queue a wake too. Otherwise bin/fm-pr-merge.sh runs
#   with --automatic and --expected-head for the reviewed commit, so its
#   green, required-check, captain-hold, and away-authority refusals all apply,
#   and it publishes the merge outcome itself. A refusal retries on the retry
#   cadence; the third refusal for one head queues a wake.
#
# conflicts (bin/fm-merge-outcome-lib.sh dispatches after a confirmed merge):
#   For the merged PR's project with conflict-steer, every other ship's PR in
#   the same repository and default branch that GitHub reports CONFLICTING gets
#   one fm-send.sh steer per PR head asking its worker to merge the base branch
#   in and push, which restarts its checks. Nothing here rewrites a branch.
#   GitHub recomputes mergeability lazily, so UNKNOWN is re-read up to
#   FM_CONFLICT_STEER_ATTEMPTS times (default 6), FM_CONFLICT_STEER_WAIT_SECS
#   apart (default 20). A failed steer queues a wake.
#
# Every wake is a durable `check` row plus a line in state/.auto-handover-wake,
# which the watcher announces. Per-task records are state/<task>.auto-review,
# .auto-merge, .auto-merge-notice, .auto-merge-away, and .conflict-steer; state/auto-handover.log is the audit trail.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONF="$CONFIG/auto-handover"
PR_MERGE="${FM_AUTO_HANDOVER_MERGE_BIN:-$SCRIPT_DIR/fm-pr-merge.sh}"
SEND="${FM_AUTO_HANDOVER_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}"

usage() {
  sed -n '7,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,3\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  tick) [ "$#" -eq 1 ] || { usage >&2; exit 2; } ;;
  conflicts) [ "$#" -eq 4 ] || { usage >&2; exit 2; } ;;
  *) usage >&2; exit 2 ;;
esac
[ -f "$CONF" ] || exit 0
[ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 0

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-pr-ready-lib.sh
. "$SCRIPT_DIR/fm-pr-ready-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

whole() {  # <value>
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 6 ]
}

setting() {  # <variable> <environment-name> <default>
  local v=${!2:-$3}
  if ! whole "$v" || [ "$((10#$v))" -lt 1 ]; then
    echo "error: $2 must be a positive whole number" >&2
    exit 1
  fi
  printf -v "$1" '%s' "$((10#$v))"
}
setting RETRY FM_AUTO_HANDOVER_RETRY_SECS 300
setting REVIEW_TIMEOUT FM_AUTO_REVIEW_TIMEOUT_SECS 900
setting STEER_ATTEMPTS FM_CONFLICT_STEER_ATTEMPTS 6
setting STEER_WAIT FM_CONFLICT_STEER_WAIT_SECS 20
NOW=$(date +%s)

log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$STATE/auto-handover.log" 2>/dev/null || true
}

# Durable row first, then the announcement line the watcher turns into a wake.
notify() {  # <key> <reason>
  fm_wake_append check "auto-handover-$1" "check: auto-handover: $2" || return 1
  printf '%s\n' "$2" >> "$STATE/.auto-handover-wake" || return 1
  log "wake: $2"
}

# --- configuration ----------------------------------------------------------

# Parallel lists rather than associative arrays, for macOS's Bash 3.2.
REVIEW_PROJECTS=() REVIEW_CMDS=() MERGE_PROJECTS=() STEER_PROJECTS=() AUTHORS=()

listed() {  # <project> <list-items...>
  local want=$1 item
  shift
  for item in "$@"; do [ "$item" != "$want" ] || return 0; done
  return 1
}

review_cmd() {  # <project>
  local i
  for ((i = 0; i < ${#REVIEW_PROJECTS[@]}; i++)); do
    [ "${REVIEW_PROJECTS[$i]}" != "$1" ] || { REVIEW_CMD=${REVIEW_CMDS[$i]}; return 0; }
  done
  return 1
}

merge_on() { listed "$1" "${MERGE_PROJECTS[@]+"${MERGE_PROJECTS[@]}"}"; }
steer_on() { listed "$1" "${STEER_PROJECTS[@]+"${STEER_PROJECTS[@]}"}"; }

parse_config() {
  local line verb project rest n=0 sum
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line#"${line%%[![:space:]]*}"}
    case "$line" in ''|'#'*) continue ;; esac
    read -r verb project rest <<< "$line"
    case "$verb" in
      review)
        [ -n "$project" ] && [ -n "$rest" ] || { CONF_ERROR="line $n: review needs <project> <command>"; break; }
        REVIEW_PROJECTS+=("$project"); REVIEW_CMDS+=("$rest") ;;
      merge|conflict-steer|receipt-author)
        [ -n "$project" ] && [ -z "$rest" ] || { CONF_ERROR="line $n: $verb takes exactly one value"; break; }
        case "$verb" in
          merge) MERGE_PROJECTS+=("$project") ;;
          conflict-steer) STEER_PROJECTS+=("$project") ;;
          receipt-author) AUTHORS+=("$project") ;;
        esac ;;
      *) CONF_ERROR="line $n: unknown directive '$verb'"; break ;;
    esac
  done < "$CONF"
  [ -n "${CONF_ERROR:-}" ] || { rm -f "$STATE/.auto-handover-config-error"; return 0; }
  sum=$(git hash-object "$CONF" 2>/dev/null || echo unknown)
  if [ "$(cat "$STATE/.auto-handover-config-error" 2>/dev/null)" != "$sum" ]; then
    printf '%s\n' "$sum" > "$STATE/.auto-handover-config-error"
    notify config "config/auto-handover is invalid ($CONF_ERROR); automatic review, merge, and conflict steers are off until it is fixed"
  fi
  return 1
}

# --- task records -----------------------------------------------------------

meta_get() {  # <meta> <key>
  sed -n "s/^$2=//p" "$1" | tail -1
}

task_project() {  # <id>
  local p
  p=$(meta_get "$STATE/$1.meta" project)
  [ -n "$p" ] || return 1
  basename "$p"
}

ship_ids() {
  local m id kind
  for m in "$STATE"/*.meta; do
    [ -f "$m" ] && [ ! -L "$m" ] || continue
    id=${m##*/}; id=${id%.meta}
    fm_pr_task_id_valid "$id" || continue
    kind=$(meta_get "$m" kind)
    case "$kind" in ''|ship) printf '%s\n' "$id" ;; esac
  done
}

# The PR named by the task's latest ready report, else its recorded pr=.
task_pr_url() {  # <id>
  local line url=''
  if [ -f "$STATE/$1.status" ] && [ ! -L "$STATE/$1.status" ]; then
    while IFS= read -r line; do
      fm_pr_ready_line_url "$line" && url=$FM_PR_URL
    done < "$STATE/$1.status"
  fi
  [ -n "$url" ] || url=$(meta_get "$STATE/$1.meta" pr)
  [ -n "$url" ] && fm_pr_url_parse "$url" && [ "$FM_PR_PROVIDER" = github ] || return 1
  fm_pr_poll_merge_already_notified "$STATE" "$1" "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" && return 1
  printf '%s\n' "$FM_PR_URL"
}

# 0 when the watcher's PR-ready record shows this URL's handoff acknowledged.
handoff_handled() {  # <id> <url>
  local f="$STATE/$1.pr-ready" url handled
  [ -f "$f" ] || return 1
  url=$(sed -n 3p "$f"); handled=$(sed -n 6p "$f")
  [ "$url" = "$2" ] && [ "$handled" = 1 ]
}

# record lines: url, head, state, attempts, last epoch
record_read() {  # <file>
  REC_URL='' REC_HEAD='' REC_STATE='' REC_ATTEMPTS=0 REC_LAST=0
  [ -f "$1" ] && [ ! -L "$1" ] || return 0
  { IFS= read -r REC_URL; IFS= read -r REC_HEAD; IFS= read -r REC_STATE
    IFS= read -r REC_ATTEMPTS; IFS= read -r REC_LAST; } < "$1" || true
  whole "$REC_ATTEMPTS" || REC_ATTEMPTS=0
  case "$REC_LAST" in ''|*[!0-9]*) REC_LAST=0 ;; esac
}

record_write() {  # <file> <url> <head> <state> <attempts>
  local tmp
  tmp=$(mktemp "$STATE/.auto-handover.XXXXXX") || return 1
  if ! { printf '%s\n' "$2" "$3" "$4" "$5" "$NOW" > "$tmp" && mv -f -- "$tmp" "$1"; }; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Same URL and head: may this attempt run now? Sets NEXT_ATTEMPTS.
attempt_due() {  # <file> <url> <head> [done-state]
  record_read "$1"
  NEXT_ATTEMPTS=1
  [ "$REC_URL" = "$2" ] && [ "$REC_HEAD" = "$3" ] || return 0
  [ -z "${4:-}" ] || [ "$REC_STATE" != "$4" ] || return 1
  [ "$REC_ATTEMPTS" -lt 3 ] || return 1
  [ "$((NOW - REC_LAST))" -ge "$RETRY" ] || return 1
  NEXT_ATTEMPTS=$((REC_ATTEMPTS + 1))
}

# --- forge reads ------------------------------------------------------------

# Sets PR_JSON, PR_STATE, PR_DRAFT, PR_HEAD, PR_BASE, PR_MERGEABLE.
pr_read() {  # <url>
  PR_JSON=$(gh pr view "$1" --json state,isDraft,headRefOid,baseRefName,mergeable,labels,statusCheckRollup 2>/dev/null) || return 1
  PR_STATE=$(printf '%s' "$PR_JSON" | jq -r '.state // ""') || return 1
  PR_DRAFT=$(printf '%s' "$PR_JSON" | jq -r '.isDraft // false') || return 1
  PR_HEAD=$(printf '%s' "$PR_JSON" | jq -r '.headRefOid // ""') || return 1
  PR_BASE=$(printf '%s' "$PR_JSON" | jq -r '.baseRefName // ""') || return 1
  PR_MERGEABLE=$(printf '%s' "$PR_JSON" | jq -r '.mergeable // ""') || return 1
  fm_pr_head_valid "$PR_HEAD"
}

# Prints green, pending, or red, judged on PR_JSON.
pr_checks() {
  local pending red
  pending=$(printf '%s' "$PR_JSON" | jq -r '[.statusCheckRollup[]?
    | select((.__typename == "CheckRun" and .status != "COMPLETED")
      or (.__typename != "CheckRun" and (.state == "PENDING" or .state == "EXPECTED")))] | length') || return 1
  [ "$pending" = 0 ] || { echo pending; return 0; }
  red=$(fm_pr_github_checks_not_green "$PR_JSON") || return 1
  if [ -n "$red" ]; then echo red; else echo green; fi
}

pr_hold_label() {
  local label want
  while IFS= read -r label; do
    for want in do-not-merge needs-captain security destructive; do
      [ "$label" != "$want" ] || { printf '%s\n' "$label"; return 0; }
    done
  done < <(printf '%s' "$PR_JSON" | jq -r '.labels[]?.name')
  return 1
}

# Prints pass or fail for the newest trusted receipt naming <head>, else fails.
receipt_for_head() {  # <owner/repo> <number> <head>
  local login first verdict sha author ok comments
  [ "${#AUTHORS[@]}" -gt 0 ] || {
    login=$(gh api user --jq .login 2>/dev/null) && [ -n "$login" ] || return 1
    AUTHORS=("$login")
  }
  comments=$(gh api "repos/$1/issues/$2/comments" --paginate \
    --jq '.[] | [.user.login, ((.body // "") | split("\n")[0] | gsub("\r"; ""))] | @tsv' 2>/dev/null) || return 1
  verdict=''
  while IFS=$'\t' read -r login first; do
    ok=0
    for author in "${AUTHORS[@]}"; do [ "$login" != "$author" ] || ok=1; done
    [ "$ok" = 1 ] || continue
    [[ $first =~ ^[[:space:]]*GATE:[[:space:]]+(pass|fail)[[:space:]]+@[[:space:]]+([0-9a-f]{40})[[:space:]]*$ ]] || continue
    sha=${BASH_REMATCH[2]}
    [ "$sha" = "$3" ] && verdict=${BASH_REMATCH[1]}
  done <<< "$comments"
  [ -n "$verdict" ] || return 1
  printf '%s\n' "$verdict"
}

registered_yolo_on() {  # <project>
  local posture
  posture=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-project-mode.sh" "$1" 2>/dev/null) || return 1
  [ "${posture##* }" = on ]
}

# --- tick -------------------------------------------------------------------

task_ready() {
  local id=$1 url=$2 meta="$STATE/$1.meta" mode kind reason
  mode=$(meta_get "$meta" mode)
  kind=$(meta_get "$meta" kind)
  if fm_pr_head_valid "$PR_HEAD" && fm_dod_forge_head_is_named_head "$mode"; then
    return 0
  fi
  if ! reason=$(fm_dod_accept_ship_done "${kind:-ship}" "$mode" \
    "$(meta_get "$meta" worktree)" "$(meta_get "$meta" project)" \
    "done: PR $url checks green" "$STATE" "$id" "$meta"); then
    log "readiness: task=$id PR=$url: $reason"
    return 1
  fi
}

review_stage() {  # <id> <project> <url>
  local id=$1 project=$2 url=$3 rec="$STATE/$1.auto-review" checks token rc
  handoff_handled "$id" "$url" && return 0
  pr_read "$url" || { log "review: could not read $url"; return 0; }
  [ "$PR_STATE" = OPEN ] && [ "$PR_DRAFT" = false ] || return 0
  task_ready "$id" "$url" || return 0
  attempt_due "$rec" "$url" "$PR_HEAD" started || return 0
  checks=$(pr_checks) || return 0
  [ "$checks" = green ] || return 0
  token=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-pr-ready-ack.sh" --capture "$id" "$url" 2>/dev/null) || {
    log "review: no ready report to capture for $id $url"; return 0; }
  rc=0
  review_cmd "$project" || return 0
  ( cd "$FM_HOME" && FM_HOME="$FM_HOME" fm_run_timed "$REVIEW_TIMEOUT" bash -c "$REVIEW_CMD" \
      fm-auto-review "$id" "$url" "$FM_PR_NUMBER" "$PR_HEAD" ) \
    </dev/null >> "$STATE/$id.auto-review.log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    record_write "$rec" "$url" "$PR_HEAD" started "$NEXT_ATTEMPTS" || return 1
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-pr-ready-ack.sh" "$id" "$url" review-started "$token" >/dev/null 2>&1 \
      || notify "review-$id" "review started for task=$id PR=$url but its handoff could not be acknowledged; acknowledge it by hand"
    log "review: started for $id $url head $PR_HEAD"
    return 0
  fi
  record_write "$rec" "$url" "$PR_HEAD" failed "$NEXT_ATTEMPTS" || return 1
  log "review: command exited $rc for $id $url (attempt $NEXT_ATTEMPTS)"
  [ "$NEXT_ATTEMPTS" -lt 3 ] \
    || notify "review-$id" "review start failed 3 times for task=$id PR=$url (last exit $rc); see state/$id.auto-review.log and start the review by hand"
}

merge_stage() {  # <id> <project> <url>
  local id=$1 project=$2 url=$3 rec="$STATE/$1.auto-merge" verdict checks label out rc
  local slug queued notice="$STATE/$1.auto-merge-notice" away_notice="$STATE/$1.auto-merge-away"
  [ "$(meta_get "$STATE/$id.meta" yolo)" = on ] || return 0
  registered_yolo_on "$project" || return 0
  pr_read "$url" || { log "merge: could not read $url"; return 0; }
  [ "$PR_STATE" = OPEN ] && [ "$PR_DRAFT" = false ] || return 0
  task_ready "$id" "$url" || return 0
  slug="$FM_PR_OWNER/$FM_PR_REPO"
  verdict=$(receipt_for_head "$slug" "$FM_PR_NUMBER" "$PR_HEAD") || return 0
  [ "$verdict" = pass ] || return 0
  attempt_due "$rec" "$url" "$PR_HEAD" || return 0
  checks=$(pr_checks) || return 0
  case "$checks" in
    pending) return 0 ;;
    red)
      record_read "$notice"
      if [ "$REC_URL" != "$url" ] || [ "$REC_HEAD" != "$PR_HEAD" ] || [ "$REC_STATE" != red ]; then
        notify "merge-$id" "task=$id PR=$url has a passing review at $PR_HEAD but red checks; it was not merged" || return 1
        record_write "$notice" "$url" "$PR_HEAD" red 0 || return 1
      fi
      return 0 ;;
  esac
  if label=$(pr_hold_label); then
    record_read "$notice"
    if [ "$REC_URL" != "$url" ] || [ "$REC_HEAD" != "$PR_HEAD" ] || [ "$REC_STATE" != "label:$label" ]; then
      notify "merge-$id" "task=$id PR=$url passed review and checks but carries label '$label'; it needs the captain's merge call" || return 1
      record_write "$notice" "$url" "$PR_HEAD" "label:$label" 0 || return 1
    fi
    return 0
  fi
  queued=$(gh api graphql \
    -f query="query(\$owner:String!,\$repo:String!,\$number:Int!){repository(owner:\$owner,name:\$repo){pullRequest(number:\$number){isInMergeQueue}}}" \
    -F "owner=$FM_PR_OWNER" -F "repo=$FM_PR_REPO" -F "number=$FM_PR_NUMBER" \
    --jq '.data.repository.pullRequest.isInMergeQueue' 2>/dev/null) || return 0
  [ "$queued" = false ] || return 0
  rc=0
  out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$PR_MERGE" "$id" "$url" --expected-head "$PR_HEAD" --automatic 2>&1 </dev/null) || rc=$?
  printf '%s\n' "$out" >> "$STATE/$id.auto-merge.log" 2>/dev/null || true
  if [ "$rc" -eq 75 ]; then
    record_read "$away_notice"
    if [ "$REC_URL" != "$url" ] || [ "$REC_HEAD" != "$PR_HEAD" ]; then
      notify "merge-away-$id-$FM_PR_NUMBER-$PR_HEAD" "task=$id PR=$url passed review at $PR_HEAD; automatic merging is deferred while away so the supervisor can interpret the captain's away words" || return 1
      record_write "$away_notice" "$url" "$PR_HEAD" deferred 0 || return 1
    fi
    return 0
  fi
  if [ "$rc" -eq 0 ]; then
    record_write "$rec" "$url" "$PR_HEAD" accepted 0 || return 1
    log "merge: request accepted for $id $url at $PR_HEAD; completion follows the confirmed-merge outcome"
    return 0
  fi
  record_write "$rec" "$url" "$PR_HEAD" refused "$NEXT_ATTEMPTS" || return 1
  log "merge: refused for $id $url (attempt $NEXT_ATTEMPTS, exit $rc)"
  [ "$NEXT_ATTEMPTS" -lt 3 ] \
    || notify "merge-$id" "automatic merge of task=$id PR=$url was refused 3 times at $PR_HEAD; see state/$id.auto-merge.log"
}

task_pr_matches_project() {
  local project origin identity
  project=$(meta_get "$STATE/$1.meta" project)
  [ -n "$project" ] || return 1
  origin=$(git -C "$project" remote get-url origin 2>/dev/null) || return 1
  origin=$(printf '%s' "$origin" | tr '[:upper:]' '[:lower:]')
  origin=${origin%/}
  origin=${origin%.git}
  identity=$(printf '%s' "$FM_PR_HOST/$FM_PR_PATH" | tr '[:upper:]' '[:lower:]')
  case "$origin" in
    "https://$identity"|"git@${identity/\//:}"|"ssh://git@$identity") return 0 ;;
  esac
  return 1
}

run_tick() {
  local id project url
  touch "$STATE/.auto-handover-last"
  parse_config || return 0
  while IFS= read -r id; do
    project=$(task_project "$id") || continue
    review_cmd "$project" || merge_on "$project" || continue
    url=$(task_pr_url "$id") || continue
    fm_pr_url_parse "$url" || continue
    task_pr_matches_project "$id" || continue
    if review_cmd "$project"; then
      review_stage "$id" "$project" "$url" || return 1
      fm_pr_url_parse "$url" || continue
    fi
    if merge_on "$project"; then
      merge_stage "$id" "$project" "$url" || return 1
    fi
  done < <(ship_ids)
}

# --- conflicts --------------------------------------------------------------

steer_text() {  # <url> <base> <merged-url>
  printf '%s\n' \
    "Your PR $1 now conflicts with $2 after $3 merged." \
    "Merge $2 into your branch (git fetch origin && git merge origin/$2), resolve the conflicts, run the affected tests, and push the merge through your task's delivery path so the checks restart." \
    "Do not rebase or force-push. Then report the PR ready again with its URL."
}

run_conflicts() {
  local merged_id=$1 merged_url=$2 project=$3 base slug attempt id url pending next
  if ! fm_pr_task_id_valid "$merged_id" || ! fm_pr_url_parse "$merged_url"; then
    usage >&2
    return 2
  fi
  [ "$FM_PR_PROVIDER" = github ] || return 0
  parse_config || return 0
  steer_on "$project" || return 0
  slug="$FM_PR_OWNER/$FM_PR_REPO"
  pr_read "$merged_url" || { log "conflicts: could not read $merged_url"; return 0; }
  [ "$PR_STATE" = MERGED ] || return 0
  base=$(gh api "repos/$slug" --jq .default_branch 2>/dev/null) || return 0
  [ -n "$base" ] && [ "$base" = "$PR_BASE" ] || return 0
  pending=()
  while IFS= read -r id; do
    [ "$id" != "$merged_id" ] || continue
    url=$(task_pr_url "$id") || continue
    fm_pr_url_parse "$url" && [ "$FM_PR_OWNER/$FM_PR_REPO" = "$slug" ] || continue
    pending+=("$id $url")
  done < <(ship_ids)
  for ((attempt = 1; attempt <= STEER_ATTEMPTS && ${#pending[@]} > 0; attempt++)); do
    [ "$attempt" -eq 1 ] || sleep "$STEER_WAIT"
    next=()
    for entry in "${pending[@]}"; do
      id=${entry%% *}; url=${entry#* }
      pr_read "$url" || { next+=("$entry"); continue; }
      [ "$PR_STATE" = OPEN ] && [ "$PR_BASE" = "$base" ] || continue
      case "$PR_MERGEABLE" in
        CONFLICTING) steer_one "$id" "$url" "$base" "$merged_url" ;;
        MERGEABLE) ;;
        *) next+=("$entry") ;;
      esac
    done
    pending=("${next[@]+"${next[@]}"}")
  done
  [ "${#pending[@]}" -eq 0 ] || log "conflicts: mergeability still unknown after $STEER_ATTEMPTS reads: ${pending[*]}"
}

steer_one() {  # <id> <url> <base> <merged-url>
  local rec="$STATE/$1.conflict-steer"
  record_read "$rec"
  [ "$REC_URL" = "$2" ] && [ "$REC_HEAD" = "$PR_HEAD" ] && [ "$REC_STATE" = sent ] && return 0
  if FM_HOME="$FM_HOME" "$SEND" "$1" "$(steer_text "$2" "$3" "$4")" >/dev/null 2>&1 </dev/null; then
    record_write "$rec" "$2" "$PR_HEAD" sent 1
    log "conflicts: steered $1 to merge $3 into $2"
  else
    notify "conflict-$1" "PR $2 of task=$1 conflicts with $3 after $4 merged, and the steer to merge $3 in could not be delivered; steer the worker by hand"
  fi
}

# --- main -------------------------------------------------------------------

case "$1" in
  tick)
    LOCK="$STATE/.auto-handover.lock"
    fm_lock_try_acquire "$LOCK" || exit 0
    rc=0
    run_tick || rc=$?
    fm_lock_release "$LOCK" || true
    exit "$rc"
    ;;
  conflicts)
    LOCK="$STATE/.conflict-steer.lock"
    fm_lock_acquire_wait_max "$LOCK" 600 || exit 1
    rc=0
    run_conflicts "$2" "$3" "$4" || rc=$?
    fm_lock_release "$LOCK" || true
    exit "$rc"
    ;;
esac
