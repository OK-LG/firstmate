#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=/root/.no-mistakes/evidence/01M6DY1J0F2N3BYSPMY2GKYGJH
export FM_HC_BIN=$ROOT/.test-hc/bin/herdr-core FM_HC_LAB_DIR=$ROOT/.test-hc/labs
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_BACKEND TMUX HERDR_ENV CMUX_WORKSPACE_ID REX_BLOCK REX_SESSION TERM_PROGRAM HC_SOCKET HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE
export FM_HOME=$ROOT/.test-hc/manual-home
[ -f "$FM_HOME/.fm-lab-home" ] || bin/fm-lab-home.sh create "$FM_HOME"
SES=$(bin/fm-hc-lab.sh name manual)
cleanup() { rc=$?; trap - EXIT; bin/fm-hc-lab.sh teardown "$SES" || rc=1; exit "$rc"; }
trap cleanup EXIT
bin/fm-hc-lab.sh provision "$SES"
export HC_SESSION=$SES FM_HC_SOCKET=$(bin/fm-hc-lab.sh socket "$SES")
export XDG_STATE_HOME=$FM_HC_LAB_DIR/$SES/env/xdg-state XDG_CONFIG_HOME=$FM_HC_LAB_DIR/$SES/env/xdg-config XDG_DATA_HOME=$FM_HC_LAB_DIR/$SES/env/xdg-data
. bin/fm-backend.sh
fm_backend_source hc
printf '\nCORE HANDSHAKE: '; fm_backend_hc_container_ensure; printf '\n'
ADDR=$(fm_backend_hc_create_task "$SES" fm-live "$ROOT/.test-hc")
TARGET=$SES:$ADDR
bin/fm-hc-lab.sh run "$SES" get "$ADDR" --json | tee "$EVIDENCE/hc-terminal.json"
fm_backend_hc_send_text_line "$TARGET" 'printf "LIVE_OUTPUT_%s\n" 731; cd tmp' fm-live
for i in {1..50}; do
  [ "$(fm_backend_hc_current_path "$TARGET" fm-live)" = "$ROOT/.test-hc/tmp" ] && break
  sleep .1
done
[ "$(fm_backend_hc_current_path "$TARGET" fm-live)" = "$ROOT/.test-hc/tmp" ]
printf '\nCAPTURE AFTER SUBMIT:\n'
fm_backend_capture hc "$TARGET" 20 fm-live | tee "$EVIDENCE/hc-screen.txt"
grep -qx LIVE_OUTPUT_731 "$EVIDENCE/hc-screen.txt"
printf '\nCURRENT DIRECTORY: '; fm_backend_hc_current_path "$TARGET" fm-live; printf '\n'
printf '\nDUPLICATE CREATE REFUSAL:\n'
if fm_backend_hc_create_task "$SES" fm-live "$ROOT/.test-hc"; then exit 21; fi
printf '\nLABEL-BOUND DETECTION:\n'
export HC_TERMINAL_ID=$ADDR HC_TERMINAL_SOCKET=$FM_HC_SOCKET
fm_backend_resolve
printf 'backend=%s signal=%s\n' "$FM_BACKEND_RESOLVED" "$FM_BACKEND_DETECT_SIGNAL"
[ "$FM_BACKEND_RESOLVED:$FM_BACKEND_DETECT_SIGNAL" = hc:app-terminal ]
printf '\nEXPLICIT SELECTION WINS:\n'
FM_BACKEND=tmux fm_backend_resolve
printf 'backend=%s signal=%s\n' "$FM_BACKEND_RESOLVED" "$FM_BACKEND_DETECT_SIGNAL"
[ "$FM_BACKEND_RESOLVED" = tmux ]
printf '\nWRONG CORE SOCKET DOES NOT SELECT HC:\n'
FM_HC_SOCKET=$ROOT/.test-hc/no-core.sock fm_backend_resolve
printf 'backend=%s\n' "$FM_BACKEND_RESOLVED"
[ "$FM_BACKEND_RESOLVED" = tmux ]
[ ! -e "$ROOT/.test-hc/no-core.sock" ]
printf '\nUNSUPPORTED INSTALLED CORE DOES NOT SELECT HC:\n'
FM_HC_BIN=/root/.local/bin/herdr-core fm_backend_resolve
printf 'backend=%s signal=%s\n' "$FM_BACKEND_RESOLVED" "$FM_BACKEND_DETECT_SIGNAL"
[ "$FM_BACKEND_RESOLVED" = tmux ]
printf '\nBARE CORE TERMINAL DOES NOT SELECT HC:\n'
BARE=$(bin/fm-hc-lab.sh run "$SES" run --bg --no-parent --outlive-parent --no-notify --cwd "$ROOT/.test-hc" | jq -r .address)
HC_TERMINAL_ID=$BARE fm_backend_resolve
printf 'backend=%s\n' "$FM_BACKEND_RESOLVED"
[ "$FM_BACKEND_RESOLVED" = tmux ]
printf '\nWRONG TASK INPUT REFUSAL:\n'
if fm_backend_hc_send_text_line "$TARGET" 'touch forbidden-write' fm-other; then exit 22; fi
[ ! -e "$ROOT/.test-hc/tmp/forbidden-write" ]
printf 'send refused; forbidden-write absent\n'
printf '\nFOREIGN HOME CLOSE REFUSAL:\n'
mkdir -p "$ROOT/.test-hc/other-home"
printf 'owner-home=%s owner-tag=%s\n' "$FM_HOME" "$(fm_backend_hometag)"
if FM_HOME=$ROOT/.test-hc/other-home env -u FM_ROOT bash -c '. bin/fm-backend.sh; fm_backend_source hc; printf "foreign-home=%s foreign-tag=%s\n" "$FM_HOME" "$(fm_backend_hometag)"; fm_backend_kill hc "$1"' _ "$TARGET"; then
  printf 'FAIL: fresh foreign-home process closed the original terminal; state=%s\n' "$(fm_backend_agent_state hc "$TARGET")"
  CROSS_HOME_FAILURE=1
  ADDR=$(fm_backend_hc_create_task "$SES" fm-live "$ROOT/.test-hc")
  TARGET=$SES:$ADDR
else
  printf 'foreign close refused\n'
  fm_backend_target_exists hc "$TARGET" fm-live
fi
printf '\nSTALE AMBIENT SOCKET DOES NOT DIVERT RECORDED TARGET:\n'
HC_SOCKET=$ROOT/.test-hc/alien.sock HC_SESSION=unrelated fm_backend_hc_send_text_line "$TARGET" 'printf "ROUTED_%s\n" 992' fm-live
for i in {1..50}; do
 fm_backend_capture hc "$TARGET" 20 fm-live > "$EVIDENCE/hc-routed-screen.txt"
 grep -qx ROUTED_992 "$EVIDENCE/hc-routed-screen.txt" && break
 sleep .1
done
cat "$EVIDENCE/hc-routed-screen.txt"
grep -qx ROUTED_992 "$EVIDENCE/hc-routed-screen.txt"
[ ! -e "$ROOT/.test-hc/alien.sock" ]
printf '\nCLOSE AND VERIFY ABSENCE:\n'
fm_backend_kill hc "$TARGET"
printf 'agent-state=%s\n' "$(fm_backend_agent_state hc "$TARGET")"
[ "$(fm_backend_agent_state hc "$TARGET")" = missing ]
fm_backend_kill hc "$TARGET"
printf 'second close succeeded\n'
printf '\nDEAD DETECTION SOCKET DOES NOT START CORE:\n'
HC_TERMINAL_SOCKET=$ROOT/.test-hc/dead.sock FM_HC_SOCKET=$ROOT/.test-hc/dead.sock fm_backend_resolve
printf 'backend=%s socket-exists=' "$FM_BACKEND_RESOLVED"
[ ! -e "$ROOT/.test-hc/dead.sock" ] && printf 'false\n'
[ "$FM_BACKEND_RESOLVED" = tmux ]
printf '\nManual checks complete; cross-home-failure=%s; guarded teardown follows\n' "${CROSS_HOME_FAILURE:-0}"
[ "${CROSS_HOME_FAILURE:-0}" = 0 ]
