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

ack_pr() {
  FM_STATE_OVERRIDE="$STATE_DIR" "$ROOT/bin/fm-pr-ready-ack.sh" ship "$1" "${2:-review-started}" >/dev/null \
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
ack_pr https://github.com/o/r/pull/8
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
