Mode: Zcode background-notify supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. First cycle: arm with the Bash tool's tracked background mechanism, as its own call with `run_in_background: true` on:

   `[ -f __FM_X_MODE_ENV_SH__ ] && . __FM_X_MODE_ENV_SH__; exec bin/fm-watch-arm.sh`

4. Trust only the arm's one-line status.
5. `watcher: started ...` or `watcher: attached ...` means a live cycle exists.
   On attach, the background task follows verified identity-matched successors instead of exiting when the first cycle ends.
6. Failure or missing cycle only: `watcher: FAILED ...` means supervision is down; fix and re-arm.
7. After a successful start or attach status, end the turn.
   The background arm remains the live wait until it returns an actionable wake or failure.
8. Waiting is silent.
9. Never use shell `&` for firstmate supervision.
10. Never bundle the arm onto another command or run it in the foreground of an ordinary tool call.

Zcode re-invokes the model with a task notification when a background task completes, whether the arm exits with a wake reason or a FAILED line, so cycle completion is itself both the wake path and the failure path.
When you see a background-task-completed notification for the arm:
1. Run `bin/fm-wake-drain.sh` first.
2. Read the arm task's output for the reason line.
3. Handle `signal`, `stale`, `check`, or `heartbeat` using the harness-neutral contract in `AGENTS.md`.
4. Ordinary wake: re-arm the next cycle with the same background `bin/fm-watch-arm.sh` call if the home still needs supervision, as `bin/fm-supervision-lib.sh` defines it.
5. Do not invent a wake from an attach-status line alone.
   Drain the queue and act only on real wake records, the drain's `OPEN DECISIONS` and `UNREAD STATUS` entries, or a real watcher reason line.
   Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
   See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract.

Zcode has no turn-end guard backstop yet: the arm task's completion notification is the only cycle-end signal, so a healthy background arm must exist before every turn ends.
The crew-side Stop hook pair (`bin/fm-zcode-turnend-hook.sh`) is task-scoped and never arms primary supervision.

Interactive TUI primary sessions are the supported supervision host.
Headless `zcode --prompt` is the one-shot crewmate launch shape and cannot host the primary's supervision cycle.
Verified live on zcode-app-cli 3.11.2-24 wrapping zcode-runtime 0.16.5: the TUI Bash tool's background tasks survive the tool call and re-invoke the model on completion (observed in the live TUI primary session, 2026-09-15), and a session acquires the fleet lock through the `zcode-cli` engine in its own ancestry (`tests/fm-zcode-primary-live-e2e.test.sh`, opt-in, refreshes the lock and detection facts against the installed harness on demand).
