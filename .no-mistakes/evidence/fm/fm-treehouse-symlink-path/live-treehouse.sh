#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=/root/.no-mistakes/evidence/01M4GV03R6385M9SNN706PDDFS
LAB=$(mktemp -d "$ROOT/.treehouse-live.XXXXXX")
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 TREEHOUSE_NO_UPDATE_CHECK=1
export PATH="$ROOT/.test-treehouse-tools:$PATH"
unset FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX TMUX_PANE TASKS_AXI_FILE TASKS_AXI_BACKEND
bash bin/fm-lab-home.sh create "$LAB/home"
export FM_HOME="$LAB/home"
SOCKET_DIR=$(bash bin/fm-lab-home.sh tmux-dir "$FM_HOME")
export TMUX_TMPDIR="$SOCKET_DIR"
worker=
cleanup() {
  [ -z "$worker" ] || kill "$worker" 2>/dev/null || true
  tmux -L fm-lab kill-server 2>/dev/null || true
  bash "$ROOT/bin/fm-lab-home.sh" teardown "$FM_HOME"
  rm -rf "$LAB"
}
trap cleanup EXIT
mkdir -p "$LAB/a/project" "$LAB/b" "$LAB/storage" "$LAB/disk"
git init -q -b main "$LAB/a/project"
printf 'seed\n' > "$LAB/a/project/seed"
printf 'root = "%s"\nmax_trees = 1\n' "$LAB/storage" > "$LAB/a/project/treehouse.toml"
git -C "$LAB/a/project" add .
git -C "$LAB/a/project" -c user.name=Lab -c user.email=lab@example.invalid commit -qm seed
git clone -q --bare "$LAB/a/project" "$LAB/origin.git"
git -C "$LAB/a/project" remote add origin "$LAB/origin.git"
git clone -q "$LAB/origin.git" "$LAB/b/project"
project="$LAB/a/project"
slot=$(cd "$project" && treehouse get --lease --lease-holder lab)
pool=$(dirname "$(dirname "$slot")")
printf 'Treehouse version: '; treehouse --version
printf 'Acquired authoritative pool path: %s\n' "$slot"
(cd "$project" && treehouse return --force "$slot")
mv "$(dirname "$slot")" "$LAB/disk/1"
ln -s "$LAB/disk/1" "$(dirname "$slot")"
physical="$LAB/disk/1/project"
git -C "$project" worktree repair "$physical"
state="$pool/treehouse-state.json"
cp "$state" "$LAB/healthy-state"
printf '\nPhysical-path rejection from real Treehouse:\n'
rc=0
(cd "$project" && treehouse return --force "$physical") || rc=$?
[ "$rc" -ne 0 ]
printf '\nShared-pool resolution from a separate clone:\n'
resolved=$(node bin/fm-treehouse-pool-path.mjs "$LAB/b/project" "$physical")
[ "$resolved" = "$slot" ]; printf '%s\n' "$resolved"
# Only this private tmux server is used. The workload is a real shell sleep,
# through fm-spawn's supported raw-command interface; no harness is simulated.
tmux -L fm-lab -f /dev/null new-session -d -s fm-lab-path -n control -c "$ROOT" 'bash --noprofile --norc'
export TMUX="$(tmux -L fm-lab display-message -p '#{socket_path}'),$(tmux -L fm-lab display-message -p '#{pid}'),0"
tmux set-option -g default-shell /bin/bash
tmux set-option -g default-command 'bash --noprofile --norc'
tmux set-environment -g PATH "$PATH"
tmux set-environment -g TREEHOUSE_NO_UPDATE_CHECK 1
write_meta() {
  local id=$1 wt=$2 proj=$3
  printf 'window=fm-lab-path:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nkind=scout\n' "$id" "$id" "$wt" "$proj" > "$FM_HOME/state/$id.meta"
}
printf '\nLegacy physical-path teardown through fm-teardown:\n'
write_meta legacy "$physical" "$LAB/b/project"
printf 'task=legacy\nhome=%s\n' "$FM_HOME" > "$LAB/disk/1/.fm-slot-owner"
bash bin/fm-teardown.sh legacy --force
[ ! -e "$FM_HOME/state/legacy.meta" ]; [ ! -e "$LAB/disk/1/.fm-slot-owner" ]
(cd "$project" && treehouse status)
printf '\nSpawn into the same symlinked pool through a separate clone:\n'
mkdir -p "$FM_HOME/data/live-path"
printf '# Task\n## Captain\x27s intent\nExercise an isolated shell workload.\n\n## Firstmate spec\nWait for cleanup.\n' > "$FM_HOME/data/live-path/brief.md"
rc=0
timeout 100 bash bin/fm-spawn.sh live-path "$LAB/b/project" --scout --backend tmux --harness 'sleep 120' || rc=$?
if [ "$rc" -ne 0 ]; then
  tmux capture-pane -p -t fm-lab-path:fm-live-path -S -100 || true
  exit "$rc"
fi
cat "$FM_HOME/state/live-path.meta"
[ "$(sed -n 's/^worktree=//p' "$FM_HOME/state/live-path.meta")" = "$slot" ]
cat "$LAB/disk/1/.fm-slot-owner"
bash bin/fm-teardown.sh live-path --force
[ ! -e "$FM_HOME/state/live-path.meta" ]; [ ! -e "$LAB/disk/1/.fm-slot-owner" ]
printf '\nReacquire freed symlinked slot with real Treehouse:\n'
again=$(cd "$LAB/b/project" && treehouse get --lease --lease-holder successor)
[ "$again" = "$slot" ]; printf '%s\n' "$again"
cp "$state" "$LAB/healthy-state"
write_meta stale "$physical" "$project"
cp "$FM_HOME/state/stale.meta" "$LAB/meta.before"
printf 'task=successor\nhome=%s\n' "$FM_HOME" > "$LAB/disk/1/.fm-slot-owner"
cp "$LAB/disk/1/.fm-slot-owner" "$LAB/claim.before"
printf 'must survive\n' > "$physical/sentinel"
git -C "$physical" checkout -qb foreign-work
(cd "$physical" && exec sleep 240) & worker=$!
for mode in malformed-config comment-eof corrupt-state recovered-omission missing-state; do
  cp "$LAB/healthy-state" "$state"
  git -C "$project" checkout -- treehouse.toml
  case "$mode" in
    malformed-config) printf 'root = [\n' > "$project/treehouse.toml" ;;
    comment-eof) printf 'hooks = { post_create = [] # interrupted edit' > "$project/treehouse.toml" ;;
    corrupt-state) printf '{"worktrees":[' > "$state" ;;
    recovered-omission)
      printf '{"worktrees":[' > "$state"
      (cd "$project" && treehouse status)
      cat "$state"
      ;;
    missing-state) rm "$state" ;;
  esac
  [ ! -e "$state" ] || cp "$state" "$LAB/state.before"
  printf '\nAdversarial teardown: %s\n' "$mode"
  rc=0
  timeout 10 bash bin/fm-teardown.sh stale --force > "$LAB/refusal" 2>&1 || rc=$?
  cat "$LAB/refusal"
  [ "$rc" -ne 0 ]; [ "$rc" -ne 124 ]; grep -q 'slot ownership is uncertain' "$LAB/refusal"
  cmp "$LAB/meta.before" "$FM_HOME/state/stale.meta"
  cmp "$LAB/claim.before" "$LAB/disk/1/.fm-slot-owner"
  [ ! -e "$state" ] || cmp "$LAB/state.before" "$state"
  kill -0 "$worker"; test -f "$physical/sentinel"
  git -C "$project" show-ref --verify refs/heads/foreign-work
  printf 'Preserved: pool evidence, metadata, foreign claim, process, checkout and branch.\n'
done
kill "$worker"; wait "$worker" || true; worker=
git -C "$project" checkout -- treehouse.toml
cp "$LAB/healthy-state" "$state"
rm "$FM_HOME/state/stale.meta"
printf '\nOrdinary non-pool worktree retains Treehouse refusal:\n'
git -C "$project" worktree add -q --detach "$LAB/ordinary"
write_meta ordinary "$LAB/ordinary" "$project"
rc=0
bash bin/fm-teardown.sh ordinary --force > "$LAB/nonpool.out" 2>&1 || rc=$?
cat "$LAB/nonpool.out"
[ "$rc" -ne 0 ]; grep -q 'not managed by treehouse' "$LAB/nonpool.out"
[ -f "$FM_HOME/state/ordinary.meta" ]; [ -f "$LAB/ordinary/.git" ]
printf 'Preserved: ordinary worktree and task metadata.\n'
printf '\nAll live path and refusal scenarios passed.\n'
