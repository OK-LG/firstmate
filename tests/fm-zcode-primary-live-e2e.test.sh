#!/usr/bin/env bash
# Live guard for the zcode PRIMARY session role: inside a real zcode session,
# firstmate's own-harness detection resolves zcode from the real ancestry, and
# the fleet lock is acquired naming the session's zcode engine pid.
# Opt-in because it submits a real model prompt against the GLM Coding Plan
# credential (no echo provider exists for zcode).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZCODE_BIN=$(command -v zcode 2>/dev/null || true)
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
REAL_JQ=$(command -v jq 2>/dev/null || true)
SOCKET="fm-zcode-primary-$$"
LAB=

cleanup() {
  [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -z "$LAB" ] || rm -rf -- "$LAB"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  cleanup
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

fm_live_gate opt-in FM_ZCODE_PRIMARY_LIVE zcode tmux
[ -n "$ZCODE_BIN" ] || fail "zcode is not installed"
[ -n "$REAL_JQ" ] || fail "jq is not installed"
[ -d "$HOME/.zcode/cli" ] || fail "no ~/.zcode/cli to stage for the throwaway zcode HOME"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-zcode-primary.XXXXXX") || fail "could not create the isolated zcode lab"
trap cleanup EXIT
ZHOME="$LAB/home"
FM_HOME_LAB="$LAB/fm-home"
mkdir -p "$ZHOME" "$FM_HOME_LAB" "$LAB/workspace"
# The whole ~/.zcode tree is staged into the throwaway HOME so the credential
# store and the session db land in the lab, never the operator's real one.
cp -R "$HOME/.zcode" "$ZHOME/.zcode" || fail "could not stage the zcode config copy"
WORKSPACE=$(cd "$LAB/workspace" && pwd -P) || fail "could not resolve the isolated workspace"

# The real zcode turn: launched through a real tmux pane under a real TTY. The
# prompt drives the model to run firstmate's own detection and lock acquisition
# from ITS OWN tool shell, so the ancestry walk this guard exists to prove is
# exercised from exactly the vantage point a live primary session occupies.
"$REAL_TMUX" -L "$SOCKET" new-session -d -s zcode-primary -n zcode -c "$WORKSPACE" \
  || fail "could not start the isolated tmux server"
TARGET=zcode-primary:zcode
PROMPT="Run these three exact shell commands one after another and reply with only their exact output lines, nothing else: 1) $ROOT/bin/fm-harness.sh 2) FM_HOME=$FM_HOME_LAB $ROOT/bin/fm-lock.sh 3) FM_HOME=$FM_HOME_LAB $ROOT/bin/fm-lock.sh status"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "HOME=\"$ZHOME\" $ZCODE_BIN --mode yolo --cwd '$WORKSPACE' --prompt '$PROMPT'" \
  || fail "could not type the zcode launch line"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the zcode launch line"

capture() {
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" -S -80 2>/dev/null || true
}

reply=
for _ in $(seq 1 240); do
  screen=$(capture)
  case "$screen" in
    *"lock acquired: harness pid"*|*"cannot locate harness process"*)
      reply=$screen
      break
      ;;
    *"Error"*|*"not configured"*)
      printf '%s\n' "$screen" | tail -5 >&2
      fail "the real zcode turn errored instead of answering"
      ;;
  esac
  sleep 1
done
[ -n "$reply" ] || fail "the real zcode session never reported a lock verdict"

# Detection from inside the session: the real ancestry resolves zcode.
printf '%s\n' "$reply" | grep -qx 'zcode' \
  || fail "fm-harness.sh did not detect zcode from inside the real session: $(printf '%s\n' "$reply" | tail -8)"

# Lock acquisition from inside the session: the lab home's lock names the
# session's own engine pid.
[ -s "$FM_HOME_LAB/state/.lock" ] || fail "the real session did not write the lab fleet lock"
LOCK_PID=$(tr -d '[:space:]' < "$FM_HOME_LAB/state/.lock")
case "$LOCK_PID" in
  ''|*[!0-9]*) fail "the recorded lock holder is not a pid: '$LOCK_PID'" ;;
esac
printf '%s\n' "$reply" | grep -q "lock acquired: harness pid $LOCK_PID" \
  || fail "the session reported a lock verdict that does not name the recorded holder: $(printf '%s\n' "$reply" | tail -8)"

# Lock verification from inside the same live session: status must read the
# holder as a live harness, never as stale, because a stale read would make
# every later session start in this shape refuse the fleet. This runs in the
# session (command 3 above), so it races nothing in this test process.
printf '%s\n' "$reply" | grep -q "lock: held by live harness pid $LOCK_PID" \
  || fail "in-session lock status did not verify the live zcode holder: $(printf '%s\n' "$reply" | tail -8)"

# The recorded holder really is a zcode engine process. The headless one-shot
# may already have exited by the time this runs, in which case the in-session
# status line above is the live-proof authority; when it is still alive, the
# kernel comm must be one of the anchored zcode engine names (the node
# launcher shape is claimed only through the structural argv rule).
if LOCK_COMM=$(ps -o comm= -p "$LOCK_PID" 2>/dev/null); then
  case "$LOCK_COMM" in
    zcode|zcode-cli) : ;;
    node)
      LOCK_ARGS=$(ps -o args= -p "$LOCK_PID" 2>/dev/null)
      # shellcheck source=/dev/null
      . "$ROOT/bin/fm-agent-process-lib.sh"
      fm_zcode_args_are_zcode "$LOCK_ARGS" \
        || fail "the lock holder is a node process that is not the zcode launcher: $LOCK_ARGS"
      ;;
    *)
      fail "the lock holder pid $LOCK_PID is comm '$LOCK_COMM', not a zcode engine process"
      ;;
  esac
fi

pass "a real zcode session detects itself, acquires the fleet lock naming its engine pid, and verifies the holder live"
