# Live validation: zcode TUI follow-ups (fm/zcode-tui-followups, 5631259 -> 2f6ccf1)

Everything below was driven against the REAL products on this host:
- zcode-app-cli 3.11.2-24 wrapping zcode-runtime 0.16.5 (the version the change's comments cite)
- real tmux 3.4 servers, isolated per lab via TMUX_TMPDIR (never the operator's server)
- bin/fm-control.sh and bin/fm-spawn.sh from the target commit

Isolation:
- ~/.zcode was staged into a throwaway HOME (the same pattern tests/fm-zcode-signals-live-e2e.test.sh uses); the staged config carries a DUMMY api key and a baseURL pointing at a local never-answering HTTP server (lab-provider-requests.txt), so every model call hung locally and a turn stayed busy for as long as needed. No external endpoint was contacted and the real credential was never used.
- FM_GATE_REFUSE_BYPASS=1 is the guard's documented test-harness escape hatch (bin/fm-gate-refuse-lib.sh); it was set only for lab commands against the isolated fleet.
- The real ~/.zcode config and hook registry were verified unchanged afterwards; the lab and its spawned task temp dirs were removed.

Files:
- s1-tui-interrupt-alive.txt   fm-control interrupt on a real busy TUI, meta zcode_tui=1 -> verified=agent-alive, turn cancelled, TUI alive, busy record preserved. PASS
- s2-tui-dies-under-key-refused.txt, s2b-tui-dies-under-key-timing.txt   adversarial: the idle TUI EXITS on C-c, but fm-control reported verified=agent-alive (exit 0) because the postcondition is read immediately; the 50 ms samples show the process lingers ~0.6 s after the key before the pane drops to a bare shell. The TUI-variant refusal never fired; busy record left open. FAIL (see finding)
- s3-headless-interrupt-ends-process.txt   fm-control interrupt on a real headless --prompt worker, no zcode_tui line -> verified=agent-ended-by-interrupt, HEADLESS_EXIT=130, busy record retired. PASS
- s4-spawn-tui-happy-path-no-retry-log.txt   real fm-spawn --zcode-tui scout: hook flip confirmed on attempt 1, zcode_tui=1 recorded, NO retry line. PASS
- s5-*, s5b-*   two attempts where the real hook flipped before even a one-poll window (no retry line; expected, delivery confirmed first try)
- s5c-s7-spawn-tui-retry-log-and-exhaustion.txt   with the staged hook delayed 2 s: exactly one stderr retry line, bare-Enter probe, spawn lands with the pointer submitted once. With the hook delayed past zcode's 10 s hook timeout: both retry lines logged, spawn fails closed with the delivery error, the TUI window is closed. PASS
- s6-spawned-tui-task-interrupt-alive.txt   fm-control interrupt on the task fm-spawn itself created (real record, real hook-flipped busy state, TUI mid-turn) -> agent-alive, record preserved. PASS
