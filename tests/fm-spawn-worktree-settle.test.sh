#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `for _ in $(seq 1 60)` loop after `treehouse get`).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
#
# The same loop has a second transient to survive: `treehouse get` reports the
# REPOSITORY's primary checkout as its own cwd while it is still preparing a
# slot. From a linked spawning home that path is not the project, so a poll
# comparing only against the project adopted it and the isolation guard then
# refused the launch. The cases below cover both the transient and the pane
# that never leaves the primary at all.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise settled-worktree detection for $id.

## Firstmate spec
Record only the pane's stable worktree.
EOF
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read costs exactly
# one confirming read - not a whole extra polling cycle on top of it. Counting
# the pane reads measures the loop itself; wall-clock time would fold in every
# other cost of a spawn (fetch, trust registration) and drift with the machine.
test_already_settled_pane_costs_one_confirm_read() {
  local rec id out status reads
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 3 ] || fail "already-settled pane took $reads reads to confirm - expected the first read, one confirmation, and the launch-boundary cwd check"
  pass "an already-settled pane confirms on the next read, not a whole extra cycle"
}

# make_primary_case <name> <id> <stale_reads> builds the linked-home shape: the
# spawning project is itself a LINKED worktree of the repository, and the path
# the pane transiently reports is that repository's PRIMARY checkout. `treehouse
# get` reports the repository it is preparing a slot from as its own cwd while
# it is still fetching and checking out, so the pane reads the primary for the
# first seconds. The primary is not the spawning project, so a poll that only
# compares against the project accepts it as the worktree, and the isolation
# guard then refuses the launch even though treehouse went on to enter a real
# slot. The settled path is a second linked worktree of the same repository.
make_primary_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home primary proj wt fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  primary="$case_dir/primary"
  proj="$case_dir/mate"
  wt="$case_dir/slot"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$primary" "$proj" "mate-$name"
  git -C "$primary" worktree add --quiet -b "slot-$name" "$wt"
  fm_test_spawn_brief "$home" "$id" "Exercise primary-checkout transient detection for $id."
  printf '%s\n' "$case_dir|$home|$proj|$wt|$primary|$fakebin|$countfile|$stale_reads"
}

# The exact incident: the pane reports the repository primary for the first
# reads, then settles into the slot treehouse actually created. The primary must
# never be adopted as the worktree, so the spawn lands on the settled slot.
test_transient_primary_checkout_is_not_accepted() {
  local rec id out status
  id=settle-primary-transient-z3
  rec=$(make_primary_case settle-primary-transient "$id" 3)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane leaves the primary checkout"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the repository primary checkout as the worktree"
  pass "a transient primary-checkout pane read is not accepted as the worktree"
}

# A pane that never leaves the primary checkout must still fail at the deadline
# rather than waiting forever or recording the primary.
test_primary_checkout_that_never_settles_fails_at_the_deadline() {
  local rec id out status
  id=settle-primary-stuck-z4
  rec=$(make_primary_case settle-primary-stuck "$id" 100000)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane that never left the primary checkout"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree" \
    "spawn did not explain that the pane never reached an isolated worktree"
  assert_contains "$out" "$STALE_DIR" \
    "the refusal did not name the path the pane kept reporting"
  assert_contains "$out" "repository's primary checkout" \
    "the refusal did not say why that path was rejected"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a pane stuck on the primary checkout fails loudly at the deadline"
}

test_symlinked_pool_slot_records_pool_path() {
  local rec id out status pool_path disk_slot case_dir original_project jq_free
  id=settle-symlink-pool-z5
  rec=$(make_settle_case settle-symlink-pool "$id" 0)
  read_settle_record "$rec"
  case_dir=${HOME_DIR%/home}
  disk_slot="$case_dir/disk/17"
  pool_path="$case_dir/pool/17/project"
  mkdir -p "$disk_slot" "$case_dir/pool"
  git -C "$PROJ_DIR" worktree move "$WT_DIR" "$disk_slot/project"
  ln -s "$disk_slot" "$case_dir/pool/17"
  printf '{"worktrees":[{"name":"17","path":"%s"}]}\n' "$pool_path" \
    > "$case_dir/pool/treehouse-state.json"
  fm_test_treehouse_pool "$PROJ_DIR" "$case_dir/pool"
  WT_DIR="$disk_slot/project"
  jq_free=$(fm_test_base_path_sans "$PATH" jq)
  ! PATH="$jq_free" command -v jq >/dev/null 2>&1 || fail "jq is still available"
  out=$(PATH="$jq_free" run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "same-clone spawn should resolve without jq"$'\n'"$out"
  assert_grep "worktree=$pool_path" "$HOME_DIR/state/$id.meta" "same-clone spawn retained the disk path"
  original_project=$PROJ_DIR
  PROJ_DIR="$case_dir/secondmate/project"
  git clone -q "$(git -C "$original_project" remote get-url origin)" "$PROJ_DIR"
  fm_test_treehouse_pool "$PROJ_DIR" "$case_dir/pool"
  [ "$(git -C "$original_project" remote get-url origin)" = "$(git -C "$PROJ_DIR" remote get-url origin)" ] \
    || fail "fixture clones do not share an origin"
  [ "$(git -C "$PROJ_DIR" rev-parse --path-format=absolute --git-common-dir)" != "$(git -C "$WT_DIR" rev-parse --path-format=absolute --git-common-dir)" ] \
    || fail "fixture clones share a Git common directory"
  id=settle-shared-pool-z7
  fm_test_spawn_brief "$HOME_DIR" "$id" "Reuse a shared pool slot from a separate clone."
  out=$(PATH="$jq_free" run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should accept a symlinked Treehouse slot"$'\n'"$out"
  assert_grep "worktree=$pool_path" "$HOME_DIR/state/$id.meta" \
    "spawn recorded the disk path instead of Treehouse's pool path"
  assert_present "$disk_slot/.fm-slot-owner" "spawn did not claim the symlinked slot"
  assert_grep "task=$id" "$disk_slot/.fm-slot-owner" "shared-clone spawn did not claim its slot"
  pass "same and separate clones record and claim symlinked slots without jq"
}

test_symlinked_slot_to_primary_fails_isolation() {
  local rec id out status pool_path case_dir
  id=settle-symlink-primary-z6
  rec=$(make_settle_case settle-symlink-primary "$id" 0)
  read_settle_record "$rec"
  case_dir=${HOME_DIR%/home}
  mkdir -p "$case_dir/pool"
  ln -s "$case_dir" "$case_dir/pool/17"
  pool_path="$case_dir/pool/17/project"
  WT_DIR=$pool_path
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a symlinked path to the primary checkout"
  assert_contains "$out" "spawning project itself" \
    "isolation refusal did not identify the primary checkout"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "isolation refusal published task metadata"
  pass "a symlinked slot path to the primary checkout fails isolation"
}

test_failed_pool_lookup_refuses_spawn() {
  local rec id=settle-lookup-failure out status
  rec=$(make_settle_case settle-lookup-failure "$id" 0)
  read_settle_record "$rec"
  printf 'root = [\n' > "$PROJ_DIR/treehouse.toml"
  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted uncertain Treehouse ownership"
  assert_contains "$out" 'Treehouse lookup failed' "spawn did not explain its lookup refusal"
  assert_absent "$HOME_DIR/state/$id.meta" "failed lookup published task metadata"
  pass "spawn refuses unknown pool membership before launching a worker"
}

test_pool_resolution_requires_unique_authoritative_entry() {
  local dir="$TMP_ROOT/pool-resolution" pool slot out status mode
  pool="$dir/pool with spaces"
  slot="$pool/17/project"
  mkdir -p "$pool"
  fm_git_worktree "$dir/project" "$dir/disk/project" pool-resolution
  fm_test_treehouse_pool "$dir/project" "$pool"
  ln -s "$dir/disk" "$pool/17"
  ln -s "$dir/disk" "$pool/18"
  for mode in valid absent malformed symlink-state ambiguous claimed-omission; do
    rm -f "$pool/treehouse-state.json" "$dir/disk/.fm-slot-owner"
    printf '{"worktrees":[{"name":"17","path":"%s"}]}\n' "$slot" > "$pool/treehouse-state.json"
    case "$mode" in
      absent|claimed-omission) printf '{"worktrees":[]}\n' > "$pool/treehouse-state.json" ;;
      malformed) printf '{' > "$pool/treehouse-state.json" ;;
      symlink-state)
        mv "$pool/treehouse-state.json" "$dir/state.json"
        ln -s "$dir/state.json" "$pool/treehouse-state.json"
        ;;
      ambiguous)
        printf '{"worktrees":[{"name":"17","path":"%s"},{"name":"18","path":"%s"}]}\n' \
          "$slot" "$pool/18/project" > "$pool/treehouse-state.json"
        ;;
    esac
    [ "$mode" != claimed-omission ] || printf 'task=foreign\n' > "$dir/disk/.fm-slot-owner"
    out=$(bash -c '. "$1"; fm_treehouse_pool_path "$2" "$3"' _ \
      "$ROOT/bin/fm-wake-lib.sh" "$dir/project" "$slot")
    status=$?
    case "$mode" in
      valid)
        expect_code 0 "$status" "valid pool entry was rejected"
        [ "$out" = "$slot" ] || fail "resolved the wrong pool path"
        ;;
      absent)
        expect_code 1 "$status" "confirmed non-pool result did not remain distinct"
        [ -z "$out" ] || fail "$mode authorized a pool path"
        ;;
      *)
        expect_code 2 "$status" "$mode was mistaken for a confirmed non-pool result"
        [ -z "$out" ] || fail "$mode authorized a pool path"
        ;;
    esac
  done
  rm -f "$dir/disk/.fm-slot-owner"
  printf '{"worktrees":[{"name":"17","path":"%s"}]}\n' "$slot" > "$pool/treehouse-state.json"
  cp "$pool/treehouse-state.json" "$dir/state.before"
  for mode in relative env multiline; do
    case "$mode" in
      relative) printf "root = '../treehouse-config'\n" > "$dir/project/treehouse.toml" ;;
      env) printf 'root = "%s{FM_TEST_TREEHOUSE_ROOT}"\n' '$' > "$dir/project/treehouse.toml" ;;
      multiline) printf '"root" = """../treehouse-config""" # pool root\n' > "$dir/project/treehouse.toml" ;;
    esac
    out=$(FM_TEST_TREEHOUSE_ROOT="$dir/treehouse-config" bash -c \
      '. "$1"; fm_treehouse_pool_path "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$dir/project" "$slot") \
      || fail "$mode root did not resolve"
    [ "$out" = "$slot" ] || fail "$mode root resolved the wrong slot"
    cmp -s "$pool/treehouse-state.json" "$dir/state.before" || fail "$mode lookup rewrote pool state"
  done
  pass "pool resolution requires one authoritative entry and preserves claim uncertainty"
}


test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_read
test_transient_primary_checkout_is_not_accepted
test_primary_checkout_that_never_settles_fails_at_the_deadline
test_symlinked_pool_slot_records_pool_path
test_symlinked_slot_to_primary_fails_isolation
test_failed_pool_lookup_refuses_spawn
test_pool_resolution_requires_unique_authoritative_entry

echo "# all fm-spawn-worktree-settle tests passed"
