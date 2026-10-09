#!/usr/bin/env bash
# PR-ready age, restart/repeat, queue acknowledgement, and landing handoff.
set -u
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-ready)
URL=https://github.com/o/r/pull/7

new_case() {
  CASE=$(make_case "$1")
  STATE_DIR="$CASE/state"
  printf 'kind=ship\n' > "$STATE_DIR/ship.meta"
}

# A fresh process on every call proves the timer/cursor needs no resident state.
tick() {
  FM_STATE_OVERRIDE="$STATE_DIR" bash -c '
    . "$1/bin/fm-pr-ready-lib.sh"
    fm_pr_ready_tick "$STATE" "$2"
  ' _ "$ROOT" "$1"
}

arm() {
  printf 'kind=ship\npr=%s\n' "$1" > "$STATE_DIR/ship.meta"
  FM_STATE_OVERRIDE="$STATE_DIR" bash -c '
    . "$1/bin/fm-pr-lib.sh"
    fm_pr_url_parse "$2" || exit 1
    fm_pr_poll_prepare "$FM_STATE_OVERRIDE" ship "$FM_PR_PROVIDER" "$2" \
      "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" "$1/bin/fm-pr-poll.sh" || exit 1
    fm_pr_poll_publish_prepared
  ' _ "$ROOT" "$1" || fail 'could not arm authenticated poll'
}

capture_pr() {
  FM_STATE_OVERRIDE="$STATE_DIR" bash "$ROOT/bin/fm-pr-ready-ack.sh" --capture ship "$1" 2> "$CASE/capture.err"
}

ack_pr() {
  local report
  report=${3:-$(capture_pr "$1")} || fail 'could not capture ready report'
  FM_STATE_OVERRIDE="$STATE_DIR" bash "$ROOT/bin/fm-pr-ready-ack.sh" ship "$1" "${2:-review-started}" "$report" >/dev/null \
    || fail 'could not acknowledge handled PR'
}

ack_queue() {
  local err seq gen
  err="$CASE/drain.err"
  FM_STATE_OVERRIDE="$STATE_DIR" "$ROOT/bin/fm-wake-drain.sh" > "$CASE/drain.out" 2> "$err" || fail 'drain failed'
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation .*/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([^ ]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$gen" ] || fail 'drain supplied no acknowledgement'
  FM_STATE_OVERRIDE="$STATE_DIR" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" \
    --recovery-generation "$gen" >/dev/null || fail 'queue acknowledgement failed'
}

new_case age
printf 'done [at=100]: PR %s checks green\n' "$URL" > "$STATE_DIR/ship.status"
[ -z "$(tick 1299)" ] || fail 'alarm before default 20-minute age'
out=$(tick 1300) || fail 'age tick failed'
assert_contains "$out" "task=ship PR=$URL age=1200s" 'alarm names task, PR and age'
assert_contains "$(cat "$STATE_DIR/.wake-queue")" 'PR-ready overdue' 'alarm is durable'
ack_queue
[ -z "$(tick 2499)" ] || fail 'repeat fired early after restart'
assert_contains "$(tick 2500)" 'PR-ready overdue' 'queue acknowledgement does not acknowledge the PR'
pass 'age and repeat survive restart and wake acknowledgement'

arm "$URL"
assert_contains "$(tick 3700)" 'PR-ready overdue' 'monitoring registration alone is not a review'
ack_pr "$URL"
[ -z "$(tick 4900)" ] || fail 'acknowledged PR still alarms'
# Retire the real poll after the acknowledgement and prove it remains handled.
FM_STATE_OVERRIDE="$STATE_DIR" bash -c '
  . "$1/bin/fm-pr-lib.sh"
  fm_pr_poll_snapshot_capture "$FM_STATE_OVERRIDE" ship "$1/bin/fm-pr-poll.sh" \
    && fm_pr_poll_retirement_publish "$FM_STATE_OVERRIDE" ship "$1/bin/fm-pr-poll.sh" merged \
    && fm_pr_poll_retirement_recover_one "$FM_STATE_OVERRIDE" ship "$1/bin/fm-pr-poll.sh"
' _ "$ROOT" || fail 'retirement failed'
[ -z "$(tick 4901)" ] || fail 'retirement lost acknowledgement'
printf 'done [at=5000]: PR %s checks green\n' "$URL" >> "$STATE_DIR/ship.status"
assert_contains "$(tick 6200)" 'age=1200s' 'new ready cycle on same PR needs another acknowledgement'
ack_pr "$URL" held
[ -z "$(tick 6201)" ] || fail 'intentional hold did not acknowledge'
printf 'ready [at=6300]: PR https://github.com/o/r/pull/8\n' >> "$STATE_DIR/ship.status"
assert_contains "$(tick 7500)" 'PR=https://github.com/o/r/pull/8' 'another PR starts a new obligation'
pass 'explicit acknowledgement survives restart and retirement but not a new review cycle'

new_case wrong-poll
printf 'done [at=100]: PR %s\n' "$URL" > "$STATE_DIR/ship.status"
arm https://github.com/o/r/pull/8
report=$(capture_pr "$URL") || fail 'could not capture actual PR'
if FM_STATE_OVERRIDE="$STATE_DIR" bash "$ROOT/bin/fm-pr-ready-ack.sh" ship \
  https://github.com/o/r/pull/8 review-started "$report" >/dev/null 2>&1; then
  fail 'acknowledgement accepted a report for another PR'
fi
[ ! -e "$STATE_DIR/ship.pr-ready-ack" ] || fail 'invalid acknowledgement was persisted'
assert_contains "$(tick 1300)" 'PR-ready overdue' 'other PR registration cannot acknowledge'
arm "$URL"
printf '\n# tampered\n' >> "$STATE_DIR/ship.check.sh"
assert_contains "$(tick 2500)" 'PR-ready overdue' 'unauthenticated registration cannot acknowledge'
pass 'wrong acknowledgements and merge monitoring cannot silence the alarm'

new_case early-ack
printf 'done [at=100]: PR %s\n' "$URL" > "$STATE_DIR/ship.status"
ack_pr "$URL"
printf 'working: review running\n' >> "$STATE_DIR/ship.status"
[ -z "$(tick 1300)" ] || fail 'ack before watcher observation was ignored'
printf 'done [at=1500]: PR %s\n' "$URL" >> "$STATE_DIR/ship.status"
[ -z "$(tick 2699)" ] || fail 'next review cycle inherited old age'
assert_contains "$(tick 2700)" 'age=1200s' 'old acknowledgement cannot cover future ready bytes'
pass 'acknowledgement binds to observed status bytes even before the watcher sees them'

for observed in no yes; do
  new_case "delayed-ack-$observed"
  printf 'done [at=100]: PR %s\n' "$URL" > "$STATE_DIR/ship.status"
  report=$(capture_pr "$URL") || fail 'could not capture first review report'
  [ -z "$(tick 100)" ] || fail 'first report alarmed early'
  printf 'ready [at=1500]: PR %s fixes ready\n' "$URL" >> "$STATE_DIR/ship.status"
  if [ "$observed" = yes ]; then
    assert_contains "$(tick 1500)" 'PR-ready overdue' 'unacknowledged report remains pending'
  fi
  ack_pr "$URL" review-started "$report"
  assert_contains "$(tick 2700)" 'PR-ready overdue' 'delayed acknowledgement cannot silence the next review'
  ack_pr "$URL"
  [ -z "$(tick 3900)" ] || fail 'second review acknowledgement did not stop alarms'
done
pass 'delayed acknowledgement preserves newer reports before and after watcher observation'

new_case invalid-report
printf 'done [at=100]: PR %s\n' "$URL" > "$STATE_DIR/ship.status"
report=$(capture_pr "$URL") || fail 'could not capture report'
endpoint=${report##*|}
printf 'working: unrelated append\n' >> "$STATE_DIR/ship.status"
size=$(wc -c < "$STATE_DIR/ship.status" | tr -d ' ')
for token in "${report%|*}|$((endpoint - 1))" "${report%|*}|$size" "${report%|*}|$((size + 1))" "${report%|*}|0"; do
  if FM_STATE_OVERRIDE="$STATE_DIR" bash "$ROOT/bin/fm-pr-ready-ack.sh" ship "$URL" held "$token" >/dev/null 2>&1; then
    fail 'invalid report endpoint was accepted'
  fi
done
if FM_STATE_OVERRIDE="$STATE_DIR" bash "$ROOT/bin/fm-pr-ready-ack.sh" ship "$URL" held >/dev/null 2>&1; then
  fail 'acknowledgement without captured report was accepted'
fi
printf 'done [at=100]: PR %s\n' "$URL" > "$CASE/replacement"
mv "$CASE/replacement" "$STATE_DIR/ship.status"
if FM_STATE_OVERRIDE="$STATE_DIR" bash "$ROOT/bin/fm-pr-ready-ack.sh" ship "$URL" held "$report" >/dev/null 2>&1; then
  fail 'replaced status accepted an old report token'
fi
[ ! -e "$STATE_DIR/ship.pr-ready-ack" ] || fail 'invalid token created an acknowledgement'
assert_contains "$(tick 1300)" 'PR-ready overdue' 'refused tokens preserve the obligation'
pass 'acknowledgement rejects missing, partial, unrelated, future and replaced report tokens'

new_case capture-boundary
printf 'ready [at=100]: café PR %s' "$URL" > "$STATE_DIR/ship.status"
if capture_pr "$URL" >/dev/null; then fail 'capture accepted an incomplete ready report'; fi
printf '\nworking: unrelated update\n' >> "$STATE_DIR/ship.status"
report=$(capture_pr "$URL") || fail 'complete ready report was not captured'
assert_contains "$(cat "$CASE/capture.err")" "café PR $URL" 'capture presents the report being handled'
if capture_pr https://github.com/o/r/pull/8 >/dev/null; then fail 'capture accepted another PR'; fi
ack_pr "$URL" held "$report"
[ -z "$(tick 1300)" ] || fail 'multibyte report with trailing progress was not acknowledged'
pass 'capture uses complete ready report bytes and presents the exact report'

new_case alarm-token
printf 'done [at=100]: PR %s\n' "$URL" > "$STATE_DIR/ship.status"
out=$(tick 1300) || fail 'alarm tick failed'
command=${out#*acknowledge with }
command=${command/'<review-started|merge-started|held>'/review-started}
printf 'ready [at=1500]: PR %s\n' "$URL" >> "$STATE_DIR/ship.status"
(cd "$ROOT" && FM_STATE_OVERRIDE="$STATE_DIR" bash -c "$command") >/dev/null \
  || fail 'alarm acknowledgement command failed'
assert_contains "$(tick 2700)" 'PR-ready overdue' 'alarm command acknowledges only its captured report'
pass 'alarm supplies an executable acknowledgement bound to its report'

new_case cleanup
printf 'done [at=100]: PR %s\n' "$URL" > "$STATE_DIR/ship.status"
assert_contains "$(tick 1300)" 'PR-ready overdue' 'cleanup fixture has a real overdue alarm'
FM_STATE_OVERRIDE="$STATE_DIR" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_wake_append check pr-ready-ship-extra "check: another overdue task" || exit 1
  fm_wake_append signal pr-ready-ship "signal: unrelated key" || exit 1
  fm_wake_queue_prune_task "$STATE" ship
' _ "$ROOT" || fail 'task wake cleanup failed'
queue=$(cat "$STATE_DIR/.wake-queue")
[[ "$queue" != *$'\tcheck\tpr-ready-ship\t'* ]] || fail 'cleanup retained the task overdue alarm'
assert_contains "$queue" $'\tcheck\tpr-ready-ship-extra\t' 'cleanup retains other task alarms'
assert_contains "$queue" $'\tsignal\tpr-ready-ship\t' 'cleanup retains other wake kinds'
pass 'task cleanup retires its overdue alarm and preserves unrelated wakes'

new_case truncated
printf 'done [at=100]: PR %s with a long description of the ready change\n' "$URL" > "$STATE_DIR/ship.status"
ack_pr "$URL"
[ -z "$(tick 1300)" ] || fail 'initial acknowledgement was ignored'
printf 'done [at=2000]: PR %s\n' "$URL" > "$STATE_DIR/ship.status"
[ -z "$(tick 3199)" ] || fail 'truncated log inherited old age'
printf 'working: unrelated status grows the log beyond the old acknowledged byte endpoint\n' >> "$STATE_DIR/ship.status"
assert_contains "$(tick 3200)" 'age=1200s' 'truncated log cannot inherit old acknowledgement'
pass 'truncating and regrowing a status log cannot revive an old acknowledgement'

new_case merged
printf 'done [at=100]: PR %s\n' "$URL" > "$STATE_DIR/ship.status"
FM_STATE_OVERRIDE="$STATE_DIR" bash -c '
  . "$1/bin/fm-pr-lib.sh"
  fm_pr_poll_merge_mark_notified "$FM_STATE_OVERRIDE" ship github github.com o/r 7
' _ "$ROOT" || fail 'could not publish merge receipt'
[ -z "$(tick 1300)" ] || fail 'published merge outcome was ignored'
pass 'published matching merge outcome acknowledges an unobserved ready PR'

new_case failed-queue
printf 'done [at=100]: PR %s\n' "$URL" > "$STATE_DIR/ship.status"
[ -z "$(tick 1299)" ] || fail 'initial alarm fired early'
mkdir "$CASE/unwritable-queue"
if FM_WAKE_QUEUE="$CASE/unwritable-queue" tick 1300 > /dev/null 2>&1; then fail 'queue failure was ignored'; fi
assert_contains "$(tick 1301)" 'PR-ready overdue' 'failed enqueue does not advance the repeat timer'
pass 'failed wake publication cannot suppress the next alarm'

new_case status
printf 'working [at=100]: see %s\n' "$URL" > "$STATE_DIR/ship.status"
[ -z "$(tick 1300)" ] || fail 'progress URL opened an obligation'
printf 'done [at=100]: local implementation complete\n' >> "$STATE_DIR/ship.status"
[ -z "$(tick 1300)" ] || fail 'pipeline handoff opened an obligation'
printf 'done [at=100]: PR %s\nresolved [at=101]: old decision closed\nworking: unrelated bookkeeping\n' "$URL" >> "$STATE_DIR/ship.status"
assert_contains "$(tick 1300)" 'PR-ready overdue' 'later status cannot hide readiness'
printf 'done [at=1400]: PR %s\n' "$URL" >> "$STATE_DIR/ship.status"
assert_contains "$(tick 2500)" 'age=2400s' 'duplicate readiness cannot reset age'
pass 'only ready declarations open alarms and unrelated status cannot erase them'

new_case legacy
printf 'ready: PR %s' "$URL" > "$STATE_DIR/ship.status"
[ -z "$(tick 100)" ] || fail 'partial declaration was consumed'
printf '\n' >> "$STATE_DIR/ship.status"
[ -z "$(tick 200)" ] || fail 'legacy declaration was treated as ancient'
[ -z "$(tick 1399)" ] || fail 'legacy observation alarm fired early'
assert_contains "$(tick 1400)" 'age=1200s' 'legacy age starts at observation'
printf 'working: replaced\n' > "$CASE/replacement"
mv "$CASE/replacement" "$STATE_DIR/ship.status"
[ -z "$(tick 2600)" ] || fail 'replaced log retained old obligation'
pass 'partial appends, unknown emission time and replacement keep correct age'

new_case config
printf 'done [at=100]: PR %s\n' "$URL" > "$STATE_DIR/ship.status"
[ -z "$(FM_PR_READY_AGE_SECS=10 tick 109)" ] || fail 'configured age fired early'
assert_contains "$(FM_PR_READY_AGE_SECS=10 tick 110)" 'age=10s' 'configured age is used'
[ -z "$(FM_PR_READY_AGE_SECS=10 FM_PR_READY_REPEAT_SECS=30 tick 139)" ] || fail 'configured repeat fired early'
assert_contains "$(FM_PR_READY_AGE_SECS=10 FM_PR_READY_REPEAT_SECS=30 tick 140)" 'age=40s' 'configured repeat is used'
if FM_PR_READY_AGE_SECS=0 tick 200 > /dev/null 2>&1; then fail 'invalid age disabled alarm'; fi
printf 'kind=scout\n' > "$STATE_DIR/ship.meta"
[ -z "$(tick 5000)" ] || fail 'scout was treated as ship'
pass 'configuration is bounded and non-ships are excluded'

# Exercise the real watcher in quiet posture, without any live worker endpoint.
new_case watcher
printf 'quiet\n' > "$STATE_DIR/.afk"
printf 'done [at=100]: PR %s\n' "$URL" > "$STATE_DIR/ship.status"
PATH="$CASE/fakebin:$PATH" FM_STATE_OVERRIDE="$STATE_DIR" FM_POLL=1 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
  "$ROOT/bin/fm-watch.sh" > "$CASE/watch.out" 2> "$CASE/watch.err" &
pid=$!
wait_for_exit "$pid" 200 || fail "watcher failed: $(cat "$CASE/watch.err")"
assert_contains "$(cat "$CASE/watch.out")" 'check: PR-ready overdue: task=ship' 'quiet watcher surfaces age alarm'
assert_contains "$(cat "$STATE_DIR/.wake-queue")" "PR=$URL" 'quiet alarm is queued'
pass 'real quiet watcher queues the actionable PR alarm without a live endpoint'
