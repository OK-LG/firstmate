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

printf '\nFresh spawn before relaunch checks:\n'
mkdir -p "$FM_HOME/data/relaunch-path"
printf '# Task\n## Captain\x27s intent\nExercise an isolated shell workload.\n\n## Firstmate spec\nWait for cleanup.\n' > "$FM_HOME/data/relaunch-path/brief.md"
timeout 100 bash bin/fm-spawn.sh relaunch-path "$LAB/b/project" --scout --backend tmux --harness 'sleep 1'
sleep 2
# Simulate an old task record without changing any other published fields.
sed "s|^worktree=.*|worktree=$physical|" "$FM_HOME/state/relaunch-path.meta" > "$LAB/meta"
mv "$LAB/meta" "$FM_HOME/state/relaunch-path.meta"
printf '\nRelaunch an agent-free legacy physical-path task:\n'
rc=0
timeout 100 bash bin/fm-spawn.sh relaunch-path --relaunch --harness 'sleep 1' || rc=$?
if [ "$rc" -ne 0 ]; then
  tmux capture-pane -p -t fm-lab-path:fm-relaunch-path -S -30 || true
  exit "$rc"
fi
cat "$FM_HOME/state/relaunch-path.meta"
[ "$(sed -n 's/^worktree=//p' "$FM_HOME/state/relaunch-path.meta")" = "$slot" ]
sleep 2
printf '\nRelaunch refuses malformed config before replacing task metadata:\n'
cp "$FM_HOME/state/relaunch-path.meta" "$LAB/meta.before"
printf 'hooks = { post_create = [] # interrupted edit' > "$LAB/b/project/treehouse.toml"
rc=0
timeout 20 bash bin/fm-spawn.sh relaunch-path --relaunch --harness 'sleep 1' > "$LAB/refused" 2>&1 || rc=$?
cat "$LAB/refused"
[ "$rc" -ne 0 ]; [ "$rc" -ne 124 ]; grep -q 'uncertain slot ownership' "$LAB/refused"
cmp "$LAB/meta.before" "$FM_HOME/state/relaunch-path.meta"
git -C "$LAB/b/project" checkout -- treehouse.toml
printf '\nRelaunch rejects a pool symlink targeting the primary checkout:\n'
rm "$(dirname "$slot")"
ln -s "$LAB/b" "$(dirname "$slot")"
tmux send-keys -t fm-lab-path:fm-relaunch-path "cd '$slot'" Enter
sleep 1
rc=0
timeout 20 bash bin/fm-spawn.sh relaunch-path --relaunch --harness 'sleep 1' > "$LAB/refused" 2>&1 || rc=$?
cat "$LAB/refused"
[ "$rc" -ne 0 ]; [ "$rc" -ne 124 ]; grep -q 'primary\|isolat' "$LAB/refused"
cmp "$LAB/meta.before" "$FM_HOME/state/relaunch-path.meta"
rm "$(dirname "$slot")"
ln -s "$LAB/disk/1" "$(dirname "$slot")"
tmux send-keys -t fm-lab-path:fm-relaunch-path "cd '$physical'" Enter
sleep 1
bash bin/fm-teardown.sh relaunch-path --force
printf '\nAll live relaunch scenarios passed.\n'
