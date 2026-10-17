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

assert_contains "$(stack status)" "limit=2 slot 0=d slot 1=c" "capacity remains two"
stack release d >/dev/null
stack release c >/dev/null
stack run c -- bash -c 'printf "%s:%s\n" "$FM_LOCAL_STACK_SLOT" "$FM_LOCAL_STACK_PORT_OFFSET" > "$1"; while [ ! -f "$2" ]; do sleep 0.05; done' stack "$TMP_ROOT/ports-c" "$TMP_ROOT/stop-c" &
runner=$!
for _ in {1..100}; do [ ! -f "$TMP_ROOT/ports-c" ] || break; sleep 0.05; done
assert_equals '0:0' "$(cat "$TMP_ROOT/ports-c")" "first running command receives slot and offset"
out=$(stack run b -- bash -c 'printf "%s:%s" "$FM_LOCAL_STACK_SLOT" "$FM_LOCAL_STACK_PORT_OFFSET"') || fail "second command failed"
assert_equals '1:10' "$out" "second running command receives distinct ports"
assert_contains "$(stack status)" "slot 0=c slot 1=free" "completed command releases only its lease"
touch "$TMP_ROOT/stop-c"
wait "$runner" || fail "first stack command failed"
assert_contains "$(stack status)" "slot 0=free slot 1=free" "all exited stacks release their leases"
rc=0
stack run b -- bash -c 'exit 7' || rc=$?
expect_code 7 "$rc" "stack command failure propagates"
assert_contains "$(stack status)" "slot 0=free slot 1=free" "failed stack command releases its lease"
pass "run exports distinct port variables and releases leases on success or failure"

python3 - "$ROOT/bin/fm-local-stack.sh" "$HOME_DIR" "$TMP_ROOT" <<'PYTEST'
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time

wrapper, home, temporary = sys.argv[1:]
ready = Path(temporary) / "server-ready"
stopping = Path(temporary) / "server-stopping"
release = Path(temporary) / "server-release"
server = r"""
import json, os, signal, socket, sys, time
from pathlib import Path
ready, stopping, release = map(Path, sys.argv[1:])
def stop(signum, frame):
    stopping.touch()
    while not release.exists():
        time.sleep(0.02)
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    listener.listen()
    staged = ready.with_suffix(".tmp")
    staged.write_text(json.dumps({"pid": os.getpid(), "port": listener.getsockname()[1]}))
    staged.replace(ready)
    while True:
        signal.pause()
"""
process = subprocess.Popen(
    ["bash", wrapper, "run", "b", "--", sys.executable, "-c", server,
     str(ready), str(stopping), str(release)],
    env=dict(os.environ, FM_HOME=home),
)
child_pid = None
def await_file(path):
    deadline = time.monotonic() + 5
    while not path.exists():
        if time.monotonic() >= deadline:
            raise AssertionError("timed out waiting for " + path.name)
        time.sleep(0.02)
try:
    await_file(ready)
    details = json.loads(ready.read_text())
    child_pid = details["pid"]
    process.send_signal(signal.SIGTERM)
    await_file(stopping)
    assert process.poll() is None, "wrapper exited before server shutdown"
    assert (Path(home) / "state/local-stack/0").read_text().strip() == "b", "lease released before server shutdown"
    with socket.socket() as probe:
        assert probe.connect_ex(("127.0.0.1", details["port"])) == 0, "server did not retain its port during shutdown"
    release.touch()
    assert process.wait(timeout=5) == 143, "wrapper did not report termination"
    assert not (Path(home) / "state/local-stack/0").exists(), "shutdown left the lease held"
    try:
        os.kill(child_pid, 0)
    except ProcessLookupError:
        pass
    else:
        raise AssertionError("server survived wrapper termination")
    with socket.socket() as probe:
        assert probe.connect_ex(("127.0.0.1", details["port"])) != 0, "server port still accepts connections"
finally:
    release.touch()
    if child_pid is not None:
        try:
            os.kill(child_pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
PYTEST
pass "termination reaches the stack server and its lease remains held until shutdown"
