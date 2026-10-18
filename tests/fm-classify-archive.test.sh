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
  local d archive
  d=$(seed_case basic)
  status_archive_task_records "$d/state" t1 "$d/data/t1" \
    || fail "archive of a complete task returned failure"
  archive=$STATUS_ARCHIVE_DIR
  cmp -s "$d/state/t1.status" "$archive/status.log" \
    || fail "archived status log differs from the live status log"
  cmp -s "$d/state/t1.inbox/002.msg" "$archive/inbox/002.msg" \
    || fail "pending inbox record was not archived"
  cmp -s "$d/state/t1.inbox/handled/001.msg" "$archive/inbox/handled/001.msg" \
    || fail "handled inbox record was not archived"
  [ -f "$d/state/t1.status" ] && [ -f "$d/state/t1.inbox/002.msg" ] \
    || fail "archiving changed the live state it reads"
  assert_absent "$archive/inbox/.ring-state" "inbox bookkeeping was archived"
  assert_absent "$archive/inbox/.seq.lock" "inbox lock was archived"
  [ -z "$(find "$d/data/t1" -name '*token*')" ] \
    || fail "a credential-bearing state file reached the archive"
  pass "the status log and inbox records are archived and live state is untouched"
}

test_retry_after_retirement_keeps_the_archive() {
  local d first second third
  d=$(seed_case retry)
  status_archive_task_records "$d/state" t1 "$d/data/t1" || fail "first archive failed"
  first=$STATUS_ARCHIVE_DIR
  printf 'resolved: late line\n' >> "$d/state/t1.status"
  status_archive_task_records "$d/state" t1 "$d/data/t1" || fail "repeat archive failed"
  second=$STATUS_ARCHIVE_DIR
  [ "$first" != "$second" ] || fail "repeat archive overwrote an earlier snapshot"
  cmp -s "$d/state/t1.status" "$second/status.log" || fail "repeat archive lost late status"
  status_retire_presentation_task "$d/state" t1 || fail "retirement failed"
  rm -rf "$d/state/t1.inbox"
  status_archive_task_records "$d/state" t1 "$d/data/t1" || fail "empty retry failed"
  [ -z "$STATUS_ARCHIVE_DIR" ] || fail "empty retry created another run"
  assert_grep 'resolved: late line' "$second/status.log" "retry erased archived status"
  assert_present "$second/inbox/handled/001.msg" "retry erased archived inbox"
  mkdir -p "$d/state/t1.inbox/handled"
  printf 'done: second run\n' > "$d/state/t1.status"
  printf 'new steer\n' > "$d/state/t1.inbox/handled/001.msg"
  status_archive_task_records "$d/state" t1 "$d/data/t1" || fail "second run archive failed"
  third=$STATUS_ARCHIVE_DIR
  [ "$third" != "$first" ] && [ "$third" != "$second" ] || fail "run paths collided"
  assert_grep 'done: finished' "$first/status.log" "later run overwrote earlier status"
  assert_grep 'first steer' "$first/inbox/handled/001.msg" "later run overwrote earlier inbox"
  assert_grep 'done: second run' "$third/status.log" "later status was not archived"
  assert_grep 'new steer' "$third/inbox/handled/001.msg" "later inbox was not archived"
  pass "retries and reused task IDs preserve every earlier run"
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
  local d archive
  d=$(seed_case symlink)
  printf 'outside secret\n' > "$d/outside"
  rm -f "$d/state/t1.inbox/002.msg"
  ln -s "$d/outside" "$d/state/t1.inbox/002.msg"
  if status_archive_task_records "$d/state" t1 "$d/data/t1"; then
    fail "archive reported success while skipping a symlinked record"
  fi
  archive=$STATUS_ARCHIVE_DIR
  assert_absent "$archive/inbox/002.msg" "a symlinked inbox record was copied"
  [ -f "$archive/status.log" ] || fail "one bad record stopped the rest of the archive"

  d=$(seed_case symlink-dest)
  mkdir -p "$d/elsewhere"
  ln -s "$d/elsewhere" "$d/data/t1"
  if status_archive_task_records "$d/state" t1 "$d/data/t1"; then
    fail "archive reported success into a symlinked data folder"
  fi
  [ -z "$(ls -A "$d/elsewhere")" ] || fail "archive wrote through a symlinked data folder"
  pass "archiving never follows a symlinked source or destination"
}

test_remote_archive_round_trip() {
  local d archive
  d=$(seed_case 'remote home with spaces')
  mkdir -p "$d/home/state/parent-route" "$d/home/bin" "$d/root/data"
  printf 't1\n' > "$d/home/.fm-secondmate-home"
  : > "$d/home/AGENTS.md"
  cp -R "$d/state/." "$d/home/state/parent-route/"
  mkdir -p "$d/home/state/child.inbox/handled" "$d/home/data/child/runs/old/inbox/handled"
  printf 'done: child current run\n' > "$d/home/state/child.status"
  printf 'child current steer\n' > "$d/home/state/child.inbox/handled/001.msg"
  printf 'done: child earlier run\n' > "$d/home/data/child/runs/old/status.log"
  printf 'child earlier steer\n' > "$d/home/data/child/runs/old/inbox/handled/001.msg"
  mkdir -p "$d/home/data/oldmate/children/grandchild/runs/old"
  printf 'done: archived grandchild\n' > "$d/home/data/oldmate/children/grandchild/runs/old/status.log"
  FM_HOME="$d/home" FM_ROOT_OVERRIDE="$d/root" bash "$ROOT/bin/fm-remote-secondmate-control.sh" archive t1 \
    > "$d/payload.json" || fail "remote archive export failed"
  status_archive_import "$d/data/t1" "$d/payload.json" || fail "remote archive import failed"
  archive=$STATUS_ARCHIVE_DIR
  cmp -s "$d/state/t1.status" "$archive/status.log" || fail "remote status changed during transfer"
  cmp -s "$d/state/t1.inbox/handled/001.msg" "$archive/inbox/handled/001.msg" \
    || fail "remote handled inbox changed during transfer"
  cmp -s "$d/state/t1.inbox/002.msg" "$archive/inbox/002.msg" \
    || fail "remote pending inbox changed during transfer"
  [ "$(find "$d/data/t1/children/child/runs" -name status.log | wc -l | tr -d ' ')" = 2 ] \
    || fail "remote transfer lost a child run"
  grep -l 'child current run' "$d/data/t1/children/child/runs/"*/status.log >/dev/null \
    || fail "remote transfer lost current child status"
  grep -l 'child earlier run' "$d/data/t1/children/child/runs/"*/status.log >/dev/null \
    || fail "remote transfer lost previous child status"
  grep -l 'child current steer' "$d/data/t1/children/child/runs/"*/inbox/handled/001.msg >/dev/null \
    || fail "remote transfer lost current child inbox"
  grep -l 'child earlier steer' "$d/data/t1/children/child/runs/"*/inbox/handled/001.msg >/dev/null \
    || fail "remote transfer lost previous child inbox"
  grep -l 'archived grandchild' "$d/data/t1/children/oldmate/children/grandchild/runs/"*/status.log >/dev/null \
    || fail "remote transfer lost a nested archived history"
  printf '{"children/../runs/old/status.log":"eA=="}\n' > "$d/unsafe-child.json"
  if status_archive_import "$d/data/t1" "$d/unsafe-child.json" 2>/dev/null; then
    fail "import accepted a child traversal path"
  fi
  printf '{"../escape":"eA=="}\n' > "$d/unsafe.json"
  if status_archive_import "$d/data/t1" "$d/unsafe.json" 2>/dev/null; then
    fail "import accepted a traversal path"
  fi
  assert_absent "$d/data/t1/runs/escape" "import escaped its run directory"
  printf '{"status.log":' > "$d/truncated.json"
  if status_archive_import "$d/data/t1" "$d/truncated.json" 2>/dev/null; then
    fail "import accepted a truncated transfer"
  fi
  pass "remote archives transfer exact records and reject unsafe or truncated payloads"
}

test_remote_retirement_requires_preparation_for_current_endpoint() {
  local d="$TMP_ROOT/retirement-phases" control home
  home="$d/home"
  mkdir -p "$d/code" "$home/state/parent-route" "$home/bin"
  cp -R "$ROOT/bin" "$d/code/bin"
  control="$d/code/bin/fm-remote-secondmate-control.sh"
  printf 't1\n' > "$home/.fm-secondmate-home"
  : > "$home/AGENTS.md"
  fm_write_meta "$home/state/parent-route/t1.meta" \
    'window=fm-remote:w1:p1' 'backend=herdr' 'kind=secondmate' 'endpoint_task_id=t1' \
    "worktree=$home" "home=$home" "project=$d/code" 'spawn_gen=first' \
    'herdr_session=fm-remote' 'herdr_workspace_id=w1' 'herdr_tab_id=w1:t1' 'herdr_pane_id=w1:p1'
  cat > "$d/code/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$d/code/bin/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
set -eu
home=${FM_STATE_OVERRIDE%/state/parent-route}
if [ "$FM_TEARDOWN_REMOTE_PREPARE" = 1 ]; then
  printf 'done: stopped\n' >> "$FM_STATE_OVERRIDE/$1.status"
else
  rm -rf "$home"
fi
SH
  if FM_HOME="$home" FM_ROOT_OVERRIDE="$d/code" bash "$control" retire t1 --commit 2>/dev/null; then
    fail "remote retirement committed without preparation"
  fi
  assert_present "$home" "unprepared commit deleted the home"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$d/code" bash "$control" retire t1 --prepare \
    || fail "remote preparation failed"
  assert_present "$home/state/parent-route/t1.meta" "preparation lost the endpoint metadata"
  assert_grep 'done: stopped' "$home/state/parent-route/t1.status" "preparation did not stop the writer"
  cp "$home/state/parent-route/t1.meta" "$d/prepared.meta"
  printf 'spawn_gen=replacement\n' >> "$home/state/parent-route/t1.meta"
  if FM_HOME="$home" FM_ROOT_OVERRIDE="$d/code" bash "$control" retire t1 --commit 2>/dev/null; then
    fail "remote retirement committed a replacement endpoint"
  fi
  assert_present "$home" "stale preparation deleted a replacement home"
  cp "$d/prepared.meta" "$home/state/parent-route/t1.meta"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$d/code" bash "$control" retire t1 --commit \
    || fail "prepared endpoint could not be committed"
  assert_absent "$home" "committed retirement left the home"
  pass "remote retirement only commits the endpoint whose preparation completed"
}

test_archives_status_log_and_inbox_records_without_touching_live_state
test_retry_after_retirement_keeps_the_archive
test_task_without_records_creates_nothing
test_symlinks_are_never_followed
test_remote_archive_round_trip
test_remote_retirement_requires_preparation_for_current_endpoint
