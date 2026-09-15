#!/usr/bin/env bash
# Live drift guard for the zcode adapter's vendor-controlled surface: the
# headless hook events (UserPromptSubmit/Stop payloads and firing), the kernel
# process names, the session-id record, the resume contract, and the
# error-path exit codes.
# Opt-in because it submits a real model prompt against the GLM Coding Plan
# credential (no echo provider exists for zcode).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZCODE_BIN=$(command -v zcode 2>/dev/null || true)
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
REAL_JQ=$(command -v jq 2>/dev/null || true)
LAB=
SOCKET="fm-zcode-signals-$$"

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

fm_live_gate opt-in FM_ZCODE_SIGNALS_LIVE zcode tmux
[ -n "$ZCODE_BIN" ] || fail "zcode is not installed"
[ -n "$REAL_JQ" ] || fail "jq is not installed"
[ -d "$HOME/.zcode/cli" ] || fail "no ~/.zcode/cli to stage for the throwaway zcode HOME"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-zcode-signals.XXXXXX") || fail "could not create the isolated zcode lab"
trap cleanup EXIT
ZHOME="$LAB/home"
mkdir -p "$ZHOME" "$LAB/workspace"
# The whole ~/.zcode tree is staged into the throwaway HOME so the credential
# store, the session db, and every hook write land in the lab, never the
# operator's real one.
cp -R "$HOME/.zcode" "$ZHOME/.zcode" || fail "could not stage the zcode config copy"
WORKSPACE=$(cd "$LAB/workspace" && pwd -P) || fail "could not resolve the isolated workspace"

# The guarded global hook install this guard exists to prove: the installer
# must accept the real staged config, and its removal must restore every
# hooks leaf semantically (gate value and present-but-empty event keys
# included) - the fidelity the install-state record exists for.
HOOKS_BEFORE=$("$REAL_JQ" -S '.hooks' "$ZHOME/.zcode/cli/config.json") \
  || fail "could not snapshot the staged config's hooks subtree"
HOME="$ZHOME" "$ROOT/bin/fm-zcode-turnend-hook.sh" install \
  || fail "the hook installer refused the staged real zcode config"
"$REAL_JQ" -e '.hooks.enabled == true and (.hooks.events.UserPromptSubmit | length) >= 1 and (.hooks.events.Stop | length) >= 1' \
  "$ZHOME/.zcode/cli/config.json" >/dev/null \
  || fail "the installed config did not gain the enabled hook gate and both owned entries"

# Arm the busy contract and the token exactly the way fm-spawn does, against a
# lab state dir, so the hook's live fire is proven against real wiring.
STATE="$LAB/state"
ID=zcode-signals-live
mkdir -p "$STATE"
BUSY_GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" "$ID") \
  || fail "could not arm the lab busy contract"
AUTH_DIR="$ZHOME/.zcode/cli/fm-turn-end.d"
old_umask=$(umask)
umask 077
auth_file=$(mktemp "$AUTH_DIR/fm.XXXXXXXXXXXX")
umask "$old_umask"
{
  printf 'state-dir=%s\n' "$STATE"
  printf 'id=%s\n' "$ID"
  printf 'gen=%s\n' "$BUSY_GEN"
  printf 'turn-ended=%s\n' "$STATE/$ID.turn-ended"
  printf 'busy-event=%s\n' "$ROOT/bin/fm-busy-event.sh"
} > "$auth_file"
printf 'token=%s\n' "${auth_file##*/}" > "$WORKSPACE/.fm-zcode-turnend"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-agent-process-lib.sh"

# The real headless turn: launched through the real tmux pane so the process
# runs under a real TTY the way a dispatched worker does. A background sampler
# records kernel comm values from /proc while the turn is in flight.
"$REAL_TMUX" -L "$SOCKET" new-session -d -s zcode-signals -n zcode -c "$WORKSPACE" \
  || fail "could not start the isolated tmux server"
TARGET=zcode-signals:zcode
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "HOME=\"$ZHOME\" $ZCODE_BIN --mode yolo --cwd '$WORKSPACE' --prompt 'Add 12345 and 67890. Reply with exactly the sum and nothing else'" \
  || fail "could not type the zcode launch line"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the zcode launch line"

: > "$LAB/comms.log"
(
  deadline=$((SECONDS + 120))
  while [ "$SECONDS" -lt "$deadline" ]; do
    for pid in $(pgrep -f "zcode.*--cwd $WORKSPACE" 2>/dev/null; pgrep -x zcode-cli 2>/dev/null); do
      [ -r "/proc/$pid/comm" ] && printf '%s\n' "$(cat "/proc/$pid/comm" 2>/dev/null)" >> "$LAB/comms.log"
    done
    sleep 0.3
  done
) &
SAMPLER=$!

capture() {
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" -S -60 2>/dev/null || true
}

reply=
for _ in $(seq 1 240); do
  screen=$(capture)
  case "$screen" in
    *80235*|*80,235*)
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
[ -n "$reply" ] || fail "the real zcode worker never answered its launch prompt"
pass "the real zcode worker processed its headless launch prompt"

kill "$SAMPLER" 2>/dev/null || true
wait "$SAMPLER" 2>/dev/null || true

# The hook pair fired against the real wiring: the Stop event closed the busy
# record through zcode-hook, touched the turn-end marker, and recorded the
# session id from the payload.
verdict=$(fm_busy_classify tmux "$TARGET" zcode "$ID" "$STATE" '')
[ "$verdict" = "idle zcode-hook" ] \
  || fail "the live Stop hook did not close the busy record through zcode-hook, got '$verdict'"
pass "the live Stop hook closed the busy record through zcode-hook"

[ -f "$STATE/$ID.turn-ended" ] \
  || fail "the live Stop hook did not touch the turn-end marker"
grep -q '^session_id=sess_' "$STATE/$ID.zcode-session" \
  || fail "the live hook did not record the zcode session id"
SESSION_ID=$(sed -n 's/^session_id=//p' "$STATE/$ID.zcode-session")

# Kernel process-name truth: the runtime child's comm is zcode-cli (verified
# set in bin/fm-agent-process-lib.sh); ps --forest artifacts are not names.
grep -qx 'zcode-cli' "$LAB/comms.log" \
  || fail "the sampled kernel comms never contained zcode-cli: $(sort -u "$LAB/comms.log" | tr '\n' ' ')"
[ "$(fm_agent_process_classify_name zcode-cli)" = agent ] \
  || fail "the classifier stopped accepting the live kernel name zcode-cli"

# The resume contract end to end: the recorded session id must restore context
# in a second headless run (verified shape: --resume <id> --prompt).
resume_out=$(cd "$WORKSPACE" && HOME="$ZHOME" timeout 120 "$ZCODE_BIN" --mode yolo \
  --cwd "$WORKSPACE" --resume "$SESSION_ID" \
  --prompt 'What two numbers did you just add? Reply with only the first one.' 2>&1 | tail -3)
case "$resume_out" in
  *12345*|*"12,345"*) pass "the recorded session id restores context through --resume" ;;
  *)
    printf '%s\n' "$resume_out" >&2
    fail "the resumed session did not recall its prior context"
    ;;
esac

# The error-path exit codes, re-pinned because the Phase B record shipped
# them wrong until the 2026-09-15 review correction: CLI-parse and
# unresumable-session errors exit 1 with their error on stderr (and the help
# dump of a rejected option goes to stderr too), while --help exits 0 on
# stdout. The supervisor-side blindness posture (never trust exit status)
# stands on policy - the record itself has flipped across probes, which is
# exactly what a wrapped proprietary runtime's vendor surface can do.
HOME="$ZHOME" "$ZCODE_BIN" --effort x --prompt hi >/dev/null 2>"$LAB/flag-err"; rc=$?
[ "$rc" -eq 1 ] || fail "an unknown option must exit 1, got $rc"
grep -q "Unknown option '--effort'" "$LAB/flag-err" \
  || fail "the unknown-option error must print to stderr"
HOME="$ZHOME" "$ZCODE_BIN" --mode yolo --cwd "$WORKSPACE" \
  --resume sess_guardneverexists0000 --prompt hi >/dev/null 2>"$LAB/resume-err"; rc=$?
[ "$rc" -eq 1 ] || fail "an unresumable session must exit 1, got $rc"
grep -q "Session not found" "$LAB/resume-err" \
  || fail "the unresumable-session error must print to stderr"
HOME="$ZHOME" "$ZCODE_BIN" --help >"$LAB/help-out" 2>/dev/null; rc=$?
[ "$rc" -eq 0 ] || fail "--help must exit 0, got $rc"
[ -s "$LAB/help-out" ] || fail "--help output belongs on stdout"
pass "the error-path exit codes stay pinned: option and resume errors exit 1 on stderr, --help exits 0"

# The credential-error paths, re-pinned credential-less: against a key-stripped
# copy of the staged config (and no ZCODE_API_KEY for the first probe, a dummy
# key for the second) both failures are local and burn no credential - the
# research-era record had claimed exit-0 failures here and was corrected by
# re-measurement on 2026-09-15.
NOKEY_HOME="$LAB/nokey-home"
mkdir -p "$NOKEY_HOME"
cp -R "$ZHOME/.zcode" "$NOKEY_HOME/.zcode"
"$REAL_JQ" 'del(.provider.zai.options.apiKey)' "$NOKEY_HOME/.zcode/cli/config.json" \
  > "$LAB/nokey-config.json" || fail "could not strip the staged key for the credential-less probe"
cp "$LAB/nokey-config.json" "$NOKEY_HOME/.zcode/cli/config.json"
env -u ZCODE_API_KEY HOME="$NOKEY_HOME" "$ZCODE_BIN" -p "reply pong" >/dev/null 2>"$LAB/nokey-err"; rc=$?
[ "$rc" -eq 1 ] || fail "the not-configured refusal must exit 1, got $rc"
grep -q "Model access is not configured" "$LAB/nokey-err" \
  || fail "the not-configured refusal must print to stderr"
HOME="$NOKEY_HOME" ZCODE_API_KEY=dummy "$ZCODE_BIN" -p "reply pong" >/dev/null 2>"$LAB/signing-err"; rc=$?
[ "$rc" -eq 1 ] || fail "the request-signing error must exit 1, got $rc"
grep -q "ClientRequestSigningV4Error" "$LAB/signing-err" \
  || fail "the request-signing error must print to stderr"
pass "the credential-error paths stay pinned: not-configured and signing errors exit 1 on stderr"

# Removal restores the staged config's hooks subtree semantically exactly.
HOME="$ZHOME" "$ROOT/bin/fm-zcode-turnend-hook.sh" remove \
  || fail "the hook remover refused the staged config"
[ "$("$REAL_JQ" -S '.hooks' "$ZHOME/.zcode/cli/config.json")" = "$HOOKS_BEFORE" ] \
  || fail "removal did not restore the staged config's hooks subtree exactly"
[ ! -e "$ZHOME/.zcode/cli/fm-turn-end.state" ] \
  || fail "removal left the install-state record"

pass "all fm-zcode-signals live checks passed"
