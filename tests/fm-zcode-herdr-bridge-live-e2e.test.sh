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
#   1. a report-agent invocation carrying only the pane-side environment a
#      real herdr-hosted worker is launched with (HERDR_SESSION plus
#      HERDR_SOCKET_PATH, no --session flag) binds the agent on the right
#      server even while another herdr server (the default one) is running,
#   2. `herdr agent list` and `herdr agent get` then list the worker, and the
#      arm (working) and apply (idle) flips arrive as real agent_status
#      transitions, with the fixture's recorded --agent-session-id riding the
#      wire (herdr 0.9.0 accepts the flag without surfacing it in the views).
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
LAB_SOCKET=$(lab status --json | jq -er '.server.socket // empty') \
  || fail "could not read the lab server socket path"

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
printf 'session_id=sess_zcode_bridge_live_probe\n' > "$SCRATCH/state/$ID.zcode-session"

# Pane-side environment: what herdr injects into a real worker's processes
# (herdr-test-safety.sh), and the ONLY routing the bridge's bare herdr call has.
declare -a BRIDGE_ENV=(HERDR_SESSION="$SESSION" HERDR_SOCKET_PATH="$LAB_SOCKET")

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

GEN=$(env "${BRIDGE_ENV[@]}" "$ROOT/bin/fm-busy-event.sh" arm "$SCRATCH/state" "$ID") \
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
# The arm report rides --agent-session-id (the fixture sidecar holds one), so
# this binding also proves the flag is accepted on the wire. Herdr 0.9.0 does
# not surface the id back through agent list/get (verified: the record's keys
# are agent, agent_status, cwd, focused, foreground_cwd, pane_id, revision,
# state_change_seq, tab_id, terminal_id, terminal_title, terminal_title_stripped,
# workspace_id), so the exact invocation itself is pinned by the portable
# tests/fm-zcode-herdr-bridge.test.sh instead of here.
# Scoping proof where the hazard actually exists: while another herdr server
# is running, the env-routed report must still land on the worker's own
# server, never the default one.
if default_session_active; then
  default_session_lists_label \
    || version_fail "the default session's agent list shows fm-$ID; the pane-side report routed to the wrong server"
fi

env "${BRIDGE_ENV[@]}" "$ROOT/bin/fm-busy-event.sh" apply "$SCRATCH/state" "$ID" idle \
  --gen "$GEN" --source zcode-hook --event stop \
  || version_fail "real idle apply against the fixture failed"
STATUS=$(agent_status)
[ "$STATUS" = idle ] \
  || version_fail "the idle apply must flip agent_status to idle, got '${STATUS:-agent_not_found}'"
note "herdr $HERDR_VERSION: fm-$ID bound on $PANE_ID, flipped working->idle through the real busy record"

# Close the scratch tab; the lab teardown tripwire then verifies the default
# session was never touched.
lab tab close "$TAB_ID" >/dev/null 2>&1 \
  || fail "could not close the scratch tab"
pass "real herdr $HERDR_VERSION: the busy-record bridge binds the agent and tracks its flips live"
