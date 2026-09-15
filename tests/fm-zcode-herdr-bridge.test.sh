#!/usr/bin/env bash
# Behavior tests for the herdr agent-view bridge in bin/fm-busy-event.sh.
#
# The bridge (header of bin/fm-busy-event.sh) reports a herdr-backend
# zcode-harness task's busy/idle flips to herdr's agent view after a
# successful arm or apply, and is best-effort ALWAYS: a missing herdr, a
# missing meta, an unusable window=, or a failing report is a silent no-op
# that leaves the exit code, the busy record, and stdout untouched. These
# tests run the REAL writer against a fake herdr that captures argv plus the
# HERDR_SESSION it was handed, so the exact report invocation, its routing by
# the recorded session rather than the inherited env, the scoping guards,
# the armed-harness rule, and the seq threading are pinned without a live
# harness.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-zcode-herdr-bridge)
EV="$ROOT/bin/fm-busy-event.sh"

make_case() {  # <name> -> "state|capture|fakebin"
  local name=$1 dir state capture fakebin
  dir="$TMP_ROOT/$name"
  state="$dir/state"
  mkdir -p "$state"
  capture="$dir/herdr-calls.log"
  : > "$capture"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
printf '%s [HERDR_SESSION=%s]\n' "\$*" "\${HERDR_SESSION-unset}" >> "$capture"
exit \${FAKE_HERDR_EXIT:-0}
SH
  chmod +x "$fakebin/herdr"
  printf '%s|%s|%s\n' "$state" "$capture" "$fakebin"
}

read_case() {
  # shellcheck disable=SC2034 # FAKEBIN is part of the shared record shape
  IFS='|' read -r STATE CAPTURE FAKEBIN <<EOF
$1
EOF
}

write_bridge_meta() {  # <state> <id> <backend-or-empty> <harness> <window>
  local state=$1 id=$2 backend=$3 harness=$4 window=$5
  {
    [ -z "$backend" ] || printf 'backend=%s\n' "$backend"
    printf 'window=%s\n' "$window"
    printf 'harness=%s\n' "$harness"
  } > "$state/$id.meta"
}

bridge_calls() {  # <capture>
  cat "$1"
}

# The wire seq contract (bin/fm-busy-event.sh header): gen epoch * 1e9 + seq.
wire_seq() {  # <gen> <record-seq>
  local epoch=${1#g}
  epoch=${epoch%%.*}
  printf '%s' $((epoch * 1000000000 + $2))
}

captured_seq() {  # <capture-line>
  printf '%s' "$1" | sed -n 's/.* --seq \([0-9]*\) .*/\1/p'
}

wait_for_next_epoch_second() {  # <gen>
  local epoch=${1#g}
  epoch=${epoch%%.*}
  while [ "$(date +%s)" -le "$epoch" ]; do sleep 0.2; done
}

test_arm_reports_working_at_seq1_routed_by_recorded_session() {
  local rec out expected
  rec=$(make_case arm-report)
  read_case "$rec"
  write_bridge_meta "$STATE" t1 herdr zcode 'fm-lab-x:w1:p7'
  # The captain-side relaunch shape: no herdr env inherited at all.
  out=$(env -u HERDR_SESSION -u HERDR_SOCKET_PATH PATH="$FAKEBIN:$BASE_PATH" "$EV" arm "$STATE" t1 --harness zcode)
  expect_code 0 $? "arm must succeed"
  case "$out" in
    g[0-9]*) : ;;
    *) fail "arm stdout must stay the bare minted gen, got '$out'" ;;
  esac
  [ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ] || fail "arm stdout grew a second line: '$out'"
  assert_grep 'seq=1 state=busy source=fm-spawn event=launch-brief' "$STATE/t1.busy-state" \
    "arm must keep its exact seed record"
  expected="pane report-agent w1:p7 --source firstmate --agent fm-t1 --state working --seq $(wire_seq "$out" 1) --session fm-lab-x [HERDR_SESSION=fm-lab-x]"
  [ "$(bridge_calls "$CAPTURE")" = "$expected" ] \
    || fail "arm report invocation mismatch: got '$(bridge_calls "$CAPTURE")'"
  pass "arm reports working at seq 1 routed by the recorded session and a clean stdout"
}

test_report_ignores_inherited_session_env() {
  local rec gen expected
  rec=$(make_case foreign-env)
  read_case "$rec"
  write_bridge_meta "$STATE" t1 herdr zcode 'fm-lab-x:w1:p7'
  # A shell bound to another server must not steer the report there.
  gen=$(HERDR_SESSION=default HERDR_SOCKET_PATH=/nonexistent/default.sock \
    PATH="$FAKEBIN:$BASE_PATH" "$EV" arm "$STATE" t1 --harness zcode) || fail "arm failed"
  HERDR_SESSION=default HERDR_SOCKET_PATH=/nonexistent/default.sock \
    PATH="$FAKEBIN:$BASE_PATH" "$EV" apply "$STATE" t1 idle \
    --gen "$gen" --source zcode-hook --event stop
  expect_code 0 $? "idle apply must succeed"
  expected="pane report-agent w1:p7 --source firstmate --agent fm-t1 --state idle --seq $(wire_seq "$gen" 2) --session fm-lab-x [HERDR_SESSION=fm-lab-x]"
  [ "$(sed -n 2p "$CAPTURE")" = "$expected" ] \
    || fail "a report under a foreign HERDR_SESSION must still route by the recorded session: '$(sed -n 2p "$CAPTURE")'"
  pass "an inherited HERDR_SESSION naming another server never routes the report"
}

test_arm_reports_only_for_the_armed_zcode_harness() {
  local rec gen expected
  rec=$(make_case relaunch-switch)
  read_case "$rec"
  # The relaunch shape: the record still says zcode when the replacement is armed.
  write_bridge_meta "$STATE" t1 herdr zcode 'fm-lab-x:w1:p7'
  gen=$(PATH="$FAKEBIN:$BASE_PATH" "$EV" arm "$STATE" t1 --harness claude)
  expect_code 0 $? "arm with a switched harness must succeed"
  [ "$(bridge_calls "$CAPTURE")" = '' ] \
    || fail "a zcode record armed for claude must not report: '$(bridge_calls "$CAPTURE")'"
  gen=$(PATH="$FAKEBIN:$BASE_PATH" "$EV" arm "$STATE" t1)
  expect_code 0 $? "arm without --harness must succeed"
  [ "$(bridge_calls "$CAPTURE")" = '' ] \
    || fail "an arm that names no harness must not report: '$(bridge_calls "$CAPTURE")'"
  gen=$(PATH="$FAKEBIN:$BASE_PATH" "$EV" arm "$STATE" t1 --harness zcode) || fail "arm failed"
  expected="pane report-agent w1:p7 --source firstmate --agent fm-t1 --state working --seq $(wire_seq "$gen" 1) --session fm-lab-x [HERDR_SESSION=fm-lab-x]"
  [ "$(bridge_calls "$CAPTURE")" = "$expected" ] \
    || fail "the same record armed for zcode must report: '$(bridge_calls "$CAPTURE")'"
  PATH="$FAKEBIN:$BASE_PATH" "$EV" apply "$STATE" t1 idle --gen "$gen" --harness zcode \
    --source zcode-hook --event stop 2>/dev/null \
    && fail "--harness must be an arm-only flag"
  expect_code 2 $? "--harness on apply must be a usage error"
  pass "the arm-time report follows the armed harness, never the stale record"
}

test_apply_flips_thread_seq() {
  local rec gen expected
  rec=$(make_case apply-flips)
  read_case "$rec"
  write_bridge_meta "$STATE" t1 herdr zcode 'fm-lab-x:w1:p7'
  gen=$(PATH="$FAKEBIN:$BASE_PATH" "$EV" arm "$STATE" t1 --harness zcode) || fail "arm failed"
  PATH="$FAKEBIN:$BASE_PATH" "$EV" apply "$STATE" t1 busy \
    --gen "$gen" --source zcode-hook --event user-prompt-submit
  expect_code 0 $? "busy apply must succeed"
  PATH="$FAKEBIN:$BASE_PATH" "$EV" apply "$STATE" t1 idle \
    --gen "$gen" --source zcode-hook --event stop
  expect_code 0 $? "idle apply must succeed"
  [ "$(wc -l < "$CAPTURE")" -eq 3 ] || fail "expected arm+busy+idle reports, got $(wc -l < "$CAPTURE")"
  expected="pane report-agent w1:p7 --source firstmate --agent fm-t1 --state working --seq $(wire_seq "$gen" 2) --session fm-lab-x [HERDR_SESSION=fm-lab-x]"
  [ "$(sed -n 2p "$CAPTURE")" = "$expected" ] || fail "busy apply report mismatch: '$(sed -n 2p "$CAPTURE")'"
  expected="pane report-agent w1:p7 --source firstmate --agent fm-t1 --state idle --seq $(wire_seq "$gen" 3) --session fm-lab-x [HERDR_SESSION=fm-lab-x]"
  [ "$(sed -n 3p "$CAPTURE")" = "$expected" ] || fail "idle apply report mismatch: '$(sed -n 3p "$CAPTURE")'"
  pass "busy and idle applies thread the record seq into exact reports"
}

test_rearm_wire_seq_exceeds_prior_incarnation() {
  local rec gen last rearm
  rec=$(make_case rearm-monotonic)
  read_case "$rec"
  write_bridge_meta "$STATE" t1 herdr zcode 'fm-lab-x:w1:p7'
  gen=$(PATH="$FAKEBIN:$BASE_PATH" "$EV" arm "$STATE" t1 --harness zcode) || fail "arm failed"
  PATH="$FAKEBIN:$BASE_PATH" "$EV" apply "$STATE" t1 busy \
    --gen "$gen" --source zcode-hook --event user-prompt-submit || fail "busy apply failed"
  PATH="$FAKEBIN:$BASE_PATH" "$EV" apply "$STATE" t1 idle \
    --gen "$gen" --source zcode-hook --event stop || fail "idle apply failed"
  last=$(captured_seq "$(sed -n 3p "$CAPTURE")")
  # The relaunch shape: the record re-seeds at seq=1 into the same pane.
  wait_for_next_epoch_second "$gen"
  PATH="$FAKEBIN:$BASE_PATH" "$EV" arm "$STATE" t1 --harness zcode >/dev/null || fail "re-arm failed"
  assert_grep 'seq=1 state=busy source=fm-spawn event=launch-brief' "$STATE/t1.busy-state" \
    "the re-arm must re-seed the record at seq=1"
  rearm=$(captured_seq "$(sed -n 4p "$CAPTURE")")
  [ -n "$last" ] && [ -n "$rearm" ] || fail "could not read the captured wire seqs: $(bridge_calls "$CAPTURE")"
  [ "$rearm" -gt "$last" ] \
    || fail "a re-arm's wire seq ($rearm) must exceed the prior incarnation's last ($last); herdr drops a lower seq"
  pass "a re-arm at record seq 1 still reports a wire seq above the prior incarnation"
}

test_refused_apply_reports_nothing() {
  local rec gen before
  rec=$(make_case refused)
  read_case "$rec"
  write_bridge_meta "$STATE" t1 herdr zcode 'fm-lab-x:w1:p7'
  gen=$(PATH="$FAKEBIN:$BASE_PATH" "$EV" arm "$STATE" t1 --harness zcode) || fail "arm failed"
  before=$(bridge_calls "$CAPTURE")
  PATH="$FAKEBIN:$BASE_PATH" "$EV" apply "$STATE" t1 idle \
    --gen "stale.$gen" --source zcode-hook --event stop 2>/dev/null \
    && fail "a stale-gen apply must be refused"
  expect_code 1 $? "a stale-gen apply must keep the refused exit code"
  [ "$(bridge_calls "$CAPTURE")" = "$before" ] || fail "a refused apply reported to herdr"
  pass "a refused apply keeps exit code 1 and reports nothing"
}

test_unknown_apply_reports_nothing() {
  local rec gen before
  rec=$(make_case unknown)
  read_case "$rec"
  write_bridge_meta "$STATE" t1 herdr zcode 'fm-lab-x:w1:p7'
  gen=$(PATH="$FAKEBIN:$BASE_PATH" "$EV" arm "$STATE" t1 --harness zcode) || fail "arm failed"
  before=$(bridge_calls "$CAPTURE")
  PATH="$FAKEBIN:$BASE_PATH" "$EV" apply "$STATE" t1 unknown \
    --gen "$gen" --source zcode-hook --event stop
  expect_code 0 $? "unknown apply must succeed"
  [ "$(bridge_calls "$CAPTURE")" = "$before" ] || fail "an unknown landing reported to herdr"
  pass "only busy and idle landings report; unknown stays silent"
}

test_tmux_backend_meta_reports_nothing() {
  local rec gen before
  rec=$(make_case tmux-scope)
  read_case "$rec"
  # tmux is the default backend: its meta records no backend= line at all.
  write_bridge_meta "$STATE" t1 '' zcode 'main:0.1'
  gen=$(PATH="$FAKEBIN:$BASE_PATH" "$EV" arm "$STATE" t1 --harness zcode) || fail "arm failed"
  before=$(bridge_calls "$CAPTURE")
  PATH="$FAKEBIN:$BASE_PATH" "$EV" apply "$STATE" t1 idle \
    --gen "$gen" --source zcode-hook --event stop
  expect_code 0 $? "tmux apply must succeed"
  [ "$(bridge_calls "$CAPTURE")" = "$before" ] || fail "a tmux task was reported to herdr"
  pass "a tmux-backend zcode task keeps today's behavior and reports nothing"
}

test_herdr_backend_claude_harness_reports_nothing() {
  local rec gen before
  rec=$(make_case claude-scope)
  read_case "$rec"
  write_bridge_meta "$STATE" t1 herdr claude 'fm-lab-x:w1:p7'
  gen=$(PATH="$FAKEBIN:$BASE_PATH" "$EV" arm "$STATE" t1 --harness claude) || fail "arm failed"
  before=$(bridge_calls "$CAPTURE")
  PATH="$FAKEBIN:$BASE_PATH" "$EV" apply "$STATE" t1 idle \
    --gen "$gen" --source claude-hook --event stop
  expect_code 0 $? "claude apply must succeed"
  [ "$(bridge_calls "$CAPTURE")" = "$before" ] || fail "a claude task was reported to herdr"
  pass "a herdr-backend claude task reports nothing; herdr detects it natively"
}

test_missing_meta_and_unsplittable_window_report_nothing() {
  local rec gen before
  rec=$(make_case no-meta)
  read_case "$rec"
  gen=$(PATH="$FAKEBIN:$BASE_PATH" "$EV" arm "$STATE" t1 --harness zcode) || fail "arm without meta failed"
  [ "$(bridge_calls "$CAPTURE")" = '' ] || fail "arm without meta reported to herdr"
  # The production fresh-spawn shape: arm runs before the task record exists.
  write_bridge_meta "$STATE" t1 herdr zcode 'fm-lab-x:w1:p7'
  PATH="$FAKEBIN:$BASE_PATH" "$EV" apply "$STATE" t1 idle \
    --gen "$gen" --source zcode-hook --event stop
  expect_code 0 $? "apply with late meta must succeed"
  [ "$(bridge_calls "$CAPTURE")" = "$(printf '%s\n' \
    "pane report-agent w1:p7 --source firstmate --agent fm-t1 --state idle --seq $(wire_seq "$gen" 2) --session fm-lab-x [HERDR_SESSION=fm-lab-x]")" ] \
    || fail "the first apply after a late meta must report exactly: '$(bridge_calls "$CAPTURE")'"
  # A window= with no colon has no session or pane part to bind.
  rec=$(make_case no-colon)
  read_case "$rec"
  write_bridge_meta "$STATE" t2 herdr zcode barewindow
  gen=$(PATH="$FAKEBIN:$BASE_PATH" "$EV" arm "$STATE" t2 --harness zcode) || fail "arm failed"
  before=$(bridge_calls "$CAPTURE")
  PATH="$FAKEBIN:$BASE_PATH" "$EV" apply "$STATE" t2 idle \
    --gen "$gen" --source zcode-hook --event stop
  expect_code 0 $? "apply with colon-less window must succeed"
  [ "$(bridge_calls "$CAPTURE")" = "$before" ] || fail "a colon-less window reported to herdr"
  pass "a missing meta and an unsplittable window are silent no-ops"
}

test_apply_succeeds_without_herdr_on_path() {
  local rec gen sans_path
  rec=$(make_case no-herdr)
  read_case "$rec"
  write_bridge_meta "$STATE" t1 herdr zcode 'fm-lab-x:w1:p7'
  sans_path=$(fm_test_base_path_sans "$BASE_PATH" herdr)
  gen=$(PATH="$sans_path" "$EV" arm "$STATE" t1 --harness zcode)
  expect_code 0 $? "arm without herdr must succeed"
  case "$gen" in
    g[0-9]*) : ;;
    *) fail "arm without herdr must still print the bare gen, got '$gen'" ;;
  esac
  PATH="$sans_path" "$EV" apply "$STATE" t1 idle \
    --gen "$gen" --source zcode-hook --event stop
  expect_code 0 $? "apply without herdr must succeed"
  assert_grep 'seq=2 state=idle source=zcode-hook event=stop' "$STATE/t1.busy-state" \
    "the busy record must keep its exact semantics without herdr"
  pass "a missing herdr on PATH is a silent no-op and the writer contract stands"
}

test_report_failure_is_silent_noop() {
  local rec gen
  rec=$(make_case report-fails)
  read_case "$rec"
  write_bridge_meta "$STATE" t1 herdr zcode 'fm-lab-x:w1:p7'
  gen=$(FAKE_HERDR_EXIT=1 PATH="$FAKEBIN:$BASE_PATH" "$EV" arm "$STATE" t1 --harness zcode) || fail "arm failed"
  FAKE_HERDR_EXIT=1 PATH="$FAKEBIN:$BASE_PATH" "$EV" apply "$STATE" t1 idle \
    --gen "$gen" --source zcode-hook --event stop
  expect_code 0 $? "a failing herdr report must not fail the apply"
  [ "$(wc -l < "$CAPTURE")" -eq 2 ] || fail "the report attempt itself is still observable"
  assert_grep 'seq=2 state=idle source=zcode-hook event=stop' "$STATE/t1.busy-state" \
    "the busy record must be written even when the report fails"
  pass "a failing herdr report is a silent no-op with the exit-code contract intact"
}

test_arm_reports_working_at_seq1_routed_by_recorded_session
test_report_ignores_inherited_session_env
test_arm_reports_only_for_the_armed_zcode_harness
test_apply_flips_thread_seq
test_rearm_wire_seq_exceeds_prior_incarnation
test_refused_apply_reports_nothing
test_unknown_apply_reports_nothing
test_tmux_backend_meta_reports_nothing
test_herdr_backend_claude_harness_reports_nothing
test_missing_meta_and_unsplittable_window_report_nothing
test_apply_succeeds_without_herdr_on_path
test_report_failure_is_silent_noop

echo "all fm-zcode-herdr-bridge tests passed"
