#!/usr/bin/env bash
set -eu
lab=$(mktemp -d "$PWD/.no-jq-check.XXXXXX")
trap 'rm -rf "$lab"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 TREEHOUSE_NO_UPDATE_CHECK=1
mkdir -p "$lab/a/project" "$lab/b" "$lab/tools"
git init -q -b main "$lab/a/project"
printf 'root = "%s"\n' "$lab" > "$lab/a/project/treehouse.toml"
git -C "$lab/a/project" add .
git -C "$lab/a/project" -c user.name=Lab -c user.email=lab@example.invalid commit -qm seed
git clone -q --bare "$lab/a/project" "$lab/origin.git"
git -C "$lab/a/project" remote add origin "$lab/origin.git"
git clone -q "$lab/origin.git" "$lab/b/project"
binary="$PWD/.test-treehouse-tools/treehouse"
slot=$(cd "$lab/a/project" && "$binary" get --lease --lease-holder nojq)
mv "$(dirname "$slot")" "$lab/disk"
ln -s "$lab/disk" "$(dirname "$slot")"
git -C "$lab/a/project" worktree repair "$lab/disk/project"
ln -s "$(command -v node)" "$lab/tools/node"
ln -s "$(command -v git)" "$lab/tools/git"
PATH="$lab/tools" node --input-type=module - "$PWD" "$lab" "$slot" <<'JS'
import {spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';
const [root, lab, expected] = process.argv.slice(2);
assert.equal(spawnSync('jq', ['--version']).error.code, 'ENOENT');
console.log('jq is absent from PATH (exec returned ENOENT).');
const r = spawnSync(process.execPath, [`${root}/bin/fm-treehouse-pool-path.mjs`, `${lab}/b/project`, `${lab}/disk/project`], {encoding:'utf8'});
assert.equal(r.status,0);
assert.equal(r.stdout.trim(),expected);
console.log('Resolved real Treehouse v2.0.1 symlinked slot from a separate clone without jq:');
console.log(r.stdout.trim());
JS
