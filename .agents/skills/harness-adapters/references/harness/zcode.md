# zcode

Z.AI's official coding-agent harness, driving GLM-5.3 and GLM-5.3-Flash against a GLM Coding Plan subscription.
The official CLI ships inside the ZCode Desktop app and has no official standalone npm package.
The runnable Linux artifact is the third-party `zcode-app-cli` package (kingsword09/zcode-cli, MIT), which extracts the official runtime, supplies a pi-tui-based TUI, and exposes the public `zcode` bin with a versioned host-integration contract for agent orchestrators at its own `docs/HOST_INTEGRATION.md`.
Researched against `zcode-app-cli` 3.11.2-24 wrapping `zcode-runtime` 0.16.5 on Linux with Node 22.22.3; every fact below comes from that research's headless probes, the shipped help, and bundle strings, the 2026-09-14 live verification pass (end-to-end dispatch, detection, and busy classification), and the 2026-09-14 Phase B live pass that verified the native hook pair, the resume contract, the absent effort flags, and the GLM Coding Plan quota windows on the real harness.
Dispatch is pinned to the exact installed wrapper version because it tracks a desktop-app-aligned release train, and the package redistributes a proprietary runtime: confirm upstream terms before use.
Verified for crewmate and scout launches: a raw-launch trivial scout executed its brief end to end under supervision on 2026-09-14, and the Phase B live guard (`tests/fm-zcode-signals-live-e2e.test.sh`, opt-in) re-proves the hook pair, the session record, the resume contract, and the kernel process names against the installed harness on demand.

## Operating facts

| Fact | Value |
|---|---|
| Binary | The `zcode` bin of the installed `zcode-app-cli` package, pinned to the exact installed version. |
| Launch | Headless single-prompt mode is first-class: `--prompt <text>`, with `-p`/`--print` aliases, runs one prompt without the TUI, and `--cwd` exists. |
| Mode | `--mode build\|edit\|plan\|yolo`, and it defaults to `yolo` for `--prompt`, which is the unattended posture; the spawn design pins it explicitly rather than trusting the default. |
| JSON | `--json` prints machine-readable output where supported. |
| Resume | Verified live on 0.16.5: `--resume <sessionId>` restores session context headless, and `-c`/`--continue` resumes the latest session for the cwd the same way. Both print an error and EXIT 0 when nothing is resumable, and unknown options exit 0 too, so a resume flag must only ever ride a recorded session id: the spawn's Stop/UserPromptSubmit hook records `session_id` into `state/<id>.zcode-session`, and a relaunch whose prior incarnation was zcode reuses exactly that id through `--resume` - never `-c`, whose latest-for-cwd slot another session could claim. `--attach <path>` is file attachment to `--prompt`, not session resume. |
| Subcommands | `app-server` (stdio protocol) and `doctor` (environment diagnosis); `app-server` serves editor-style integrations, not Firstmate's pane model. |
| Exit codes | Blind: headless error paths exit 0 - credential refusals, request-signing errors, unknown options (`--model`, `--effort`, `--reasoning-effort` all print the help dump), and unresumable-session errors were all verified exiting 0 - so success detection reads output and state, never exit status. |
| Busy state | Semantic since Phase B: the firstmate-owned global UserPromptSubmit/Stop hook pair (below) opens and closes the busy record through source `zcode-hook`, verified live headless. The rendered-tail classifier stays as the no-record fallback with no default signature (`FM_BUSY_ZCODE_REGEX` pins one explicitly), because the headless mode renders nothing mid-turn. |
| Turn end | The runtime's native `Stop` hook, wired through `bin/fm-zcode-turnend-hook.sh`: a guarded global hook installed into `~/.zcode/cli/config.json` (the kimi surgical pattern adapted to JSON - JSON carries no comment markers, so entry identity is the hook script path in the command), gated per task by a `.fm-zcode-turnend` token pointer matching the firstmate-owned registry `~/.zcode/cli/fm-turn-end.d/`. Verified live on 0.16.5: user-config `hooks.events` entries fire in headless `--prompt` mode with a Claude-compatible stdin payload (`hook_event_name`, `cwd`, `session_id`, `permission_mode`), gated on `hooks.enabled=true` (the shipped `config.example.json` defaults it false, so install raises it). `Stop` fires at normal turn end and does NOT fire on a SIGINT interrupt (verified: the process dies, status 130, no event). A project-level `.zcode/config.json` hook was tested live and does not fire without zcode's workspace-hook trust grant, which is exactly why the hook is global. |
| Interrupt | `SIGINT` forwarded to the runtime under the documented host contract; `../../../../../bin/fm-control.sh` interrupt owns the verb. Verified live: a mid-turn C-c ends the headless process (status 130) - the process IS the turn - so the interrupt verification accepts the dead state as the documented success shape. |
| Exit | Signal-shaped: `../../../../../bin/fm-control.sh` exit owns the verb and stops a live zcode worker with the same single C-c, waiting for the dead state - there is no composer and no typed exit command. |
| Skill | No verified slash-skill form in the researched surface; use natural language. |
| Autonomy | `--mode yolo` is the autopilot value; verified live across the research, Phase A, and Phase B probes. |
| Marker | None of zcode's own: the runtime's `ZCODE_*` env surface carries no child-identity marker. `FM_ZCODE_HARNESS=zcode` is Firstmate's launch marker, the omp pattern, and ancestry matches the `zcode` bin. |
| Process names | Kernel comm values verified live via `/proc/<pid>/comm`: the wrapper runs as `node`, the runtime child renames itself `zcode-cli`, and the MCP grandchild is `zcode-node-repl`. `ps --forest` prints `zco` and `zcode-c` artifacts for the same processes because its tree indentation eats the fixed-width comm column - no real process carries those names, and the anchored sets in `../../../../../bin/fm-harness.sh` and `../../../../../bin/fm-agent-process-lib.sh` match only the kernel values. |
| Model | No headless model flag: `--model` is rejected with the help dump (verified live); model selection is the TUI's `/model` slash command or the config's `model.main`. `references/common/model-and-effort.md`'s record-and-omit contract applies. The authoritative catalog is the config's provider block: `zai/glm-5.3`, `glm-5.3-flash`, `glm-5.2`, `glm-5.1`, `glm-5-turbo`. |
| Effort | No effort flag at all: `--effort` and `--reasoning-effort` are both rejected with the help dump (verified live on 0.16.5); record-and-omit applies. |
| Quota | Provider-level windows, not tokens: the GLM Coding Plan meters a 5-hour and a weekly credit window. Verified live on 2026-09-14 against `https://api.z.ai/api/monitor/usage/quota/limit` with the plan key: two `CREDIT_LIMIT` entries (`unit=3,number=5` and `unit=6,number=1`) with `percentage` and `nextResetTime`, plus the plan `level`. `quota-axi --provider zai` reads exactly that endpoint and normalizes exactly those windows (quota-axi 0.1.42), so provider-level quota evidence for every GLM model in the family flows through the zai provider; its credential source is opencode's `~/.local/share/opencode/auth.json` (`zai-coding-plan` and friends), which is a separate surface from the zcode config's own key. |
| Credential | Three paths: Z.AI OAuth (macOS-only callback), a Coding Plan API key masked at `/login` and stored in `~/.zcode/cli/config.json`, or a custom provider with an inline key; `ZCODE_API_KEY` is read by the runtime, verified by a dummy value reaching request-signing. |
| Trust | A first-run setup wizard exists (`setup-pending`); no project-trust gate was observed, and the 2026-09-14 live pass completed an unattended spawn with a clean self-exit and no setup park. |

ZCODE_API_KEY must reach the worker environment on its own, because the launch template wires no credential itself: keep the export in the environment firstmate launches from (for example a `config/zcode.env` on the home, exported ahead of the launch) or configure the runtime's own `~/.zcode/cli/config.json` instead.

## Detection

`FM_ZCODE_HARNESS=zcode` plus an ancestry rule matching the `zcode` bin is Firstmate's own identity, because zcode carries no native child-process marker.
`../../../../../bin/fm-harness.sh` owns the marker and ancestry mechanics, and a marker inherited without real zcode ancestry is inert, the omp foreign-marker discipline.

## Crewmate and scout only

zcode is verified for crewmate and scout launches only.
A secondmate is a firstmate instance and needs a primary supervision protocol; zcode has none, so the spawn arm refuses a zcode secondmate, the muse/gemini/agy shape in `../../../../../bin/fm-spawn.sh`.

## Supervision recipe

This recipe has been operative since the 2026-09-14 live verification pass, and it lives here rather than in `docs/supervision-protocols/` because that directory is the rendered primary-wake-protocol set whose emptiness for crewmate/scout-only harnesses is load-bearing in `../../../../../bin/fm-spawn.sh`'s refusal comments.
When a session supervises live zcode workers:
1. Drain first with `../../../../../bin/fm-wake-drain.sh`, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED` after handling every emitted wake, and let interruption before that acknowledgement leave the work durable for idempotent re-handling.
2. Busy state comes from the zcode-hook semantic record: the global hook pair opens the record on UserPromptSubmit and closes it on Stop (verified live headless), armed at spawn like claude and gemini. For a task with no record, the rendered-tail fallback keeps its Phase A contract: `unknown` is the safe verdict, and no default signature ships because the headless mode renders nothing mid-turn.
3. Drive lifecycle only through `../../../../../bin/fm-control.sh <task-id> interrupt|exit|relaunch`; the documented host contract forwards `SIGINT` and `SIGTERM` to the runtime, interrupt and exit are signal verbs (one C-c; for a headless worker the interrupt legitimately ends the process, and exit is that same signal with a dead-state wait), never typed keys or lifecycle text through `fm-send`.
4. Read current state through `../../../../../bin/fm-crew-state.sh <id>`, which feeds the pane tail to the classifier the way the grok tail-capture precedent does; a status line is a wake event, not current state.
5. Never trust exit status.
   zcode's headless error paths exit 0, so a failed turn can look successful to any check that reads exit codes; judge outcomes from output, worker status events, and current-state reads.
6. Treat any credential refusal - `Model access is not configured for zai. Run /login or /setup in zcode` - as a credential blocker under `../../../../../AGENTS.md` section 9: fix the environment (`ZCODE_API_KEY` or `~/.zcode/cli/config.json`) and retire the endpoint rather than typing into the pane.
7. Relaunches of a zcode task resume the prior incarnation's recorded session through `--resume` (the hook records the id; `../../../../../bin/fm-spawn.sh` reuses it only when the prior recorded harness was zcode), so the replacement worker keeps its predecessor's conversation context while the brief on disk remains the durable instruction.

## Live verification gate

Passed 2026-09-14 against `zcode-app-cli` 3.11.2-24 wrapping `zcode-runtime` 0.16.5: a raw-launch trivial scout ran its brief end to end under supervision, writing its report and status tokens exactly, with the `FM_ZCODE_HARNESS` detection marker resolved, the busy classifier per its documented contract, and a clean self-exit.
The Phase B live guard `tests/fm-zcode-signals-live-e2e.test.sh` (opt-in, `FM_ZCODE_SIGNALS_LIVE=1`) re-proves on the installed harness: the hook installer against the real config, a real headless turn closing the busy record through `zcode-hook`, the session-id record, the kernel comm set, the `--resume` context restore, and clean removal.
Record the dated per-harness result in `../../../../../docs/verification/runtime-backends.md` when that gate runs.

## Primary integration

Unsupported and unverified.
A firstmate session running on zcode follows the unknown-harness fallback, and `references/common/primary-hooks.md`'s unsupported-boundary rule applies: never invent a wake protocol from a similar TUI.
