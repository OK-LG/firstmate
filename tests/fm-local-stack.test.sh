#!/usr/bin/env bash
# bin/fm-local-stack.sh: a bounded number of local website stack slots, each
# with its own port offset, freed on release or once the holder is cleaned up.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-local-stack)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
for id in a b c; do
  fm_write_meta "$HOME_DIR/state/$id.meta" "kind=ship"
done

stack() {
  FM_HOME="$HOME_DIR" FM_LOCAL_STACK_POLL_SECS=1 bash "$ROOT/bin/fm-local-stack.sh" "$@"
}

out=$(stack acquire a) || fail "first acquire failed"
assert_contains "$out" "FM_LOCAL_STACK_SLOT=0" "first task gets slot 0"
assert_contains "$out" "FM_LOCAL_STACK_PORT_OFFSET=0" "slot 0 keeps the default ports"
out=$(stack acquire b) || fail "second acquire failed"
assert_contains "$out" "FM_LOCAL_STACK_SLOT=1" "default limit admits a second stack"
assert_contains "$out" "FM_LOCAL_STACK_PORT_OFFSET=10" "slot 1 shifts ports by the default stride"
out=$(stack acquire a) || fail "repeat acquire failed"
assert_contains "$out" "FM_LOCAL_STACK_SLOT=0" "a holder gets its own slot again"
pass "default limit of two stacks, each with its own port offset"

set +e
err=$(stack acquire c 2>&1 >/dev/null)
rc=$?
set -e
expect_code 3 "$rc" "third stack with both slots held"
assert_contains "$err" "slot 0=a slot 1=b" "the refusal names the holders"
pass "a third stack is refused while both slots are held"

# A waiting acquire gets the slot once the holder releases it.
( sleep 2; stack release b >/dev/null ) &
releaser=$!
out=$(stack acquire c --wait 20) || fail "waiting acquire did not get the released slot"
wait "$releaser" 2>/dev/null || true
assert_contains "$out" "FM_LOCAL_STACK_SLOT=1" "the waiter takes the released slot"
pass "a waiting acquire queues behind a running stack"

# A holder whose task record is gone no longer keeps its slot.
rm -f "$HOME_DIR/state/a.meta"
fm_write_meta "$HOME_DIR/state/d.meta" "kind=ship"
out=$(stack acquire d) || fail "acquire after holder cleanup failed"
assert_contains "$out" "FM_LOCAL_STACK_SLOT=0" "a cleaned-up holder's slot is reused"
pass "a cleaned-up task frees its slot"

printf '3\n' > "$HOME_DIR/config/local-stack-limit"
fm_write_meta "$HOME_DIR/state/e.meta" "kind=ship"
out=$(stack acquire e) || fail "acquire under a raised limit failed"
assert_contains "$out" "FM_LOCAL_STACK_SLOT=2" "a configured limit of three admits a third stack"
assert_contains "$(stack status)" "limit=3 slot 0=d slot 1=c slot 2=e" "status lists every slot"
printf 'two\n' > "$HOME_DIR/config/local-stack-limit"
set +e
err=$(stack acquire e 2>&1)
rc=$?
set -e
expect_code 1 "$rc" "invalid limit"
assert_contains "$err" "positive whole number" "an invalid limit refuses rather than guessing"
pass "the limit is configurable and an invalid limit refuses"
