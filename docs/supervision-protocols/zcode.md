Mode: zcode crewmate and scout supervision.

zcode is a verified crewmate and scout adapter only; it never hosts a firstmate primary or secondmate.
This file is the supervision recipe for live zcode workers, not a primary wake protocol: `bin/fm-supervision-instructions.sh` does not render it, and a firstmate session running on zcode follows [`unknown.md`](unknown.md), the unsupported boundary `references/common/primary-hooks.md` owns.

When this session supervises live zcode workers:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Busy state comes from the rendered-tail screen-scrape classification in `bin/fm-busy-lib.sh`, the grok-regex shape: zcode has no semantic busy source in Phase A, and `unknown` is the safe verdict when the busy marker scrolls out of the captured tail.
3. Drive lifecycle only through `bin/fm-control.sh <task-id> interrupt|exit|relaunch`.
   zcode's documented host contract forwards `SIGINT` and `SIGTERM` to the runtime and preserves exit status, so interrupt and exit are signal verbs, never typed keys or lifecycle text through `fm-send`.
4. Read current state through `bin/fm-crew-state.sh <id>`, which feeds the pane tail to the classifier the way the grok tail-capture precedent does; a status line is a wake event, not current state.
5. Never trust exit status.
   zcode's headless error paths exit 0, so a failed turn can look successful to any check that reads exit codes; judge outcomes from output, worker status events, and current-state reads.
6. Treat any credential refusal - `Model access is not configured for zai. Run /login or /setup in zcode` - as a credential blocker under `AGENTS.md` section 9: fix the environment (`ZCODE_API_KEY` or `~/.zcode/cli/config.json`) and retire the endpoint rather than typing into the pane.
7. Phase A wires no native turn-end touch: completion arrives through the worker status protocol and the screen-scrape return to idle, and the runtime's native `Stop` hook stays unwired until the Phase B plugin exists.

`.agents/skills/harness-adapters/references/harness/zcode.md` owns the adapter's operating facts, the installed-version pin, and the live-verification requirement before any dispatch.
