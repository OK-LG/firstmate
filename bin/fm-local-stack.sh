#!/usr/bin/env bash
# Lease one of this home's local website stack slots to a task, so a bounded
# number of workers can run a local stack side by side without port clashes.
#
# Usage:
#   fm-local-stack.sh run <task-id> -- <foreground-command> [args...]
#   fm-local-stack.sh acquire <task-id> [--wait <seconds>]
#   fm-local-stack.sh release <task-id>
#   fm-local-stack.sh status
#
# There are exactly two slots. run waits up to 300 seconds to acquire one,
# exports both port variables to the command, and releases it when that command
# exits. The command must keep its stack in the foreground and stop its services
# before returning; its launcher must apply the offset to every listening port.
# run requires task metadata and rejects another run for the same task. INT or
# TERM forwards TERM to its active allocator or command and waits for it before
# releasing any lease; the command remains responsible for stopping its services.
# acquire prints two shell assignments a worker can eval:
#   FM_LOCAL_STACK_SLOT=<n>               slot index, 0 or 1
#   FM_LOCAL_STACK_PORT_OFFSET=<n*stride> add to each of the stack's ports
# so slot 0 keeps the stack's default ports and slot n shifts every port by
# n * FM_LOCAL_STACK_PORT_STRIDE (whole number, default 10). Firstmate never
# knows a project's ports; the project's own stack script applies the offset.
# A task that already holds a slot gets the same slot again. With every slot
# held, acquire exits 3 naming the holders, or with --wait keeps retrying every
# FM_LOCAL_STACK_POLL_SECS (default 5) until <seconds> pass.
# A slot is state/local-stack/<n> holding its task id. It frees on release, and
# also once that task's state/<id>.meta is gone, so a cleaned-up task never
# keeps a slot. Every scan and claim runs under state/.local-stack.lock.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
case "${1:-}" in
  -h|--help) sed -n '5,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,3\}//'; exit 0 ;;
esac
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

SLOTS="$STATE/local-stack"
LOCK="$STATE/.local-stack.lock"

usage() {
  sed -n '5,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,3\}//'
}

die() {
  echo "error: $*" >&2
  exit 1
}

whole() {  # <value>
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 6 ]
}

lock_take() {
  mkdir -p "$SLOTS" || die "cannot create $SLOTS"
  fm_lock_acquire_wait_max "$LOCK" 30 || die "local-stack lock is busy"
}

lock_drop() {
  fm_lock_release "$LOCK" || true
}

slot_owner() {  # <n>
  local f="$SLOTS/$1"
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  head -1 "$f" 2>/dev/null
}

# Free when unclaimed or its owner's task record is gone.
slot_free() {  # <n>
  local owner
  owner=$(slot_owner "$1") || return 0
  fm_pr_task_id_valid "$owner" || return 0
  [ -f "$STATE/$owner.meta" ] && return 1
  return 0
}

print_slot() {  # <n>
  printf 'FM_LOCAL_STACK_SLOT=%s\nFM_LOCAL_STACK_PORT_OFFSET=%s\n' "$1" "$(($1 * STRIDE))"
}

# 0 printed a slot, 3 none free.
try_claim() {  # <task-id>
  local id=$1 n tmp
  for ((n = 0; n < LIMIT; n++)); do
    if [ "$(slot_owner "$n" 2>/dev/null || true)" = "$id" ]; then
      print_slot "$n"
      return 0
    fi
  done
  for ((n = 0; n < LIMIT; n++)); do
    slot_free "$n" || continue
    tmp=$(mktemp "$SLOTS/.claim.XXXXXX") || return 1
    if ! { printf '%s\n' "$id" > "$tmp" && mv -f -- "$tmp" "$SLOTS/$n"; }; then
      rm -f -- "$tmp"
      return 1
    fi
    print_slot "$n"
    return 0
  done
  return 3
}

holders() {
  local n out=''
  for ((n = 0; n < LIMIT; n++)); do
    out="$out slot $n=$(slot_owner "$n" 2>/dev/null || echo free)"
  done
  printf '%s\n' "${out# }"
}

cmd=${1:-}
case "$cmd" in
  run|acquire|release|status) shift ;;
  *) usage >&2; exit 2 ;;
esac

STRIDE=${FM_LOCAL_STACK_PORT_STRIDE:-10}
whole "$STRIDE" || die "FM_LOCAL_STACK_PORT_STRIDE must be a whole number, got '$STRIDE'"
STRIDE=$((10#$STRIDE))
POLL=${FM_LOCAL_STACK_POLL_SECS:-5}
whole "$POLL" && [ "$((10#$POLL))" -ge 1 ] || die "FM_LOCAL_STACK_POLL_SECS must be positive whole seconds"
LIMIT=2

case "$cmd" in
  run)
    if [ "$#" -lt 3 ] || ! fm_pr_task_id_valid "$1" || [ "$2" != -- ]; then usage >&2; exit 2; fi
    ID=$1
    shift 2
    [ -f "$STATE/$ID.meta" ] || die "task $ID has no metadata"
    RUN_LOCK="$STATE/.local-stack-$ID.run.lock"
    fm_lock_try_acquire "$RUN_LOCK" || die "task $ID already has a running stack command"
    RUN_PID= RUN_STOP=0 RUN_ASSIGNMENTS=
    cleanup_run() {
      FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" bash "$SCRIPT_DIR/fm-local-stack.sh" release "$ID" >/dev/null
      [ -z "$RUN_ASSIGNMENTS" ] || rm -f -- "$RUN_ASSIGNMENTS"
      fm_lock_release "$RUN_LOCK" || true
    }
    stop_run() {
      RUN_STOP=$1
      [ -n "$RUN_PID" ] || return 0
      trap '' INT TERM
      kill -TERM "$RUN_PID" 2>/dev/null || true
      wait "$RUN_PID" || true
      exit "$RUN_STOP"
    }
    run_child() {
      local child_rc=0
      [ "$RUN_STOP" -eq 0 ] || exit "$RUN_STOP"
      "$@" <&0 &
      RUN_PID=$!
      [ "$RUN_STOP" -eq 0 ] || stop_run "$RUN_STOP"
      wait "$RUN_PID" || child_rc=$?
      RUN_PID=
      return "$child_rc"
    }
    trap cleanup_run EXIT
    trap 'stop_run 130' INT
    trap 'stop_run 143' TERM
    RUN_ASSIGNMENTS=$(mktemp "$STATE/.local-stack-$ID.XXXXXX") || exit 1
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" run_child bash "$SCRIPT_DIR/fm-local-stack.sh" acquire "$ID" --wait 300 > "$RUN_ASSIGNMENTS" || exit "$?"
    assignments=$(cat "$RUN_ASSIGNMENTS") || exit 1
    eval "$assignments"
    export FM_LOCAL_STACK_SLOT FM_LOCAL_STACK_PORT_OFFSET
    run_child "$@"
    exit "$?"
    ;;
  status)
    [ "$#" -eq 0 ] || { usage >&2; exit 2; }
    lock_take
    printf 'limit=%s %s\n' "$LIMIT" "$(holders)"
    lock_drop
    ;;
  release)
    if [ "$#" -ne 1 ] || ! fm_pr_task_id_valid "$1"; then usage >&2; exit 2; fi
    lock_take
    for f in "$SLOTS"/*; do
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      [ "$(head -1 "$f" 2>/dev/null)" = "$1" ] || continue
      rm -f -- "$f"
      printf 'released: %s slot %s\n' "$1" "${f##*/}"
    done
    lock_drop
    ;;
  acquire)
    if [ "$#" -lt 1 ] || ! fm_pr_task_id_valid "$1"; then usage >&2; exit 2; fi
    ID=$1 WAIT=0
    shift
    if [ "$#" -gt 0 ]; then
      if [ "$#" -ne 2 ] || [ "$1" != --wait ] || ! whole "$2"; then usage >&2; exit 2; fi
      WAIT=$((10#$2))
    fi
    trap lock_drop EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    deadline=$((SECONDS + WAIT))
    while :; do
      lock_take
      rc=0
      try_claim "$ID" || rc=$?
      [ "$rc" -ne 3 ] || busy=$(holders)
      lock_drop
      [ "$rc" -eq 3 ] || exit "$rc"
      if [ "$SECONDS" -ge "$deadline" ]; then
        echo "busy: all $LIMIT local stack slots are held ($busy)" >&2
        exit 3
      fi
      sleep "$POLL"
    done
    ;;
esac
