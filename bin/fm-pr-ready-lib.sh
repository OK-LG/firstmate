#!/usr/bin/env bash
# Durable PR-ready handoff alarm, called only by the singleton watcher.
# fm_pr_ready_tick <state> <now-epoch> queues overdue check wakes
# and prints their reasons. No forge calls or endpoint/harness probes are made.
# FM_PR_READY_AGE_SECS and FM_PR_READY_REPEAT_SECS are positive seconds, both
# defaulting to 1200. Invalid values fail closed instead of disabling the alarm.
# A done:/ready: declaration with a validated PR URL opens an obligation for a
# ship (legacy metadata without kind defaults to ship). Repeated declarations
# of the same URL keep the original age. Other status prose cannot acknowledge
# it. A valid emission stamp supplies its age; otherwise age starts at first
# observation, without pretending the observation is the emission time.
# fm-pr-ready-ack.sh records explicit handling through a captured status byte
# endpoint. A matching published merge outcome also acknowledges the handoff.
# Draining a wake or registering merge monitoring alone does not acknowledge it.
# A later ready declaration, including fixes to the same PR, opens a new handoff
# after acknowledgement. Duplicate ready declarations while pending keep its age.
# <task>.pr-ready stores eight lines: status identity, consumed byte offset,
# URL (or -), age origin, last alarm epoch, handled (0/1), ready byte endpoint,
# format version. fm-pr-ready-ack.sh owns the separate acknowledgement record.
# The cursor consumes complete lines only. File replacement/truncation resets
# it. Writes are atomic, and a wake is queued BEFORE its repeat timer advances.

FM_PR_READY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$FM_PR_READY_LIB_DIR/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$FM_PR_READY_LIB_DIR/fm-classify-lib.sh"
# shellcheck source=/dev/null
. "$FM_PR_READY_LIB_DIR/fm-wake-lib.sh"

fm_pr_ready_line_url() {
  local line=$1 verb token
  local -a words
  status_line_verb "$line" verb
  case "$verb" in done|ready) ;; *) return 1 ;; esac
  read -r -a words <<< "$line"
  for token in "${words[@]}"; do
    case "$token" in https://*) ;; *) continue ;; esac
    while :; do
      case "$token" in *[.,\;\)\]]) token=${token%?} ;; *) break ;; esac
    done
    fm_pr_url_parse "$token" && return 0
  done
  return 1
}

fm_pr_ready_tick() {
  local state=$1 now=$2 age=${FM_PR_READY_AGE_SECS:-1200} repeat=${FM_PR_READY_REPEAT_SECS:-1200}
  local id size ident f marker device old_ident offset url since last handled version
  local line candidate token stamp reason tmp snapshot before after ready_end report_token
  local ack_ident ack_end ack_url ack_reason ack_version ack
  local LC_ALL=C
  for token in "$age" "$repeat"; do
    case "$token" in ''|0*|*[!0-9]*) echo 'error: PR-ready alarm intervals must be positive seconds' >&2; return 1 ;; esac
    [ "${#token}" -le 9 ] || return 1
  done
  device=$(fm_pr_file_device "$state") || return 1
  snapshot=$(status_presentation_snapshot "$state") || return 1
  while IFS=$'\t' read -r id size ident; do
    [ -n "$id" ] || continue
    fm_pr_task_id_valid "$id" || continue
    [ -f "$state/$id.meta" ] && [ ! -L "$state/$id.meta" ] || continue
    case "$(sed -n 's/^kind=//p' "$state/$id.meta" | tail -1)" in ''|ship) ;; *) continue ;; esac
    f="$state/$id.status"
    marker="$state/$id.pr-ready"
    fm_pr_regular_destination_on_device_or_absent "$marker" "$device" || return 1
    old_ident='' offset=0 url=- since=0 last=0 handled=0 ready_end=0 version=''
    if [ -f "$marker" ]; then
      {
        IFS= read -r old_ident && IFS= read -r offset && IFS= read -r url \
          && IFS= read -r since && IFS= read -r last && IFS= read -r handled \
          && IFS= read -r ready_end && IFS= read -r version
      } < "$marker" || return 1
      [ "$version" = fm-pr-ready-v1 ] || return 1
      for token in "$offset" "$since" "$last" "$ready_end"; do
        case "$token" in ''|*[!0-9]*|0[0-9]*) return 1 ;; esac
        [ "${#token}" -le 12 ] || return 1
      done
      case "$handled" in 0|1) ;; *) return 1 ;; esac
      [ "$url" = - ] || fm_pr_url_parse "$url" || return 1
    fi
    before=$(printf '%s\n' "$old_ident" "$offset" "$url" "$since" "$last" "$handled" "$ready_end")
    if [ "$old_ident" != "$ident" ] || [ "$offset" -gt "$size" ]; then
      offset=0 url=- since=0 last=0 handled=0 ready_end=0
    fi
    ack_ident='' ack_end=0 ack_url='' ack_reason='' ack_version=''
    ack="$state/$id.pr-ready-ack"
    if [ -e "$ack" ] || [ -L "$ack" ]; then
      fm_pr_private_file_valid "$ack" 600 "$device" || return 1
      {
        IFS= read -r ack_ident && IFS= read -r ack_end && IFS= read -r ack_url \
          && IFS= read -r ack_reason && IFS= read -r ack_version
      } < "$ack" || return 1
      [ "$ack_version" = fm-pr-ready-ack-v1 ] || return 1
      case "$ack_reason" in review-started|merge-started|held) ;; *) return 1 ;; esac
      fm_pr_url_parse "$ack_url" || return 1
      case "$ack_end" in ''|*[!0-9]*|0[0-9]*) return 1 ;; esac
      [ "${#ack_end}" -le 12 ] || return 1
      # A truncated log cannot inherit an acknowledgement from bytes it no
      # longer contains, including after unrelated new appends grow it again.
      if [ "$ack_ident" = "$ident" ] && [ "$ack_end" -gt "$size" ]; then
        rm -f -- "$ack" || return 1
        ack_ident=''
      fi
    fi
    if [ "$ack_ident" = "$ident" ] && [ "$ack_end" -ge "$ready_end" ] && [ "$ack_url" = "$url" ]; then handled=1; fi
    # Read only the newly captured bytes; a partial append remains unread.
    while IFS= read -r line; do
      offset=$((offset + ${#line} + 1))
      fm_pr_ready_line_url "$line" || continue
      candidate=$FM_PR_URL
      if [ "$candidate" != "$url" ] || [ "$handled" -eq 1 ]; then
        url=$candidate last=0 handled=0
        stamp=$(status_line_at_epoch "$line") || stamp=$now
        [ "$stamp" -le "$now" ] || stamp=$now
        since=$stamp
      fi
      ready_end=$offset
      if [ "$ack_ident" = "$ident" ] && [ "$ack_end" -ge "$ready_end" ] && [ "$ack_url" = "$url" ]; then handled=1; fi
    done < <(_fm_status_read_span "$f" "$offset" "$((size - offset))")
    # Replacement during the read is deferred, never combined with old bytes.
    [ "$(_fm_open_decisions_file_ident "$f")" = "$ident" ] || continue
    [ "$(_fm_status_file_size "$f")" -ge "$size" ] || continue
    if [ "$url" != - ] && [ "$handled" -eq 0 ]; then
      fm_pr_url_parse "$url" || return 1
      if fm_pr_poll_merge_already_notified "$state" "$id" "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER"; then
        handled=1
      elif [ "$((now - since))" -ge "$age" ] \
        && { [ "$last" -eq 0 ] || [ "$((now - last))" -ge "$repeat" ]; }; then
        printf -v report_token '%q' "$ident|$ready_end"
        reason="check: PR-ready overdue: task=$id PR=$url age=$((now - since))s; start its authorized review or landing, then acknowledge with bin/fm-pr-ready-ack.sh $id $url <review-started|merge-started|held> $report_token"
        fm_wake_append check "pr-ready-$id" "$reason" || return 1
        printf '%s\n' "$reason"
        last=$now
      fi
    fi
    after=$(printf '%s\n' "$ident" "$offset" "$url" "$since" "$last" "$handled" "$ready_end")
    [ "$before" != "$after" ] || continue
    tmp=$(mktemp "$state/.pr-ready.XXXXXX") || return 1
    if ! { printf '%s\n%s\n' "$after" fm-pr-ready-v1 > "$tmp" \
      && chmod 600 "$tmp" && fm_pr_regular_destination_on_device_or_absent "$marker" "$device" \
      && mv -f -- "$tmp" "$marker"; }; then
      rm -f -- "$tmp"
      return 1
    fi
  done <<< "$snapshot"
}
