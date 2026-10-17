#!/usr/bin/env bash
# bin/fm-auto-handover.sh: opt-in review start on a green ready PR, merge on a
# passing receipt only under yolo, and conflict steers after a merge.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-auto-handover)
URL=https://github.com/o/r/pull/7
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# A fake gh: `pr view <url>` prints $FAKE/pr-<number>.json, `api user` prints
# the login, and the comments read prints $FAKE/comments-<number>.tsv as the
# already-projected login<TAB>first-line rows the real --jq would yield.
new_case() {
  CASE="$TMP_ROOT/$1"
  H="$CASE/home"
  FAKE="$CASE/fake"
  mkdir -p "$H/state" "$H/config" "$H/data" "$H/projects/proj" "$FAKE/bin"
  printf '%s\n' '# Fleet navigation registry' '' \
    '- proj [direct-PR +yolo] - fixture (added 2026-10-17)' > "$H/data/projects.md"
  cat > "$FAKE/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE/gh.log"
case "$1 $2" in
  "pr view") n=${3##*/}; cat "$FAKE/pr-$n.json" ;;
  "api user") echo bot ;;
  "api graphql") if [ -e "$FAKE/queued" ]; then echo true; else echo false; fi ;;
  api\ repos/*/comments) n=${2%/comments}; n=${n##*/}; cat "$FAKE/comments-$n.tsv" 2>/dev/null; [ ! -e "$FAKE/comments-fail" ] ;;
  "api repos/o/r") echo main ;;
  *) exit 1 ;;
esac
SH
  cat > "$FAKE/merge" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE/merge.log"
rc=$(cat "$FAKE/merge-rc" 2>/dev/null || echo 0)
if [ "$rc" = 0 ]; then
  if [ -e "$FAKE/merge-queued" ]; then
    touch "$FAKE/queued"
  else
    n=${2##*/}
    jq '.state = "MERGED"' "$FAKE/pr-$n.json" > "$FAKE/merged.json"
    mv "$FAKE/merged.json" "$FAKE/pr-$n.json"
  fi
fi
exit "$rc"
SH
  cat > "$FAKE/send" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FAKE/send.log"
printf '%s\n' "$2" > "$FAKE/send-text-$1"
SH
  chmod +x "$FAKE/bin/gh" "$FAKE/merge" "$FAKE/send"
  : > "$FAKE/gh.log"
}

ship() {  # <id> <yolo> [status-line]
  fm_write_meta "$H/state/$1.meta" "kind=ship" "project=$H/projects/proj" "yolo=$2"
  [ -z "${3:-}" ] || printf '%s\n' "$3" > "$H/state/$1.status"
}

# Args: number head mergeable [rollup-json] [labels-json]
pr_json() {
  local rollup=${4:-'[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]'}
  printf '{"state":"OPEN","isDraft":false,"headRefOid":"%s","baseRefName":"main","mergeable":"%s","labels":%s,"statusCheckRollup":%s}\n' \
    "$2" "$3" "${5:-[]}" "$rollup" > "$FAKE/pr-$1.json"
}

run() {
  FAKE="$FAKE" PATH="$FAKE/bin:$PATH" FM_HOME="$H" \
    FM_AUTO_HANDOVER_MERGE_BIN="$FAKE/merge" FM_AUTO_HANDOVER_SEND_BIN="$FAKE/send" \
    FM_CONFLICT_STEER_WAIT_SECS=1 FM_CONFLICT_STEER_ATTEMPTS=2 \
    bash "$ROOT/bin/fm-auto-handover.sh" "$@"
}

# --- opt-in ------------------------------------------------------------------

new_case off
ship s1 on "done [at=100]: PR $URL checks green"
pr_json 7 "$HEAD_A" MERGEABLE
run tick || fail "tick without config failed"
[ ! -s "$FAKE/gh.log" ] || fail "tick without config read the forge"
[ ! -e "$H/state/.auto-handover-last" ] || fail "tick without config touched state"
pass "without config/auto-handover nothing runs"

# --- review start ------------------------------------------------------------

new_case review
ship s1 off "done [at=100]: PR $URL checks green"
# shellcheck disable=SC2016 # The review command expands its own arguments.
printf '%s\n' '# fixture' 'review proj { printf "%s|" "$@"; echo; } >> "$FM_HOME/review-args"' > "$H/config/auto-handover"
pr_json 7 "$HEAD_A" MERGEABLE '[{"__typename":"CheckRun","name":"ci","status":"IN_PROGRESS","conclusion":null}]'
run tick || fail "tick with pending checks failed"
[ ! -e "$H/review-args" ] || fail "review started while checks were still running"
pr_json 7 "$HEAD_A" MERGEABLE '[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"FAILURE"}]'
run tick || fail "tick with red checks failed"
[ ! -e "$H/review-args" ] || fail "review started on red checks"
pr_json 7 "$HEAD_A" MERGEABLE
run tick || fail "tick with green checks failed"
assert_equals "s1|$URL|7|$HEAD_A|" "$(cat "$H/review-args" 2>/dev/null)" "review command gets task, PR, number, and head"
assert_contains "$(cat "$H/state/s1.pr-ready-ack" 2>/dev/null)" "review-started" "the handoff is acknowledged as review-started"
run tick || fail "repeat tick failed"
assert_equals 1 "$(wc -l < "$H/review-args" | tr -d ' ')" "one review per PR head"
[ ! -e "$H/state/.auto-handover-wake" ] || fail "a started review woke firstmate"
pass "review starts once checks are green, once per head, and acknowledges the handoff"

new_case review-fails
ship s1 off "done [at=100]: PR $URL checks green"
printf '%s\n' 'review proj exit 7' > "$H/config/auto-handover"
pr_json 7 "$HEAD_A" MERGEABLE
for _ in 1 2 3; do
  FM_AUTO_HANDOVER_RETRY_SECS=1 run tick || fail "tick with failing review failed"
  sleep 1.1
done
assert_contains "$(cat "$H/state/.auto-handover-wake" 2>/dev/null)" "review start failed 3 times for task=s1" \
  "the third failed start wakes firstmate"
assert_contains "$(cat "$H/state/.wake-queue")" "auto-handover-review-s1" "the wake is durable"
[ ! -e "$H/state/s1.pr-ready-ack" ] || fail "a failed review start acknowledged the handoff"
pass "a review that cannot start retries, then escalates without acknowledging"

# --- merge -------------------------------------------------------------------

new_case merge
ship s1 on "done [at=100]: PR $URL checks green"
printf '%s\n' 'merge proj' > "$H/config/auto-handover"
pr_json 7 "$HEAD_B" MERGEABLE
printf 'bot\tGATE: pass @ %s\n' "$HEAD_A" > "$FAKE/comments-7.tsv"
run tick || fail "merge tick failed"
[ ! -e "$FAKE/merge.log" ] || fail "merged on a receipt for an older head"
printf 'bot\tGATE: pass @ %s\nmallory\tGATE: fail @ %s\n' "$HEAD_A" "$HEAD_B" > "$FAKE/comments-7.tsv"
printf 'mallory\tGATE: pass @ %s\n' "$HEAD_B" >> "$FAKE/comments-7.tsv"
run tick || fail "merge tick failed"
[ ! -e "$FAKE/merge.log" ] || fail "merged on an untrusted author's receipt"
printf 'bot\tGATE: pass @ %s\nbot\tGATE: fail @ %s\n' "$HEAD_B" "$HEAD_B" > "$FAKE/comments-7.tsv"
run tick || fail "merge tick failed"
[ ! -e "$FAKE/merge.log" ] || fail "merged although the newest receipt for the head failed"
printf 'bot\tGATE: fail @ %s\nbot\tGATE: pass @ %s\n' "$HEAD_B" "$HEAD_B" > "$FAKE/comments-7.tsv"
touch "$FAKE/comments-fail"
run tick || fail "partial receipt tick failed"
[ ! -e "$FAKE/merge.log" ] || fail "merged after an incomplete comments read"
rm "$FAKE/comments-fail"
run tick || fail "merge tick failed"
assert_equals "s1 $URL --expected-head $HEAD_B" "$(cat "$FAKE/merge.log" 2>/dev/null)" "the guarded merge path is bound to the reviewed head"
run tick || fail "repeat merge tick failed"
assert_equals 1 "$(wc -l < "$FAKE/merge.log" | tr -d ' ')" "one merge per head"
pass "merge runs only on the newest trusted passing receipt for the live head"

new_case merge-queue-recovery
ship s1 on "done [at=100]: PR $URL checks green"
printf '%s\n' 'merge proj' > "$H/config/auto-handover"
printf 'bot\tGATE: pass @ %s\n' "$HEAD_A" > "$FAKE/comments-7.tsv"
pr_json 7 "$HEAD_A" MERGEABLE
touch "$FAKE/merge-queued"
for attempt in 1 2 3 4; do
  FM_AUTO_HANDOVER_RETRY_SECS=1 run tick || fail "queue entry failed"
  assert_equals "$attempt" "$(wc -l < "$FAKE/merge.log" | tr -d ' ')" "same head may reenter after ejection"
  assert_equals accepted "$(sed -n 3p "$H/state/s1.auto-merge")" "queue acceptance is not merge completion"
  sleep 1.1
  FM_AUTO_HANDOVER_RETRY_SECS=1 run tick || fail "queued tick failed"
  assert_equals "$attempt" "$(wc -l < "$FAKE/merge.log" | tr -d ' ')" "queued PR does not submit another request"
  rm "$FAKE/queued"
  pr_json 7 "$HEAD_A" MERGEABLE '[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"FAILURE"}]'
  FM_AUTO_HANDOVER_RETRY_SECS=1 run tick || fail "ejected red tick failed"
  assert_equals "$attempt" "$(wc -l < "$FAKE/merge.log" | tr -d ' ')" "ejected PR waits for green checks"
  pr_json 7 "$HEAD_A" MERGEABLE
done
rm "$FAKE/merge-queued"
FM_AUTO_HANDOVER_RETRY_SECS=1 run tick || fail "recovered queue merge failed"
assert_equals 5 "$(wc -l < "$FAKE/merge.log" | tr -d ' ')" "same-head recovery eventually merges"
assert_equals MERGED "$(jq -r .state "$FAKE/pr-7.json")" "recovered PR is confirmed merged"
sleep 1.1
FM_AUTO_HANDOVER_RETRY_SECS=1 run tick || fail "merged tick failed"
assert_equals 5 "$(wc -l < "$FAKE/merge.log" | tr -d ' ')" "confirmed merge is not retried"
pass "queue ejection remains retryable at the same head without exhausting refusal attempts"

new_case merge-yolo-off
ship s1 off "done [at=100]: PR $URL checks green"
printf '%s\n' 'merge proj' > "$H/config/auto-handover"
pr_json 7 "$HEAD_A" MERGEABLE
printf 'bot\tGATE: pass @ %s\n' "$HEAD_A" > "$FAKE/comments-7.tsv"
run tick || fail "tick failed"
[ ! -e "$FAKE/merge.log" ] || fail "merged a task whose yolo is off"
ship s1 on
printf '%s\n' '- proj [direct-PR] - fixture (added 2026-10-17)' > "$H/data/projects.md"
run tick || fail "tick failed"
[ ! -e "$FAKE/merge.log" ] || fail "merged although the registered posture has yolo off"
pass "merge needs yolo in both the task record and the registered posture"

new_case merge-guards
ship s1 on "done [at=100]: PR $URL checks green"
printf '%s\n' 'merge proj' > "$H/config/auto-handover"
printf 'bot\tGATE: pass @ %s\n' "$HEAD_A" > "$FAKE/comments-7.tsv"
pr_json 7 "$HEAD_A" MERGEABLE '[]' '[{"name":"security"}]'
FM_AUTO_MERGE_HOLD_LABELS= run tick || fail "tick failed"
[ ! -e "$FAKE/merge.log" ] || fail "merged a PR carrying a hold label"
assert_contains "$(cat "$H/state/.auto-handover-wake")" "carries label 'security'" "a hold label asks for the captain's call"
rm -f "$H/state/s1.auto-merge" "$H/state/.auto-handover-wake"
pr_json 7 "$HEAD_A" MERGEABLE '[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"FAILURE"}]'
run tick || fail "tick failed"
[ ! -e "$FAKE/merge.log" ] || fail "merged on red checks"
assert_contains "$(cat "$H/state/.auto-handover-wake")" "red checks" "a passing review with red checks wakes firstmate"
run tick || fail "repeat red tick failed"
assert_equals 1 "$(wc -l < "$H/state/.auto-handover-wake" | tr -d ' ')" "red checks notify only once"
pr_json 7 "$HEAD_A" MERGEABLE
run tick || fail "recovered checks tick failed"
assert_equals "s1 $URL --expected-head $HEAD_A" "$(cat "$FAKE/merge.log")" "same-head recovery merges without resetting state"
rm -f "$H/state/s1.auto-merge" "$H/state/.auto-handover-wake" "$FAKE/merge.log"
pr_json 7 "$HEAD_A" MERGEABLE
printf '1\n' > "$FAKE/merge-rc"
for _ in 1 2 3; do
  FM_AUTO_HANDOVER_RETRY_SECS=1 run tick || fail "tick failed"
  sleep 1.1
done
assert_equals 3 "$(wc -l < "$FAKE/merge.log" | tr -d ' ')" "a refused merge retries"
assert_contains "$(cat "$H/state/.auto-handover-wake")" "was refused 3 times" "the third refusal wakes firstmate"
pass "hold labels, red checks, and repeated refusals escalate instead of merging"

# --- conflict steers ---------------------------------------------------------

new_case conflicts
ship merged on "done [at=100]: PR https://github.com/o/r/pull/1 checks green"
ship s2 off "done [at=100]: PR https://github.com/o/r/pull/2 checks green"
ship s3 off "done [at=100]: PR https://github.com/o/r/pull/3 checks green"
ship s4 off "done [at=100]: PR https://github.com/o/other/pull/4 checks green"
printf '%s\n' 'conflict-steer proj' > "$H/config/auto-handover"
pr_json 1 "$HEAD_A" MERGEABLE
jq '.state = "MERGED"' "$FAKE/pr-1.json" > "$FAKE/merged.json"
mv "$FAKE/merged.json" "$FAKE/pr-1.json"
pr_json 2 "$HEAD_A" UNKNOWN
pr_json 3 "$HEAD_A" MERGEABLE
pr_json 4 "$HEAD_A" CONFLICTING
( sleep 0.5; pr_json 2 "$HEAD_A" CONFLICTING ) &
run conflicts merged https://github.com/o/r/pull/1 proj || fail "conflict pass failed"
wait
assert_equals s2 "$(cat "$FAKE/send.log" 2>/dev/null)" "only the conflicting PR in the same repository is steered"
assert_contains "$(cat "$FAKE/send-text-s2")" "Merge main into your branch" "the steer asks for a merge of the base branch"
assert_contains "$(cat "$FAKE/send-text-s2")" "Do not rebase or force-push" "the steer never asks to rewrite the branch"
run conflicts merged https://github.com/o/r/pull/1 proj || fail "repeat conflict pass failed"
assert_equals 1 "$(wc -l < "$FAKE/send.log" | tr -d ' ')" "one steer per PR head"
pass "after a merge, only newly conflicting PRs in the same repository are steered, once per head"

rm -f "$FAKE/send.log" "$H/state/s2.conflict-steer"
jq '.baseRefName = "release"' "$FAKE/pr-1.json" > "$FAKE/merged.json"
mv "$FAKE/merged.json" "$FAKE/pr-1.json"
jq '.baseRefName = "release"' "$FAKE/pr-2.json" > "$FAKE/merged.json"
mv "$FAKE/merged.json" "$FAKE/pr-2.json"
run conflicts merged https://github.com/o/r/pull/1 proj || fail "nondefault conflict pass failed"
[ ! -e "$FAKE/send.log" ] || fail "steered after a merge to a nondefault branch"
pass "conflict recovery only follows default-branch merges"

for origin in self poll; do
  new_case "outcome-$origin"
  ship merged on "done [at=100]: PR https://github.com/o/r/pull/1 checks green"
  ship s2 off "done [at=100]: PR https://github.com/o/r/pull/2 checks green"
  printf '%s\n' 'conflict-steer proj' > "$H/config/auto-handover"
  pr_json 1 "$HEAD_A" MERGEABLE
  jq '.state = "MERGED"' "$FAKE/pr-1.json" > "$FAKE/merged.json"
  mv "$FAKE/merged.json" "$FAKE/pr-1.json"
  pr_json 2 "$HEAD_A" CONFLICTING
  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$H/state/.conflict-steer.lock" || exit 1
    touch "$FAKE/locked"
    while [ ! -e "$FAKE/release" ]; do sleep 0.05; done
    fm_lock_release "$H/state/.conflict-steer.lock"
  ) &
  holder=$!
  for _ in {1..100}; do [ ! -e "$FAKE/locked" ] || break; sleep 0.05; done
  [ -e "$FAKE/locked" ] || fail "conflict lock holder did not start"
  (
    export FAKE PATH="$FAKE/bin:$PATH" FM_AUTO_HANDOVER_SEND_BIN="$FAKE/send"
    . "$ROOT/bin/fm-merge-outcome-lib.sh"
    fm_merge_outcome_report "$H" "$H/state" merged https://github.com/o/r/pull/1 "$origin"
  ) || fail "merge outcome failed"
  rm "$H/state/merged.meta"
  touch "$FAKE/release"
  wait "$holder" || fail "conflict lock release failed"
  for _ in {1..100}; do [ ! -e "$H/state/s2.conflict-steer" ] || break; sleep 0.05; done
  assert_equals s2 "$(cat "$FAKE/send.log" 2>/dev/null)" "$origin outcome steers even after the merged task is cleaned up"
  pass "$origin merge outcome dispatches detached conflict recovery with captured routing"
done

new_case conflicts-off
ship merged on "done [at=100]: PR https://github.com/o/r/pull/1 checks green"
ship s2 off "done [at=100]: PR https://github.com/o/r/pull/2 checks green"
printf '%s\n' 'merge proj' > "$H/config/auto-handover"
pr_json 1 "$HEAD_A" MERGEABLE
jq '.state = "MERGED"' "$FAKE/pr-1.json" > "$FAKE/merged.json"
mv "$FAKE/merged.json" "$FAKE/pr-1.json"
pr_json 2 "$HEAD_A" CONFLICTING
run conflicts merged https://github.com/o/r/pull/1 proj || fail "conflict pass failed"
[ ! -e "$FAKE/send.log" ] || fail "steered without conflict-steer for the project"
pass "conflict steers are opt-in per project"

new_case bad-config
ship s1 on "done [at=100]: PR $URL checks green"
printf '%s\n' 'merge' > "$H/config/auto-handover"
run tick || fail "tick with invalid config failed"
run tick || fail "repeat tick with invalid config failed"
assert_equals 1 "$(grep -c 'is invalid' "$H/state/.auto-handover-wake")" "an invalid config wakes once per content"
[ ! -s "$FAKE/gh.log" ] || fail "an invalid config still read the forge"
pass "an invalid config changes nothing and wakes once"

# --- watcher wiring ----------------------------------------------------------

watch_once() {  # <home> <out>
  PATH="$1/fakebin:$PATH" FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_CONFIG_OVERRIDE="$1/config" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch.sh" > "$2" 2>&1 &
  WATCH_PID=$!
}

W=$(make_case watcher)
mkdir -p "$W/config"
printf '%s\n' 'merge proj' > "$W/config/auto-handover"
watch_once "$W" "$W/watch.out"
i=0
while [ ! -e "$W/state/.auto-handover-last" ] && [ "$i" -lt 50 ]; do
  sleep 0.1
  i=$((i + 1))
done
[ -e "$W/state/.auto-handover-last" ] || fail "the watcher never ran the handover pass"
kill -0 "$WATCH_PID" 2>/dev/null || fail "the watcher exited without a wake"
printf '%s\n' 'first reason' 'second reason' > "$W/state/.auto-handover-wake"
i=0
while kill -0 "$WATCH_PID" 2>/dev/null && [ "$i" -lt 50 ]; do
  sleep 0.1
  i=$((i + 1))
done
kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
assert_contains "$(cat "$W/watch.out")" "check: auto-handover: first reason; second reason" \
  "the watcher announces the queued handover reasons in one wake"
[ ! -e "$W/state/.auto-handover-wake" ] || fail "announced reasons were left to repeat"
pass "the watcher runs the detached pass and announces what it queued"
