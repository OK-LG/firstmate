#!/usr/bin/env bash
# fm-busy-event.sh - the ONLY writer of the semantic busy-state contract
# owned by bin/fm-busy-lib.sh (record format, gen binding, and classification
# live there; this script owns mutation mechanics only).
#
# Subcommands:
#
#   arm <state-dir> <id> [--state busy|idle|unknown] [--source S] [--event E]
#       Mint a fresh incarnation gen token, write the gen sidecar, and seed
#       the record at seq=1 (default: busy, source fm-spawn, event
#       launch-brief - the launch prompt IS a submitted turn). Prints the
#       minted gen on stdout so the caller can embed it into adapter wiring.
#       Arming again replaces the previous incarnation: late events carrying
#       the old gen are rejected as stale from then on.
#
#   apply <state-dir> <id> <busy|idle|unknown> (--gen G | --current-gen)
#         --source S --event E
#       Append one lifecycle event: validate the gen against the armed
#       sidecar, advance seq under the lock, atomically replace the record.
#       Adapter wiring passes the exact --gen embedded at arm time, so a
#       hook that outlives its incarnation fails closed here. The legacy
#       Claude fm-send --key Escape path (fm-interrupt) and firstmate recovery
#       paths (fm-recovery) may pass --current-gen to bind to the incarnation
#       armed right now.
#
#   progress <state-dir> <id> --gen G
#       Refresh state/<id>.progress for observed native-harness activity under
#       the incarnation lock. This neither changes busy state nor emits a
#       turn-ended notification. Arm and retire clear the marker, and an old
#       incarnation can never refresh its replacement's progress.
#
#   retire <state-dir> <id> (--gen G | --current-gen)
#       Remove one incarnation's sidecar and record while holding the same
#       writer lock used by arm and apply. An exact gen prevents teardown for
#       an old task from retiring a newly armed incarnation. A missing sidecar
#       is already retired, so any orphan record is removed idempotently.
#
# Exit codes: 0 applied; 1 refused (stale gen, unarmed task, lock timeout,
# invalid input); 2 usage. Adapter hook command lines append `|| true` so a
# refusal never breaks the harness's own lifecycle.
#
# Herdr agent-view bridge: after a SUCCESSFUL arm or an apply that lands busy
# or idle, a task whose <state-dir>/<id>.meta records BOTH backend=herdr and
# harness=zcode is also reported to herdr's agent view so its pane lists the
# worker (`herdr pane report-agent <pane> --source firstmate --agent fm-<id>
# --state working|idle --seq <record-seq> --session <session>`). <session>
# is the part of meta `window=` before the first colon and <pane> the part
# after it (a herdr pane id itself contains colons; see docs/herdr-backend.md
# "Endpoint metadata"). The report routes by the recorded session exactly
# like fm_backend_herdr_cli, never by inherited HERDR_SESSION: the arm-time
# report from `fm-spawn --relaunch` runs in the captain's shell, where the
# env may be unset or name another server. The bridge is best-effort ALWAYS
# and outside the writer lock: a missing herdr on PATH, a missing meta, a
# missing pane, or any report failure is a silent no-op that never changes
# the exit code, the record, or stdout. herdr detects tmux-side and
# other-harness agents natively, so the report is scoped to exactly
# herdr+zcode tasks.
set -u

usage() {
  cat >&2 <<'EOF'
usage:
  fm-busy-event.sh arm <state-dir> <id> [--state busy|idle|unknown] [--source S] [--event E]
  fm-busy-event.sh apply <state-dir> <id> <busy|idle|unknown> (--gen G | --current-gen) --source S --event E
  fm-busy-event.sh progress <state-dir> <id> --gen G
  fm-busy-event.sh retire <state-dir> <id> (--gen G | --current-gen)
See the header comment for the full contract.
EOF
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"

CMD=${1:-}
case "$CMD" in
  arm|apply|progress|retire) shift ;;
  *) usage ;;
esac

STATE=${1:-}
ID=${2:-}
[ -n "$STATE" ] && [ -n "$ID" ] || usage
shift 2
case "$ID" in *[!A-Za-z0-9._-]*) echo "error: invalid task id" >&2; exit 1 ;; esac
[ -d "$STATE" ] || { echo "error: state dir not found: $STATE" >&2; exit 1; }

NEW_STATE=
GEN=
USE_CURRENT_GEN=0
SOURCE=
EVENT=
if [ "$CMD" = apply ]; then
  NEW_STATE=${1:-}
  case "$NEW_STATE" in busy|idle|unknown) shift ;; *) usage ;; esac
elif [ "$CMD" = arm ]; then
  NEW_STATE=busy
  SOURCE=fm-spawn
  EVENT=launch-brief
fi
while [ $# -gt 0 ]; do
  case "$1" in
    --state) NEW_STATE=${2:-}; shift 2 || usage ;;
    --gen) GEN=${2:-}; shift 2 || usage ;;
    --current-gen) USE_CURRENT_GEN=1; shift ;;
    --source) SOURCE=${2:-}; shift 2 || usage ;;
    --event) EVENT=${2:-}; shift 2 || usage ;;
    *) usage ;;
  esac
done
if [ "$CMD" = apply ] || [ "$CMD" = arm ]; then
  case "$NEW_STATE" in busy|idle|unknown) : ;; *) usage ;; esac
  fm_busy_token_valid "$SOURCE" || { echo "error: invalid --source" >&2; exit 1; }
  fm_busy_token_valid "$EVENT" || { echo "error: invalid --event" >&2; exit 1; }
fi

[ "$CMD" != progress ] || [ "$USE_CURRENT_GEN" = 0 ] || usage

REC=$(fm_busy_record_path "$STATE" "$ID")
GEN_FILE=$(fm_busy_gen_path "$STATE" "$ID")
LOCK="$REC.lock"

# Portable mtime in epoch seconds. macOS (BSD) stat uses `-f <fmt>`; Linux (GNU)
# stat uses `-c <fmt>`. Do NOT collapse this into `stat -f <fmt> ... || stat -c
# <fmt> ...`: on GNU `-f` is *filesystem* stat, so it reads the format string as
# a path, reports that on stderr, prints a partial filesystem dump ("  File:
# ...") on stdout, and still exits 0 - the fallback never runs and the caller
# gets a non-numeric token. Detect the platform once and pick the right form,
# exactly as bin/fm-watch.sh does.
if [ "$(uname)" = Darwin ]; then
  lock_mtime() { /usr/bin/stat -f %m "$1" 2>/dev/null; }
else
  lock_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

# Serialize writers. The lock protects seq advancement and the sidecar/record
# pair; a holder that died mid-write is broken after FM_BUSY_LOCK_STALE_SECS.
lock_acquire() {
  local tries=0 now mtime age
  while ! mkdir "$LOCK" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 40 ]; then
      now=$(date +%s)
      mtime=$(lock_mtime "$LOCK" || true)
      # Anything unreadable or non-numeric reads as "just created", so an
      # unforeseen stat surprise degrades to a lock-timeout refusal instead of
      # aborting the writer - and its caller, fm-teardown.sh - under `set -u`.
      case "$mtime" in ''|*[!0-9]*) mtime=$now ;; esac
      age=$((now - mtime))
      if [ "$age" -ge "${FM_BUSY_LOCK_STALE_SECS:-5}" ]; then
        rmdir "$LOCK" 2>/dev/null || rm -rf "$LOCK" 2>/dev/null || true
        mkdir "$LOCK" 2>/dev/null && break
      fi
      echo "error: busy-state lock timeout for $ID" >&2
      return 1
    fi
    sleep 0.05
  done
  return 0
}
lock_release() { rmdir "$LOCK" 2>/dev/null || true; }

write_record() {  # <gen> <seq>
  local tmp
  tmp="$REC.tmp.$$"
  printf 'v1 gen=%s seq=%s state=%s source=%s event=%s ts=%s\n' \
    "$1" "$2" "$NEW_STATE" "$SOURCE" "$EVENT" "$(date +%s)" > "$tmp" || return 1
  mv -f "$tmp" "$REC"
}

# fm_herdr_agent_report: the one herdr agent-view bridge call (see the header).
# Runs OUTSIDE the writer lock and best-effort ALWAYS: every failure mode -
# no meta, a meta without backend=herdr AND harness=zcode, no colon in
# window= or an empty side of it, no herdr on PATH, a failing report -
# returns without touching the caller's exit code, stdout, or stderr.
# <busy-state> is the state the record just landed in (busy|idle); <seq> is
# that record's seq.
fm_herdr_agent_report() {  # <state-dir> <id> <busy-state> <seq>
  local state_dir=$1 id=$2 busy_state=$3 seq=$4
  local meta backend harness window session pane herdr_state
  case "$busy_state" in
    busy) herdr_state=working ;;
    idle) herdr_state=idle ;;
    *) return 0 ;;
  esac
  meta="$state_dir/$id.meta"
  [ -f "$meta" ] || return 0
  backend=$(sed -n 's/^backend=//p' "$meta" | head -n 1)
  harness=$(sed -n 's/^harness=//p' "$meta" | head -n 1)
  [ "$backend" = herdr ] && [ "$harness" = zcode ] || return 0
  window=$(sed -n 's/^window=//p' "$meta" | head -n 1)
  case "$window" in
    *:*) session=${window%%:*}; pane=${window#*:} ;;
    *) return 0 ;;
  esac
  [ -n "$session" ] && [ -n "$pane" ] || return 0
  command -v herdr >/dev/null 2>&1 || return 0
  HERDR_SESSION="$session" herdr pane report-agent "$pane" --source firstmate \
    --agent "fm-$id" --state "$herdr_state" --seq "$seq" --session "$session" \
    >/dev/null 2>&1 || true
  return 0
}

old_umask=$(umask)
umask 077

if [ "$CMD" = arm ]; then
  GEN="g$(date +%s).$$.$RANDOM"
  lock_acquire || exit 1
  {
    printf '%s\n' "$GEN" > "$GEN_FILE.tmp.$$" && mv -f "$GEN_FILE.tmp.$$" "$GEN_FILE" \
      && write_record "$GEN" 1 && rm -f "$STATE/$ID.progress"
  } || { lock_release; umask "$old_umask"; echo "error: arm failed for $ID" >&2; exit 1; }
  lock_release
  umask "$old_umask"
  printf '%s\n' "$GEN"
  fm_herdr_agent_report "$STATE" "$ID" "$NEW_STATE" 1
  exit 0
fi

# apply / progress / retire
if [ "$USE_CURRENT_GEN" = 1 ] && [ "$CMD" != retire ]; then
  GEN=$(fm_busy_current_gen "$STATE" "$ID") || {
    umask "$old_umask"
    echo "error: no armed busy-state gen for $ID" >&2
    exit 1
  }
fi
if [ "$USE_CURRENT_GEN" != 1 ] || [ "$CMD" != retire ]; then
  fm_busy_token_valid "$GEN" || { umask "$old_umask"; echo "error: invalid --gen" >&2; exit 1; }
fi

lock_acquire || { umask "$old_umask"; exit 1; }
CURRENT=$(fm_busy_current_gen "$STATE" "$ID") || {
  if [ "$CMD" = retire ] && [ ! -e "$GEN_FILE" ] && [ ! -L "$GEN_FILE" ]; then
    rm -f "$REC" "$STATE/$ID.progress" || {
      lock_release
      umask "$old_umask"
      echo "error: busy-state retirement failed for $ID" >&2
      exit 1
    }
    lock_release
    umask "$old_umask"
    exit 0
  fi
  lock_release
  umask "$old_umask"
  echo "error: no armed busy-state gen for $ID" >&2
  exit 1
}
if [ "$CMD" = retire ] && [ "$USE_CURRENT_GEN" = 1 ]; then
  GEN=$CURRENT
fi
if [ "$GEN" != "$CURRENT" ]; then
  lock_release
  umask "$old_umask"
  echo "error: stale busy-state gen for $ID (event rejected)" >&2
  exit 1
fi
if [ "$CMD" = retire ]; then
  rm -f "$GEN_FILE" "$REC" "$STATE/$ID.progress" || {
    lock_release
    umask "$old_umask"
    echo "error: busy-state retirement failed for $ID" >&2
    exit 1
  }
  lock_release
  umask "$old_umask"
  exit 0
fi
if [ "$CMD" = progress ]; then
  touch "$STATE/$ID.progress" || { lock_release; umask "$old_umask"; exit 1; }
  lock_release
  umask "$old_umask"
  exit 0
fi
OLD_SEQ=0
if [ -f "$REC" ]; then
  old_line=$(head -n 1 "$REC" 2>/dev/null || true)
  case "$old_line" in
    *" gen=$GEN "*)
      old_seq_field=${old_line##* seq=}
      old_seq_field=${old_seq_field%% *}
      case "$old_seq_field" in
        ''|*[!0-9]*) OLD_SEQ=0 ;;
        *) OLD_SEQ=$old_seq_field ;;
      esac
      ;;
  esac
fi
NEW_SEQ=$((OLD_SEQ + 1))
write_record "$GEN" "$NEW_SEQ" || {
  lock_release
  umask "$old_umask"
  echo "error: record write failed for $ID" >&2
  exit 1
}
lock_release
umask "$old_umask"
fm_herdr_agent_report "$STATE" "$ID" "$NEW_STATE" "$NEW_SEQ"
exit 0
