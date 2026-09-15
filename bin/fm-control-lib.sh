#!/usr/bin/env bash
# fm-control-lib.sh - the ONE executable owner of firstmate's agent lifecycle
# CONTROL-PLANE mechanics.
#
# Data plane vs control plane (captain-approved root architecture, 2026-07-13).
# bin/fm-send.sh is the DATA plane: conversational text for the agent to read,
# always routing-marked for a kind=secondmate target so the reply comes back
# through the status path. That marking is exactly right for a message and
# exactly wrong for a lifecycle command: a marked "/quit" arrives as ordinary
# chat ("[fm-from-firstmate] /quit") that the agent reasons ABOUT instead of
# executing. bin/fm-control.sh is the CONTROL plane: allowlisted lifecycle
# verbs addressed to an exact task id, with the per-harness mechanics owned
# here rather than improvised per harness in agent prose.
#
# This file owns three capability tables plus their pure artifact-path tables
# and nothing else. It has no side effects, runs no backend command, and reads
# no state, so it can be sourced by a test as a pure contract:
#
#   1. Verb allowlist. There is no arbitrary-text and no generic raw-key entry
#      point on the control plane; a caller either names an allowlisted verb or
#      is refused.
#   2. Per-harness control mechanics: which key interrupts a running turn, how
#      many times it must be sent, whether the composer needs clearing after
#      that key, which adapter-owned cancellation acknowledgement is observable,
#      which command exits the agent, and which task kinds the adapter is
#      verified to run. These are the empirically verified facts previously
#      carried only in the harness-adapters skill's per-adapter tables; that
#      skill now points here so one executable owner holds them, and
#      bin/fm-send.sh's --key path reads the same table rather than a second
#      copy of it.
#   3. Per-backend capability: which named keys a runtime backend can deliver,
#      and whether the backend has a recovery-grade agent-state classifier
#      (bin/fm-backend.sh's fm_backend_agent_state) able to PROVE that an agent
#      stopped. A verb whose postcondition cannot be proven on the recorded
#      backend is refused rather than performed blind.
#
# `resume` is deliberately NOT a verb. It is not deterministic across the
# verified adapters: codex and grok resume only from a session id printed at
# exit, opencode resumes the most recent session for the cwd with --continue,
# and claude, pi, pi-signed, omp, and kimi have no verified pane-resume contract
# at all. `relaunch` covers the same need deterministically for every adapter,
# because the brief on disk - not a harness-private session - is the durable
# instruction.

# The complete control-plane verb allowlist, one per line.
fm_control_verbs() {
  cat <<'EOF'
interrupt
exit
relaunch
EOF
}

fm_control_verb_allowed() {  # <verb>
  case "${1-}" in
    interrupt|exit|relaunch) return 0 ;;
  esac
  return 1
}

# The harnesses whose control mechanics are verified. Mirrors AGENTS.md
# section 4's verified-adapter list; an unverified adapter is refused rather
# than guessed at, exactly as a spawn on it would be.
fm_control_harness_supported() {  # <harness>
  case "${1-}" in
    claude|codex|opencode|pi|pi-signed|grok|kimi|cursor|gemini|muse|rovo|omp|agy|zcode) return 0 ;;
  esac
  return 1
}

# The verified adapter a RECORDED harness value belongs to. Every table below
# is keyed by the exact verified adapter name, but a task launched from a raw
# command records the command's basename instead (bin/fm-spawn.sh derives
# harness= that way), which is why the spawn adapters match `claude*`, `muse*`,
# and friends. This is the one place that prefix rule is stated. `pi` and
# `pi-signed` are exact because a `pi*` prefix would swallow the signed adapter,
# `omp` is exact because an `omp*` prefix would claim unrelated commands, `agy`
# is exact for the same reason on an even shorter name, and an
# unrecognized value returns nonzero rather than being guessed into a family.
fm_control_harness_family() {  # <recorded-harness>
  case "${1-}" in
    pi) printf 'pi' ;;
    pi-signed) printf 'pi-signed' ;;
    omp) printf 'omp' ;;
    agy) printf 'agy' ;;
    # zcode is exact for the same reason as omp and agy: a `zcode*` prefix
    # would claim unrelated commands such as zcodegraph, and the only names a
    # launch records are the canonical `zcode` and a raw command's basename.
    zcode) printf 'zcode' ;;
    claude*) printf 'claude' ;;
    codex*) printf 'codex' ;;
    opencode*) printf 'opencode' ;;
    grok*) printf 'grok' ;;
    kimi*) printf 'kimi' ;;
    cursor*) printf 'cursor' ;;
    gemini*) printf 'gemini' ;;
    muse*) printf 'muse' ;;
    rovo*) printf 'rovo' ;;
    *) return 1 ;;
  esac
}

# Which task kinds an adapter is verified to run. muse, gemini, rovo, agy,
# and zcode are crewmate/scout adapters only: none has a primary supervision
# protocol, and bin/fm-spawn.sh refuses a --secondmate launch on any of them.
# The control plane asks this BEFORE it stops anything, so an incompatible
# relaunch target is refused while the current agent is still running rather
# than after it has been stopped.
fm_control_harness_supports_kind() {  # <harness> <kind>
  local harness=${1-} kind=${2-}
  fm_control_harness_supported "$harness" || return 1
  case "$harness" in
    muse|gemini|rovo|agy|zcode) [ "$kind" != secondmate ] || return 1 ;;
  esac
  return 0
}

# The key that cancels a running turn. Escape for every adapter except grok
# and zcode. grok's Esc only moves focus to the scrollback; grok cancels on
# Ctrl+C. zcode cancels on Ctrl+C in BOTH launch variants: the headless
# single-prompt process reads no stdin, so C-c is SIGINT delivered to the
# pane's foreground process group through the TTY (the signal-forwarding
# shape zcode's host contract documents), while the opt-in TUI variant
# renders the key itself - C-c mid-turn prints "Turn cancelled." and keeps
# the TUI alive (verified live on zcode-runtime 0.16.5 in both shapes), so
# one key cancels the turn in either variant and only the process outcome
# differs (see interrupt_ends_process and the exit verbs below).
# gemini names its own key in the running turn's status row
# (`(esc to cancel, <n>s)`), and a single Escape was verified to cancel it.
# rovo cancels on a single Escape too, printing "Agent cancelled" (verified,
# 202609.1.2). agy cancels on a single Escape, printing the Interrupted row
# with an idle composer and no repollution (verified live, agy 1.2.0 through
# Herdr). omp (Oh My Pi) shares Pi's single Escape, empty composer
# afterwards, and /quit exit (verified omp 18.1.2 in a PTY, re-verified 18.1.11
# through Herdr).
fm_control_interrupt_key() {  # <harness>
  case "${1-}" in
    claude|codex|opencode|pi|pi-signed|omp|kimi|cursor|gemini|muse|rovo|agy) printf 'Escape' ;;
    grok|zcode) printf 'C-c' ;;
    *) return 1 ;;
  esac
}

# How many times the interrupt key must be delivered. OpenCode needs a double
# Escape; every other verified adapter interrupts on a single press.
fm_control_interrupt_repeat() {  # <harness>
  case "${1-}" in
    opencode) printf '2' ;;
    claude|codex|pi|pi-signed|omp|grok|kimi|cursor|gemini|muse|rovo|agy|zcode) printf '1' ;;
    *) return 1 ;;
  esac
}

# The key that must follow the interrupt key to leave the composer empty, or
# nothing when the adapter needs none. muse is the one verified adapter that
# RESTORES the cancelled prompt into its composer as real bright text, so an
# interrupt is not complete until Ctrl+U has cleared it; leaving it there would
# make the next submitted line - a steer, or this plane's own exit command -
# concatenate onto it. cursor was checked for exactly that behaviour and does
# NOT repollute: after a single Escape its composer shows only the `Add a
# follow-up` placeholder, so it needs no clear key. gemini was checked the
# same way and also does not repollute: after a single Escape it prints
# `Request cancelled.` and its composer shows only the `Type your message
# or @path/to/file` placeholder. Prints the key or nothing;
# a harness with no verified mechanics returns nonzero, matching the tables
# above.
fm_control_interrupt_clear_key() {  # <harness>
  case "${1-}" in
    muse) printf 'C-u' ;;
    # zcode needs no clear key in either variant: the headless -p process
    # reads no stdin, and the TUI's cancelled turn does NOT restore its prompt
    # into the composer (verified live on 0.16.5: after "Turn cancelled." the
    # composer is empty and the next prompt submits clean).
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|rovo|agy|zcode) ;;
    *) return 1 ;;
  esac
}

fm_control_interrupt_ack_source() {  # <harness>
  case "${1-}" in
    muse) printf 'muse-session-terminal' ;;
    # cursor's transcript DOES type an aborted close, but its write latency
    # after an interrupt was measured as variable - sometimes seconds, sometimes
    # not within 20 - so a cancellation claim built on it would be unreliable.
    # Normal turn completion is prompt, which is what the busy fold depends on.
    # rovo's TUI prints "Agent cancelled" on Escape, but for parity with
    # claude/cursor this stays 'none': the ack is a rendered string, not a
    # recorded state source, and rovo has no busy wiring to confirm against.
    # zcode stays 'none' for the same reason even though its TUI renders
    # "Turn cancelled." (verified live, 0.16.5): the headless SIGINT path
    # prints nothing at all, and neither path writes a recorded ack source -
    # the busy record is the structured truth, and a cancelled TUI turn
    # leaving it open is the claude manual-interrupt posture, not an ack.
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|rovo|agy|zcode) printf 'none' ;;
    *) return 1 ;;
  esac
}

# Whether an interrupt legitimately ENDS the worker process. The headless
# zcode worker IS the turn (verified live on zcode-runtime 0.16.5: a mid-turn
# C-c exits the process with status 130 and the runtime fires no Stop hook on
# that path), while the opt-in TUI variant survives its interrupt (verified
# live: C-c cancels the turn, the TUI stays alive) - so this table records
# that a zcode interrupt MAY legitimately end the worker, and
# bin/fm-control.sh's interrupt verification accepts BOTH the dead state
# (the headless shape) and the alive state (every TUI adapter, zcode's TUI
# variant included) as the documented success shapes. Every other TUI
# adapter keeps running after its interrupt key cancels the turn.
fm_control_interrupt_ends_process() {  # <harness>
  case "${1-}" in
    zcode) return 0 ;;
    *) return 1 ;;
  esac
}

# Whether the exit verb stops the agent through a SIGNAL rather than a typed
# composer command. zcode's workers never take a typed exit command: the
# headless worker has no composer and never reads stdin, so its exit is the
# interrupt key itself - one C-c (SIGINT through the pane's foreground process
# group, the documented host-contract forwarding shape) ends the process. The
# TUI variant exits on the same key at an idle composer (verified live on
# 0.16.5: a clean shutdown prints the token summary and the resume line), so
# a mid-turn TUI stops on cancel-then-exit: the first C-c cancels the turn,
# and bin/fm-control.sh's signal-shaped exit delivers one bounded second key
# after a settle window to perform the exit. The agent-state wait proves the
# stop in both shapes. The executor refuses an exit on a harness that is
# neither signal-shaped nor carrying an exit command above.
fm_control_exit_is_signal_shutdown() {  # <harness>
  case "${1-}" in
    zcode) return 0 ;;
    *) return 1 ;;
  esac
}

# The command that exits the agent from its own composer. zcode deliberately
# has NO entry: its headless workers read no stdin and end with the turn,
# and its TUI variant exits on the C-c signal shape above rather than a
# typed command - a finished headless worker has already stopped, and a
# mid-run stop in either variant is that signal exit, not typed text.
fm_control_exit_command() {  # <harness>
  case "${1-}" in
    claude|opencode|grok|kimi|cursor|muse|rovo) printf '/exit' ;;
    codex|pi|pi-signed|omp|gemini|agy) printf '/quit' ;;
    *) return 1 ;;
  esac
}

# Which named keys a backend adapter can deliver. Every session provider
# normalizes Enter, Ctrl+C, and the Ctrl+U composer clear; Orca's terminal API
# exposes only an interrupt and an Enter, so it can deliver neither Escape nor
# Ctrl+U (bin/backends/orca.sh's fm_backend_orca_send_key).
fm_control_backend_supports_key() {  # <backend> <key>
  local backend=${1-} key=${2-}
  case "$backend" in
    tmux|herdr|zellij|cmux)
      case "$key" in Escape|Enter|C-c|C-u) return 0 ;; esac
      ;;
    orca)
      case "$key" in Enter|C-c) return 0 ;; esac
      ;;
  esac
  return 1
}

# Whether <backend> has a recovery-grade agent-state classifier. Only tmux and
# herdr implement fm_backend_agent_state; zellij, orca, and cmux report
# `unverified`, so no reading of theirs can prove an agent stopped. The control
# plane refuses a stop-proving verb there instead of reporting an unprovable
# transition as success.
fm_control_backend_state_verified() {  # <backend>
  case "${1-}" in
    tmux|herdr) return 0 ;;
  esac
  return 1
}

# The per-task wiring artifacts a harness leaves behind, so a relaunch that
# changes harness (or re-arms the same one with a fresh busy generation) can
# clear the previous incarnation's wiring instead of leaving a stale hook
# pointing at a retired generation. Prints zero or more absolute paths, one per
# line: worktree-resident hook files and firstmate-owned state tokens only,
# never a harness's own managed config.
fm_control_harness_wiring_paths() {  # <harness> <worktree> <state-dir> <id>
  local harness=${1-} wt=${2-} state=${3-} id=${4-}
  [ -n "$wt" ] && [ -n "$state" ] && [ -n "$id" ] || return 1
  case "$harness" in
    claude) printf '%s\n' "$wt/.claude/settings.local.json" ;;
    opencode) printf '%s\n' "$wt/.opencode/plugins/fm-busy-state.js" ;;
    pi|pi-signed) printf '%s\n' "$state/$id.pi-ext.ts" ;;
    omp) printf '%s\n' "$state/$id.omp-ext.ts" ;;
    grok)
      printf '%s\n' "$wt/.fm-grok-turnend"
      printf '%s\n' "$state/$id.grok-turnend-token"
      ;;
    kimi)
      printf '%s\n' "$wt/.fm-kimi-turnend"
      printf '%s\n' "$state/$id.kimi-turnend-token"
      ;;
    # zcode's pointer and token retire here like grok's and kimi's. The
    # session sidecar is deliberately NOT listed: fm-spawn's zcode arm must
    # read it after this retirement ran (a relaunch reuses the prior
    # incarnation's recorded session through --resume), so that arm owns the
    # sidecar's removal, guarded on the prior recorded harness being zcode.
    zcode)
      printf '%s\n' "$wt/.fm-zcode-turnend"
      printf '%s\n' "$state/$id.zcode-turnend-token"
      ;;
    muse)
      # muse installs no hook: its busy source is its own session event log,
      # bound to the pane by these two firstmate-owned sidecars. A relaunch
      # ONTO muse rewrites them, but a relaunch AWAY from muse must retire them
      # so no retired incarnation's session binding outlives the agent.
      printf '%s\n' "$state/$id.muse-session"
      printf '%s\n' "$state/$id.muse-session-current"
      ;;
    cursor) printf '%s\n' "$state/$id.cursor-session" ;;
    # gemini's busy-state and turn-end hooks live in a firstmate-owned
    # settings file the launch reaches through GEMINI_CLI_SYSTEM_SETTINGS_PATH,
    # so retiring that one file retires the whole incarnation's wiring. Nothing
    # is written into the worktree, whose own .gemini/settings.json belongs to
    # the project, and nothing global is installed.
    gemini) printf '%s\n' "$state/$id.gemini-settings.json" ;;
  esac
}

# The firstmate-owned global turn-end registry entry a harness mints per task.
# grok, kimi, and zcode are the adapters whose turn-end hook is global and gated
# by a private token file; every other adapter's wiring is fully covered by
# fm_control_harness_wiring_paths. Prints the registry path or nothing.
fm_control_harness_turnend_token_path() {  # <harness> <state-dir> <id>
  local harness=${1-} state=${2-} id=${3-}
  [ -n "$state" ] && [ -n "$id" ] || return 1
  case "$harness" in
    grok) printf '%s\n' "$state/$id.grok-turnend-token" ;;
    kimi) printf '%s\n' "$state/$id.kimi-turnend-token" ;;
    zcode) printf '%s\n' "$state/$id.zcode-turnend-token" ;;
  esac
}

fm_control_harness_turnend_auth_path() {  # <harness> <token>
  local harness=${1-} token=${2-}
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  case "$harness" in
    grok) printf '%s\n' "${GROK_HOME:-$HOME/.grok}/hooks/fm-turn-end.d/$token" ;;
    kimi) printf '%s\n' "$HOME/.kimi-code/fm-turn-end.d/$token" ;;
    zcode) printf '%s\n' "$HOME/.zcode/cli/fm-turn-end.d/$token" ;;
    *) return 0 ;;
  esac
}
