#!/usr/bin/env bash
# zcode process identity.
# Sourced by bin/fm-agent-process-lib.sh, bin/fm-session-lock-lib.sh, and
# bin/fm-harness.sh. This file is sourced by scripts and has no side effects on
# source.
#
# Why one owner: zcode's wrapper bin is a node script, so a live zcode process
# can present as a bare interpreter exactly like gemini's bundle - the command
# name is `node` and only the script argument carries the identity (observed on
# zcode-app-cli 3.11.2-24 wrapping zcode-runtime 0.16.5 with Node 22.22.3).
# Every consumer that must decide "is this process zcode" from a path or a
# command line reads the same structural rule from here, so the pane-liveness
# classifier, the session-lock ancestry walk, and the own-harness detector can
# never drift into disagreeing. The rule is the same shape as
# bin/fm-gemini-lib.sh's: structural only, and only argv[0] and the script
# argument are ever consulted, so an unrelated command line that merely
# mentions zcode in a later argument never matches.

# True when path $1 carries zcode's structural evidence: the file is named
# zcode, or it sits inside the published zcode-app-cli package tree.
fm_zcode_path_is_zcode() {  # <path>
  local path=$1
  [ -n "$path" ] || return 1
  case "$path" in
    -*) return 1 ;;
  esac
  case "${path##*/}" in
    zcode) return 0 ;;
  esac
  case "$path" in
    */zcode-app-cli/*) return 0 ;;
  esac
  return 1
}

# True when the whitespace-separated command line $1 is a zcode process:
# a command whose own argv[0] is zcode (the bin run directly), and an
# interpreter whose first non-flag argument is zcode's bin or package path -
# the exact shape the wrapper's shebang execs (`node /usr/lib/node_modules/
# zcode-app-cli/bin/zcode --mode yolo ...`).
fm_zcode_args_are_zcode() {  # <args>
  local args=$1 argv0 rest token
  [ -n "$args" ] || return 1
  args=${args#"${args%%[![:space:]]*}"}
  argv0=${args%%[[:space:]]*}
  fm_zcode_path_is_zcode "$argv0" && return 0
  case "${argv0##*/}" in
    node|node-*|node[0-9]*|MainThread) ;;
    *) return 1 ;;
  esac
  rest=${args#"$argv0"}
  # The first non-flag token after the interpreter is the script it runs,
  # skipping the interpreter's own options exactly like the gemini rule.
  while [ -n "$rest" ]; do
    rest=${rest#"${rest%%[![:space:]]*}"}
    [ -n "$rest" ] || break
    token=${rest%%[[:space:]]*}
    rest=${rest#"$token"}
    case "$token" in
      -*) continue ;;
    esac
    fm_zcode_path_is_zcode "$token" && return 0
    return 1
  done
  return 1
}
