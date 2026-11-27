#!/usr/bin/env bash
# Live driver: run the real bin/fm-watch.sh against a disposable lab FM_HOME
# and show that one sweep runs every due check (usage: drive-sweep.sh <repo-root> <label>)
set -u
ROOT=$1; LABEL=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
S="$LAB/state"
echo "== [$LABEL] watcher: $ROOT/bin/fm-watch.sh  lab home: $LAB"
# Checks in name order: ea-incidents prints (chatty early), order-attention prints
# and records that it ran (time-critical later check), zz-quiet prints nothing.
cat > "$S/ea-incidents.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'new EA incident INC-1\n'
SH
cat > "$S/order-attention.check.sh" <<SH
#!/usr/bin/env bash
date +%s > "$S/order-attention.ran"
printf 'order EA-TEST-0001 admin_needs_action\n'
SH
cat > "$S/zz-quiet.check.sh" <<SH
#!/usr/bin/env bash
date +%s > "$S/zz-quiet.ran"
SH
chmod 0700 "$S"/*.check.sh
for c in ea-incidents order-attention zz-quiet; do
  env -u FM_STATE_OVERRIDE FM_HOME="$LAB" "$ROOT/bin/fm-check-register.sh" "$c" >/dev/null || echo "register $c failed"
done
run_watch() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
      -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
      FM_HOME="$LAB" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
      timeout 30 "$ROOT/bin/fm-watch.sh"
}
echo "-- cycle 1 wake output (stdout of fm-watch.sh):"
run_watch; echo "   (exit=$?)"
echo "-- which checks ran in cycle 1:"
for f in order-attention zz-quiet; do [ -f "$S/$f.ran" ] && echo "   $f.check.sh RAN" || echo "   $f.check.sh DID NOT RUN"; done
echo "-- durable wake queue rows after cycle 1 (fm-wake-drain.sh):"
env -u FM_STATE_OVERRIDE FM_HOME="$LAB" "$ROOT/bin/fm-wake-drain.sh" | grep "$(printf '\tcheck\t')" | cut -f2- | sed 's/^/   /'
echo "-- exit log tail:"; tail -n 3 "$S/.watch-cycle-exits.log" 2>/dev/null | sed 's/^/   /'
rm -rf "$LAB"
echo "== [$LABEL] lab removed"
