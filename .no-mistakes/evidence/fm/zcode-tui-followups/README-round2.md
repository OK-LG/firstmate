# Round 2 live validation: zcode TUI follow-ups (fm/zcode-tui-followups, 5631259 -> de98782)

Round 1 (files s1..s7, README.md) found one live failure: with zcode_tui=1 recorded, an interrupt
on an IDLE real TUI exits the TUI ~0.6 s after the key, but fm-control read the agent state once,
immediately, and published verified=agent-alive (exit 0) for a dead worker. Commit de98782 replaces
that single read with a bounded settle poll (wait_agent_state over FM_CONTROL_SETTLE_WAIT, 5 s
default) that returns as soon as a death is observed and otherwise holds the alive state.

Everything below was driven in THIS round against the REAL products on this host:
- zcode-app-cli 3.11.2-24 wrapping zcode-runtime 0.16.5
- real tmux 3.4 servers, isolated per lab via TMUX_TMPDIR (never the operator's server)
- bin/fm-control.sh and bin/fm-spawn.sh from the target commit de98782

Isolation: ~/.zcode staged into a throwaway HOME with a DUMMY api key and a baseURL pointing at a
local never-answering HTTP server (r2-lab-provider-requests.txt), so every model call hung locally
and a turn stayed busy as long as needed. The real ~/.zcode config and hook script were verified
byte-identical afterwards (r2-isolation-real-zcode-config-unchanged.txt). FM_GATE_REFUSE_BYPASS=1
is the guard's documented test-harness escape hatch, set only for lab commands.

Files (r2-*):
- r2-s1-tui-busy-interrupt-alive.txt        real TUI mid-turn, zcode_tui=1 -> verified=agent-alive after the full settle window (~6.5 s), "Turn cancelled." on screen, node/zcode-cli still foreground, busy record preserved. PASS
- r2-s2-tui-idle-dies-under-key-refused.txt  the round-1 FAIL re-driven: idle real TUI exits under C-c; 50 ms samples show node/zcode-cli lingering ~1.6 s, then a bare shell; fm-control now REFUSES (exit 1, "an interrupt must leave the agent running"), prints no interrupt-delivered line, busy record left open (not retired). PASS
- r2-s3-headless-interrupt-ends-process.txt  real headless --prompt worker, no zcode_tui line -> verified=agent-ended-by-interrupt in 1.6 s (the poll returned on the first observed death), HEADLESS_EXIT=130, busy record retired. PASS
- r2-s4-spawn-tui-happy-path-no-retry-log.txt  real fm-spawn --zcode-tui scout: hook flip confirmed on attempt 1, zcode_tui=1 recorded in the meta, NO retry line. PASS
- r2-s5-spawned-tui-task-interrupt-alive.txt   fm-control interrupt on the task fm-spawn created (real record, real hook-flipped busy state, TUI mid-turn) -> agent-alive, record preserved. PASS
- r2-s6-s7-spawn-tui-retry-log-and-exhaustion.txt  hook delayed ~2 s: exactly one retry line, bare-Enter probe, spawn lands with the pointer submitted once. Hook delayed past zcode's 10 s hook timeout: both retry lines logged, spawn fails closed, the TUI window is closed. PASS
- r2-s8-retry-line-is-on-stderr.txt          stdout and stderr captured separately: the retry line is on STDERR only; stdout carries just the spawned line. PASS

Targeted automated tests run as baseline (not the full suite):
- tests/fm-control.test.sh   40 ok, includes the new "zcode interrupt postcondition follows the recorded launch variant" test with its lingering-then-dead fixture
- tests/fm-zcode-harness.test.sh   22 ok, includes "a pre-interactivity swallow is recovered by the verify-and-retry delivery, loudly"
