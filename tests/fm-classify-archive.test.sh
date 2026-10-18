#!/usr/bin/env bash
# tests/fm-classify-archive.test.sh - status_archive_task_records
# (bin/fm-classify-lib.sh), which keeps a task's status log and steering-inbox
# records in its private data folder before cleanup retires the live copies.
# These tests drive the REAL function over crafted state directories and
# assert the archived files and the untouched live state, never its source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-classify-archive-tests)

# Fresh state and data dirs for one case, seeded with a status log and an inbox
# holding one pending and one handled record plus inbox bookkeeping files.
seed_case() {  # <name>
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state/t1.inbox/handled" "$d/data"
  printf 'working: setup done\ndone: finished\n' > "$d/state/t1.status"
  printf 'schema=fm-task-inbox.v1\n--\nsecond steer\n' > "$d/state/t1.inbox/002.msg"
  printf 'schema=fm-task-inbox.v1\n--\nfirst steer\n' > "$d/state/t1.inbox/handled/001.msg"
  printf '002.msg\t1\t0\n' > "$d/state/t1.inbox/.ring-state"
  : > "$d/state/t1.inbox/.seq.lock"
  printf 'secret-token\n' > "$d/state/t1.grok-turnend-token"
  printf '%s' "$d"
}

test_archives_status_log_and_inbox_records_without_touching_live_state() {
  local d
  d=$(seed_case basic)
  status_archive_task_records "$d/state" t1 "$d/data/t1" \
    || fail "archive of a complete task returned failure"
  cmp -s "$d/state/t1.status" "$d/data/t1/status.log" \
    || fail "archived status log differs from the live status log"
  cmp -s "$d/state/t1.inbox/002.msg" "$d/data/t1/inbox/002.msg" \
    || fail "pending inbox record was not archived"
  cmp -s "$d/state/t1.inbox/handled/001.msg" "$d/data/t1/inbox/handled/001.msg" \
    || fail "handled inbox record was not archived"
  [ -f "$d/state/t1.status" ] && [ -f "$d/state/t1.inbox/002.msg" ] \
    || fail "archiving changed the live state it reads"
  assert_absent "$d/data/t1/inbox/.ring-state" "inbox bookkeeping was archived"
  assert_absent "$d/data/t1/inbox/.seq.lock" "inbox lock was archived"
  [ -z "$(find "$d/data/t1" -name '*token*')" ] \
    || fail "a credential-bearing state file reached the archive"
  pass "the status log and inbox records are archived and live state is untouched"
}

test_retry_after_retirement_keeps_the_archive() {
  local d
  d=$(seed_case retry)
  status_archive_task_records "$d/state" t1 "$d/data/t1" || fail "first archive failed"
  printf 'resolved: late line\n' >> "$d/state/t1.status"
  status_archive_task_records "$d/state" t1 "$d/data/t1" || fail "repeat archive failed"
  cmp -s "$d/state/t1.status" "$d/data/t1/status.log" \
    || fail "repeat archive did not refresh the status log copy"
  status_retire_presentation_task "$d/state" t1 || fail "retirement failed"
  rm -rf "$d/state/t1.inbox"
  status_archive_task_records "$d/state" t1 "$d/data/t1" \
    || fail "archive with no live records left returned failure"
  assert_grep 'resolved: late line' "$d/data/t1/status.log" \
    "a retry after retirement erased the archived status log"
  [ -f "$d/data/t1/inbox/handled/001.msg" ] \
    || fail "a retry after retirement erased the archived inbox"
  pass "archiving is idempotent and a retry after retirement keeps the archive"
}

test_task_without_records_creates_nothing() {
  local d="$TMP_ROOT/empty"
  mkdir -p "$d/state" "$d/data"
  status_archive_task_records "$d/state" t1 "$d/data/t1" \
    || fail "archive of a task with no records returned failure"
  assert_absent "$d/data/t1" "archive created a data folder for a task with no records"
  pass "a task with no status log or inbox leaves no archive folder"
}

test_symlinks_are_never_followed() {
  local d
  d=$(seed_case symlink)
  printf 'outside secret\n' > "$d/outside"
  rm -f "$d/state/t1.inbox/002.msg"
  ln -s "$d/outside" "$d/state/t1.inbox/002.msg"
  if status_archive_task_records "$d/state" t1 "$d/data/t1"; then
    fail "archive reported success while skipping a symlinked record"
  fi
  assert_absent "$d/data/t1/inbox/002.msg" "a symlinked inbox record was copied"
  [ -f "$d/data/t1/status.log" ] || fail "one bad record stopped the rest of the archive"

  d=$(seed_case symlink-dest)
  mkdir -p "$d/elsewhere"
  ln -s "$d/elsewhere" "$d/data/t1"
  if status_archive_task_records "$d/state" t1 "$d/data/t1"; then
    fail "archive reported success into a symlinked data folder"
  fi
  [ -z "$(ls -A "$d/elsewhere")" ] || fail "archive wrote through a symlinked data folder"
  pass "archiving never follows a symlinked source or destination"
}

test_archives_status_log_and_inbox_records_without_touching_live_state
test_retry_after_retirement_keeps_the_archive
test_task_without_records_creates_nothing
test_symlinks_are_never_followed
