# zcode

Z.AI's official coding-agent harness, driving GLM-5.3 and GLM-5.3-Flash against a GLM Coding Plan subscription.
The official CLI ships inside the ZCode Desktop app and has no official standalone npm package.
The runnable Linux artifact is the third-party `zcode-app-cli` package (kingsword09/zcode-cli, MIT), which extracts the official runtime, supplies a pi-tui-based TUI, and exposes the public `zcode` bin with a versioned host-integration contract for agent orchestrators at its own `docs/HOST_INTEGRATION.md`.
Researched against `zcode-app-cli` 3.11.2-24 wrapping `zcode-runtime` 0.16.5 on Linux with Node 22.22.3; every fact below comes from that research's headless probes, the shipped help, and bundle strings, and the 2026-09-14 live verification pass confirmed the supervision-critical subset - end-to-end dispatch, detection, and busy classification - on the real harness.
Dispatch is pinned to the exact installed wrapper version because it tracks a desktop-app-aligned release train, and the package redistributes a proprietary runtime: confirm upstream terms before use.
Verified for crewmate and scout launches on 2026-09-14 against `zcode-app-cli` 3.11.2-24 wrapping `zcode-runtime` 0.16.5: a raw-launch trivial scout executed its brief end to end under supervision, with report and status tokens written exactly, the `FM_ZCODE_HARNESS` detection marker resolved, the busy classifier holding its documented contract, and a clean self-exit.

## Operating facts

| Fact | Value |
|---|---|
| Binary | The `zcode` bin of the installed `zcode-app-cli` package, pinned to the exact installed version. |
| Launch | Headless single-prompt mode is first-class: `--prompt <text>`, with `-p`/`--print` aliases, runs one prompt without the TUI, and `--cwd` exists. |
| Mode | `--mode build\|edit\|plan\|yolo`, and it defaults to `yolo` for `--prompt`, which is the unattended posture; the Phase A spawn design pins it explicitly rather than trusting the default. |
| JSON | `--json` prints machine-readable output where supported. |
| Resume | `--resume <sessionId>`, `-c`/`--continue`, `--attach`, and `--disallowed-tools` exist; there is no verified pane-resume contract, so use deterministic relaunch. |
| Subcommands | `app-server` (stdio protocol) and `doctor` (environment diagnosis); `app-server` serves editor-style integrations, not Firstmate's pane model. |
| Exit codes | Blind: headless error paths exit 0 - the not-configured message and a request-signing error both exited 0 in the research probes - so success detection reads output and state, never exit status. |
| Busy state | No semantic source: the Phase A design adds a zcode arm to `../../../../../bin/fm-busy-lib.sh` in the grok/rovo/agy rendered-tail screen-scrape shape, and the 2026-09-14 live pass confirmed the classifier's unknown-not-idle contract on a real zcode turn. |
| Turn end | No turn-end touch is wired in Phase A; completion arrives through the worker status protocol and the screen-scrape return to idle. The runtime's native `Stop` hook exists, and a firstmate-owned plugin for it is Phase B work. |
| Interrupt | `SIGINT` forwarded to the runtime under the documented host contract; `../../../../../bin/fm-control.sh` interrupt owns the verb. |
| Exit | `SIGTERM` forwarded to the runtime with exit status preserved under the same contract; `../../../../../bin/fm-control.sh` exit owns the verb. |
| Skill | No verified slash-skill form in the researched surface; use natural language. |
| Autonomy | `--mode yolo` is the autopilot value; no model turn ran during the research, so unattended tool approval is unverified until the live gate. |
| Marker | None of zcode's own: the runtime's `ZCODE_*` env surface carries no child-identity marker. `FM_ZCODE_HARNESS=zcode` is Firstmate's launch marker, the omp pattern, and ancestry matches the `zcode` bin. |
| Model | Model selection exists in the TUI and the headless flag set needs verification; `references/common/model-and-effort.md`'s record-and-omit contract applies. |
| Effort | No effort flag in the researched surface; record-and-omit applies. |
| Credential | Three paths: Z.AI OAuth (macOS-only callback), a Coding Plan API key masked at `/login` and stored in `~/.zcode/cli/config.json`, or a custom provider with an inline key; `ZCODE_API_KEY` is read by the runtime, verified by a dummy value reaching request-signing. |
| Trust | A first-run setup wizard exists (`setup-pending`); no project-trust gate was observed, and the 2026-09-14 live pass completed an unattended spawn with a clean self-exit and no setup park. |

ZCODE_API_KEY must reach the worker environment on its own, because the Phase A launch template wires no credential itself: keep the export in the environment firstmate launches from (for example a `config/zcode.env` on the home, exported ahead of the launch) or configure the runtime's own `~/.zcode/cli/config.json` instead.

## Detection

`FM_ZCODE_HARNESS=zcode` plus an ancestry rule matching the `zcode` bin is Firstmate's own identity, because zcode carries no native child-process marker.
`../../../../../bin/fm-harness.sh` owns the marker and ancestry mechanics, and a marker inherited without real zcode ancestry is inert, the omp foreign-marker discipline.

## Crewmate and scout only

zcode is verified for crewmate and scout launches only; the live verification gate below is the historical gate that scope passed.
A secondmate is a firstmate instance and needs a primary supervision protocol; zcode has none, so the spawn arm refuses a zcode secondmate, the muse/gemini/agy shape in `../../../../../bin/fm-spawn.sh`.

## Supervision recipe, Phase A design

This recipe has been operative since the 2026-09-14 live verification pass, and it lives here rather than in `docs/supervision-protocols/` because that directory is the rendered primary-wake-protocol set whose emptiness for crewmate/scout-only harnesses is load-bearing in `../../../../../bin/fm-spawn.sh`'s refusal comments.
When a session supervises live zcode workers:
1. Drain first with `../../../../../bin/fm-wake-drain.sh`, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED` after handling every emitted wake, and let interruption before that acknowledgement leave the work durable for idempotent re-handling.
2. Busy state comes from the zcode arm the Phase A design adds to `../../../../../bin/fm-busy-lib.sh`, the grok/rovo/agy rendered-tail screen-scrape shape: zcode has no semantic busy source, `unknown` is the safe verdict when the busy marker scrolls out of the captured tail, and the 2026-09-14 live pass confirmed that unknown-not-idle contract on a real zcode turn.
3. Drive lifecycle only through `../../../../../bin/fm-control.sh <task-id> interrupt|exit|relaunch`; the documented host contract forwards `SIGINT` and `SIGTERM` to the runtime and preserves exit status, so interrupt and exit are signal verbs, never typed keys or lifecycle text through `fm-send`.
4. Read current state through `../../../../../bin/fm-crew-state.sh <id>`, which feeds the pane tail to the classifier the way the grok tail-capture precedent does; a status line is a wake event, not current state.
5. Never trust exit status.
   zcode's headless error paths exit 0, so a failed turn can look successful to any check that reads exit codes; judge outcomes from output, worker status events, and current-state reads.
6. Treat any credential refusal - `Model access is not configured for zai. Run /login or /setup in zcode` - as a credential blocker under `../../../../../AGENTS.md` section 9: fix the environment (`ZCODE_API_KEY` or `~/.zcode/cli/config.json`) and retire the endpoint rather than typing into the pane.
7. Phase A wires no native turn-end touch: completion arrives through the worker status protocol and the screen-scrape return to idle, and the runtime's native `Stop` hook stays unwired until the Phase B plugin exists.

## Live verification gate

Passed 2026-09-14 against `zcode-app-cli` 3.11.2-24 wrapping `zcode-runtime` 0.16.5: a raw-launch trivial scout ran its brief end to end under supervision, writing its report and status tokens exactly, with the `FM_ZCODE_HARNESS` detection marker resolved, the busy classifier per its documented contract, and a clean self-exit.
A new tool remains undispatchable until the `verify` plan, its harness entry, every named owner, and the live checks land: pass dispatch, control-and-recovery, primary-hooks, and model-and-effort end to end on the real harness before dispatching anything.
Record the dated per-harness result in `../../../../../docs/verification/runtime-backends.md` when that gate runs.

## Primary integration

Unsupported and unverified.
A firstmate session running on zcode follows the unknown-harness fallback, and `references/common/primary-hooks.md`'s unsupported-boundary rule applies: never invent a wake protocol from a similar TUI.