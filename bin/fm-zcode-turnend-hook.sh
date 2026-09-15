#!/usr/bin/env bash
# Install or remove Firstmate's guarded zcode crew turn-end and busy-state hook.
#
# This command is the sole owner of the structured edit to
# $HOME/.zcode/cli/config.json. It validates the existing JSON but never
# preserves its byte formatting: install adds or replaces exactly the
# Firstmate-owned leaves (the hooks.enabled=true gate and one hook entry in
# hooks.events.UserPromptSubmit and hooks.events.Stop whose command runs
# $HOME/.zcode/cli/fm-turn-end.sh), and remove excises exactly those entries.
# JSON carries no comment markers, so the kimi-style marker-delimited region
# is impossible here; entry identity is the hook script path referenced by
# the command instead, and every foreign key survives the round trip
# semantically because the whole file is parsed before and after the merge.
# Missing, malformed, symlinked, or otherwise surprising config is refused
# without a config write.
#
# The installed hook always exits 0 and stays silent. It reads its payload
# and workspace cwd from stdin, checks for a .fm-zcode-turnend pointer before
# any registry work, and touches a task turn-end marker, applies a busy-state
# event, and records the zcode session id only when the pointer names a
# Firstmate-created token in $HOME/.zcode/cli/fm-turn-end.d/ whose registry
# entry was written by bin/fm-spawn.sh.
#
# Verified live on zcode-app-cli 3.11.2-24 wrapping zcode-runtime 0.16.5:
# user-config hooks.events entries fire in headless --prompt mode with a
# Claude-compatible stdin payload (hook_event_name, cwd, session_id), and
# they require hooks.enabled=true (the shipped config.example.json defaults
# it to false, so install sets it explicitly).
#
# Usage:
#   fm-zcode-turnend-hook.sh install
#   fm-zcode-turnend-hook.sh remove
set -u

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

case "${1:-}" in
  install|remove) ACTION=$1 ;;
  -h|--help)
    sed -n '2,30{s/^# \{0,1\}//;p;}' "$0"
    exit 0
    ;;
  *)
    printf 'usage: %s install|remove\n' "${0##*/}" >&2
    exit 2
    ;;
esac

if [ -z "${HOME:-}" ]; then
  printf 'fm-zcode-turnend-hook: refused: HOME is unset.\n' >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf 'fm-zcode-turnend-hook: refused: python3 is required to validate config.json.\n' >&2
  exit 1
fi
if [ "$ACTION" = install ] && ! command -v jq >/dev/null 2>&1; then
  printf 'fm-zcode-turnend-hook: refused: jq is required by the installed zcode turn-end hook.\n' >&2
  exit 1
fi

python3 - "$ACTION" "$HOME/.zcode/cli" "$FM_ROOT/bin/fm-busy-event.sh" <<'PY'
import json
import os
import re
import shutil
import stat
import sys
import tempfile

ACTION = sys.argv[1]
CONFIG_DIR = sys.argv[2]
BUSY_EVENT = sys.argv[3]
CONFIG = os.path.join(CONFIG_DIR, "config.json")
HOOK = os.path.join(CONFIG_DIR, "fm-turn-end.sh")
REGISTRY = os.path.join(CONFIG_DIR, "fm-turn-end.d")
HOOK_NAME = b"fm-turn-end.sh"
TOKEN_NAME = re.compile(r"fm\.[A-Za-z0-9]{12}\Z")
FIRSTMATE_EVENTS = ("UserPromptSubmit", "Stop")

# The hook command intentionally carries no arguments: the registry entry is
# the per-task data plane, so one global command serves every task and every
# event, and the hook itself gates on hook_event_name.
HOOK_COMMAND = f'bash "{HOOK}"'

HOOK_BYTES = b'''#!/usr/bin/env bash
# Firstmate zcode turn-end and busy-state hook. Managed by fm-zcode-turnend-hook.sh.
# This hook is deliberately passive: every path is silent and exits zero.
set +e
exec >/dev/null 2>&1
payload=
IFS= read -r payload || [ -n "$payload" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
event=$(jq -er 'select((.hook_event_name // "") == "UserPromptSubmit" or (.hook_event_name // "") == "Stop") | .hook_event_name' <<< "$payload" 2>/dev/null) || exit 0
workspace=$(jq -er '.cwd | strings | select(length > 0)' <<< "$payload" 2>/dev/null) || exit 0
session=$(jq -r '.session_id | strings | select(length > 0)' <<< "$payload" 2>/dev/null) || session=
pointer="$workspace/.fm-zcode-turnend"
[ -f "$pointer" ] || exit 0
first=
IFS= read -r -n 256 first < "$pointer" 2>/dev/null || [ -n "$first" ] || exit 0
case "$first" in token=*) token=${first#token=} ;; *) exit 0 ;; esac
case "$token" in fm.????????????) : ;; *) exit 0 ;; esac
case "$token" in *[!A-Za-z0-9._-]*) exit 0 ;; esac
auth_dir=${HOME:-}/.zcode/cli/fm-turn-end.d
[ -n "${HOME:-}" ] || exit 0
state_dir= id= gen= turnended=
while IFS= read -r line; do
  case "$line" in
    state-dir=*) state_dir=${line#state-dir=} ;;
    id=*) id=${line#id=} ;;
    gen=*) gen=${line#gen=} ;;
    turn-ended=*) turnended=${line#turn-ended=} ;;
  esac
done < "$auth_dir/$token" 2>/dev/null || exit 0
case "$id" in ''|*[!A-Za-z0-9._-]*) exit 0 ;; esac
case "$state_dir" in /*) : ;; *) exit 0 ;; esac
case "$gen" in ''|*[!A-Za-z0-9._-]*) exit 0 ;; esac
case "$turnended" in /*.turn-ended) : ;; *) exit 0 ;; esac
if [ -n "$session" ]; then
  case "$session" in
    sess_[!/=]*)
      printf 'session_id=%s\n' "$session" > "$state_dir/$id.zcode-session" 2>/dev/null || true
      ;;
  esac
fi
case "$event" in
  UserPromptSubmit)
    '__BUSY_EVENT__' apply "$state_dir" "$id" busy --gen "$gen" --source zcode-hook --event user-prompt-submit 2>/dev/null || true
    ;;
  Stop)
    touch -- "$turnended" 2>/dev/null || true
    '__BUSY_EVENT__' apply "$state_dir" "$id" idle --gen "$gen" --source zcode-hook --event stop 2>/dev/null || true
    ;;
esac
exit 0
'''

# Bake the concrete busy-event path so the globally installed hook never
# depends on PATH or on firstmate's checkout location at fire time.
HOOK_BYTES = HOOK_BYTES.replace(b"'__BUSY_EVENT__'", json.dumps(BUSY_EVENT).encode())


def refuse(reason: str) -> None:
    print(f"fm-zcode-turnend-hook: refused: {reason}", file=sys.stderr)
    raise SystemExit(1)


def regular_not_symlink(path: str, label: str) -> os.stat_result:
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        refuse(f"{label} is missing at {path}.")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        refuse(f"{label} is not a regular non-symlink file at {path}.")
    return info


def entry_is_firstmate(entry) -> bool:
    return (
        isinstance(entry, dict)
        and isinstance(entry.get("hooks"), list)
        and any(
            isinstance(hook, dict)
            and isinstance(hook.get("command"), str)
            and HOOK_NAME.decode() in hook["command"]
            for hook in entry["hooks"]
        )
    )


def parse_and_validate(data: bytes, label: str):
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        refuse(f"{label} is not UTF-8: {error}.")
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError as error:
        refuse(f"{label} is malformed JSON: {error}.")
    if not isinstance(parsed, dict):
        refuse(f"{label} is not a JSON object.")
    hooks = parsed.get("hooks")
    if hooks is None:
        return parsed
    if not isinstance(hooks, dict):
        refuse(f"{label} has an unexpected non-object 'hooks' value.")
    events = hooks.get("events")
    if events is None:
        return parsed
    if not isinstance(events, dict):
        refuse(f"{label} has an unexpected non-object 'hooks.events' value.")
    for name, entries in events.items():
        if not isinstance(entries, list):
            refuse(f"{label} has an unexpected non-array hooks.events.{name} value.")
        for entry in entries:
            if not isinstance(entry, dict):
                refuse(f"{label} has a non-object hooks.events.{name} entry.")
            inner = entry.get("hooks")
            if not isinstance(inner, list):
                refuse(f"{label} has a hooks.events.{name} entry without a hooks array.")
            for hook in inner:
                if not isinstance(hook, dict):
                    refuse(f"{label} has a non-object hook in hooks.events.{name}.")
                command = hook.get("command")
                if not isinstance(command, str) or not command:
                    refuse(f"{label} has a hook without a command in hooks.events.{name}.")
    return parsed


def firstmate_entry() -> dict:
    return {"hooks": [{"type": "command", "command": HOOK_COMMAND, "timeout": 10}]}


def strip_firstmate(parsed: dict, only_owned_events: bool) -> dict:
    hooks = parsed.get("hooks")
    if not isinstance(hooks, dict):
        return parsed
    events = hooks.get("events")
    if not isinstance(events, dict):
        return parsed
    for name in list(events):
        if only_owned_events and name not in FIRSTMATE_EVENTS:
            continue
        entries = events[name]
        if not isinstance(entries, list):
            continue
        kept = [entry for entry in entries if not entry_is_firstmate(entry)]
        if len(kept) != len(entries):
            if kept:
                events[name] = kept
            else:
                del events[name]
    if not events:
        del hooks["events"]
    return parsed


def install_into(parsed: dict) -> dict:
    hooks = parsed.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        refuse("config.json has an unexpected non-object 'hooks' value.")
    # The runtime gates every hook source on this switch (the shipped
    # config.example.json defaults it to false), so install raises it. A
    # captain who wants hooks off removes this Firstmate region; the value
    # itself is left untouched on remove because the pre-install value is
    # not recorded anywhere durable.
    hooks["enabled"] = True
    events = hooks.setdefault("events", {})
    if not isinstance(events, dict):
        refuse("config.json has an unexpected non-object 'hooks.events' value.")
    for name in FIRSTMATE_EVENTS:
        entries = events.setdefault(name, [])
        if not isinstance(entries, list):
            refuse(f"config.json has an unexpected non-array hooks.events.{name} value.")
        kept = [entry for entry in entries if not entry_is_firstmate(entry)]
        kept.append(firstmate_entry())
        events[name] = kept
    return parsed


def serialize(parsed: dict) -> bytes:
    return (json.dumps(parsed, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def atomic_write(path: str, data: bytes, mode: int) -> None:
    fd, temporary = tempfile.mkstemp(prefix=f".{os.path.basename(path)}.", dir=os.path.dirname(path))
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as stream:
            fd = -1
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    except Exception:
        if fd >= 0:
            os.close(fd)
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def validate_firstmate_files_for_remove() -> None:
    if os.path.lexists(HOOK):
        info = regular_not_symlink(HOOK, "Firstmate hook script")
        with open(HOOK, "rb") as stream:
            if stream.read() != HOOK_BYTES:
                refuse(f"Firstmate hook script has unexpected content at {HOOK}.")
        if stat.S_IMODE(info.st_mode) & 0o077:
            refuse(f"Firstmate hook script has unexpectedly broad permissions at {HOOK}.")
    if os.path.lexists(REGISTRY):
        info = os.lstat(REGISTRY)
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            refuse(f"Firstmate registry is not a regular directory at {REGISTRY}.")
        for name in os.listdir(REGISTRY):
            path = os.path.join(REGISTRY, name)
            child = os.lstat(path)
            if not TOKEN_NAME.fullmatch(name) or stat.S_ISLNK(child.st_mode) or not stat.S_ISREG(child.st_mode):
                refuse(f"Firstmate registry contains an unexpected entry at {path}.")


try:
    if not os.path.isdir(CONFIG_DIR) or os.path.islink(CONFIG_DIR):
        refuse(f"zcode config directory is missing or unexpected at {CONFIG_DIR}.")
    config_info = regular_not_symlink(CONFIG, "zcode config")
    with open(CONFIG, "rb") as stream:
        original = stream.read()
    parsed = parse_and_validate(original, "config.json")

    if ACTION == "install":
        # kimi parity: a Firstmate hook reference in an event this installer
        # does not own is a surprise, refused rather than silently rewritten.
        foreign_elsewhere = any(
            name not in FIRSTMATE_EVENTS
            and isinstance(entries, list)
            and any(entry_is_firstmate(entry) for entry in entries)
            for name, entries in parsed.get("hooks", {}).get("events", {}).items()
            if isinstance(entries, list)
        )
        if foreign_elsewhere:
            refuse(
                "config.json references fm-turn-end.sh in a hook event Firstmate does not own."
            )
        stripped = strip_firstmate(json.loads(json.dumps(parsed)), True)
        candidate = serialize(install_into(stripped))
        parse_and_validate(candidate, "updated config.json")
        os.makedirs(REGISTRY, mode=0o700, exist_ok=True)
        os.chmod(REGISTRY, 0o700)
        installed_hook = None
        if os.path.exists(HOOK):
            with open(HOOK, "rb") as stream:
                installed_hook = stream.read()
            if installed_hook != HOOK_BYTES and not installed_hook.startswith(
                b"#!/usr/bin/env bash\n# Firstmate zcode turn-end"
            ):
                refuse(f"Firstmate hook path has unexpected content at {HOOK}.")
        if installed_hook != HOOK_BYTES:
            atomic_write(HOOK, HOOK_BYTES, 0o700)
        if candidate != original:
            atomic_write(CONFIG, candidate, stat.S_IMODE(config_info.st_mode))
    else:
        validate_firstmate_files_for_remove()
        candidate = serialize(strip_firstmate(parsed, False))
        parse_and_validate(candidate, "config.json after Firstmate hook removal")
        if candidate != original:
            atomic_write(CONFIG, candidate, stat.S_IMODE(config_info.st_mode))
        if os.path.lexists(HOOK):
            os.unlink(HOOK)
        if os.path.lexists(REGISTRY):
            shutil.rmtree(REGISTRY)
except OSError as error:
    refuse(f"filesystem operation failed: {error}.")
PY
