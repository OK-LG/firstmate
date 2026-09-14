# zcode

Z.AI's official coding-agent harness, driving GLM-5.3 and GLM-5.3-Flash against a GLM Coding Plan subscription.
The official CLI ships inside the ZCode Desktop app and has no official standalone npm package.
The runnable Linux artifact is the third-party `zcode-app-cli` package (kingsword09/zcode-cli, MIT), which extracts the official runtime, supplies a pi-tui-based TUI, and exposes the public `zcode` bin with a versioned host-integration contract for agent orchestrators at its own `docs/HOST_INTEGRATION.md`.
Researched against `zcode-app-cli` 3.11.2-24 wrapping `zcode-runtime` 0.16.5 on Linux with Node 22.22.3; every fact below comes from that research's headless probes, the shipped help, and bundle strings, and the live verification gate owns turning them into verified supervision behavior.
Dispatch is pinned to the exact installed wrapper version because it tracks a desktop-app-aligned release train and redistributes a proprietary runtime under an upstream-terms caveat the captain has accepted.

## Operating facts

| Fact | Value |
|---|---|
| Binary | The `zcode` bin of the installed `zcode-app-cli` package, pinned to the exact installed version. |
| Launch | Headless single-prompt mode is first-class: `--prompt <text>`, with `-p`/`--print` aliases, runs one prompt without the TUI, and `--cwd` sets the working directory. |
| Mode | `--mode build\|edit\|plan\|yolo`, and it defaults to `yolo` for `--prompt`, which is the unattended posture; the spawn pins it explicitly rather than trusting the default. |
| JSON | `--json` prints machine-readable output where supported. |
| Resume | `--resume <sessionId>`, `-c`/`--continue`, `--attach`, and `--disallowed-tools` exist; there is no verified pane-resume contract, so use deterministic relaunch. |
| Subcommands | `app-server` (stdio protocol) and `doctor` (environment diagnosis); `app-server` serves editor-style integrations, not Firstmate's pane model. |
| Exit codes | Blind: headless error paths exit 0 - the not-configured message and a request-signing error both exited 0 in the research probes - so success detection reads output and state, never exit status. |
| Busy state | No semantic source: the rendered-tail screen-scrape fallback in `../../../../../bin/fm-busy-lib.sh` (grok-regex shape) classifies busy. |
| Turn end | No turn-end touch is wired in Phase A; completion arrives through the worker status protocol and the screen-scrape return to idle. The runtime's native `Stop` hook exists, and a firstmate-owned plugin for it is Phase B work. |
| Interrupt | `SIGINT` forwarded to the runtime under the documented host contract; `../../../../../bin/fm-control.sh` interrupt owns the verb. |
| Exit | `SIGTERM` forwarded to the runtime with exit status preserved under the same contract; `../../../../../bin/fm-control.sh` exit owns the verb. |
| Skill | No verified slash-skill form in the researched surface; use natural language. |
| Autonomy | `--mode yolo` is the autopilot value; no model turn ran during the research, so unattended tool approval is unverified until the live gate. |
| Marker | None of zcode's own: the runtime's `ZCODE_*` env surface carries no child-identity marker. `FM_ZCODE_HARNESS=zcode` is Firstmate's launch marker, the omp pattern, and ancestry matches the `zcode` bin. |
| Model | Model selection exists in the TUI and the headless flag set needs verification; `references/common/model-and-effort.md`'s record-and-omit contract applies. |
| Effort | No effort flag in the researched surface; record-and-omit applies. |
| Credential | Three paths: Z.AI OAuth (macOS-only callback), a Coding Plan API key masked at `/login` and stored in `~/.zcode/cli/config.json`, or a custom provider with an inline key; `ZCODE_API_KEY` is read by the runtime, verified by a dummy value reaching request-signing. |
| Trust | A first-run setup wizard exists (`setup-pending`); no project-trust gate was observed, and the unattended setup-skip equivalent is unverified, so close both in the live gate before trusting a spawn. |

## Detection

`FM_ZCODE_HARNESS=zcode` plus an ancestry rule matching the `zcode` bin is Firstmate's own identity, because zcode carries no native child-process marker.
`../../../../../bin/fm-harness.sh` owns the marker and ancestry mechanics, and a marker inherited without real zcode ancestry is inert, the omp foreign-marker discipline.

## Crewmate and scout only

zcode is verified for crewmate and scout launches only.
A secondmate is a firstmate instance and needs a primary supervision protocol; zcode has none, so `../../../../../bin/fm-spawn.sh` refuses a zcode secondmate.
[`../../../../../docs/supervision-protocols/zcode.md`](../../../../../docs/supervision-protocols/zcode.md) documents supervising zcode workers, not a primary wake protocol.

## Live verification gate

No supervised zcode worker has run yet: the research verified the CLI surface headlessly, and every supervision fact here is the Phase A design, not observed behavior.
A new tool remains undispatchable until the `verify` plan, its harness entry, every named owner, and the live checks land: pass dispatch, control-and-recovery, primary-hooks, and model-and-effort end to end on the real harness before dispatching anything.
Record the dated per-harness result under `../../../../../docs/verification/` when that gate runs.

## Primary integration

Unsupported and unverified.
A firstmate session running on zcode follows the unknown-harness fallback, and `references/common/primary-hooks.md`'s unsupported-boundary rule applies: never invent a wake protocol from a similar TUI.
