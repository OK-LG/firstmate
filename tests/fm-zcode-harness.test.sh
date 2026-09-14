#!/usr/bin/env bash
# Behavior tests for the zcode crewmate/scout adapter, Phase A.
#
# The facts pinned here are the ones a zcode release could silently change and
# the ones a wrong guess would make dangerous:
#   1. zcode publishes no harness-identity marker of its own (its ZCODE_* env
#      surface is configuration only), so FM_ZCODE_HARNESS=zcode is a
#      Firstmate-owned precedence override that needs REAL zcode ancestry, the
#      omp pattern: inert when it leaks into another harness's worker.
#   2. The anchored process-name set is the wrapper's own `zcode` plus the
#      runtime's renamed children (verified live on zcode-runtime 0.16.5 under
#      tmux: comm values `zcode-cli`, `zcode-c`, and `zco`); an unrelated name
#      merely containing the fragment must never claim the identity, and a bare
#      node launcher is claimed only through its zcode bin path in the
#      interpreter args fallback.
#   3. The Phase A launch is the HEADLESS single-prompt run: --prompt carries
#      the brief, --mode yolo is pinned explicitly rather than trusted from the
#      CLI default, --cwd anchors the run, foreign markers are cleared, and the
#      Firstmate marker is established at the launch boundary. The headless
#      flag set has no --model and no effort flag (verified against 0.16.5
#      --help), so both axes are recorded in metadata and never reach the
#      launch command.
#   4. Nothing is armed as busy wiring: the runtime's Stop hook is Phase B
#      work, and the headless mode renders nothing mid-turn (verified over
#      pipe and PTY on 0.16.5), so the busy classifier reads unknown until a
#      signature is configured through FM_BUSY_ZCODE_REGEX, and even then a
#      non-matching tail is unknown, never idle.
#   5. zcode is a crewmate/scout adapter only: a secondmate launch is refused,
#      and a missing zcode bin refuses the spawn instead of launching a pane
#      that dies on command-not-found.
#   6. Control is signal-shaped: interrupt is C-c (SIGINT through the pane's
#      foreground process group, verified live to cancel a mid-turn run), there
#      is no composer to clear, no cancellation acknowledgement to observe,
#      and no typed exit command at all - the headless process IS the turn.
#   7. The pane-liveness classifier (bin/fm-agent-process-lib.sh) knows the
#      same anchored name set plus the wrapper's node-launcher shapes - the
#      install path and the npm-global lib path - because fm-control's
#      interrupt/exit/relaunch verify against it and an unattributed pane can
#      never confirm a lifecycle action.
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
TMP_ROOT=$(fm_test_tmproot fm-zcode-harness)

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
  for name in zcode /usr/local/bin/zcode zcode-cli zcode-c zco; do
    out=$(FAKE_PS_COMM=$name detect)
    [ "$out" = zcode ] \
      || fail "the observed live name '$name' must detect as zcode by ancestry, got '$out'"
  done
  pass "fm-harness: ancestry detects the wrapper name and every observed runtime child name"
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
  # The wrapper's own comm and every observed runtime child name classify agent.
  for name in zcode zcode-cli zcode-c zco; do
    [ "$(fm_agent_process_classify_name "$name")" = agent ] \
      || fail "the observed live name '$name' must classify as an agent pane"
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
      'node unrelated-server.js --prompt "run zcode tests"')" = other ] \
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
  pass "fm-control-lib: zcode control is signal-shaped - C-c interrupt, no composer, no typed exit"
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

# --- 4. Launch ------------------------------------------------------------------

make_zcode_spawn_case() {  # <name> <id>
  local name=$1 harness=zcode id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" zcode)
  fm_test_spawn_home "$home" "$harness"
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

test_zcode_spawn_launch_line_records_axes_and_pins_headless() {
  local rec id=zcode-launch-q1 out status launch state
  rec=$(make_zcode_spawn_case launch "$id")
  read_case_record "$rec"
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
    "env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u GEMINI_CLI -u CURSOR_AGENT -u CURSOR_INVOKED_AS FM_ZCODE_HARNESS=zcode ZCODE_DISABLE_UPDATE_CHECK=1 '$FAKEBIN_DIR/zcode'" \
    "zcode launch did not clear foreign markers and establish its own at the launch boundary"
  assert_contains "$launch" "--mode yolo --cwd '$WT_DIR'" \
    "zcode launch did not pin the yolo permission mode and the working directory"
  assert_contains "$launch" \
    "--prompt \"\$('$ROOT/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/launch-brief.md')\"" \
    "zcode launch lost the headless prompt carrying the canonical typed launch-brief envelope"
  # ...but never reach the launch command, because the headless flag set has
  # neither flag (verified against zcode-runtime 0.16.5 --help).
  case "$launch" in
    *--model*|*--effort*|*--thinking*) fail "zcode launch must not carry model/effort flags: $launch" ;;
  esac
  pass "fm-spawn: the zcode launch pins headless yolo, records the axes, and never passes model/effort flags"
}

test_zcode_spawn_arms_no_busy_wiring() {
  local rec id=zcode-nowiring-z7 out statedir sidecar
  rec=$(make_zcode_spawn_case nowiring "$id")
  read_case_record "$rec"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness zcode)
  expect_code 0 $? "zcode spawn should succeed: $out"
  statedir="$HOME_DIR/state"
  [ -e "$statedir/$id.busy-gen" ] \
    && fail "zcode spawn armed a busy generation nothing could clear" || true
  for sidecar in "$statedir/$id."zcode* "$statedir/$id."pi-ext.ts "$statedir/$id."omp-ext.ts \
    "$statedir/$id."muse-session "$statedir/$id."gemini-settings.json; do
    [ -e "$sidecar" ] || continue
    fail "zcode spawn left adapter wiring behind: $sidecar"
  done
  out=$(fm_busy_classify tmux fake:w zcode "$id" "$statedir" 'worker finished its turn')
  [ "$out" = "unknown zcode-regex" ] \
    || fail "an unwired zcode task must classify unknown zcode-regex, got '$out'"
  pass "fm-spawn: zcode arms no busy wiring, writes no sidecar, and classifies unknown"
}

test_zcode_spawn_refused_without_the_bin() {
  local rec id=zcode-nobin-q3 out fakebin_nobin
  rec=$(make_zcode_spawn_case nobin "$id")
  read_case_record "$rec"
  # A fakebin WITHOUT a zcode entry: the resolution must refuse before any
  # endpoint exists rather than launching a pane that dies on command-not-found.
  fakebin_nobin=$(make_spawn_fakebin "$CASE_DIR/fake-nobin")
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$fakebin_nobin" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness zcode)
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
    fail "a zcode secondmate must be refused, it has no primary supervision protocol: $out"
  }
  assert_contains "$out" 'crewmate/scout adapter only' \
    "refusing a zcode secondmate must name the crewmate/scout boundary: $out"
  pass "zcode is refused as a secondmate because it has no primary supervision protocol"
}

test_zcode_ancestry_detects_every_observed_process_name
test_zcode_ancestry_rejects_unrelated_mentions
test_zcode_marker_needs_real_ancestry
test_zcode_pane_liveness_classifies_every_observed_surface
test_zcode_control_mechanics_are_the_verified_ones
test_zcode_busy_signature_is_configured_only
test_zcode_spawn_launch_line_records_axes_and_pins_headless
test_zcode_spawn_arms_no_busy_wiring
test_zcode_spawn_refused_without_the_bin
test_zcode_is_refused_as_a_secondmate

echo "all fm-zcode-harness tests passed"
