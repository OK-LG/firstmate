#!/usr/bin/env bash
# Manual live scenarios for the zcode->herdr agent-view bridge, driven against
# the REAL Herdr 0.9.0 binary on an isolated fm-lab- session and the REAL
# zcode headless CLI (staged throwaway HOME, real GLM credential).
set -u
ROOT=${ROOT:?worktree root}
EVID=${EVID:?evidence dir}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

# shellcheck source=/dev/null
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
HERDR_VERSION=$(herdr --version 2>&1 | head -1)

SESSION="fm-lab-zbridge-nm-$$"
export HERDR_SESSION="$SESSION"
cleanup_all() {
  local status=$?
  herdr_safe_stop_and_delete "$SESSION"
  exit "$status"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"
lab() { fm_herdr_lab_cli "$SESSION" "$@"; }
fm_backend_herdr_server_ensure "$SESSION" || fail "could not start the lab server"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-zbridge-nm.XXXXXX"); LAB=$(cd "$LAB" && pwd)
mkdir -p "$LAB/state" "$LAB/workspace"
WORKSPACE=$(cd "$LAB/workspace" && pwd -P)

WS=$(lab workspace create --label fm-zbridge-nm --cwd "$WORKSPACE") || fail "workspace create failed"
TAB1=$(printf '%s' "$WS" | jq -er '.result.tab.tab_id')
PANE1=$(printf '%s' "$WS" | jq -er '.result.root_pane.pane_id')
WSID=$(printf '%s' "$WS" | jq -er '.result.workspace.workspace_id')
T2=$(lab tab create --workspace "$WSID" --cwd "$WORKSPACE" --label seqprobe --no-focus) || fail "tab2 create failed"
PANE2=$(printf '%s' "$T2" | jq -er '.result.root_pane.pane_id // .result.pane.pane_id')
T3=$(lab tab create --workspace "$WSID" --cwd "$WORKSPACE" --label switchprobe --no-focus) || fail "tab3 create failed"
PANE3=$(printf '%s' "$T3" | jq -er '.result.root_pane.pane_id // .result.pane.pane_id')

status_of() { lab agent get "$1" 2>/dev/null | jq -r '.result.agent.agent_status // empty'; }
# herdr 0.9.0 surfaces an idle report on an UNFOCUSED pane as agent_status=done
# (observed live; the repo's classifiers treat idle|done|blocked alike).
idle_like() { case "$1" in idle|done) return 0 ;; esac; return 1; }
settle_idle() { local i s; for i in $(seq 1 30); do s=$(status_of "$1"); idle_like "$s" && { echo "$s"; return 0; }; sleep 0.1; done; echo "$s"; return 1; }
code_of() { lab agent get "$1" 2>&1 | jq -r '.error.code // empty'; }
bridge() { env -u HERDR_SESSION -u HERDR_SOCKET_PATH "$ROOT/bin/fm-busy-event.sh" "$@"; }

# ---------------------------------------------------------------------------
note "SCENARIO A: herdr $HERDR_VERSION drops a report whose seq is not above the last it saw (raw vendor fact)"
lab pane report-agent "$PANE2" --source firstmate --agent fm-seqprobe --state working --seq 5 >/dev/null || fail "seq 5 report failed"
[ "$(status_of "$PANE2")" = working ] || fail "seq 5 working not bound"
lab pane report-agent "$PANE2" --source firstmate --agent fm-seqprobe --state idle --seq 2 >/dev/null || fail "seq 2 report errored (expected silent accept)"
S=$(status_of "$PANE2")
[ "$S" = working ] || fail "a lower seq (2 after 5) was NOT dropped: status=$S"
lab pane report-agent "$PANE2" --source firstmate --agent fm-seqprobe --state idle --seq 5 >/dev/null || fail "seq 5 idle report errored"
S=$(status_of "$PANE2")
[ "$S" = working ] || fail "an equal seq (5 after 5) was NOT dropped: status=$S"
lab pane report-agent "$PANE2" --source firstmate --agent fm-seqprobe --state idle --seq 6 >/dev/null || fail "seq 6 report errored"
S=$(settle_idle "$PANE2") || fail "seq 6 idle not applied: status=$S"
pass "A: herdr $HERDR_VERSION silently drops seq<=last (2 and 5 after 5 left working) and applies seq 6 (unfocused pane reads '$S'); the monotonic wire seq is necessary"

# ---------------------------------------------------------------------------
note "SCENARIO B: relaunch harness switch - a herdr+zcode record armed for claude / no harness never reports; armed for zcode reports"
ID3=zcode-switch-probe
printf 'backend=herdr\nwindow=%s:%s\nendpoint_task_id=%s\nharness=zcode\n' "$SESSION" "$PANE3" "$ID3" > "$LAB/state/$ID3.meta"
G=$(bridge arm "$LAB/state" "$ID3" --harness claude) || fail "arm --harness claude failed"
[ "$(code_of "$PANE3")" = agent_not_found ] || fail "arm --harness claude over a zcode record bound an agent: $(lab agent get "$PANE3")"
G=$(bridge arm "$LAB/state" "$ID3") || fail "bare arm failed"
[ "$(code_of "$PANE3")" = agent_not_found ] || fail "arm without --harness bound an agent"
# An apply under a zcode meta after a claude arm still reports (meta says zcode):
# that is the accepted apply rule; here we just prove the arm-time gate.
G=$(bridge arm "$LAB/state" "$ID3" --harness zcode) || fail "arm --harness zcode failed"
[ "$(status_of "$PANE3")" = working ] || fail "arm --harness zcode did not bind working"
[ "$(lab agent get "$PANE3" | jq -r .result.agent.agent)" = "fm-$ID3" ] || fail "wrong agent label"
pass "B: claude/no-harness arms over a zcode record leave the pane agent_not_found; the zcode arm binds fm-$ID3 working"

# ---------------------------------------------------------------------------
note "SCENARIO C: real zcode headless turn inside a herdr lab pane; the real Stop hook reports through the bridge (fresh-spawn shape)"
command -v zcode >/dev/null || fail "zcode not installed"
[ -d "$HOME/.zcode/cli" ] || fail "no ~/.zcode/cli to stage"
ZHOME="$LAB/home"; mkdir -p "$ZHOME"
cp -R "$HOME/.zcode" "$ZHOME/.zcode" || fail "could not stage ~/.zcode copy"
HOME="$ZHOME" "$ROOT/bin/fm-zcode-turnend-hook.sh" install || fail "hook install into the staged HOME failed"
STATE="$LAB/state"; ID=zcode-nm-live
# Fresh-spawn shape: arm BEFORE the meta exists -> no report at arm.
BUSY_GEN=$(bridge arm "$STATE" "$ID" --harness zcode) || fail "arm failed"
[ "$(code_of "$PANE1")" = agent_not_found ] || fail "arm before the meta exists must not report"
printf 'backend=herdr\nwindow=%s:%s\nendpoint_task_id=%s\nharness=zcode\nherdr_session=%s\nherdr_pane_id=%s\n' \
  "$SESSION" "$PANE1" "$ID" "$SESSION" "$PANE1" > "$STATE/$ID.meta"
AUTH_DIR="$ZHOME/.zcode/cli/fm-turn-end.d"
old_umask=$(umask); umask 077
auth_file=$(mktemp "$AUTH_DIR/fm.XXXXXXXXXXXX"); umask "$old_umask"
{
  printf 'state-dir=%s\n' "$STATE"; printf 'id=%s\n' "$ID"; printf 'gen=%s\n' "$BUSY_GEN"
  printf 'turn-ended=%s\n' "$STATE/$ID.turn-ended"; printf 'busy-event=%s\n' "$ROOT/bin/fm-busy-event.sh"
} > "$auth_file"
printf 'token=%s\n' "${auth_file##*/}" > "$WORKSPACE/.fm-zcode-turnend"

# HOME is staged so zcode's hook registry and credential copy live in the lab;
# herdr resolves its socket from the config dir, so the REAL config dir is
# pinned through XDG_CONFIG_HOME (a production worker keeps the real HOME and
# needs neither; this only keeps the staged-HOME lab faithful to that).
CMD=$(printf 'HOME=%q XDG_CONFIG_HOME=%q FM_ZCODE_HARNESS=zcode ZCODE_DISABLE_UPDATE_CHECK=1 zcode --mode yolo --cwd %q --prompt %q' \
  "$ZHOME" "$HOME/.config" "$WORKSPACE" 'Add 12345 and 67890. Reply with exactly the sum and nothing else')
lab pane run "$PANE1" "$CMD" >/dev/null || fail "could not run zcode in the lab pane"

saw_working=0; final=
for _ in $(seq 1 240); do
  s=$(status_of "$PANE1")
  [ "$s" = working ] && saw_working=1
  rec=$(cat "$STATE/$ID.busy-state" 2>/dev/null || true)
  case "$rec" in *"state=idle source=zcode-hook event=stop"*) final=$rec; break ;; esac
  sleep 0.5
done
[ -n "$final" ] || fail "the real Stop hook never closed the busy record; pane: $(lab pane read "$PANE1" 2>/dev/null | jq -r '.result.text // .result.output // empty' | tail -20)"
note "busy record after the real turn: $final"
sleep 1
AG=$(lab agent get "$PANE1") || fail "agent get failed after the turn: $AG"
printf '%s\n' "$AG" > "$EVID/scenario-c-agent-get.json"
[ "$(printf '%s' "$AG" | jq -r .result.agent.agent)" = "fm-$ID" ] || fail "agent label mismatch: $AG"
idle_like "$(printf '%s' "$AG" | jq -r .result.agent.agent_status)" || fail "agent not idle after Stop hook: $AG"
[ "$saw_working" = 1 ] && note "observed transient agent_status=working during the turn (UserPromptSubmit hook report)"
lab agent list > "$EVID/scenario-c-agent-list.json"
lab pane read "$PANE1" > "$EVID/scenario-c-pane-read.json" 2>/dev/null || true
grep -q '^session_id=sess_' "$STATE/$ID.zcode-session" || fail "hook did not record the zcode session id"
pass "C: real zcode turn in herdr pane $PANE1 -> real Stop hook -> bridge -> herdr lists fm-$ID idle (saw_working=$saw_working)"

# Default server must not have seen the label (misroute hazard).
if herdr status --json --session default 2>/dev/null | jq -e '.server.running == true' >/dev/null; then
  herdr agent list --session default | jq -e --arg l "fm-$ID" '[.result.agents[] | select(.agent == $l)] | length == 0' >/dev/null \
    || fail "fm-$ID leaked onto the default server"
  pass "C2: the default herdr server never saw fm-$ID"
fi

# ---------------------------------------------------------------------------
note "SCENARIO D: relaunch shape - re-arm into the same pane flips the agent back to working at record seq 1"
E=${BUSY_GEN#g}; E=${E%%.*}
while [ "$(date +%s)" -le "$E" ]; do sleep 0.2; done
G2=$(bridge arm "$STATE" "$ID" --harness zcode) || fail "re-arm failed"
grep -q "gen=$G2 seq=1 state=busy" "$STATE/$ID.busy-state" || fail "re-arm did not re-seed seq=1"
[ "$(status_of "$PANE1")" = working ] || fail "re-arm did not flip agent back to working: $(lab agent get "$PANE1")"
pass "D: re-arm (record seq 1 after the hook's seq 3) flipped fm-$ID back to working via the monotonic wire seq"

# ---------------------------------------------------------------------------
note "SCENARIO E: exit-code/record contract intact when herdr is absent from PATH"
G3=$(env -u HERDR_SESSION PATH=/usr/bin:/bin "$ROOT/bin/fm-busy-event.sh" arm "$STATE" "$ID" --harness zcode) || fail "arm without herdr failed"
env -u HERDR_SESSION PATH=/usr/bin:/bin "$ROOT/bin/fm-busy-event.sh" apply "$STATE" "$ID" idle --gen "$G3" --source zcode-hook --event stop || fail "apply without herdr failed"
grep -q "gen=$G3 seq=2 state=idle" "$STATE/$ID.busy-state" || fail "record wrong without herdr"
pass "E: without herdr on PATH the writer still arms/applies with exit 0 and the record intact"

lab tab close "$TAB1" >/dev/null 2>&1 || true
lab tab close "$(printf '%s' "$T2" | jq -r '.result.tab.tab_id')" >/dev/null 2>&1 || true
lab tab close "$(printf '%s' "$T3" | jq -r '.result.tab.tab_id')" >/dev/null 2>&1 || true
rm -rf "$LAB"
pass "all manual live scenarios passed on herdr $HERDR_VERSION"
