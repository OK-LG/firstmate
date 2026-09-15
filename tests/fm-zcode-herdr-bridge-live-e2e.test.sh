#!/usr/bin/env bash
# Default-on live guard for the herdr agent-view bridge in bin/fm-busy-event.sh
# against the REAL Herdr binary.
#
# The bridge reports a herdr-backend zcode-harness task's busy/idle flips to
# herdr's reporting API so the worker appears in herdr's Agents view and its
# status tracks the busy record live. A fixture can only prove the argv we
# send; this guard proves the vendor half of the contract, which no fixture
# can prove:
#
#   1. a report-agent invocation issued from a shell with NO herdr
#      environment at all (the captain-side shape of `fm-spawn --relaunch`)
#      binds the agent on the recorded session's server through its
#      explicit --session flag, even while another herdr server (the
#      default one) is running,
#   2. `herdr agent list` and `herdr agent get` then list the worker, and the
#      arm (working) and apply (idle) flips arrive as real agent_status
#      transitions,
#   3. a re-arm into the SAME pane (the relaunch shape, record re-seeded at
#      seq=1) still flips the agent back to working. Herdr 0.9.0 orders
#      reports by seq per pane and silently drops a lower one (observed
#      2026-09-15: a raw seq=1 re-arm after seq=3 left the agent idle), which
#      is why the bridge puts gen-epoch * 1e9 + record-seq on the wire.
#
# It fails naming the Herdr version when either fact drifts. No model
# credential and no zcode process are involved: the busy events run the real
# bin/fm-busy-event.sh against a fixture meta and state dir, so the shared
# live gate runs it by default wherever herdr is installed. Run it after
# every Herdr upgrade and before trusting a refreshed
# docs/verification/runtime-backends.md entry.
#
# Always runs on a private, named, throwaway lab session, never the default
# one (tests/herdr-test-safety.sh; bin/fm-herdr-lab.sh owns the isolation),
# and closes the scratch tab before teardown.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

fm_live_gate default-on FM_ZCODE_HERDR_BRIDGE_LIVE_E2E herdr jq

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

HERDR_VERSION=$(herdr --version 2>&1 | head -1)
HERDR_VERSION=${HERDR_VERSION#herdr }
version_fail() {  # <message>
  fail "$1 [herdr $HERDR_VERSION]"
}

SESSION="fm-lab-zcode-bridge-$$"
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

# prepare only records the tripwire; the adapter's own server-ensure starts
# the lab session's server exactly as a spawn would.
fm_backend_herdr_server_ensure "$SESSION" || fail "could not start the isolated Herdr lab server"

# The scratch tab the fixture worker will be bound to.
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-zcode-bridge.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
mkdir -p "$SCRATCH/state"
WS=$(lab workspace create --label fm-zcode-bridge-live --cwd "$SCRATCH") \
  || fail "could not create the lab workspace"
TAB_ID=$(printf '%s' "$WS" | jq -er '.result.tab.tab_id // empty') \
  || fail "workspace create did not return a tab id"
PANE_ID=$(printf '%s' "$WS" | jq -er '.result.root_pane.pane_id // empty') \
  || fail "workspace create did not return a root pane id"

# The fixture task record exactly as a herdr-backed zcode spawn leaves it
# (docs/herdr-backend.md "Endpoint metadata"): window is <session>:<pane>.
ID=zcode-herdr-bridge-e2e
printf 'backend=herdr\nwindow=%s:%s\nendpoint_task_id=%s\nharness=zcode\n' \
  "$SESSION" "$PANE_ID" "$ID" > "$SCRATCH/state/$ID.meta"

# Captain-side environment: no herdr routing inherited at all, so the ONLY
# thing that can reach the lab server is the recorded session in the meta.
bridge() { env -u HERDR_SESSION -u HERDR_SOCKET_PATH "$ROOT/bin/fm-busy-event.sh" "$@"; }

agent_label() {
  lab agent list | jq -er --arg label "$1" \
    '[.result.agents[] | select(.agent == $label)] | if length == 1 then .[0] else empty end' \
    2>/dev/null
}
agent_status() {
  lab agent get "$PANE_ID" 2>/dev/null | jq -er '.result.agent.agent_status // empty'
}
default_session_active() {
  herdr status --json --session default 2>/dev/null \
    | jq -e '.server.running == true' >/dev/null 2>&1
}
default_session_lists_label() {
  herdr agent list --session default 2>/dev/null \
    | jq -e --arg label "fm-$ID" '[.result.agents[] | select(.agent == $label)] | length == 0' \
    >/dev/null 2>&1
}

GEN=$(bridge arm "$SCRATCH/state" "$ID" --harness zcode) \
  || version_fail "real arm against the fixture failed"
RECORD=$(cat "$SCRATCH/state/$ID.busy-state")
case "$RECORD" in
  *"gen=$GEN seq=1 state=busy source=fm-spawn event=launch-brief"*) : ;;
  *) version_fail "arm wrote an unexpected record: $RECORD" ;;
esac

AGENT=$(agent_label "fm-$ID") \
  || version_fail "herdr agent list does not list fm-$ID after the arm report; got: $(lab agent list 2>&1 | tr -d '\n' | head -c 400)"
[ "$(printf '%s' "$AGENT" | jq -r .agent_status)" = working ] \
  || version_fail "the arm report must bind agent_status working, got '$(printf '%s' "$AGENT" | jq -r .agent_status)'"
[ "$(printf '%s' "$AGENT" | jq -r .pane_id)" = "$PANE_ID" ] \
  || version_fail "the agent bound pane $(printf '%s' "$AGENT" | jq -r .pane_id) rather than the fixture pane $PANE_ID"
# Routing proof where the hazard actually exists: while another herdr server
# is running, the env-less report must still land on the recorded session's
# server, never the default one.
if default_session_active; then
  default_session_lists_label \
    || version_fail "the default session's agent list shows fm-$ID; the --session-routed report landed on the wrong server"
fi

bridge apply "$SCRATCH/state" "$ID" idle \
  --gen "$GEN" --source zcode-hook --event stop \
  || version_fail "real idle apply against the fixture failed"
STATUS=$(agent_status)
[ "$STATUS" = idle ] \
  || version_fail "the idle apply must flip agent_status to idle, got '${STATUS:-agent_not_found}'"

# Relaunch shape: a second arm into the SAME pane re-seeds the record at
# seq=1 while herdr has already seen three reports for this pane/source/agent.
# Herdr 0.9.0 drops a report whose seq is not above the last one it saw, so
# the re-arm's working report only lands through the monotonic wire seq; the
# next epoch second guarantees the new gen's epoch exceeds the old one.
bridge apply "$SCRATCH/state" "$ID" busy \
  --gen "$GEN" --source zcode-hook --event user-prompt-submit \
  || version_fail "real busy apply against the fixture failed"
bridge apply "$SCRATCH/state" "$ID" idle \
  --gen "$GEN" --source zcode-hook --event stop \
  || version_fail "second real idle apply against the fixture failed"
[ "$(agent_status)" = idle ] \
  || version_fail "the pane must read idle before the re-arm"
ARM_EPOCH=${GEN#g}
ARM_EPOCH=${ARM_EPOCH%%.*}
while [ "$(date +%s)" -le "$ARM_EPOCH" ]; do sleep 0.2; done
GEN2=$(bridge arm "$SCRATCH/state" "$ID" --harness zcode) \
  || version_fail "real re-arm against the fixture failed"
[ "$GEN2" != "$GEN" ] || version_fail "the re-arm must mint a fresh gen"
case "$(cat "$SCRATCH/state/$ID.busy-state")" in
  *"gen=$GEN2 seq=1 state=busy source=fm-spawn event=launch-brief"*) : ;;
  *) version_fail "the re-arm did not re-seed the record at seq=1: $(cat "$SCRATCH/state/$ID.busy-state")" ;;
esac
STATUS=$(agent_status)
[ "$STATUS" = working ] \
  || version_fail "the re-arm's report (record seq 1 after 3) must flip agent_status back to working, got '${STATUS:-agent_not_found}'; the wire seq no longer outruns herdr's per-pane ordering"
note "herdr $HERDR_VERSION: fm-$ID bound on $PANE_ID, flipped working->idle through the real busy record, and a re-arm at record seq 1 after 3 read working again"

# Close the scratch tab; the lab teardown tripwire then verifies the default
# session was never touched.
lab tab close "$TAB_ID" >/dev/null 2>&1 \
  || fail "could not close the scratch tab"
pass "real herdr $HERDR_VERSION: the busy-record bridge binds the agent and tracks its flips live"
