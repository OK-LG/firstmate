#!/usr/bin/env bash
# Behavior tests for the zcode crewmate/scout adapter, Phase B.
#
# The facts pinned here are the ones a zcode release could silently change and
# the ones a wrong guess would make dangerous:
#   1. zcode publishes no harness-identity marker of its own (its ZCODE_* env
#      surface is configuration only), so FM_ZCODE_HARNESS=zcode is a
#      Firstmate-owned precedence override that needs REAL zcode ancestry, the
#      omp pattern: inert when it leaks into another harness's worker.
#   2. The anchored process-name set is the wrapper's own `zcode` plus the
#      kernel comm values of its runtime children (verified live on
#      zcode-runtime 0.16.5 by reading /proc/<pid>/comm: `zcode-cli` and
#      `zcode-node-repl`; the `zco` and `zcode-c` spellings are `ps --forest`
#      column artifacts no real process carries); an unrelated name merely
#      containing the fragment must never claim the identity, and a bare node
#      launcher is claimed only through its zcode bin path in the interpreter
#      args fallback.
#   3. The launch is the HEADLESS single-prompt run: --prompt carries the
#      brief, --mode yolo is pinned explicitly rather than trusted from the
#      CLI default, --cwd anchors the run, foreign markers are cleared -
#      including rovo's two, because a marker beats args-strength ancestry -
#      and the Firstmate marker is established at the launch boundary. The
#      headless flag set has no --model and no effort flag (verified against
#      0.16.5: --model, --effort, and --reasoning-effort are all rejected
#      with the help dump), so both axes are recorded in metadata and never
#      reach the launch command. A fresh launch carries no --resume; only a
#      relaunch whose prior zcode incarnation recorded a session does.
#   4. Turn lifecycle is the Phase B semantic wiring: a guarded global
#      UserPromptSubmit/Stop hook pair installed into ~/.zcode/cli/config.json
#      by bin/fm-zcode-turnend-hook.sh (verified live on 0.16.5: both events
#      fire headless with a Claude-compatible payload), gated per task by a
#      token pointer, opening and closing the busy record (source zcode-hook),
#      touching the turn-end marker, and recording the zcode session id. The
#      rendered-tail classifier stays as the no-record fallback: no default
#      busy signature ships, and even with FM_BUSY_ZCODE_REGEX configured a
#      non-matching tail is unknown, never idle.
#   5. zcode is verified for primary sessions and crewmate/scout launches, but
#      a secondmate launch is still refused (its own surface, no dated live
#      pass yet), and a missing zcode bin refuses the spawn instead of
#      launching a pane that dies on command-not-found.
#   6. Control is signal-shaped: interrupt is C-c (SIGINT through the pane's
#      foreground process group, verified live to cancel a mid-turn run and
#      end the HEADLESS process with status 130 and no Stop hook), there is
#      no composer to clear, no cancellation acknowledgement to observe, no
#      typed exit command - and the headless interrupt legitimately ENDS the
#      worker process, so both the interrupt verification and the exit verb
#      accept the dead state as the documented success shape (one C-c is the
#      exit). The interrupt record is variant-shaped: a meta recording
#      zcode_tui=1 - the TUI variant, whose C-c cancels the turn and leaves
#      the TUI alive - answers no, so the verification requires the agent
#      alive there.
#   7. The pane-liveness classifier (bin/fm-agent-process-lib.sh) knows the
#      same anchored name set plus the wrapper's node-launcher shapes - the
#      install path and the npm-global lib path - because fm-control's
#      interrupt/exit/relaunch verify against it and an unattributed pane can
#      never confirm a lifecycle action.
#   8. The opt-in TUI variant (fm-spawn --zcode-tui): the launch template goes
#      BARE (no --prompt; a positional prompt is a subcommand parse error, not
#      a queued TUI prompt - verified live on 0.16.5), the variant is recorded
#      as zcode_tui=1 while the default headless spawn records no line, the
#      brief arrives as a one-line pointer through the kimi launch-then-send
#      gates, and delivery is confirmed STRUCTURALLY by the same global
#      UserPromptSubmit hook flipping the busy record to source=zcode-hook.
#      The readiness gate answers only painted-TUI evidence - the pane's own
#      echo of the launch command is rejected by its launch marker, and a
#      positive must hold on two consecutive captures - because the PR#6
#      review reproduced a bare identity grep matching that echo ~2.5s before
#      the real TUI painted, silently discarding the once-typed pointer; the
#      fake renders exactly that echo behind a paint delay, and the pointer-
#      state log is the regression net. Delivery is verify-and-retry, never a
#      single fire-and-forget type: a swallowed first pointer is recovered by
#      one bare-Enter probe (a verified no-op on an empty composer) and a
#      retype, and every retry logs one best-effort stderr line so a field
#      swallow is observable in the spawn's output, not only here. The flag
#      is refused off zcode and refused on a relaunch, whose
#      variant comes from the task's own record - and a relaunch reuses that
#      variant in both directions.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry. A suite run
# from inside another harness inherits those markers, which outrank the fake
# ancestry the detection cases set up. Drop the ambient markers so the asserted
# verdict does not depend on which harness launched the suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  ATLASSIAN_AGENT_TYPE ROVODEV_CLI GEMINI_CLI AGENT FM_OMP_HARNESS FM_ZCODE_HARNESS

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
ZCODE_HOOK="$ROOT/bin/fm-zcode-turnend-hook.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-zcode-harness)
JQ_BIN=$(command -v jq) || fail "test needs jq"
BASE_PATH=${FM_TEST_BASE_PATH:-$(dirname "$(command -v python3)"):/usr/bin:/bin:/usr/sbin:/sbin}
ZCODE_TASK_TMPS=()

cleanup_zcode_harness() {
  local d
  for d in "${ZCODE_TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  rm -rf "$TMP_ROOT"
}
trap cleanup_zcode_harness EXIT

# --- 1. Detection --------------------------------------------------------------

# A fake ps whose comm/args answers come from the environment, so each case
# drives one exact process identity through the real walk.
make_fake_ps() {  # <dir> -> echoes <bindir>
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' "${FAKE_PS_COMM:?}"; exit 0 ;;
  *"args="*) printf '%s\n' "${FAKE_PS_ARGS:-}"; exit 0 ;;
  *"ppid="*) printf '1\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$dir/ps"
  printf '%s\n' "$dir"
}

detect() {  # [env var assignments via caller] -> verdict
  PATH="$FAKE_PS_BIN:$PATH" "$HARNESS"
}

test_zcode_ancestry_detects_every_observed_process_name() {
  local FAKE_PS_BIN out
  FAKE_PS_BIN=$(make_fake_ps "$TMP_ROOT/ps-names")
  for name in zcode /usr/local/bin/zcode zcode-cli zcode-node-repl; do
    out=$(FAKE_PS_COMM=$name detect)
    [ "$out" = zcode ] \
      || fail "the observed live name '$name' must detect as zcode by ancestry, got '$out'"
  done
  # The ps --forest artifacts are NOT real process names and must not match:
  # `zco` would claim an unrelated command literally named zco.
  for artifact in zco zcode-c; do
    out=$(FAKE_PS_COMM=$artifact FAKE_PS_ARGS="$artifact" detect)
    [ "$out" != zcode ] \
      || fail "the ps --forest artifact '$artifact' must not detect as zcode, got '$out'"
  done
  pass "fm-harness: ancestry detects the wrapper and kernel comm names, not ps artifacts"
}

test_zcode_ancestry_rejects_unrelated_mentions() {
  local FAKE_PS_BIN out
  FAKE_PS_BIN=$(make_fake_ps "$TMP_ROOT/ps-negatives")
  out=$(FAKE_PS_COMM=zcodegraph FAKE_PS_ARGS='zcodegraph --serve' detect)
  [ "$out" != zcode ] \
    || fail "an unrelated zcodegraph command must not detect as zcode, got '$out'"
  out=$(FAKE_PS_COMM=bash FAKE_PS_ARGS='bash -c "echo zcode --help"' detect)
  [ "$out" != zcode ] \
    || fail "a later shell argument naming zcode must not detect as zcode, got '$out'"
  # A bare node interpreter is claimed ONLY through its script path: an
  # unrelated node command stays unknown rather than matching the fragment.
  out=$(FAKE_PS_COMM=node FAKE_PS_ARGS='node unrelated-server.js' detect)
  [ "$out" = unknown ] \
    || fail "an unrelated node command must stay unknown, got '$out'"
  out=$(FAKE_PS_COMM=node FAKE_PS_ARGS='node /srv/zcode-app-cli/bin/zcode.js -p hi' detect)
  [ "$out" = zcode ] \
    || fail "the node launcher running the zcode bin must detect as zcode through its args, got '$out'"
  pass "fm-harness: ancestry rejects unrelated zcode mentions and claims a bare node only via its zcode path"
}

test_zcode_marker_needs_real_ancestry() {
  local FAKE_PS_BIN out
  FAKE_PS_BIN=$(make_fake_ps "$TMP_ROOT/ps-marker")
  # The marker beats an inherited CLAUDECODE only under a real zcode ancestor.
  out=$(CLAUDECODE=1 FM_ZCODE_HARNESS=zcode FAKE_PS_COMM=zcode detect)
  [ "$out" = zcode ] \
    || fail "FM_ZCODE_HARNESS under a zcode ancestor must outrank an inherited CLAUDECODE, got '$out'"
  # ...and is inert when it leaks into a worker with no zcode ancestor.
  out=$(CLAUDECODE=1 FM_ZCODE_HARNESS=zcode FAKE_PS_COMM=claude detect)
  [ "$out" = claude ] \
    || fail "a leaked FM_ZCODE_HARNESS without a zcode ancestor must not relabel a claude worker, got '$out'"
  out=$(CLAUDECODE=1 FM_ZCODE_HARNESS=zcode FAKE_PS_COMM=bash FAKE_PS_ARGS='bash -lc ls' detect)
  [ "$out" != zcode ] \
    || fail "the marker alone must never claim the zcode identity, got '$out'"
  pass "fm-harness: FM_ZCODE_HARNESS is a precedence override that needs real zcode ancestry"
}

# --- 1b. Pane-liveness classification -----------------------------------------

# bin/fm-agent-process-lib.sh is the classifier every lifecycle verification
# reads (fm-control interrupt/exit/relaunch, session-start liveness, recovery):
# `other` folds to ambiguous, and an ambiguous pane can never verify a
# lifecycle action. The rows below pin every observed zcode surface and the
# negatives that keep a stranger's pane out.
test_zcode_pane_liveness_classifies_every_observed_surface() {
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-agent-process-lib.sh"
  # The wrapper's own comm and every kernel comm of the runtime children.
  for name in zcode zcode-cli zcode-node-repl; do
    [ "$(fm_agent_process_classify_name "$name")" = agent ] \
      || fail "the observed live name '$name' must classify as an agent pane"
  done
  # The ps --forest artifacts are not real names; `zco` would claim strangers.
  for artifact in zco zcode-c; do
    [ "$(fm_agent_process_classify_name "$artifact")" != agent ] \
      || fail "the ps artifact '$artifact' must not classify an agent pane"
  done
  # The install-path shape: the bin's own path as the pane command.
  [ "$(fm_agent_process_classify_name /usr/local/bin/zcode)" = agent ] \
    || fail "the zcode install path must classify as an agent pane"
  # The wrapper's node-launcher shape, the npm-global lib bin path, claimed
  # through path-component evidence as an interpreter's argv[0]...
  [ "$(fm_agent_process_classify_name node /usr/lib/node_modules/zcode-app-cli/bin/zcode)" = agent ] \
    || fail "a node pane whose argv[0] is the zcode lib bin must classify agent"
  [ "$(fm_agent_process_classify_name '' /usr/lib/node_modules/zcode-app-cli/bin/zcode)" = agent ] \
    || fail "an argv[0]-only zcode lib path must classify agent"
  # ...or through the flattened command line a backend hands over.
  [ "$(fm_agent_process_classify node node \
      'node /usr/lib/node_modules/zcode-app-cli/bin/zcode --mode yolo --cwd /x --prompt hi')" = agent ] \
    || fail "the node launcher running the zcode bin must classify agent through its args"
  [ "$(fm_agent_process_classify node node \
      'node /usr/local/bin/zcode --mode yolo --cwd /x --prompt hi')" = agent ] \
    || fail "the node launcher running the install-path bin must classify agent through its args"
  # The safety half: an unrelated node process stays other, never agent, and
  # the callers fold `other` into ambiguous rather than dead.
  [ "$(fm_agent_process_classify node /usr/bin/node 'node unrelated-server.js')" = other ] \
    || fail "an unrelated node process must stay other, never agent"
  [ "$(fm_agent_process_classify node node \
      'node unrelated-server.js --prompt \"run zcode tests\"')" = other ] \
    || fail "a later argument naming zcode must not classify an unrelated node pane agent"
  # Anchored names keep fragment decoys out, exactly like omp's.
  for decoy in zcodegraph zcod zco2; do
    [ "$(fm_agent_process_classify_name "$decoy")" != agent ] \
      || fail "'$decoy' merely contains a zcode name fragment and must not classify agent"
  done
  [ "$(fm_agent_process_classify_name /usr/local/bin/zcodegraph)" != agent ] \
    || fail "an unrelated zcodegraph path must not classify agent"
  # Neighbours must not regress.
  [ "$(fm_agent_process_classify_name agy)" = agent ] || fail "agy regressed"
  [ "$(fm_agent_process_classify_name zsh)" = shell ] || fail "zsh regressed"
  pass "fm-agent-process-lib: every zcode surface classifies agent; unrelated node and fragment decoys stay out"
}

# --- 2. Control mechanics -------------------------------------------------------

test_zcode_control_mechanics_are_the_verified_ones() {
  fm_control_harness_supported zcode || fail "zcode must be a supported control harness"
  [ "$(fm_control_harness_family zcode)" = zcode ] || fail "zcode must map to its own family"
  fm_control_harness_family zcodegraph \
    && fail "zcodegraph must not be guessed into the zcode adapter" || true
  fm_control_harness_family zcode-cli \
    && fail "zcode-cli must not be guessed into the zcode adapter (the canonical launch records zcode)" || true
  fm_control_harness_supports_kind zcode scout || fail "zcode must run scouts"
  fm_control_harness_supports_kind zcode ship || fail "zcode must run ships"
  fm_control_harness_supports_kind zcode secondmate \
    && fail "zcode must refuse secondmates" || true
  [ "$(fm_control_interrupt_key zcode)" = C-c ] \
    || fail "zcode must interrupt on C-c, SIGINT through the pane's foreground process group"
  [ "$(fm_control_interrupt_repeat zcode)" = 1 ] || fail "zcode must interrupt on a single C-c"
  [ -z "$(fm_control_interrupt_clear_key zcode)" ] \
    || fail "zcode has no composer, so no clear key may exist"
  [ "$(fm_control_interrupt_ack_source zcode)" = none ] \
    || fail "the headless SIGINT path prints no acknowledgement, so the ack source is none"
  fm_control_exit_command zcode \
    && fail "zcode has no composer and no typed exit command; the table must refuse to name one" || true
  # The headless process IS the turn: a C-c interrupt ends the worker process
  # (verified live: exit 130, no Stop hook), and the exit verb is that same
  # signal, not a typed command. The record is variant-shaped: an empty
  # variant value is the headless meta (no zcode_tui line) and keeps the
  # process-ends answer, while a recorded TUI incarnation survives its
  # interrupt and must not answer process-ends.
  fm_control_interrupt_ends_process zcode \
    || fail "zcode's interrupt must be recorded as legitimately ending the worker process"
  fm_control_interrupt_ends_process zcode '' \
    || fail "a zcode meta with no variant line is the headless shape and must keep the process-ends answer"
  fm_control_interrupt_ends_process zcode 1 \
    && fail "a recorded TUI variant survives its interrupt and must not answer process-ends" || true
  fm_control_interrupt_ends_process claude \
    && fail "a TUI adapter's interrupt must never claim to end the process" || true
  fm_control_exit_is_signal_shutdown zcode \
    || fail "zcode's exit verb must be signal-shaped"
  fm_control_exit_is_signal_shutdown claude \
    && fail "claude's exit verb is a typed command, not a signal" || true
  pass "fm-control-lib: zcode control is signal-shaped - C-c interrupt and signal exit, no composer"
}

# --- 3. Busy classification -----------------------------------------------------

test_zcode_busy_signature_is_configured_only() {
  local state="$TMP_ROOT/busy-state"
  mkdir -p "$state"
  # No default signature ships: the headless mode renders nothing mid-turn
  # (verified on zcode-runtime 0.16.5 over pipe and PTY), so even a tail that
  # would match another harness's busy token classifies unknown.
  out=$(fm_busy_classify tmux fake:w zcode t-busy "$state" 'esc to cancel')
  [ "$out" = "unknown zcode-regex" ] \
    || fail "without a configured signature no tail may read busy, got '$out'"
  out=$(FM_BUSY_ZCODE_REGEX='esc[[:space:]]+to[[:space:]]+cancel' \
    fm_busy_classify tmux fake:w zcode t-busy "$state" 'esc to cancel')
  [ "$out" = "busy zcode-regex" ] \
    || fail "a configured signature matching the tail must read busy, got '$out'"
  out=$(FM_BUSY_ZCODE_REGEX='esc[[:space:]]+to[[:space:]]+cancel' \
    fm_busy_classify tmux fake:w zcode t-busy "$state" 'all done here')
  [ "$out" = "unknown zcode-regex" ] \
    || fail "a non-matching tail is can't-tell, never idle, got '$out'"
  # Harness scoping: zcode's configured signature never borrows grok's token
  # and grok's arm never reads zcode's configuration.
  out=$(FM_BUSY_ZCODE_REGEX='Ctrl\+c:cancel' \
    fm_busy_classify tmux fake:w grok t-busy "$state" 'Ctrl+c:cancel')
  [ "$out" = "busy grok-regex" ] \
    || fail "grok must classify through its own signature, not zcode's configuration, got '$out'"
  out=$(FM_BUSY_ZCODE_REGEX='never-matches-anything' \
    fm_busy_classify tmux fake:w grok t-busy "$state" 'Ctrl+c:cancel')
  [ "$out" = "busy grok-regex" ] \
    || fail "a zcode signature must not change grok's verdict, got '$out'"
  # A zcode harness never borrows grok's token either.
  out=$(fm_busy_classify tmux fake:w zcode t-busy "$state" 'Ctrl+c:cancel')
  [ "$out" = "unknown zcode-regex" ] \
    || fail "grok's busy token must not read busy for zcode, got '$out'"
  pass "fm-busy-lib: zcode classifies busy only through FM_BUSY_ZCODE_REGEX and never falls to idle"
}

# --- 4. Hook installer ----------------------------------------------------------

make_hook_config_home() {  # <dir> [config-json]
  local home=$1 config=${2:-}
  [ -n "$config" ] || config='{"provider":{"zai":{"kind":"anthropic"}}}'
  mkdir -p "$home/.zcode/cli"
  printf '%s\n' "$config" > "$home/.zcode/cli/config.json"
  printf '%s\n' "$home"
}

test_zcode_hook_install_is_surgical_idempotent_and_removable() {
  local home config before after
  home=$(make_hook_config_home "$TMP_ROOT/hook-surgery" \
    '{"provider":{"zai":{"kind":"anthropic"}},"hooks":{"enabled":false,"timeoutMs":60000,"events":{"Stop":[{"hooks":[{"type":"command","command":"printf foreign"}]}]}}}')
  config="$home/.zcode/cli/config.json"
  before=$(mktemp)
  python3 -c 'import json,sys; json.dump(json.load(open(sys.argv[1]), parse_constant=lambda c: None), sys.stdout, sort_keys=True)' "$config" > "$before"

  HOME="$home" "$ZCODE_HOOK" install || fail "zcode hook install refused a realistic config"
  python3 - "$config" <<'PY' || fail "installed config did not keep the foreign hook and gain ours"
import json, sys
cfg = json.load(open(sys.argv[1]))
hooks = cfg["hooks"]
assert hooks["enabled"] is True, "install must raise the runtime hook gate"
stop = [h["command"] for e in hooks["events"]["Stop"] for h in e["hooks"]]
assert any("fm-turn-end.sh" in c for c in stop), "our Stop entry is missing"
assert "printf foreign" in stop, "the foreign Stop entry was dropped"
ups = [h["command"] for e in hooks["events"]["UserPromptSubmit"] for h in e["hooks"]]
assert any("fm-turn-end.sh" in c for c in ups), "our UserPromptSubmit entry is missing"
PY
  HOME="$home" "$ZCODE_HOOK" install || fail "second zcode hook install failed"
  python3 - "$config" <<'PY' || fail "second install was not idempotent"
import json, sys
cfg = json.load(open(sys.argv[1]))
ours = 0
for entries in cfg["hooks"]["events"].values():
    for entry in entries:
        for hook in entry["hooks"]:
            if "fm-turn-end.sh" in hook["command"]:
                ours += 1
assert ours == 2, f"expected exactly one install per owned event, found {ours}"
PY
  [ -x "$home/.zcode/cli/fm-turn-end.sh" ] || fail "install must write the hook script"
  [ -d "$home/.zcode/cli/fm-turn-end.d" ] || fail "install must create the registry"

  HOME="$home" "$ZCODE_HOOK" remove || fail "zcode hook removal failed"
  after=$(mktemp)
  python3 -c 'import json,sys; json.dump(json.load(open(sys.argv[1])), sys.stdout, sort_keys=True)' "$config" > "$after"
  python3 - "$before" "$after" <<'PY' || fail "removal did not restore the pre-install config semantically"
import json, sys
before = json.load(open(sys.argv[1]))
after = json.load(open(sys.argv[2]))
assert before == after, "removal must restore every foreign leaf and the pre-install enabled value"
PY
  [ ! -e "$home/.zcode/cli/fm-turn-end.sh" ] || fail "removal left the Firstmate hook script"
  [ ! -e "$home/.zcode/cli/fm-turn-end.d" ] || fail "removal left the Firstmate registry"
  [ ! -e "$home/.zcode/cli/fm-turn-end.state" ] || fail "removal left the install-state record"
  pass "zcode hook install is idempotent and removal restores the pre-install config exactly"
}

test_zcode_hook_removal_restores_every_observed_pre_install_shape() {
  local home config before after out rc
  # The vendor-default shipped shape: the hook gate defaulted false and every
  # event key pre-created as an empty array - the exact config.json the
  # installer meets on a real machine, whose empty owned keys a naive strip
  # would delete and whose gate a raise-without-record would leave flipped.
  home=$(make_hook_config_home "$TMP_ROOT/hook-vendor" \
    '{"provider":{"zai":{"kind":"anthropic"}},"hooks":{"enabled":false,"timeoutMs":60000,"maxOutputBytes":32768,"events":{"SessionStart":[],"UserPromptSubmit":[],"PreToolUse":[],"PermissionRequest":[],"PostToolUse":[],"PostToolUseFailure":[],"Stop":[]}}}')
  config="$home/.zcode/cli/config.json"
  before=$(jq -S . "$config")
  HOME="$home" "$ZCODE_HOOK" install || fail "install refused the vendor-default config"
  HOME="$home" "$ZCODE_HOOK" install || fail "second install on the vendor-default config failed"
  [ "$(jq -r '.hooks.enabled' "$config")" = true ] \
    || fail "install must raise the runtime hook gate"
  HOME="$home" "$ZCODE_HOOK" remove || fail "removal of the vendor-default install failed"
  after=$(jq -S . "$config")
  [ "$before" = "$after" ] \
    || fail "install+remove must restore the vendor-default config semantically exactly"
  # enabled:true pre-install must be restored as true, and an absent gate key
  # must be removed again rather than left raised or recorded as a value.
  home=$(make_hook_config_home "$TMP_ROOT/hook-true" \
    '{"hooks":{"enabled":true,"events":{"Stop":[],"UserPromptSubmit":[]}}}')
  config="$home/.zcode/cli/config.json"
  before=$(jq -S . "$config")
  HOME="$home" "$ZCODE_HOOK" install || fail "install refused the enabled:true shape"
  HOME="$home" "$ZCODE_HOOK" remove || fail "removal refused the enabled:true shape"
  [ "$before" = "$(jq -S . "$config")" ] \
    || fail "install+remove must restore the enabled:true shape exactly"
  home=$(make_hook_config_home "$TMP_ROOT/hook-absent" '{"hooks":{"events":{"Stop":[]}}}')
  config="$home/.zcode/cli/config.json"
  before=$(jq -S . "$config")
  HOME="$home" "$ZCODE_HOOK" install || fail "install refused the enabled-absent shape"
  HOME="$home" "$ZCODE_HOOK" remove || fail "removal refused the enabled-absent shape"
  [ "$before" = "$(jq -S . "$config")" ] \
    || fail "install+remove must restore the enabled-absent shape exactly"
  # Without the install-state record, removal fails closed rather than
  # guessing the pre-install leaves - the record is what makes removal
  # faithful, so its absence is a stop-and-reinstall condition.
  home=$(make_hook_config_home "$TMP_ROOT/hook-nostate" \
    '{"hooks":{"enabled":false,"events":{"Stop":[],"UserPromptSubmit":[]}}}')
  HOME="$home" "$ZCODE_HOOK" install || fail "install for the missing-state case failed"
  rm "$home/.zcode/cli/fm-turn-end.state"
  rc=0
  out=$(HOME="$home" "$ZCODE_HOOK" remove 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "removal without the install-state record must refuse"
  assert_contains "$out" "install-state file is missing" \
    "the missing-state refusal lacked its concrete reason"
  pass "zcode hook removal restores the vendor-default, enabled-true, and enabled-absent shapes exactly"
}

test_zcode_hook_fails_closed_on_missing_malformed_or_surprising_config() {
  local missing malformed symlinked foreign_event out rc
  missing="$TMP_ROOT/hook-missing"
  malformed="$TMP_ROOT/hook-malformed"
  symlinked="$TMP_ROOT/hook-symlink"
  foreign_event="$TMP_ROOT/hook-foreign-event"
  mkdir -p "$missing/.zcode/cli" "$malformed/.zcode/cli" "$symlinked/.zcode/cli" "$foreign_event/.zcode/cli"

  rc=0
  out=$(HOME="$missing" "$ZCODE_HOOK" install 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "missing zcode config was accepted"
  assert_contains "$out" "missing" "missing config refusal lacked its concrete reason"

  printf '{"broken' > "$malformed/.zcode/cli/config.json"
  cp "$malformed/.zcode/cli/config.json" "$malformed/before"
  rc=0
  out=$(HOME="$malformed" "$ZCODE_HOOK" install 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "malformed zcode config was accepted"
  assert_contains "$out" "malformed JSON" "malformed config refusal lacked its concrete reason"
  cmp -s "$malformed/before" "$malformed/.zcode/cli/config.json" \
    || fail "malformed config refusal changed config bytes"

  ln -s /etc/hostname "$symlinked/.zcode/cli/config.json"
  rc=0
  out=$(HOME="$symlinked" "$ZCODE_HOOK" install 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a symlinked zcode config was accepted"
  assert_contains "$out" "not a regular non-symlink" "symlink refusal lacked its concrete reason"

  # A Firstmate hook reference in an event this installer does not own is a
  # surprise, refused rather than silently rewritten (kimi parity).
  printf '{"hooks":{"enabled":true,"events":{"PreToolUse":[{"hooks":[{"type":"command","command":"bash ~/.zcode/cli/fm-turn-end.sh"}]}]}}}' \
    > "$foreign_event/.zcode/cli/config.json"
  rc=0
  out=$(HOME="$foreign_event" "$ZCODE_HOOK" install 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a Firstmate reference in an unowned event was accepted"
  assert_contains "$out" "does not own" "the unowned-event refusal lacked its concrete reason"
  [ ! -e "$foreign_event/.zcode/cli/fm-turn-end.sh" ] \
    || fail "a refused install wrote the hook script"
  pass "zcode hook install refuses missing, malformed, symlinked, and surprising config without writing"
}

test_zcode_hook_install_refuses_without_jq() {
  local home fakebin out rc
  home=$(make_hook_config_home "$TMP_ROOT/hook-no-jq")
  fakebin=$(fm_fakebin "$TMP_ROOT/hook-no-jq-fake")
  ln -s "$(command -v bash)" "$fakebin/bash"
  ln -s "$(command -v python3)" "$fakebin/python3"
  rc=0
  out=$(HOME="$home" PATH="$fakebin" "$ZCODE_HOOK" install 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "zcode hook install succeeded without jq"
  assert_contains "$out" "jq is required" "missing-jq refusal did not name jq"
  [ ! -e "$home/.zcode/cli/fm-turn-end.sh" ] \
    || fail "missing-jq refusal wrote the hook script"
  [ ! -e "$home/.zcode/cli/fm-turn-end.d" ] \
    || fail "missing-jq refusal wrote the registry"
  pass "zcode hook install refuses without jq before any config write"
}

# --- 5. Launch and wiring --------------------------------------------------------

make_zcode_spawn_case() {  # <name> <id>
  local name=$1 harness=zcode id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" zcode)
  ln -s "$JQ_BIN" "$fakebin/jq"
  fm_test_spawn_home "$home" "$harness"
  # The installer refuses a missing global config, so the throwaway user HOME
  # the spawn runs under carries a realistic pre-seeded one; the spawn's
  # install assertion below then reads from exactly this throwaway copy.
  mkdir -p "$home/user-home/.zcode/cli"
  printf '{"provider":{"zai":{"kind":"anthropic"}}}\n' > "$home/user-home/.zcode/cli/config.json"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  : > "$case_dir/launch.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$case_dir/launch.log"
}

read_case_record() {
  # shellcheck disable=SC2034 # CASE_DIR is part of the shared record shape
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_scout_spawn() {  # <home> <wt> <fakebin> <launch-log> <spawn-args...>
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  FM_FAKE_LAUNCH_LOG="$launchlog" fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" --scout
}

# The TUI-variant fake pane: a tmux stub whose state machine walks the real
# launch-then-send sequence (launch -> Enter -> echoed command -> paint ->
# ready -> pointer -> Enter -> delivered), rendering the verified screen
# shapes for the readiness gate. The pre-paint state renders the pane's own
# ECHO of the launch command - exactly the poison the PR#6 review reproduced
# live (a bare identity grep matched the echo's FM_ZCODE_HARNESS/ZCODE
# substrings ~2.5s before the real TUI painted) - and the paint itself is
# delayed FM_FAKE_ZCODE_TUI_PAINT_POLLS capture-pane calls after the launch
# Enter, so a gate that opens on the echo types the pointer into the echo
# state and the pointer-state log catches it red-handed. The delivered
# transition fires the REAL installed global hook with a Claude-compatible
# UserPromptSubmit payload - exactly what a live TUI submit does (verified
# live on zcode-runtime 0.16.5) - so the delivery gate's source=zcode-hook
# flip is produced by the real wiring, never faked.
make_zcode_tui_fakebin() {  # <dir> -> echoes <fakebin>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=${FM_FAKE_DIR:?}
state=$(cat "$D/zcode-tui-state" 2>/dev/null || true)
fake_screen() {
  case "$state" in
    ready|pointer-typed|delivered)
      printf '╭─ ◆ ZCODE  v3.11.2-24 ─────────────────────────╮\n'
      printf '│ /tmp/wt/workspace                             │\n'
      if [ "$state" = pointer-typed ]; then
        printf '│ > Read the brief at /brief and follow it.     │\n'
      else
        printf '│ Ask a task about this workspace               │\n'
      fi
      printf '│                                               │\n'
      printf '╰─ /help commands · /status details ────────────╯\n'
      if [ "$state" = delivered ]; then
        printf ' working… ── [ 1s ]\n'
      fi
      ;;
    launching)
      # The shell echo of the launch command, before the TUI paints.
      cat "$D/zcode-tui-launch-line" 2>/dev/null || true
      printf '$ \n'
      ;;
    *)
      printf 'shell starting\n$ \n'
      ;;
  esac
}
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{cursor_y}"*) printf '2\n'; exit 0 ;;
  # Relaunch validation: no foreground tty, and a shell as the pane command,
  # so the agent-state classifier proves the endpoint dead.
  *"#{pane_tty}"*) printf '\n'; exit 0 ;;
  *"#{pane_current_command}"*) printf 'zsh\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    [ -n "${FM_FAKE_WINDOW:-}" ] && printf '%s\n' "$FM_FAKE_WINDOW"
    exit 0
    ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  capture-pane)
    if [ "$state" = launching ]; then
      # The paint lands only after its delay elapses in capture calls.
      left=$(( $(cat "$D/zcode-tui-paint-left" 2>/dev/null || printf 0) - 1 ))
      printf '%s' "$left" > "$D/zcode-tui-paint-left"
      if [ "$left" -le 0 ]; then
        printf 'ready\n' > "$D/zcode-tui-state"
        state=ready
      fi
    fi
    fake_screen
    exit 0
    ;;
  send-keys)
    literal=
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    if [ -n "$literal" ]; then
      case "$literal" in
        *'--mode yolo'*)
          printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
          printf '%s\n' "$literal" > "$D/zcode-tui-launch-line"
          printf 'launching\n' > "$D/zcode-tui-state"
          ;;
        *)
          printf '%s\n' "$literal" >> "$FM_FAKE_POINTER_LOG"
          printf '%s\n' "$state" >> "$D/zcode-tui-pointer-states"
          printf 'pointer-typed\n' > "$D/zcode-tui-state"
          ;;
      esac
      exit 0
    fi
    case " $* " in
      *' Enter '*)
        case "$state" in
          launching)
            # Four capture calls of paint delay: long enough that a gate
            # matching its own echo types the pointer while the pane still
            # shows 'launching' even after the submit core's own baseline
            # capture consumes one tick (the B1 reproduction shape).
            printf '%s' "${FM_FAKE_ZCODE_TUI_PAINT_POLLS:-4}" > "$D/zcode-tui-paint-left"
            ;;
          pointer-typed)
            # The pre-interactivity swallow the PR#6 review reproduced live:
            # the first pointer's whole keystroke set is discarded and the
            # composer comes back empty, so only a verify-and-retry delivery
            # can recover it.
            if [ -n "${FM_FAKE_ZCODE_TUI_SWALLOW_FIRST:-}" ] \
               && [ ! -f "$D/zcode-tui-swallowed" ]; then
              : > "$D/zcode-tui-swallowed"
              printf 'ready\n' > "$D/zcode-tui-state"
              exit 0
            fi
            printf 'delivered\n' > "$D/zcode-tui-state"
            printf '{"hook_event_name":"UserPromptSubmit","session_id":"sess_tui_fake1","cwd":"%s","prompt":"pointer"}\n' \
              "$FM_FAKE_PANE_PATH" | bash "$HOME/.zcode/cli/fm-turn-end.sh" >/dev/null 2>&1 || true
            ;;
        esac
        ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse zcode
  ln -s "$JQ_BIN" "$fakebin/jq"
  printf '%s\n' "$fakebin"
}

make_zcode_tui_spawn_case() {  # <name> <id>
  local name=$1 harness=zcode id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_zcode_tui_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  mkdir -p "$home/user-home/.zcode/cli"
  printf '{"provider":{"zai":{"kind":"anthropic"}}}\n' > "$home/user-home/.zcode/cli/config.json"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  mkdir -p "$case_dir/fake"
  : > "$case_dir/launch.log"
  : > "$case_dir/pointer.log"
  printf 'shell\n' > "$case_dir/fake/zcode-tui-state"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$case_dir/launch.log|$case_dir/pointer.log"
}

read_tui_case_record() {
  # shellcheck disable=SC2034 # CASE_DIR is part of the shared record shape
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG POINTER_LOG <<EOF
$1
EOF
}

run_tui_scout_spawn() {  # <record> <spawn-args...>
  local rec=$1
  shift
  read_tui_case_record "$rec"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_POINTER_LOG="$POINTER_LOG" \
    FM_FAKE_DIR="$CASE_DIR/fake" \
    FM_ZCODE_TUI_READY_POLLS=10 FM_ZCODE_TUI_DELIVERY_POLLS=4 \
    FM_ZCODE_TUI_POLL_INTERVAL=0 FM_ZCODE_TUI_SUBMIT_SLEEP=0 FM_ZCODE_TUI_SUBMIT_SETTLE=0 \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@" --scout
}

test_zcode_spawn_launch_line_records_axes_and_pins_headless() {
  local rec id=zcode-launch-q1 out status launch state
  rec=$(make_zcode_spawn_case launch "$id")
  read_case_record "$rec"
  ZCODE_TASK_TMPS+=("/tmp/fm-$id")
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness zcode --model glm-5.3 --effort low)
  status=$?
  expect_code 0 "$status" "zcode scout spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=zcode" "spawn did not report the zcode harness"
  state="$HOME_DIR/state"
  assert_grep "harness=zcode" "$state/$id.meta" "meta missing harness=zcode"
  # Record-and-omit: the requested axes are recorded in metadata...
  assert_grep "model=glm-5.3" "$state/$id.meta" "meta missing the recorded model"
  assert_grep "effort=low" "$state/$id.meta" "meta missing the recorded effort"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" \
    "env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u GEMINI_CLI -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI FM_ZCODE_HARNESS=zcode ZCODE_DISABLE_UPDATE_CHECK=1 '$FAKEBIN_DIR/zcode'" \
    "zcode launch did not clear every foreign marker (including rovo's two) and establish its own"
  assert_contains "$launch" "--mode yolo --cwd '$WT_DIR'" \
    "zcode launch did not pin the yolo permission mode and the working directory"
  assert_contains "$launch" \
    "--prompt \"\$('$ROOT/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/launch-brief.md')\"" \
    "zcode launch lost the headless prompt carrying the canonical typed launch-brief envelope"
  # ...but never reach the launch command, because the headless flag set has
  # neither flag (verified against zcode-runtime 0.16.5), and a fresh launch
  # never carries a resume flag.
  case "$launch" in
    *--model*|*--effort*|*--thinking*|*--resume*|*--continue*) \
      fail "zcode launch must not carry model/effort/resume flags: $launch" ;;
  esac
  # The default spawn stays HEADLESS: no TUI variant line is recorded for it.
  ! grep -q '^zcode_tui=' "$state/$id.meta" \
    || fail "a default headless spawn must record no zcode_tui variant line"
  pass "fm-spawn: the zcode launch pins headless yolo, records the axes, and never passes model/effort/resume flags"
}

test_zcode_tui_flag_maps_to_the_bare_tui_launch_and_delivers_the_pointer() {
  local rec id=zcode-tui-q5 out status launch state pointer brief_real
  rec=$(make_zcode_tui_spawn_case tui "$id")
  read_tui_case_record "$rec"
  ZCODE_TASK_TMPS+=("/tmp/fm-$id")
  out=$(run_tui_scout_spawn "$rec" "$id" "$PROJ_DIR" --harness zcode --zcode-tui)
  status=$?
  expect_code 0 "$status" "zcode TUI scout spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=zcode" "TUI spawn did not report the zcode harness"
  state="$HOME_DIR/state"
  launch=$(cat "$LAUNCH_LOG")
  # The TUI template: the same env boundary, yolo pin, and worktree anchor as
  # headless, but BARE - no --prompt, because the TUI takes no prompt argument
  # (verified live on 0.16.5: a positional prompt is parsed as a subcommand and
  # exits 1) and the brief arrives through the pointer below.
  assert_contains "$launch" \
    "env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u GEMINI_CLI -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI FM_ZCODE_HARNESS=zcode ZCODE_DISABLE_UPDATE_CHECK=1 '$FAKEBIN_DIR/zcode'" \
    "zcode TUI launch did not keep the headless env boundary"
  assert_contains "$launch" "--mode yolo --cwd '$WT_DIR'" \
    "zcode TUI launch did not pin the yolo mode and the working directory"
  case "$launch" in
    *--prompt*) fail "the TUI launch must carry no headless --prompt: $launch" ;;
  esac
  # The variant rides the task record so a relaunch reuses it.
  assert_grep 'zcode_tui=1' "$state/$id.meta" "the TUI spawn did not record its variant"
  # The launch-then-send delivery: the exact one-line brief pointer...
  brief_real="$(cd "$HOME_DIR/data/$id" && pwd -P)/launch-brief.md"
  pointer=$(cat "$POINTER_LOG")
  [ "$pointer" = "Read the brief at $brief_real and follow it exactly." ] \
    || fail "the zcode TUI pointer was not the exact absolute-path instruction: $pointer"
  # ...confirmed STRUCTURALLY: the delivered transition fired the real global
  # UserPromptSubmit hook, so the armed busy record flipped to source=zcode-hook
  # (the same open the live TUI produces), never a rendered-string guess.
  assert_grep 'source=zcode-hook' "$state/$id.busy-state" \
    "the TUI pointer delivery did not flip the busy record through the hook"
  # The B1 regression net: the pointer was typed exactly once, and only after
  # the readiness gate saw the painted TUI - never while the pane still showed
  # the echoed launch command ('launching'), which is the state a gate that
  # matches its own echo would type into. A clean delivery also logs no retry.
  [ "$(wc -l < "$CASE_DIR/fake/zcode-tui-pointer-states")" -eq 1 ] \
    || fail "the pointer must be typed exactly once in the happy path: $(cat "$CASE_DIR/fake/zcode-tui-pointer-states")"
  assert_grep 'ready' "$CASE_DIR/fake/zcode-tui-pointer-states" \
    "the pointer was typed before the TUI painted (state log: $(cat "$CASE_DIR/fake/zcode-tui-pointer-states"))"
  case "$out" in
    *"unconfirmed in window"*) fail "a confirmed first delivery must log no retry: $out" ;;
  esac
  pass "fm-spawn: --zcode-tui launches bare, delivers the brief pointer, and proves it through the hook record"
}

test_zcode_tui_delivery_retries_after_a_pre_interactivity_swallow() {
  local rec id=zcode-tui-sw-q8 out state pointer_states
  rec=$(make_zcode_tui_spawn_case swallow "$id")
  read_tui_case_record "$rec"
  ZCODE_TASK_TMPS+=("/tmp/fm-$id")
  # The first pointer's whole keystroke set is discarded (the PR#6 review's
  # reproduced pre-paint swallow): the delivery ladder must notice the missing
  # hook flip, probe with one bare Enter (a no-op on the empty composer), and
  # retype the pointer - not fail the spawn and not fire the hook early. The
  # retry is also OBSERVABLE: each attempt that misses the hook flip logs one
  # stderr line naming the failed attempt and the retry, so a field swallow
  # never rides through silently.
  out=$(FM_FAKE_ZCODE_TUI_SWALLOW_FIRST=1 \
    FM_ZCODE_TUI_DELIVERY_POLLS=2 FM_ZCODE_TUI_SWALLOW_PROBE_POLLS=2 \
    run_tui_scout_spawn "$rec" "$id" "$PROJ_DIR" --harness zcode --zcode-tui)
  expect_code 0 $? "a swallowed first pointer must be recovered by the retry ladder: $out"
  assert_contains "$out" \
    "zcode TUI brief delivery attempt 1 of 3 unconfirmed" \
    "the swallowed first attempt must log its retry to stderr: $out"
  assert_contains "$out" "retry 2 of 3 probes a bare Enter" \
    "the retry log must name the bare-Enter probe it is about to run: $out"
  state="$HOME_DIR/state"
  assert_grep 'source=zcode-hook' "$state/$id.busy-state" \
    "the retried delivery did not flip the busy record through the hook"
  pointer_states=$(cat "$CASE_DIR/fake/zcode-tui-pointer-states")
  [ "$(printf '%s\n' "$pointer_states" | grep -c '^ready$')" -eq 2 ] \
    || fail "the pointer must be typed exactly twice, both into the painted TUI: $pointer_states"
  [ -f "$CASE_DIR/fake/zcode-tui-swallowed" ] \
    || fail "the swallow fixture never engaged"
  pass "fm-spawn: a pre-interactivity swallow is recovered by the verify-and-retry delivery, loudly"
}

test_zcode_tui_flag_refused_off_zcode() {
  local rec id=zcode-tui-off-q6 out
  rec=$(make_zcode_tui_spawn_case offzcode "$id")
  read_tui_case_record "$rec"
  out=$(run_tui_scout_spawn "$rec" "$id" "$PROJ_DIR" --harness grok --zcode-tui)
  expect_code 1 $? "a --zcode-tui spawn on another harness must fail: $out"
  assert_contains "$out" "--zcode-tui applies only to zcode" \
    "the refusal must name the flag's zcode-only scope: $out"
  pass "fm-spawn: --zcode-tui is refused on a non-zcode harness"
}

test_zcode_tui_flag_refused_on_relaunch() {
  local rec id=zcode-tui-rl-q7 out
  rec=$(make_zcode_tui_spawn_case relaunch "$id")
  read_tui_case_record "$rec"
  # A relaunch carries no delivery contract and no kind flag (the secondmate
  # refusal test's shape), so this deliberately bypasses run_tui_scout_spawn's
  # appended --scout, whose kind refusal would fire first.
  out=$(FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_POINTER_LOG="$POINTER_LOG" \
    FM_FAKE_DIR="$CASE_DIR/fake" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" --relaunch --zcode-tui "$id")
  expect_code 1 $? "a --zcode-tui relaunch must fail: $out"
  assert_contains "$out" "recorded zcode launch variant" \
    "the refusal must name the recorded-variant contract: $out"
  pass "fm-spawn: --zcode-tui cannot override a relaunch, whose variant comes from the record"
}

write_zcode_relaunch_meta() {  # <home> <proj> <wt> <id> [zcode_tui=1]
  local home=$1 proj=$2 wt=$3 id=$4
  {
    echo "window=firstmate:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=zcode"
    echo "kind=scout"
    echo "model=default"
    echo "effort=default"
    [ -z "${5:-}" ] || echo "zcode_tui=$5"
  } > "$home/state/$id.meta"
}

run_zcode_relaunch() {  # <record> <id>
  local rec=$1 id=$2
  read_tui_case_record "$rec"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_POINTER_LOG="$POINTER_LOG" \
    FM_FAKE_DIR="$CASE_DIR/fake" FM_FAKE_WINDOW="fm-$id" \
    FM_ZCODE_TUI_READY_POLLS=10 FM_ZCODE_TUI_DELIVERY_POLLS=4 \
    FM_ZCODE_TUI_POLL_INTERVAL=0 FM_ZCODE_TUI_SUBMIT_SLEEP=0 FM_ZCODE_TUI_SUBMIT_SETTLE=0 \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" --relaunch "$id"
}

test_zcode_relaunch_reuses_the_recorded_launch_variant() {
  local rec id=zcode-tui-rr-q9 out launch pointer_states
  rec=$(make_zcode_tui_spawn_case relaunch-tui "$id")
  read_tui_case_record "$rec"
  ZCODE_TASK_TMPS+=("/tmp/fm-$id")
  # A recorded TUI variant relaunches BARE and re-delivers through the gates.
  write_zcode_relaunch_meta "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$id" 1
  out=$(run_zcode_relaunch "$rec" "$id")
  expect_code 0 $? "a zcode TUI relaunch should succeed: $out"
  assert_contains "$out" "spawned $id harness=zcode" "the TUI relaunch did not report success"
  launch=$(cat "$LAUNCH_LOG")
  case "$launch" in
    *--prompt*) fail "a recorded TUI variant must relaunch bare, got: $launch" ;;
    *--resume*) fail "a relaunch with no recorded session must carry no resume flag: $launch" ;;
  esac
  assert_contains "$launch" "--mode yolo --cwd '$WT_DIR'" \
    "the TUI relaunch lost the yolo pin or worktree anchor: $launch"
  assert_grep 'source=zcode-hook' "$HOME_DIR/state/$id.busy-state" \
    "the TUI relaunch did not re-deliver the brief through the hook"
  pointer_states=$(cat "$CASE_DIR/fake/zcode-tui-pointer-states")
  [ "$(printf '%s\n' "$pointer_states" | grep -c '^ready$')" -eq 1 ] \
    || fail "the relaunch pointer must be typed once into the painted TUI: $pointer_states"
  assert_grep 'zcode_tui=1' "$HOME_DIR/state/$id.meta" \
    "the relaunch dropped the recorded variant"

  # A recorded HEADLESS variant relaunches with --prompt and runs no gates:
  # the pointer log stays empty because the brief rides the launch command.
  local id2=zcode-tui-rh-qA
  rec=$(make_zcode_tui_spawn_case relaunch-headless "$id2")
  read_tui_case_record "$rec"
  ZCODE_TASK_TMPS+=("/tmp/fm-$id2")
  write_zcode_relaunch_meta "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$id2"
  out=$(run_zcode_relaunch "$rec" "$id2")
  expect_code 0 $? "a zcode headless relaunch should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--prompt " \
    "a recorded headless variant must relaunch with its brief on the launch command: $launch"
  [ ! -s "$POINTER_LOG" ] \
    || fail "a headless relaunch must run no brief-pointer gates: $(cat "$POINTER_LOG")"
  ! grep -q '^zcode_tui=' "$HOME_DIR/state/$id2.meta" \
    || fail "a headless relaunch must record no variant line"
  pass "fm-spawn: a relaunch reuses the recorded zcode launch variant in both directions"
}

test_zcode_spawn_arms_the_hook_wiring_and_busy_record() {
  local rec id=zcode-wiring-z7 out statedir user_home token gen
  rec=$(make_zcode_spawn_case wiring "$id")
  read_case_record "$rec"
  ZCODE_TASK_TMPS+=("/tmp/fm-$id")
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness zcode)
  expect_code 0 $? "zcode spawn should succeed: $out"
  statedir="$HOME_DIR/state"
  user_home="$HOME_DIR/user-home"
  # The global hook is installed into the throwaway user HOME's zcode config.
  assert_grep 'fm-turn-end.sh' "$user_home/.zcode/cli/config.json" \
    "zcode spawn did not install its guarded global hook"
  [ -x "$user_home/.zcode/cli/fm-turn-end.sh" ] \
    || fail "zcode spawn did not install the hook script"
  # The per-task token, pointer, and registry entry all exist and bind.
  assert_grep 'token=' "$WT_DIR/.fm-zcode-turnend" "zcode spawn did not write its token pointer"
  token=$(sed -n 's/^token=//p' "$WT_DIR/.fm-zcode-turnend")
  assert_present "$statedir/$id.zcode-turnend-token" "zcode spawn did not record its token"
  assert_present "$user_home/.zcode/cli/fm-turn-end.d/$token" \
    "the registry entry for the minted token is missing"
  gen=$(cat "$statedir/$id.busy-gen")
  assert_grep "state-dir=$statedir" "$user_home/.zcode/cli/fm-turn-end.d/$token" \
    "the registry entry lost the busy writer's state dir"
  assert_grep "id=$id" "$user_home/.zcode/cli/fm-turn-end.d/$token" \
    "the registry entry lost the task id"
  assert_grep "gen=$gen" "$user_home/.zcode/cli/fm-turn-end.d/$token" \
    "the registry entry lost the busy generation"
  assert_grep "turn-ended=$statedir/$id.turn-ended" "$user_home/.zcode/cli/fm-turn-end.d/$token" \
    "the registry entry lost the turn-end marker path"
  assert_grep "busy-event=$ROOT/bin/fm-busy-event.sh" "$user_home/.zcode/cli/fm-turn-end.d/$token" \
    "the registry entry lost its busy-event writer binding"
  # The hook script is machine-global (one path for every firstmate home and
  # checkout), so it must not bake this checkout's absolute path: the writer
  # is resolved per task from the registry at fire time, which keeps every
  # home's install byte-identical and cross-checkout removals valid.
  if grep -F -q "$ROOT" "$user_home/.zcode/cli/fm-turn-end.sh"; then
    fail "the machine-global hook baked the spawning checkout's path"
  fi
  # The busy contract is armed and seeded busy by the launch brief itself.
  assert_grep "v1 gen=$gen seq=1 state=busy source=fm-spawn event=launch-brief" \
    "$statedir/$id.busy-state" "the seeded busy record is missing or malformed"
  out=$(fm_busy_classify tmux fake:w zcode "$id" "$statedir" 'worker finished its turn')
  [ "$out" = "busy zcode-hook" ] || [ "$out" = "busy fm-spawn" ] \
    || fail "an armed zcode task must classify busy through its record, got '$out'"
  # No session sidecar exists before the first hook event fires.
  [ ! -e "$statedir/$id.zcode-session" ] \
    || fail "a fresh spawn must not carry a session sidecar"
  pass "fm-spawn: zcode installs its hook, arms the busy record, and binds the token"
}

test_zcode_hook_opens_closes_and_records_only_through_the_token() {
  local rec id=zcode-hook-z9 out rc hook statedir token target
  rec=$(make_zcode_spawn_case hookfire "$id")
  read_case_record "$rec"
  ZCODE_TASK_TMPS+=("/tmp/fm-$id")
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness zcode)
  expect_code 0 $? "zcode spawn should succeed before hook firing: $out"
  hook="$HOME_DIR/user-home/.zcode/cli/fm-turn-end.sh"
  statedir="$HOME_DIR/state"
  target="$statedir/$id.turn-ended"
  token=$(sed -n 's/^token=//p' "$WT_DIR/.fm-zcode-turnend")

  # A tokenless workspace is a no-op: silent, exit zero, nothing written.
  mkdir -p "$TMP_ROOT/hookfire-stranger"
  out=$(printf '{"hook_event_name":"Stop","session_id":"ordinary","cwd":"%s","stop_hook_active":false}\n' \
    "$TMP_ROOT/hookfire-stranger" | HOME="$HOME_DIR/user-home" bash "$hook" 2>&1)
  rc=$?
  expect_code 0 "$rc" "the zcode hook must never block a tokenless session"
  [ -z "$out" ] || fail "the zcode hook printed into a tokenless session: $out"
  assert_absent "$target" "a tokenless zcode hook invocation touched a task marker"

  # An event the hook does not handle is a no-op even with a valid token.
  out=$(printf '{"hook_event_name":"PreToolUse","session_id":"sess_1","cwd":"%s","tool_name":"Bash"}\n' \
    "$WT_DIR" | HOME="$HOME_DIR/user-home" bash "$hook" 2>&1)
  rc=$?
  expect_code 0 "$rc" "an unhandled event must still exit zero"
  assert_absent "$target" "an unhandled event touched the turn-end marker"
  [ ! -e "$statedir/$id.zcode-session" ] \
    || fail "an unhandled event recorded a session id"

  # UserPromptSubmit opens the busy record and records the session id.
  out=$(printf '{"hook_event_name":"UserPromptSubmit","session_id":"sess_zcode9","cwd":"%s","prompt":"hi"}\n' \
    "$WT_DIR" | HOME="$HOME_DIR/user-home" bash "$hook" 2>&1)
  rc=$?
  expect_code 0 "$rc" "a registered UserPromptSubmit invocation did not exit zero"
  [ -z "$out" ] || fail "a registered invocation printed output: $out"
  assert_grep 'session_id=sess_zcode9' "$statedir/$id.zcode-session" \
    "the hook did not record the zcode session id"
  out=$(fm_busy_classify tmux fake:w zcode "$id" "$statedir" '')
  [ "$out" = "busy zcode-hook" ] \
    || fail "UserPromptSubmit must open the busy record through zcode-hook, got '$out'"

  # Stop closes it and touches the turn-end marker.
  out=$(printf '{"hook_event_name":"Stop","session_id":"sess_zcode9","cwd":"%s","stop_hook_active":false}\n' \
    "$WT_DIR" | HOME="$HOME_DIR/user-home" bash "$hook" 2>&1)
  rc=$?
  expect_code 0 "$rc" "a registered Stop invocation did not exit zero"
  assert_present "$target" "a registered Stop invocation did not touch the turn-end marker"
  out=$(fm_busy_classify tmux fake:w zcode "$id" "$statedir" '')
  [ "$out" = "idle zcode-hook" ] \
    || fail "Stop must close the busy record through zcode-hook, got '$out'"

  # A stale generation (the registry entry of a superseded incarnation) is
  # rejected by the busy writer, so the record keeps its current state.
  sed -i 's/^gen=.*/gen=fm.stalegen0000/' "$HOME_DIR/user-home/.zcode/cli/fm-turn-end.d/$token"
  out=$(printf '{"hook_event_name":"Stop","session_id":"sess_zcode9","cwd":"%s","stop_hook_active":false}\n' \
    "$WT_DIR" | HOME="$HOME_DIR/user-home" bash "$hook" 2>&1)
  expect_code 0 $? "a stale-gen hook invocation must still exit zero"
  out=$(fm_busy_classify tmux fake:w zcode "$id" "$statedir" '')
  [ "$out" = "idle zcode-hook" ] \
    || fail "a stale-generation event must not disturb the current record, got '$out'"
  # A registry entry without a shape-valid busy-event writer is a silent
  # no-op: the hook resolves and shape-checks the writer path at fire time,
  # so a stranger-edited token can never redirect it at an arbitrary command
  # and an entry from a vanished checkout can never dangle into one.
  sed -i '/^gen=/s/.*/gen=okgen/' "$HOME_DIR/user-home/.zcode/cli/fm-turn-end.d/$token"
  sed -i '/^busy-event=/d' "$HOME_DIR/user-home/.zcode/cli/fm-turn-end.d/$token"
  rm -f "$target"
  out=$(printf '{"hook_event_name":"Stop","session_id":"sess_zcode9","cwd":"%s","stop_hook_active":false}\n' \
    "$WT_DIR" | HOME="$HOME_DIR/user-home" bash "$hook" 2>&1)
  expect_code 0 $? "a busy-event-less token invocation must still exit zero"
  [ -z "$out" ] || fail "a busy-event-less invocation printed output: $out"
  assert_absent "$target" "a token without a busy-event writer must not touch the turn-end marker"
  # A writer path that is absolute but not a firstmate root's
  # bin/fm-busy-event.sh shape is rejected by the fire-time check, never
  # invoked - the hook only ever runs the writer fm-spawn itself recorded.
  sed -i 's|^busy-event=.*|busy-event=/tmp/evil/fm-busy-event.sh|' \
    "$HOME_DIR/user-home/.zcode/cli/fm-turn-end.d/$token"
  out=$(printf '{"hook_event_name":"Stop","session_id":"sess_zcode9","cwd":"%s","stop_hook_active":false}\n' \
    "$WT_DIR" | HOME="$HOME_DIR/user-home" bash "$hook" 2>&1)
  expect_code 0 $? "a foreign writer path invocation must still exit zero"
  [ ! -e /tmp/evil ] \
    || fail "a writer path outside a firstmate root shape must never be invoked"
  assert_absent "$target" "a foreign writer path must not touch the turn-end marker"
  pass "zcode hook opens, closes, and records only through the firstmate token"
}

test_zcode_spawn_refuses_when_the_hook_cannot_install() {
  local rec id=zcode-badcfg-qa out
  rec=$(make_zcode_spawn_case badcfg "$id")
  read_case_record "$rec"
  printf '{"broken\n' > "$HOME_DIR/user-home/.zcode/cli/config.json"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness zcode)
  expect_code 1 $? "an unresolvable zcode global config must fail the spawn: $out"
  assert_contains "$out" "global turn-end hook could not be installed safely" \
    "the refusal must name the hook install failure: $out"
  pass "fm-spawn: an unsafe zcode global config refuses the spawn"
}

test_zcode_spawn_refused_without_the_bin() {
  local rec id=zcode-nobin-q3 out fakebin_nobin
  rec=$(make_zcode_spawn_case nobin "$id")
  read_case_record "$rec"
  # A fakebin WITHOUT a zcode entry, on a PATH that also excludes any real
  # zcode install: the resolution must refuse before any endpoint exists
  # rather than launching a pane that dies on command-not-found. Pinning the
  # PATH matters because this suite's machines may genuinely have zcode in
  # /usr/local/bin, which would silently defeat the refusal.
  fakebin_nobin=$(make_spawn_fakebin "$CASE_DIR/fake-nobin")
  ln -s "$JQ_BIN" "$fakebin_nobin/jq"
  out=$(PATH="$fakebin_nobin:$BASE_PATH" run_scout_spawn "$HOME_DIR" "$WT_DIR" \
    "$fakebin_nobin" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness zcode)
  expect_code 1 $? "a spawn without a zcode bin must fail: $out"
  assert_contains "$out" "zcode executable not found on PATH" \
    "the refusal must name the missing zcode executable: $out"
  assert_contains "$out" "zcode-app-cli" \
    "the refusal must name the package that supplies the bin: $out"
  pass "fm-spawn: a missing zcode bin refuses the spawn naming the zcode-app-cli package"
}

test_zcode_is_refused_as_a_secondmate() {
  local rec id=zcode-secondmate-q4 out
  rec=$(make_zcode_spawn_case secondmate "$id")
  read_case_record "$rec"
  # A secondmate spawn carries no delivery contract, so this one deliberately
  # bypasses run_scout_spawn's --scout flag.
  out=$(FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" --secondmate "$id" zcode) && {
    fail "a zcode secondmate must be refused, secondmate launches are not verified for zcode: $out"
  }
  assert_contains "$out" 'secondmate launches are not verified for zcode' \
    "refusing a zcode secondmate must name the unverified secondmate surface: $out"
  pass "zcode is refused as a secondmate because secondmate launches are not verified for it"
}

test_zcode_teardown_removes_pointer_token_and_registry_entry() {
  local rec id=zcode-teardown-z8 out rc token user_home
  rec=$(make_zcode_spawn_case teardown "$id")
  read_case_record "$rec"
  ZCODE_TASK_TMPS+=("/tmp/fm-$id")
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness zcode)
  expect_code 0 "$?" "zcode spawn should succeed before teardown: $out"
  user_home="$HOME_DIR/user-home"
  token=$(sed -n 's/^token=//p' "$WT_DIR/.fm-zcode-turnend")
  printf 'session_id=sess_tear0\n' > "$HOME_DIR/state/$id.zcode-session"

  HOME="$user_home" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$TEARDOWN" "$id" --force >/dev/null 2>&1 || fail "zcode teardown failed"
  assert_absent "$WT_DIR/.fm-zcode-turnend" "zcode token pointer survived teardown"
  assert_absent "$user_home/.zcode/cli/fm-turn-end.d/$token" "zcode registry token survived teardown"
  assert_absent "$HOME_DIR/state/$id.zcode-turnend-token" "zcode token state survived teardown"
  assert_absent "$HOME_DIR/state/$id.zcode-session" "zcode session sidecar survived teardown"
  pass "fm-teardown: zcode pointer, registry token, and session sidecar are removed"
}

test_zcode_ancestry_detects_every_observed_process_name
test_zcode_ancestry_rejects_unrelated_mentions
test_zcode_marker_needs_real_ancestry
test_zcode_pane_liveness_classifies_every_observed_surface
test_zcode_control_mechanics_are_the_verified_ones
test_zcode_busy_signature_is_configured_only
test_zcode_hook_install_is_surgical_idempotent_and_removable
test_zcode_hook_removal_restores_every_observed_pre_install_shape
test_zcode_hook_fails_closed_on_missing_malformed_or_surprising_config
test_zcode_hook_install_refuses_without_jq
test_zcode_spawn_launch_line_records_axes_and_pins_headless
test_zcode_tui_flag_maps_to_the_bare_tui_launch_and_delivers_the_pointer
test_zcode_tui_delivery_retries_after_a_pre_interactivity_swallow
test_zcode_tui_flag_refused_off_zcode
test_zcode_tui_flag_refused_on_relaunch
test_zcode_relaunch_reuses_the_recorded_launch_variant
test_zcode_spawn_arms_the_hook_wiring_and_busy_record
test_zcode_hook_opens_closes_and_records_only_through_the_token
test_zcode_spawn_refuses_when_the_hook_cannot_install
test_zcode_spawn_refused_without_the_bin
test_zcode_is_refused_as_a_secondmate
test_zcode_teardown_removes_pointer_token_and_registry_entry

echo "all fm-zcode-harness tests passed"
