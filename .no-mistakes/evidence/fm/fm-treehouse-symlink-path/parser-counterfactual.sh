#!/usr/bin/env bash
set -eu
scratch=$(mktemp -d "$PWD/.parser-check.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
cp bin/vendor/smol-toml/* "$scratch/"
git show b800a43d:bin/vendor/smol-toml/util.js > "$scratch/util.js"
rc=0
timeout 2 node --input-type=module - "$scratch/parse.js" <<'JS' || rc=$?
const {parse} = await import(process.argv[2]);
parse('hooks = { post_create = [] # interrupted edit');
JS
printf 'Before R5 fix: exact unterminated inline-table comment exited %s (124 = timeout).\n' "$rc"
[ "$rc" = 124 ]
node --input-type=module - <<'JS'
import assert from 'node:assert/strict';
import {parse} from './bin/vendor/smol-toml/parse.js';
const start = performance.now();
assert.throws(() => parse('hooks = { post_create = [] # interrupted edit'));
console.log(`After R5 fix: same comment rejected in ${(performance.now()-start).toFixed(2)} ms.`);
assert.deepEqual(parse('hooks = { post_create = [] } # final comment').hooks.post_create, []);
console.log('Valid inline-table configuration with final comment parsed successfully.');
JS
